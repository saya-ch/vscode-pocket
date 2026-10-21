# Architecture

## Process tree

```
Launch.cmd
└─ pwsh -File scripts/Launch.ps1          ← owns the Job Object
   ├─ code-server  (lib\node.exe)         → 127.0.0.1:8091
   ├─ proxy.js     (lib\node.exe)         → [::]:8092  (TLS)
   └─ cloudflared  (optional)             → outbound only
```

Every child is assigned to a Windows **Job Object** created with
`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` (`0x2000`, class `9`):

```csharp
job = CreateJobObject(IntPtr.Zero, null);
ext.Basic.LimitFlags = 0x2000;
SetInformationJobObject(job, 9, p, len);          // 9 = ExtendedLimitInformation
AssignProcessToJobObject(job, OpenProcess(0x0100 | 0x0001, false, pid));
```

The handle lives only in the launcher process. When the launcher exits *for any
reason* — window closed, Ctrl-C, crash, Task Manager kill — the kernel closes the
handle and terminates every process in the job. This is why there is no cleanup
code in the normal exit path: there does not need to be one. It also means a
`Start-Process -PassThru` child that spawns *its own* children (cloudflared,
language servers, terminals) is covered, because grandchildren inherit job
membership.

Contrast with `Stop-Process` in a `finally` block: that misses detached children
and does nothing if the process is killed from outside. The job object is the only
guarantee that survives `TerminateProcess`.

## Why code-server and not `code serve-web`

VS Code's built-in web server (`code serve-web`, extension
`ms-vscode.remote-server`) runs the workbench in the browser, but the *extension
host* runs **in the browser** too — as a web worker. Only extensions that ship a
`browser` entry point can load. On a typical desktop install that is roughly 25 of
87 extensions; everything else is silently unavailable.

code-server instead runs a **Node.js extension host on the server machine**. It
reads `package.json`'s `main` field, not `browser`, so desktop extensions run
unmodified — including ones with native modules, since they execute on the same OS
and architecture they were built for.

The cost is that the browser workbench must still render extension UI. Extension
UI is rendered as a **webview**: an iframe that VS Code hosts, whose assets are
served by the server and intercepted in the browser by a Service Worker. That
pipeline is where all the HTTPS requirements come from (see
[TROUBLESHOOTING §1–3](TROUBLESHOOTING.md)).

## The authentication layer

code-server supports `auth: password` or `auth: none`. Neither gives the desired
behaviour: a password prompt on every device, or an open port.

`proxy/proxy.js` sits in front and implements a single rule:

```
GET /...?k=<token>   →  Set-Cookie: crtok=<token>; Max-Age=1y; HttpOnly; SameSite=Lax
                        and proxy the request through (no redirect)
anything else        →  403
```

Details that matter:

- **No redirect on token match.** The response for the token-bearing request is
  the proxied response itself. Clients that do not follow redirects still work,
  and there is no extra round trip.
- **`changeOrigin: false`.** The upstream `Host` header is preserved, so
  code-server sees the public host and generates webview origins
  (`vscode-resource.vscode-cdn.net` subdomains) that match what the browser
  actually requested. Rewriting `Host` to `127.0.0.1` breaks that mapping.
- **`xfwd: true`.** `X-Forwarded-*` headers are set for diagnostics and for
  code-server's URL generation.
- **WebSocket upgrades** are handled on the `upgrade` event with the same token
  check, because the extension host connection is a WebSocket.
- **The proxy is the only thing bound to a routable address.** code-server stays
  on loopback with `auth: none`.

Because the tunnel ingress points at the proxy (not at code-server), the public
hostname also requires the token. There is exactly one authentication path.

## Certificate model

```
ca.pem + ca-key.pem          generated once, 15 years, stable
      │
      └─ signs ──▶ cert.pem + key.pem    re-signed on every launch
                                          SANs = localhost, 127.0.0.1, ::1,
                                                 + every current global IPv6
```

Why the CA indirection:

- A **self-signed leaf** would have to be re-imported on every device whenever the
  address changes, and — decisively — a self-signed leaf cannot register a Service
  Worker on Android (§3).
- A **stable CA** is imported once. The leaf can rotate freely; devices keep
  trusting it.
- The leaf carries an explicit IP SAN for every address the machine currently has,
  so whichever URL you open, hostname verification succeeds.

The leaf is sent together with the CA certificate (`cert.pem` contains both PEM
blocks) so clients that do not already have the CA can still build the chain.

## Request path, end to end

```
1. browser →  https://[addr]:8092/?k=TOKEN
2. proxy   →  token OK → set cookie → proxy to http://127.0.0.1:8091
3. code-server → serves workbench HTML + JS
4. workbench → opens WebSocket to the extension host (through the proxy)
5. first extension with a sidebar → creates webview iframe
6. iframe  → registers Service Worker (needs trusted cert + secure context)
7. Service Worker → intercepts vscode-resource.vscode-cdn.net → proxy → code-server
8. webview assets load → renderer posts "ready" → extension UI appears
```

Steps 6 and 7 are where every failure in this project originated. Steps 1–5 are
robust and will happily work on a broken setup, which is exactly why the failure
mode is so confusing.

## Android shell

A single `Activity` with programmatic UI (no layout XML) and a programmatically
constructed `WebView`:

- `setJavaScriptEnabled`, `setDomStorageEnabled`, `setDatabaseEnabled`
- `setUseWideViewPort(true)`, `setBuiltInZoomControls(false)`
- User agent with the `"; wv"` token stripped, so servers that feature-detect
  "this is a WebView" (and serve a degraded page) treat it as a normal browser
- `onReceivedSslError → proceed()` for page navigations (the local CA path)
- `network_security_config` trusting `user` CAs (required on Android 7+)
- `WindowCompat.setDecorFitsSystemWindows(false)` +
  `WindowInsetsControllerCompat.hide(systemBars())` for immersive mode
- `configChanges` covering orientation/keyboard/screenSize so rotation does not
  recreate the Activity and lose the webview session
- Back handling: webview history first, then an in-app dialog

`targetSdk 36`, `minSdk 26`. The APK is debug-signed; it is a personal tool, not a
store app.
