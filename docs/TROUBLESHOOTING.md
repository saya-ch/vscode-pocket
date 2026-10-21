# Troubleshooting

Every entry here is a failure that actually happened during development. Each is
written as **symptom → cause → fix**, because the symptoms are misleading.

---

## 1. `'crypto.subtle' is not available so webviews will not work`

```
Error: 'crypto.subtle' is not available so webviews will not work.
This is likely because the editor is not running in a secure context.
```

**Cause.** You are serving VS Code over plain HTTP from a non-`localhost`
origin. The Web Crypto API is gated behind [secure contexts](https://developer.mozilla.org/en-US/docs/Web/Security/Secure_Contexts):

| Origin | Secure context | `crypto.subtle` |
|---|---|---|
| `https://anything` | yes | available |
| `http://localhost` / `http://127.0.0.1` | yes | available |
| `http://[2001:db8::1]:8092` | **no** | **undefined** |
| `http://192.168.1.10:8080` | **no** | **undefined** |

VS Code encrypts the webview postMessage channel with `crypto.subtle`. Without
it, the workbench refuses to create webviews.

**Fix.** Serve HTTPS. CodeRemote's proxy terminates TLS with a locally-signed
certificate (see §3). Do not "fix" this by adding `--ignore-certificate-errors`
to a browser — that does not change the security context.

**Why it is confusing.** Everything that is *not* a webview keeps working:
the file tree, the editor, the terminal, language servers. Only extensions that
render UI in a webview break — so it looks like "extension X is broken" rather
than "the whole page is on the wrong protocol".

---

## 2. `Extension X could not start its user interface` / sidebar stays blank

```
[CodexWebviewProvider] Webview renderer did not become ready
  elapsedMs=30004 reason=renderer_ready_timeout
  receivedWebviewMessage=false role=sidebar stage=renderer timeoutMs=30000
```

**Cause.** The extension's webview HTML loaded, but its JavaScript never sent the
initial `ready` message back to the extension host, so the extension gave up after
30 s. In practice this is almost always a consequence of §1 or §3 — the webview
asset pipeline is broken, not the extension.

**Diagnosis order.**

1. Check the originating protocol (§1). Non-HTTPS is by far the most common.
2. Confirm webview frames exist at all. In DevTools, look for
   `.../webview/browser/pre/index.html?id=...` frames.
3. Turn on the extension host log. code-server writes to
   `%LOCALAPPDATA%\code-server\Data\logs\<timestamp>\exthost1\<publisher>.<ext>\<name>.log`
   (one directory per session). A `renderer_ready_timeout` line there confirms the
   diagnosis.
4. For the Android app, `onConsoleMessage` is wired to logcat under the tag
   `CodeRemoteWV`. `adb logcat -s CodeRemoteWV` is the fastest way to see the
   webview's own errors.

**Do not** waste time downgrading the extension. The extension version is
generally irrelevant; the host protocol is what matters.

---

## 3. Android: `Could not register service worker` / `net_error -202`

```
Webview fatal error: Error: Could not register service worker:
  SecurityError: Failed to register a ServiceWorker for scope ('.../webview/browser/pre/')
  ... An unknown error occurred when fetching the script.
net_error -202   ← ERR_CERT_AUTHORITY_INVALID
```

**Cause.** VS Code serves webview assets from a synthetic origin
(`vscode-resource.vscode-cdn.net`) and relies on a **Service Worker** to intercept
those requests. Two hard constraints apply:

1. Service Workers require HTTPS.
2. Service Worker **script fetches are not covered by
   `WebViewClient.onReceivedSslError`**. `handler.proceed()` lets the *page* load,
   but the service worker fetch is still rejected by the network stack.

So a self-signed certificate is enough for a desktop browser (click through the
warning once) but **fails on Android WebView with no way to click through**.

**Fix.** Install the local CA on the device, and make the app trust user CAs:

```xml
<!-- app/src/main/res/xml/network_security_config.xml -->
<network-security-config>
    <base-config cleartextTrafficPermitted="true">
        <trust-anchors>
            <certificates src="system" />
            <certificates src="user" />   <!-- required on Android 7+ -->
        </trust-anchors>
    </base-config>
</network-security-config>
```

```xml
<application android:networkSecurityConfig="@xml/network_security_config" ... />
```

Then install `proxy/certs/ca.pem` on the device:

```
Settings → Security → Encryption & credentials
         → Install a certificate → CA certificate → Install anyway
```

**Verify the CA before debugging anything else.** If `openssl` disagrees with a
certificate parser, trust `openssl`:

```bash
openssl verify -CAfile certs/ca.pem server-cert.pem     # → server-cert.pem: OK
```

> Note: `node-forge`'s `certificate.verify()` can report
> "issuer does not match parent subject" for a chain that `openssl` accepts. That
> is a forge RDN-comparison quirk, not a real problem.

**Alternative.** Use the Cloudflare Tunnel path, which serves a publicly trusted
certificate and needs no CA on the device.

---

## 4. Cloudflare Tunnel returns 502 after switching the proxy to HTTPS

```
ERR  Unable to reach the origin service ... originService=http://127.0.0.1:8092
ERR  Failed to proxy HTTP: ... EOF
```

**Cause.** `config/tunnel.yml` still points at `http://`, but the proxy now speaks
TLS. cloudflared sends a plaintext request to a TLS port → `EOF`.

**Fix.** Point the ingress at `https://` and disable origin verification, because
the proxy's certificate comes from a local CA that cloudflared cannot validate:

```yaml
ingress:
  - hostname: code.example.com
    service: https://127.0.0.1:8092
    originRequest:
      noTLSVerify: true
```

---

## 5. A stray `~/.cloudflared/config.yml` hijacks *other* tunnels

**Symptom.** An unrelated Cloudflare Tunnel on the same machine breaks. The
tunnel name reported by `cloudflared tunnel info <name>` is suddenly wrong.

**Cause.** `cloudflared tunnel run` with no `--config` reads
`~/.cloudflared/config.yml` by default, and a `tunnel:` key in that file
**overrides the CLI argument**. If any tool writes there, every other tool that
runs `cloudflared` without `--config` silently uses the wrong tunnel.

**Fix.** Keep tunnel configs out of `~/.cloudflared`. Store them next to the
project and always pass the path explicitly:

```powershell
cloudflared --config C:\path\to\project\config\tunnel.yml tunnel run <name>
```

**Never** create `~/.cloudflared/config.yml` on a machine that has more than one
tunnel.

---

## 6. QUIC silently drops the tunnel

**Symptom.** The tunnel process is alive, but the public hostname returns 530.
Logs show `failed to dial to quic connection ... timeout: no recent network activity`.

**Cause.** UDP/QUIC is blocked, rate-limited, or mangled by a load-balancing
proxy or firewall.

**Fix.** Force HTTP/2, which rides on TCP:

```yaml
protocol: http2
```

---

## 7. Port stuck in `TIME_WAIT` after a hard kill

**Symptom.** `os error 10048: Only one usage of each socket address is normally
permitted`. Ports appear to "drift" (8080 → 8081 → 8082) as you retry.

**Cause.** Force-killing leaves the kernel socket in `TIME_WAIT` for ~90 s. Also
beware: binding `[::]` can silently fall back to `127.0.0.1` when an old process
still holds the IPv6 socket — the log still says "listening", so it looks fine.

**Fix.** After killing, wait for **both** TCP and TCPv6 listeners to disappear
before rebinding, with a retry loop. `Launch.ps1` does this via `Wait-PortFree`
(which checks `TCP` *and* `TCPv6`) plus a 20 s retry.

---

## 8. PowerShell: `$pid` is read-only, and assignments fail *silently*

```powershell
$pid = $proc.Id      # silently does nothing — $PID is read-only
```

`$PID`, `$HOME`, `$HOST`, `$ERROR` and friends are automatic variables. Assigning
to them fails without a loud error, which produces false status reports and — in
one spectacular case here — made a cleanup routine kill its own process.

**Fix.** Never use automatic variable names. Use `$procId`, `$cfId`, `$ownerId`.

Related traps:

- `"$var:something"` parses as a scope qualifier. Use `"${var}:something"`.
- Piping a child process's stdout into `ForEach-Object` makes **grandchildren**
  inherit the pipe and hang the loop. Redirect to a file instead.
- `Set-Content -Encoding ascii` mangles non-ASCII text into `?`. Write `.cmd`
  files in pure ASCII.

---

## 9. code-server deletes extension versions from a *shared* extensions directory

**Symptom.** After running code-server against `~/.vscode/extensions`, old
extension versions vanish. Desktop VS Code is unaffected but rollbacks are gone.

**Cause.** code-server runs VS Code's extension cleanup, which removes directories
listed in `.obsolete`. Sharing one directory between two hosts means both may
garbage-collect it.

**Fix.** Disable automatic extension updates and the related sync settings:

```json
{
  "extensions.autoUpdate": "off",
  "extensions.autoCheckUpdates": false,
  "settingsSync.ignoredSettings": ["extensions.autoUpdate", "extensions.autoCheckUpdates"]
}
```

If you want strict isolation, set `extensions-dir` to a code-server-owned
directory instead of sharing (CodeRemote does the opposite by default — sharing is
the whole point — so back up anything you want to keep).

---

## 10. Restricted Mode silently limits extensions

**Symptom.** A banner reads *"Restricted Mode is intended for safe code browsing.
Trust this folder to enable all features."* Extensions that do not declare
`capabilities.untrustedWorkspaces` are limited or disabled.

**Cause.** Workspace Trust is on by default; no folder has been trusted.

**Fix.** For a personal remote dev box, turn the feature off entirely
(`%LOCALAPPDATA%\code-server\Data\User\settings.json`):

```json
{
  "security.workspace.trust.enabled": false,
  "security.workspace.trust.startupPrompt": "never"
}
```

---

## 11. `code-server --list-extensions` shows it, but the extension is "not installed"

**Symptom.** The extension directory exists under `extensions-dir`, code-server
lists it, yet it never activates.

**Cause.** Usually the extension is platform-specific (`-win32-x64` suffix) and
was installed for a different target, or it declares `extensionKind: ui` with no
`browser` entry point — such an extension cannot run in a browser client at all,
regardless of the host.

**Diagnosis.**

- `grep -n '"extensionKind"' <ext>/package.json` — `ui` means client-side only.
- Check for a `browser` key in `package.json`. No `browser` key + `extensionKind: ui`
  = it will never load in a browser.
- Native modules (`.node` files) built for another platform also block it.

---

## 12. A "corrupted installation" that isn't

**Symptom.** code-server logs:

```
File not found: ...\lib\vscode\node_modules\vsda\rust\web\vsda_bg.wasm
File not found: ...\typescript-language-features\dist\browser\extension.js
```

It is tempting to conclude that a file copy was incomplete.

**Reality.** These files are simply **not shipped** in the official code-server
Windows build. Verify before "repairing" anything:

```bash
# Download the same version fresh, extract elsewhere, and compare
tar -xzf code-server-4.141.0-windows-amd64.tar.gz -C /tmp/fresh
diff -rq ./code-server /tmp/fresh/code-server-4.141.0-windows-amd64 | head
```

If the fresh copy has the same file count and size, nothing is missing and the
`File not found` lines are normal probing. In this project the two trees matched
exactly (5980 files, 630 MB, zero diffs) — the "corruption" was a red herring that
cost hours.

---

## 13. IPv6 address changes and everything breaks

**Symptom.** It worked yesterday. Today the URL is dead.

**Cause.** Windows privacy extensions (RFC 4941) rotate the temporary address;
DHCPv6 re-delegation can also change the prefix. The stable address
(`PrefixLength 64`, `PrefixOrigin RouterAdvertisement`) is the one to publish.

**Fix.** CodeRemote enumerates all global IPv6 addresses at launch, puts **all of
them** into the certificate SAN, and prints the stable `/64` one as primary with
the rest as backups. Combined with a stable CA this means a rotated address never
requires reinstalling the CA — just open the new printed link.

---

## 14. Diagnosing "it just doesn't work" without a device in hand

Two techniques paid for themselves repeatedly:

**Drive a real browser programmatically.** `playwright-core` can drive the
already-installed Edge without downloading a browser:

```js
const { chromium } = require('playwright-core');
const browser = await chromium.launch({
  channel: 'msedge',
  args: ['--no-proxy-server', '--ignore-certificate-errors'],
});
const page = await browser.newPage();
page.on('console', (m) => console.log(m.type(), m.text()));   // ← the whole point
page.on('pageerror', (e) => console.log('pageerror', e.message));
page.on('requestfailed', (r) => console.log('reqfail', r.url(), r.failure()));
await page.goto(url);
```

`--no-proxy-server` matters: an HTTP proxy that cannot handle a literal IPv6 host
will emit `502` and send you hunting in the wrong place.

**Surface webview console output on Android.** The stock WebView discards it.
Override `onConsoleMessage` and log to logcat:

```java
@Override
public boolean onConsoleMessage(ConsoleMessage cm) {
    Log.e("CodeRemoteWV", cm.message() + " @" + cm.sourceId() + ":" + cm.lineNumber());
    return true;
}
```

Then `adb logcat -s CodeRemoteWV`.

**Also:** inside a WebView, the Back button is consumed by the browser history, so
`adb shell input keyevent 4` often does not dismiss the soft keyboard. A plain
BACK in a fullscreen webview will also trigger the app's own back handler — expect
a "quit?" dialog and dismiss it explicitly.

---

## 15. Screenshots from `adb` come out corrupt

```powershell
adb exec-out screencap -p > shot.png      # ← corrupt under PowerShell
```

PowerShell's redirection re-encodes the byte stream as text.

**Fix.** Round-trip through the device:

```powershell
adb shell screencap -p /sdcard/shot.png
adb pull /sdcard/shot.png shot.png
adb shell rm /sdcard/shot.png
```
