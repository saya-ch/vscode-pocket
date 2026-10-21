// VSCode Pocket 令牌反向代理
// 作用:给 code-server 套一层"URL 带令牌即登录"的鉴权
//
//   http://[IPv6]:<端口>/?k=<令牌>   → 设置 cookie 并跳转,之后免密访问
//   无令牌 / 令牌错误               → 403
//
// code-server 本身只监听 127.0.0.1 且 auth:none,所以只能经由本代理访问。

const http = require('http');
const https = require('https');
const fs = require('fs');
const httpProxy = require('http-proxy');

const LISTEN_HOST = process.env.PROXY_HOST || '::';
const LISTEN_PORT = parseInt(process.env.PROXY_PORT || '8092', 10);
const TARGET      = process.env.PROXY_TARGET || 'http://127.0.0.1:8091';
const TOKEN       = process.env.PROXY_TOKEN || '';
const COOKIE_NAME = 'crtok';
const TLS_CERT    = process.env.PROXY_TLS_CERT || '';
const TLS_KEY     = process.env.PROXY_TLS_KEY || '';

if (!TOKEN) {
  console.error('[proxy] 缺少 PROXY_TOKEN,退出');
  process.exit(1);
}

const proxy = httpProxy.createProxyServer({
  target: TARGET,
  ws: true,
  xfwd: true,
  changeOrigin: false,
});

proxy.on('error', (err, req, res) => {
  console.error('[proxy] error:', err.message);
  if (res && res.writeHead && !res.headersSent) {
    res.writeHead(502, { 'Content-Type': 'text/plain; charset=utf-8' });
    res.end('proxy error: ' + err.message);
  } else if (res && res.destroy) {
    res.destroy();
  }
});

function hasValidCookie(req) {
  const raw = req.headers.cookie || '';
  return raw.split(';').some((c) => {
    const [k, ...v] = c.trim().split('=');
    return k === COOKIE_NAME && v.join('=') === TOKEN;
  });
}

function getQuery(req) {
  try {
    return new URL(req.url, 'http://placeholder.local');
  } catch {
    return null;
  }
}

function isAuthorized(req) {
  if (hasValidCookie(req)) return true;
  const u = getQuery(req);
  if (u && u.searchParams.get('k') === TOKEN) return true;
  return false;
}

function handleRequest(req, res) {
  const u = getQuery(req);
  const k = u ? u.searchParams.get('k') : null;

  // 带正确令牌 → 种 cookie 并【直接代理】,不做跳转。
  // 这样即使客户端不跟跳转也能一次成功。
  if (k === TOKEN) {
    res.setHeader(
      'Set-Cookie',
      `${COOKIE_NAME}=${TOKEN}; Path=/; Max-Age=31536000; SameSite=Lax; HttpOnly`
    );
    proxy.web(req, res);
    return;
  }

  if (!isAuthorized(req)) {
    res.writeHead(403, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' });
    res.end(
      '<!doctype html><meta charset="utf-8"><title>403</title>' +
      '<body style="font-family:system-ui;padding:40px;line-height:1.7">' +
      '<h1>403</h1><p>需要带令牌访问。</p>' +
      '<p>请从启动窗口复制完整链接(形如 <code>/?k=...</code>)。</p></body>'
    );
    return;
  }

  // 诊断日志:记录 webview 资源请求与 4xx/5xx
  res.on('finish', () => {
    try {
      const uu = req.url || '';
      if (res.statusCode >= 400 || /webview|vscode-remote-resource|extensionHost/i.test(uu)) {
        console.log(`[proxy] ${res.statusCode} ${req.method} ${uu.slice(0, 200)}`);
      }
    } catch (_) { }
  });

  proxy.web(req, res);
}

// 有证书就上 HTTPS —— 这是关键:浏览器的 crypto.subtle 只在安全上下文可用,
// 明文 HTTP(非 localhost)会导致 VS Code 所有 WebView 失效。
let server;
if (TLS_CERT && TLS_KEY && fs.existsSync(TLS_CERT) && fs.existsSync(TLS_KEY)) {
  server = https.createServer(
    { key: fs.readFileSync(TLS_KEY), cert: fs.readFileSync(TLS_CERT) },
    handleRequest
  );
} else {
  server = http.createServer(handleRequest);
}

server.on('upgrade', (req, socket, head) => {
  if (!isAuthorized(req)) {
    socket.write('HTTP/1.1 403 Forbidden\r\n\r\n');
    socket.destroy();
    return;
  }
  proxy.ws(req, socket, head);
});

server.listen(LISTEN_PORT, LISTEN_HOST, () => {
  const scheme = TLS_CERT ? 'https' : 'http';
  console.log(`[proxy] ${scheme} listening on [${LISTEN_HOST}]:${LISTEN_PORT} -> ${TARGET}`);
});

process.on('SIGTERM', () => process.exit(0));
process.on('SIGINT', () => process.exit(0));
