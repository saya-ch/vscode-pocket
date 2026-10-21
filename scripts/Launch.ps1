#Requires -Version 5.1
<#
.SYNOPSIS
    CodeRemote 启动器 — 把本机 VS Code 暴露成浏览器可用的完整开发环境。

.DESCRIPTION
    窗口关闭 = 服务立即停止(用 Windows Job Object 保证子进程被回收)。

    链路:
        浏览器 --HTTPS(本地 CA 签发)--> 反向代理(令牌鉴权) --HTTP--> code-server

    必须走 HTTPS:浏览器的 crypto.subtle 只在安全上下文可用,
    明文 HTTP + 非 localhost 会让 VS Code 所有 WebView 失效。

.PARAMETER CsPort
    code-server 内部端口(仅监听 127.0.0.1)。

.PARAMETER ProxyPort
    对外 HTTPS 端口。

.PARAMETER TunnelName
    可选。Cloudflare 隧道名称,留空则不启动隧道。

.PARAMETER SystemExtensions
    清空后只加载 code-server 自带扩展,不共享桌面版 VS Code 的扩展。

.EXAMPLE
    .\Launch.ps1

.EXAMPLE
    .\Launch.ps1 -ProxyPort 9443 -TunnelName vscode
#>
[CmdletBinding()]
param(
    [int]$CsPort = 8091,
    [int]$ProxyPort = 8092,
    [string]$TunnelName = '',
    [switch]$NoDesktopExtensions
)

$ErrorActionPreference = 'Stop'

$Root      = Split-Path -Parent $PSScriptRoot
$Logs      = Join-Path $Root 'logs'
$ConfigDir = Join-Path $Root 'config'
$ProxyDir  = Join-Path $Root 'proxy'
$DataDir   = Join-Path $Root 'data'
foreach ($d in @($Logs, $ConfigDir, $DataDir)) {
    New-Item -ItemType Directory -Force -Path $d | Out-Null
}

# =========================================================
# Job Object:窗口关闭/进程退出时,系统强制回收所有子进程
# =========================================================
if (-not ('CodeRemoteJob' -as [type])) {
    Add-Type -Namespace '' -Name 'CodeRemoteJob' -MemberDefinition @'
    [StructLayout(LayoutKind.Sequential)] public struct BASIC { public long PerProcessUserTimeLimit; public long PerJobUserTimeLimit; public uint LimitFlags; public UIntPtr MinimumWorkingSetSize; public UIntPtr MaximumWorkingSetSize; public uint ActiveProcessLimit; public UIntPtr Affinity; public uint PriorityClass; public uint SchedulingClass; }
    [StructLayout(LayoutKind.Sequential)] public struct IOCounters { public ulong ReadOperationCount; public ulong WriteOperationCount; public ulong OtherOperationCount; public ulong ReadTransferCount; public ulong WriteTransferCount; public ulong OtherTransferCount; }
    [StructLayout(LayoutKind.Sequential)] public struct EXTENDED { public BASIC Basic; public IOCounters IoInfo; public UIntPtr ProcessMemoryLimit; public UIntPtr JobMemoryLimit; public UIntPtr PeakProcessMemoryUsed; public UIntPtr PeakJobMemoryUsed; }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr CreateJobObject(IntPtr a, string n);
    [DllImport("kernel32.dll")] public static extern bool SetInformationJobObject(IntPtr h, int c, IntPtr i, uint l);
    [DllImport("kernel32.dll")] public static extern bool AssignProcessToJobObject(IntPtr j, IntPtr p);
    [DllImport("kernel32.dll")] public static extern IntPtr OpenProcess(uint a, bool i, int p);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
    public static IntPtr CreateKillOnCloseJob() {
        IntPtr job = CreateJobObject(IntPtr.Zero, null);
        var ext = new EXTENDED();
        ext.Basic.LimitFlags = 0x2000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        int len = Marshal.SizeOf(ext);
        IntPtr p = Marshal.AllocHGlobal(len);
        Marshal.StructureToPtr(ext, p, false);
        SetInformationJobObject(job, 9, p, (uint)len); // 9 = ExtendedLimitInformation
        Marshal.FreeHGlobal(p);
        return job;
    }
    public static void Add(IntPtr job, int pid) {
        IntPtr h = OpenProcess(0x0100 or 0x0001, false, pid); // PROCESS_SET_QUOTA|PROCESS_TERMINATE
        if (h != IntPtr.Zero) { AssignProcessToJobObject(job, h); CloseHandle(h); }
    }
'@
}
$Job = [CodeRemoteJob]::CreateKillOnCloseJob()
function Add-ToJob([int]$ProcessId) {
    if ($ProcessId -gt 0) { try { [CodeRemoteJob]::Add($Job, $ProcessId) } catch { } }
}

# =========================================================
# 辅助函数
# =========================================================
function Test-PortListening([int]$Port) {
    foreach ($proto in @('TCP', 'TCPv6')) {
        if (netstat -ano -p $proto | Select-String ":$Port\s+.*LISTENING") { return $true }
    }
    return $false
}

function Wait-PortUp([int]$Port, [int]$TimeoutSec) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        if (Test-PortListening $Port) { return $true }
        Start-Sleep -Milliseconds 300
    }
    return $false
}

function Wait-PortFree([int]$Port, [int]$TimeoutSec) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        if (-not (Test-PortListening $Port)) { return $true }
        Start-Sleep -Milliseconds 300
    }
    return $false
}

function Get-GlobalIPv6 {
    try {
        return @(Get-NetIPAddress -AddressFamily IPv6 -PrefixOrigin RouterAdvertisement -ErrorAction Stop |
            Where-Object { $_.IPAddress -notlike 'fe80*' -and $_.IPAddress -ne '::1' } |
            Select-Object IPAddress, PrefixLength, @{N = 'IsStable'; E = { $_.PrefixLength -eq 64 } })
    } catch {
        return @()
    }
}

Write-Host ''
Write-Host '  ================================================' -ForegroundColor Cyan
Write-Host '   CodeRemote — VS Code in your browser' -ForegroundColor Cyan
Write-Host '   关闭此窗口 = 停止服务' -ForegroundColor DarkGray
Write-Host '  ================================================' -ForegroundColor Cyan
Write-Host ''

# =========================================================
# 1. 清理残留端口
# =========================================================
foreach ($p in @($CsPort, $ProxyPort)) {
    if (Test-PortListening $p) {
        Write-Host ("  清理端口 {0} 上的旧进程..." -f $p) -ForegroundColor DarkGray
        foreach ($proto in @('TCP', 'TCPv6')) {
            foreach ($line in (netstat -ano -p $proto | Select-String ":$p\s")) {
                $parts = ($line.ToString() -split '\s+' | Where-Object { $_ -ne '' })
                if ($parts -contains 'LISTENING') {
                    Stop-Process -Id ([int]$parts[-1]) -Force -ErrorAction SilentlyContinue
                }
            }
        }
        $null = Wait-PortFree $p 20
    }
}

# =========================================================
# 2. 定位 code-server 与 Node
# =========================================================
$CsHome = $env:CODE_SERVER_HOME
if (-not $CsHome) {
    foreach ($cand in @((Join-Path $Root 'code-server'), (Join-Path $env:USERPROFILE 'code-server'))) {
        if (Test-Path $cand) { $CsHome = $cand; break }
    }
}
if (-not $CsHome) {
    Write-Host '  [X] 找不到 code-server。' -ForegroundColor Red
    Write-Host '      请把 code-server 解压到本目录下的 code-server\ 子目录,' -ForegroundColor DarkGray
    Write-Host '      或设置环境变量 CODE_SERVER_HOME。' -ForegroundColor DarkGray
    Write-Host ''
    Read-Host '  按回车退出'
    exit 1
}

$CsExe = @(
    (Join-Path $CsHome 'bin\code-server.cmd'),
    (Join-Path $CsHome 'bin\code-server')
) | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $CsExe) {
    Write-Host ("  [X] {0}\bin 下找不到 code-server 可执行文件" -f $CsHome) -ForegroundColor Red
    Read-Host '  按回车退出'
    exit 1
}

$NodeExe = Join-Path $CsHome 'lib\node.exe'
if (-not (Test-Path $NodeExe)) {
    $n = Get-Command node -ErrorAction SilentlyContinue
    if ($n) { $NodeExe = $n.Source }
}
if (-not $NodeExe) {
    Write-Host '  [X] 找不到 Node.js' -ForegroundColor Red
    Read-Host '  按回车退出'
    exit 1
}

# =========================================================
# 3. 令牌(首次自动生成,之后固定,便于收藏链接长期有效)
# =========================================================
$TokenFile = Join-Path $ConfigDir 'access-token.txt'
if (-not (Test-Path $TokenFile)) {
    $bytes = New-Object byte[] 16
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    ($bytes | ForEach-Object { $_.ToString('x2') }) -join '' | Set-Content -Path $TokenFile -NoNewline -Encoding ascii
    Write-Host '  已生成访问令牌(保存在 config\access-token.txt)' -ForegroundColor DarkGray
}
$Token = (Get-Content $TokenFile -Raw).Trim()

# =========================================================
# 4. 运行时生成 code-server 配置
# =========================================================
$ExtDir = $env:CODE_REMOTE_EXTENSIONS
if (-not $ExtDir) {
    $desktopExt = Join-Path $env:USERPROFILE '.vscode\extensions'
    if ((-not $NoDesktopExtensions) -and (Test-Path $desktopExt)) {
        # 直接复用桌面版 VS Code 的扩展目录 → 桌面插件在浏览器里也能用
        $ExtDir = $desktopExt
    } else {
        $ExtDir = Join-Path $DataDir 'extensions'
    }
}
$UserDataDir = Join-Path $DataDir 'code-server'

$CsCfg = Join-Path $ConfigDir 'code-server.yaml'
@"
# 由 Launch.ps1 自动生成 —— 请勿手改(每次启动会覆盖)
bind-addr: 127.0.0.1:$CsPort
auth: none
cert: false
extensions-dir: $($ExtDir -replace '\\', '/')
user-data-dir: $($UserDataDir -replace '\\', '/')
disable-telemetry: true
disable-update-check: true
trusted-origins: "*"
"@ | Set-Content -Path $CsCfg -Encoding utf8

# =========================================================
# 5. 启动 code-server(仅环回)
# =========================================================
Write-Host '  启动 code-server...' -ForegroundColor DarkGray
$csProc = Start-Process $CsExe -ArgumentList @('--config', $CsCfg) -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput (Join-Path $Logs 'code-server.out.log') `
    -RedirectStandardError  (Join-Path $Logs 'code-server.err.log')
if ($csProc) { Add-ToJob $csProc.Id }

if (-not (Wait-PortUp $CsPort 60)) {
    Write-Host '  [X] code-server 启动失败,日志:' -ForegroundColor Red
    Write-Host ("      {0}\code-server.err.log" -f $Logs) -ForegroundColor DarkGray
    Write-Host ''
    Read-Host '  按回车退出'
    exit 1
}
Write-Host '  [OK] code-server 已启动' -ForegroundColor Green

# =========================================================
# 6. 生成 HTTPS 证书(固定 CA + 每次重签的服务器证书)
#
#    为什么必须 CA:
#    Android WebView 的 Service Worker 只接受「受信任 CA 签发」的证书,
#    onReceivedSslError 的 proceed() 对 SW 脚本无效。
# =========================================================
$v6 = @(Get-GlobalIPv6)
$CertDir  = Join-Path $ProxyDir 'certs'
$CertFile = Join-Path $CertDir 'cert.pem'
$KeyFile  = Join-Path $CertDir 'key.pem'
$CaFile   = Join-Path $CertDir 'ca.pem'

Write-Host '  生成 HTTPS 证书...' -ForegroundColor DarkGray
$env:CERT_DIR = $CertDir
$ipArgs = @()
foreach ($a in $v6) { $ipArgs += $a.IPAddress }
& $NodeExe (Join-Path $ProxyDir 'gencert.js') @ipArgs *> (Join-Path $Logs 'gencert.log')

if (-not ((Test-Path $CertFile) -and (Test-Path $KeyFile))) {
    Write-Host '  [X] 证书生成失败。请先在 proxy 目录执行 npm install' -ForegroundColor Red
    Get-Content (Join-Path $Logs 'gencert.log') -ErrorAction SilentlyContinue | Select-Object -Last 8 | ForEach-Object { "      $_" }
    Read-Host '  按回车退出'
    exit 1
}
Write-Host '  [OK] 证书就绪' -ForegroundColor Green

# =========================================================
# 7. 启动反向代理(HTTPS + 令牌)
# =========================================================
Write-Host '  启动反向代理...' -ForegroundColor DarkGray
$env:PROXY_HOST     = '::'
$env:PROXY_PORT     = "$ProxyPort"
$env:PROXY_TARGET   = "http://127.0.0.1:$CsPort"
$env:PROXY_TOKEN    = $Token
$env:PROXY_TLS_CERT = $CertFile
$env:PROXY_TLS_KEY  = $KeyFile

$proxyProc = Start-Process $NodeExe -ArgumentList @((Join-Path $ProxyDir 'proxy.js')) -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput (Join-Path $Logs 'proxy.out.log') `
    -RedirectStandardError  (Join-Path $Logs 'proxy.err.log')
if ($proxyProc) { Add-ToJob $proxyProc.Id }

if (-not (Wait-PortUp $ProxyPort 30)) {
    Write-Host '  [X] 反向代理启动失败,日志:' -ForegroundColor Red
    Get-Content (Join-Path $Logs 'proxy.err.log') -ErrorAction SilentlyContinue | Select-Object -Last 8 | ForEach-Object { "      $_" }
    Write-Host ''
    Read-Host '  按回车退出'
    exit 1
}
Write-Host '  [OK] 反向代理已启动' -ForegroundColor Green

# =========================================================
# 8. 可选:Cloudflare 隧道(离校/公网访问)
# =========================================================
$TunnelUrl = $null
$CfCfg = Join-Path $ConfigDir 'tunnel.yml'
if ($TunnelName -and (Test-Path $CfCfg)) {
    $CfExe = @(
        (Join-Path $env:USERPROFILE '.cloudflared\bin\cloudflared.exe'),
        'cloudflared.exe'
    ) | Where-Object {
        if ($_.Contains('\')) { Test-Path $_ } else { Get-Command $_ -ErrorAction SilentlyContinue }
    } | Select-Object -First 1

    if ($CfExe) {
        Write-Host '  启动 Cloudflare 隧道...' -ForegroundColor DarkGray
        $cfProc = Start-Process $CfExe -ArgumentList @('--config', $CfCfg, 'tunnel', 'run', $TunnelName) -WindowStyle Hidden -PassThru `
            -RedirectStandardOutput (Join-Path $Logs 'tunnel.out.log') `
            -RedirectStandardError  (Join-Path $Logs 'tunnel.err.log')
        if ($cfProc) { Add-ToJob $cfProc.Id }
        # 从配置里读 hostname
        $m = Select-String -Path $CfCfg -Pattern '^\s*-\s*hostname:\s*(\S+)' | Select-Object -First 1
        if ($m) { $TunnelUrl = 'https://' + $m.Matches[0].Groups[1].Value }
        Write-Host '  [OK] 隧道已启动' -ForegroundColor Green
    } else {
        Write-Host '  [!] 未找到 cloudflared,跳过隧道' -ForegroundColor Yellow
    }
}
Write-Host ''

# =========================================================
# 9. 输出链接
# =========================================================
Write-Host '  ------------------------------------------------' -ForegroundColor DarkGray
Write-Host '   打开下面任一链接,无需手动输密码' -ForegroundColor Yellow
Write-Host '  ------------------------------------------------' -ForegroundColor DarkGray
Write-Host ''

$primaryUrl = $null
if ($v6.Count -gt 0) {
    $primary = $v6 | Where-Object { $_.IsStable } | Select-Object -First 1
    if (-not $primary) { $primary = $v6[0] }
    $primaryUrl = "https://[" + $primary.IPAddress + "]:" + $ProxyPort + "/?k=" + $Token

    Write-Host '  【局域网 / 校园网】最快:' -ForegroundColor Yellow
    Write-Host ''
    Write-Host ('    ' + $primaryUrl) -ForegroundColor Cyan
    Write-Host ''

    $others = @($v6 | Where-Object { $_.IPAddress -ne $primary.IPAddress })
    foreach ($o in $others) {
        Write-Host ('    备用: https://[' + $o.IPAddress + ']:' + $ProxyPort + '/?k=' + $Token) -ForegroundColor DarkGray
    }
    if ($others.Count -gt 0) { Write-Host '' }
} else {
    Write-Host '  [!] 未检测到公网 IPv6' -ForegroundColor Yellow
    Write-Host ''
}

if ($TunnelUrl) {
    $link = $TunnelUrl + '/?k=' + $Token
    Write-Host '  【任意网络】离校也能用:' -ForegroundColor Yellow
    Write-Host ''
    Write-Host ('    ' + $link) -ForegroundColor Cyan
    Write-Host ''
    if (-not $primaryUrl) { $primaryUrl = $link }
}

Write-Host '  ------------------------------------------------' -ForegroundColor DarkGray
Write-Host '   关闭本窗口 → 服务立即停止' -ForegroundColor DarkGray
if (Test-Path $CaFile) {
    Write-Host '' -ForegroundColor DarkGray
    Write-Host '   手机/平板首次使用需安装 CA 证书:' -ForegroundColor Yellow
    Write-Host ('     ' + $CaFile) -ForegroundColor DarkGray
    Write-Host '   设置 → 安全 → 加密与凭据 → 安装证书 → CA 证书' -ForegroundColor DarkGray
}
Write-Host '  ------------------------------------------------' -ForegroundColor DarkGray
Write-Host ''

if ($primaryUrl) {
    try {
        Set-Clipboard -Value $primaryUrl
        Write-Host '  [OK] 链接已复制到剪贴板' -ForegroundColor Green
        Write-Host ''
    } catch { }
}

# =========================================================
# 10. 保持窗口(关窗即触发 Job 清理)
# =========================================================
try {
    while ($true) {
        Start-Sleep -Seconds 2
        if ($csProc -and $csProc.HasExited) {
            Write-Host '  code-server 意外退出,停止服务' -ForegroundColor Red
            break
        }
    }
} finally {
    if ($Job -ne [IntPtr]::Zero) { [CodeRemoteJob]::CloseHandle($Job) | Out-Null }
}
