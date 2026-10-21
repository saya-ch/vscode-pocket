# CodeRemote

**Turn your desktop VS Code into a full-featured remote IDE you can open from a browser or a tablet — with every desktop extension, the integrated terminal, and debugging working.**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Windows-lightgrey.svg)](#requirements)
[![code-server](https://img.shields.io/badge/code--server-4.141.0-2ea043.svg)](https://github.com/coder/code-server)

---

## Why this exists

VS Code's official `serve-web` only loads the ~25 extensions that ship a **web** entry point. If your workflow depends on desktop-only extensions (AI assistants, language servers, database clients, theme packs), `serve-web` silently drops most of them.

[code-server](https://github.com/coder/code-server) solves that: it runs a **real Node extension host on the server**, so desktop extensions run *unmodified*. Point it at your existing `~/.vscode/extensions` directory and your desktop setup appears in the browser, extension for extension.

CodeRemote is the missing operational layer around code-server:

- **One double-click to run**, and closing the window kills everything — guaranteed.
- **No password prompt.** The access token lives in the URL, so a bookmark just works.
- **HTTPS out of the box**, which turns out to be non-negotiable (see [The HTTPS trap](#the-https-trap-this-is-the-whole-ballgame)).
- **An Android shell app** that goes straight into immersive fullscreen.

---

## Features

| | |
|---|---|
| **Full desktop extensions** | code-server's Node extension host runs them natively. Shares `~/.vscode/extensions` with your desktop install. |
| **Integrated terminal** | Real PTY on your machine, works from the browser. |
| **Debugging** | Node/Java/Python/etc. debuggers behave as they do locally. |
| **Token in URL** | `https://host:port/?k=<token>` sets a long-lived cookie and gets out of the way. No login form. |
| **Zero leftover processes** | Children are bound to a Windows **Job Object** with `KILL_ON_JOB_CLOSE`. Close the window → code-server, proxy and tunnel all die. No orphans, no port leaks. |
| **Dual access path** | Direct IPv6 on the LAN (fast) **and** an optional Cloudflare Tunnel for off-network access. |
| **Android app** | URL input + history, fullscreen immersive, external keyboard friendly. Ships as a debug-signed APK in [`apk/`](apk/). |

---

## Architecture

```
                    ┌──────────────────────────────────────────────┐
  browser / tablet  │  HTTPS  (CA-signed; see "The HTTPS trap")     │
        │           └──────────────────────────────────────────────┘
        │
        ▼
  ┌─────────────────────────────┐
  │ proxy/proxy.js             │   reverse proxy, Node
  │  · :8092, dual-stack [::]  │
  │  · TLS termination         │
  │  · token auth → cookie     │
  └──────────┬─────────────────┘
             │ HTTP, loopback only
             ▼
  ┌─────────────────────────────┐
  │ code-server                │   127.0.0.1:8091, auth: none
  │  · Node extension host     │   ← this is why desktop extensions work
  │  · extensions-dir ─────────┼──▶ ~/.vscode/extensions  (shared with desktop)
  └─────────────────────────────┘

  optional: Cloudflare Tunnel ──▶ https://code.example.com ──▶ proxy:8092
```

`code-server` is bound to **loopback only** and runs with `auth: none`. It is therefore unreachable except through the proxy, and the proxy is the single place where authentication happens.

---

## Requirements

- **Windows 10/11** (the launcher is PowerShell + Win32 Job Objects; the proxy and code-server themselves are cross-platform)
- **Node.js ≥ 18** — only for `npm install`; the runtime uses the Node bundled inside code-server
- **[code-server](https://github.com/coder/code-server/releases)** (tested with 4.141.0) extracted to `./code-server/`
- **VS Code desktop installed** (optional but recommended — lets you share the extension directory)
- **Android 8+** for the companion app (optional)

---

## Quick start

```powershell
git clone https://github.com/saya-ch/coderemote.git
cd coderemote

# 1. Download code-server and extract it here as ./code-server/
#    https://github.com/coder/code-server/releases  →  code-server-<ver>-windows-amd64

# 2. Install the proxy's two dependencies
cd proxy
npm install
cd ..

# 3. Run
.\Launch.cmd
```

The window prints something like:

```
  【LAN / campus network】fastest:

    https://[2001:db8::1]:8092/?k=3f9c...e21a

  关闭本窗口 → 服务立即停止
```

Open that link. On first visit the browser warns about the certificate — accept it once (the proxy uses a **local CA you generate yourself**, see below).

The token is generated on first run and stored in `config/access-token.txt`. Delete that file to rotate it. All other configuration is generated at runtime and never needs hand-editing.

### Options

```powershell
.\Launch.cmd -CsPort 8091 -ProxyPort 8092 -NoDesktopExtensions
.\Launch.cmd -TunnelName coderemote      # also start a Cloudflare Tunnel
```

---

## The HTTPS trap (this is the whole ballgame)

**If you serve VS Code over plain `http://` on a non-`localhost` address, every webview silently dies.**

What you see:

```
Error: 'crypto.subtle' is not available so webviews will not work.
This is likely because the editor is not running in a secure context.
```

and, for any extension with a sidebar (AI assistants being the common case):

```
Codex could not start its user interface.
[CodexWebviewProvider] Webview renderer did not become ready
  reason=renderer_ready_timeout receivedWebviewMessage=false
```

**Why:** `crypto.subtle` exists only in a [secure context](https://developer.mozilla.org/en-US/docs/Web/Security/Secure_Contexts) — `https://`, or `http://localhost`. VS Code's webviews use it to encrypt their postMessage channel. No secure context → no webviews → any extension that renders UI into a webview is dead. Everything *else* (editor, terminal, file tree) still works, which makes this maddening to diagnose.

**The second trap, and it's worse on Android.** You might reach for a self-signed certificate. That is enough for desktop browsers (they let you click through), but **not** for Android's WebView:

```
Webview fatal error: Could not register service worker:
  SecurityError: Failed to register a ServiceWorker
  ... net_error -202                      ← ERR_CERT_AUTHORITY_INVALID
```

VS Code loads all webview assets through a **Service Worker**. Service Worker script fetches are **not** covered by `WebViewClient.onReceivedSslError` → `proceed()`. There is no click-through, no bypass. An untrusted certificate simply cannot register a service worker, full stop.

### How CodeRemote solves it

A **stable local CA** signs a short-lived server certificate at every launch:

```
proxy/certs/ca.pem        ← generated once, valid 15 years, never changes
proxy/certs/ca-key.pem
proxy/certs/cert.pem      ← re-signed each launch, SANs = current IPv6 addresses
proxy/certs/key.pem
```

Because the CA is stable, you install it **once** per device. Because the server certificate is re-signed at every launch, it always carries the *current* address in its SAN — so a rotating IPv6 address never invalidates your setup.

Install the CA on each phone/tablet:

```
Settings → Security → Encryption & credentials
         → Install a certificate → CA certificate
         → (warned) Install anyway
         → pick coderemote-ca.pem
```

The Android app declares `android:networkSecurityConfig` with `<certificates src="user" />` so it actually trusts user-installed CAs (Android 7+ ignores them by default).

> **Shortcut:** the Cloudflare Tunnel path (`-TunnelName`) serves a *publicly trusted* certificate, so devices using the tunnel need no CA at all. Install the CA only if you want the faster direct-LAN path.

---

## Access paths

| Path | Certificate | Best for | Needs CA on device |
|---|---|---|---|
| Direct IPv6 (LAN / campus) | local CA | lowest latency, works offline | yes |
| Cloudflare Tunnel | public CA | anywhere, no setup on device | no |

Both terminate at the same proxy, so both require the `?k=` token. Without it you get a `403`.

---

## Android app

[`android/`](android/) is a small (~2 MB) WebView shell. [`apk/CodeRemote.apk`](apk/CodeRemote.apk) is a prebuilt **debug-signed** APK — fine for personal sideloading, not for distribution.

```bash
adb install -r apk/CodeRemote.apk
```

- URL entry with paste button and 6-item history (long-press to delete)
- Auto-fills the last URL, or the clipboard if it holds a link
- Immersive fullscreen: system bars hidden, `BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE`
- `adjustResize` + external keyboard support
- Back button: webview history first, then a "change link / quit" dialog
- Accepts the local CA (`network_security_config`), and proceeds through SSL errors for the page itself
- `FLAG_KEEP_SCREEN_ON` so the screen doesn't sleep mid-session

Build it yourself:

```bash
cd android
./gradlew assembleDebug        # Linux / macOS
gradlew.bat assembleDebug      # Windows
```

`android/local.properties` must point at your SDK; it is git-ignored.

---

## Layout

```
coderemote/
├── Launch.cmd              double-click launcher
├── scripts/Launch.ps1      the real launcher: Job Object, ports, certs, URLs
├── proxy/
│   ├── proxy.js            HTTPS reverse proxy + token auth
│   ├── gencert.js          stable CA + per-launch server certificate
│   └── package.json
├── config/
│   └── tunnel.yml.sample   optional Cloudflare Tunnel config
├── android/                WebView shell app
├── apk/CodeRemote.apk      prebuilt, debug-signed
└── docs/
    ├── ARCHITECTURE.md
    ├── TROUBLESHOOTING.md  ← read this if anything misbehaves
    └── README.zh-CN.md
```

Generated at runtime, never committed: `proxy/certs/`, `proxy/node_modules/`, `config/code-server.yaml`, `config/access-token.txt`, `config/tunnel.yml`, `logs/`, `data/`.

---

## Security notes

This is a **personal remote-development tool**. Understand the trade-offs before exposing it.

- **`code-server` runs with `auth: none`** — safe only because it is bound to `127.0.0.1`. Never change `bind-addr` to `0.0.0.0`.
- **The token is a bearer credential** in a URL. It ends up in browser history and in the clipboard. Rotate it by deleting `config/access-token.txt`.
- **The local CA private key** (`proxy/certs/ca-key.pem`) sits on the server. Anyone who gets it can mint certificates your devices will trust. Treat it like an SSH key; delete `proxy/certs/` to start over (all devices then need the new CA).
- **HTTPS here is for browser API access, not for defending a hostile network.** Anyone who can reach the port still needs the token, but treat plain LAN exposure accordingly.
- **Fail2ban-ish behaviour is absent** — there is no rate limiting. Fine on a home LAN, questionable on a public address.
- The APK is **debug-signed**. Do not distribute it; build and sign your own release.
- The app disables SSL error handling for page navigations to accommodate the local CA. If you use a public-CA path exclusively, consider removing that override.

---

## Caveats

- The launcher targets Windows (Win32 Job Object, `netstat`, `Get-NetIPAddress`). The proxy and Android app are portable; porting the launcher to POSIX would need a process-group/subreaper equivalent.
- Extension compatibility is code-server's, not CodeRemote's. Some extensions hard-depend on desktop-only VS Code APIs and will degrade in any browser host — check code-server's issue tracker.
- The `apk/` icon is derived from VS Code's logo for personal convenience. **Not affiliated with or endorsed by Microsoft.** Replace it before redistributing.

---

## License

[MIT](LICENSE)
