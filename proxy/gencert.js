// 生成本地 CA + 由该 CA 签发的服务器证书
//
// 为什么要 CA:
//   Android WebView 的 Service Worker 只接受「受信任 CA 签发」的证书,
//   onReceivedSslError 的 proceed() 对 SW 脚本加载无效。
//   所以必须:① 建一个固定的 CA(只在第一次生成),② 平板装一次这个 CA,
//   ③ 之后每次启动用它签发带当前 IPv6 的服务器证书 → 自动通过校验。
//
// 用法: node gencert.js <ip1> [ip2] ...
// 输出:
//   certs/ca.pem          ← 需要安装到平板(长期不变)
//   certs/ca-key.pem
//   certs/cert.pem        ← 服务器证书(每次启动重签)
//   certs/key.pem

const forge = require('node-forge');
const fs = require('fs');
const path = require('path');

const outDir = process.env.CERT_DIR || path.join(__dirname, 'certs');
const ips = process.argv.slice(2).filter(Boolean);

const caCertPath = path.join(outDir, 'ca.pem');
const caKeyPath = path.join(outDir, 'ca-key.pem');
const srvCertPath = path.join(outDir, 'cert.pem');
const srvKeyPath = path.join(outDir, 'key.pem');

fs.mkdirSync(outDir, { recursive: true });

function loadOrCreateCA() {
  if (fs.existsSync(caCertPath) && fs.existsSync(caKeyPath)) {
    return {
      cert: forge.pki.certificateFromPem(fs.readFileSync(caCertPath, 'utf8')),
      key: forge.pki.privateKeyFromPem(fs.readFileSync(caKeyPath, 'utf8')),
      created: false,
    };
  }
  const keys = forge.pki.rsa.generateKeyPair(2048);
  const cert = forge.pki.createCertificate();
  cert.publicKey = keys.publicKey;
  cert.serialNumber = '01';
  cert.validity.notBefore = new Date(Date.now() - 24 * 3600 * 1000);
  cert.validity.notAfter = new Date();
  cert.validity.notAfter.setFullYear(cert.validity.notBefore.getFullYear() + 15);

  const attrs = [{ name: 'commonName', value: 'CodeRemote Local CA' }];
  cert.setSubject(attrs);
  cert.setIssuer(attrs);
  cert.setExtensions([
    { name: 'basicConstraints', cA: true, critical: true },
    { name: 'keyUsage', keyCertSign: true, cRLSign: true, critical: true },
  ]);
  cert.sign(keys.privateKey, forge.md.sha256.create());

  fs.writeFileSync(caCertPath, forge.pki.certificateToPem(cert));
  fs.writeFileSync(caKeyPath, forge.pki.privateKeyToPem(keys.privateKey));
  return { cert, key: keys.privateKey, created: true };
}

const ca = loadOrCreateCA();

// ---- 签发服务器证书 ----
const keys = forge.pki.rsa.generateKeyPair(2048);
const cert = forge.pki.createCertificate();
cert.publicKey = keys.publicKey;
cert.serialNumber = Date.now().toString(16);
cert.validity.notBefore = new Date(Date.now() - 24 * 3600 * 1000);
cert.validity.notAfter = new Date();
cert.validity.notAfter.setFullYear(cert.validity.notBefore.getFullYear() + 10);

cert.setSubject([{ name: 'commonName', value: 'CodeRemote' }]);
cert.setIssuer(ca.cert.subject.attributes);

const altNames = [{ type: 2, value: 'localhost' }]; // DNS
for (const ip of ['127.0.0.1', '::1', ...ips]) {
  altNames.push({ type: 7, ip }); // IP
}

cert.setExtensions([
  { name: 'basicConstraints', cA: false },
  { name: 'keyUsage', digitalSignature: true, keyEncipherment: true, critical: true },
  { name: 'extKeyUsage', serverAuth: true },
  { name: 'subjectAltName', altNames },
]);

cert.sign(ca.key, forge.md.sha256.create());

// 服务器证书要带 CA 证书一起(证书链)
fs.writeFileSync(srvCertPath, forge.pki.certificateToPem(cert) + forge.pki.certificateToPem(ca.cert));
fs.writeFileSync(srvKeyPath, forge.pki.privateKeyToPem(keys.privateKey));

console.log(
  `cert ok  SAN=${altNames.map((a) => a.value || a.ip).join(',')}  CA=${ca.created ? '新建' : '复用'}`
);
