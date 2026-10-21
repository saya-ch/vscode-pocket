# CodeRemote

**把桌面版 VS Code 变成可在浏览器 / 平板上使用的完整远程 IDE —— 桌面插件、终端、调试全部可用。**

> English: [../README.md](../README.md)

---

## 为什么做这个

VS Code 官方的 `serve-web` 只加载那约 25 个提供了 **browser 入口**的扩展。如果你的工作流依赖桌面插件(AI 助手、语言服务、数据库客户端、主题包),`serve-web` 会把它们**默默丢掉**,而且不报错。

[code-server](https://github.com/coder/code-server) 换了一条路:它在**服务器上跑真正的 Node 扩展宿主**,所以桌面插件能**原样运行**。把 `extensions-dir` 指向你桌面版已经在用的 `~/.vscode/extensions`,浏览器里看到的就是你熟悉的那一整套,一个不少。

CodeRemote 补的是 code-server 周边缺的那层运维能力:

- **双击即用**,关掉窗口全部服务立即停止(内核级保证,不留孤儿进程)。
- **不需要输密码**。令牌写在 URL 里,存个书签就够了。
- **默认 HTTPS** —— 这不是"更安全一点",而是**没有 HTTPS 整个方案就是废的**(见下)。
- **安卓壳 App**,打开直接进沉浸全屏。

---

## 核心功能

| | |
|---|---|
| **完整桌面插件** | code-server 的 Node 扩展宿主原生运行它们,并与桌面版共用扩展目录 |
| **集成终端** | 真实的 PTY,浏览器里直接敲 |
| **调试** | Node / Java / Python 等调试器表现与本地一致 |
| **令牌写在 URL** | `https://host:port/?k=<token>` 种一个长期 cookie,无需登录表单 |
| **零残留进程** | 子进程绑定 Windows **Job Object**(`KILL_ON_JOB_CLOSE`),关窗即全灭,不占端口 |
| **双通道** | 局域网 IPv6 直连(快)+ 可选 Cloudflare 隧道(离校可用) |
| **安卓 App** | URL 输入 + 历史记录、沉浸全屏、支持外接键盘,APK 见 [`apk/`](../apk/) |

---

## 架构

```
                    ┌──────────────────────────────────────────────┐
  浏览器 / 平板      │  HTTPS(本地 CA 签发,详见下文)                │
        │           └──────────────────────────────────────────────┘
        ▼
  ┌─────────────────────────────┐
  │ proxy/proxy.js             │   反向代理
  │  · :8092 双栈 [::]          │
  │  · TLS 终止                 │
  │  · 令牌 → cookie            │
  └──────────┬─────────────────┘
             │ HTTP,仅环回
             ▼
  ┌─────────────────────────────┐
  │ code-server                │   127.0.0.1:8091, auth: none
  │  · Node 扩展宿主            │   ← 桌面插件能用的根本原因
  │  · extensions-dir ─────────┼──▶ ~/.vscode/extensions(与桌面共用)
  └─────────────────────────────┘

  可选:Cloudflare 隧道 ──▶ https://code.example.com ──▶ proxy:8092
```

code-server **只监听环回地址**且 `auth: none`,外部无法直连,鉴权完全收敛在代理这一层。

---

## 环境要求

- **Windows 10/11**(启动器依赖 Win32 Job Object;代理和 App 本身跨平台)
- **Node.js ≥ 18**(仅 `npm install` 用,运行时用 code-server 自带的 Node)
- **[code-server](https://github.com/coder/code-server/releases)** 解压到 `./code-server/`(实测 4.141.0)
- **桌面版 VS Code**(可选,推荐 —— 用于共享扩展目录)
- **Android 8+**(可选)

---

## 快速开始

```powershell
git clone https://github.com/saya-ch/coderemote.git
cd coderemote

# 1. 下载 code-server 解压为 ./code-server/
#    https://github.com/coder/code-server/releases → code-server-<ver>-windows-amd64

# 2. 安装代理依赖
cd proxy
npm install
cd ..

# 3. 启动
.\Launch.cmd
```

窗口会打印类似:

```
  【局域网 / 校园网】最快:

    https://[2001:db8::1]:8092/?k=3f9c...e21a

  关闭本窗口 → 服务立即停止
```

打开即可。首次访问浏览器会提示证书不受信任 —— 接受一次(证书是**你自己生成的本地 CA** 签的)。

令牌首次运行时自动生成,存于 `config/access-token.txt`;删掉该文件即可轮换。其余配置全部运行时生成,不需要手改。

### 参数

```powershell
.\Launch.cmd -CsPort 8091 -ProxyPort 8092 -NoDesktopExtensions
.\Launch.cmd -TunnelName coderemote      # 同时启动 Cloudflare 隧道
```

---

## HTTPS 陷阱(这是整件事的关键)

**用明文 `http://` 且不是 `localhost` 访问 VS Code,所有 WebView 会静默失效。**

你会看到:

```
Error: 'crypto.subtle' is not available so webviews will not work.
This is likely because the editor is not running in a secure context.
```

以及任何带侧边栏的插件(AI 助手最常见)报:

```
Codex could not start its user interface.
[CodexWebviewProvider] Webview renderer did not become ready
  reason=renderer_ready_timeout receivedWebviewMessage=false
```

**原因**:`crypto.subtle` 只在[安全上下文](https://developer.mozilla.org/en-US/docs/Web/Security/Secure_Contexts)可用 —— 即 `https://` 或 `http://localhost`。VS Code 的 WebView 用它加密 postMessage 通道。没有安全上下文 → 没有 WebView → 所有往 WebView 里渲染 UI 的插件全废。**而编辑器、终端、文件树全都正常**,所以极具迷惑性。

**第二个坑,在安卓上更致命。** 你可能想到用自签证书。桌面浏览器能点"继续"绕过,但安卓 WebView 不行:

```
Webview fatal error: Could not register service worker:
  SecurityError: Failed to register a ServiceWorker
  ... net_error -202                      ← ERR_CERT_AUTHORITY_INVALID
```

VS Code 的 WebView 资源全靠 **Service Worker** 加载,而 **SW 脚本的加载不受 `WebViewClient.onReceivedSslError` 的 `proceed()` 豁免** —— 没有点击绕过的可能。不受信任的证书就是注册不了 SW。

### CodeRemote 怎么解决

**固定的本地 CA** + **每次启动重签的服务器证书**:

```
proxy/certs/ca.pem        ← 只生成一次,15 年有效,永不变化
proxy/certs/cert.pem      ← 每次启动重签,SAN 里带当前所有 IPv6
```

CA 固定 → 每个设备**只装一次**;服务器证书每次重签 → 永远带着**当下的**地址,IP 变了也不会失效。

在手机/平板上装 CA:

```
设置 → 安全 → 加密与凭据
     → 安装证书 → CA 证书
     → (警告)仍然安装
     → 选择 coderemote-ca.pem
```

App 里声明了 `android:networkSecurityConfig` 并带 `<certificates src="user" />`,否则 Android 7+ 会忽略用户安装的 CA。

> **捷径**:走 Cloudflare 隧道(`-TunnelName`)时用的是**公共信任证书**,设备上不用装 CA。只有想走更快的局域网直连才需要装。

---

## 两种访问方式

| 方式 | 证书 | 适用 | 设备需装 CA |
|---|---|---|---|
| IPv6 直连(局域网/校园网) | 本地 CA | 延迟最低,离线可用 | 需要 |
| Cloudflare 隧道 | 公共 CA | 任何网络,设备零配置 | 不需要 |

两者都终结在同一个代理,所以**都必须带 `?k=` 令牌**,否则返回 403。

---

## 安卓 App

[`android/`](../android/) 是一个 ~2 MB 的 WebView 壳。[`apk/CodeRemote.apk`](../apk/CodeRemote.apk) 是预编译的 **debug 签名**版本,适合自用侧载,不适合分发。

```bash
adb install -r apk/CodeRemote.apk
```

- URL 输入 + 粘贴按钮 + 6 条历史记录(长按删除)
- 自动填入上次的链接;剪贴板里是链接时自动填入
- 沉浸全屏:隐藏系统栏,边缘滑动可临时呼出
- `adjustResize` + 外接键盘支持
- 返回键:先走网页历史,到根目录再弹「换链接 / 退出」
- 信任本地 CA(`network_security_config`),页面级 SSL 错误放行
- `FLAG_KEEP_SCREEN_ON`,长时间会话不熄屏

自行构建:

```bash
cd android
gradlew.bat assembleDebug      # Windows
./gradlew assembleDebug        # Linux / macOS
```

`android/local.properties` 需指向你的 SDK,已 gitignore。

---

## 目录结构

```
coderemote/
├── Launch.cmd              双击启动
├── scripts/Launch.ps1      真正的启动器:Job Object、端口、证书、URL
├── proxy/
│   ├── proxy.js            HTTPS 反向代理 + 令牌鉴权
│   ├── gencert.js          固定 CA + 每次重签的服务器证书
│   └── package.json
├── config/
│   └── tunnel.yml.sample   可选 Cloudflare 隧道配置
├── android/                安卓 WebView 壳
├── apk/CodeRemote.apk      预编译,debug 签名
└── docs/
    ├── ARCHITECTURE.md
    ├── TROUBLESHOOTING.md  ← 出问题先看这个
    └── README.zh-CN.md
```

运行时生成、**不入库**:`proxy/certs/`、`proxy/node_modules/`、`config/code-server.yaml`、`config/access-token.txt`、`config/tunnel.yml`、`logs/`、`data/`。

---

## 安全须知

这是**个人远程开发工具**,请理解取舍后再暴露。

- **code-server 跑在 `auth: none`** —— 安全的前提是它只绑 `127.0.0.1`。**永远不要把 `bind-addr` 改成 `0.0.0.0`**。
- **令牌是 URL 里的 bearer 凭据**,会进浏览器历史和剪贴板。删 `config/access-token.txt` 可轮换。
- **CA 私钥**(`proxy/certs/ca-key.pem`)在服务器上。拿到它的人可以签发你的设备会信任的证书。像对待 SSH 私钥一样对待它;删除 `proxy/certs/` 可重来(之后所有设备需装新 CA)。
- **这里的 HTTPS 是为了让浏览器 API 可用,不是为了抵御敌对网络**。能连到端口的人仍然需要令牌,但请据此判断是否要在公网暴露。
- **没有速率限制 / 封禁**,家用局域网没问题,公网地址上要谨慎。
- APK 是 **debug 签名**,不要分发,要发布请自行构建并签名。
- App 对页面级 SSL 错误做了放行以适配本地 CA。如果你只用公共 CA 通道,建议去掉这个 override。

---

## 已知限制

- 启动器仅 Windows(Win32 Job Object、`netstat`、`Get-NetIPAddress`)。代理和 App 可移植;移植启动器需要等效的进程组 / subreaper 机制。
- 插件兼容性是 code-server 的范畴,不是 CodeRemote 的。少数强依赖桌面独有 API 的插件在任何浏览器宿主里都会降级 —— 请查 code-server 的 issue。
- `apk/` 里的图标取自 VS Code 的 logo,仅为个人使用方便。**与 Microsoft 无关联、未获其背书**。再分发前请替换。

---

## 许可证

[MIT](../LICENSE)
