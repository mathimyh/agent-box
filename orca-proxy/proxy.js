'use strict';
// Filtering proxy between agent-box containers and the Orca desktop runtime.
//
// Why: a paired Orca client can call every runtime method, including
// terminal.create, which runs commands on the Windows host. Orca encrypts each
// frame end to end, so a plain network filter cannot see the method names.
// This proxy ends the encryption itself: containers pair with the proxy (its own
// key and token), and the proxy forwards only allowed methods to Orca with the
// real pairing. The real token stays in the proxy volume.
//
// Usage:
//   node proxy.js init <orca-pairing-link> <endpoint-for-containers>
//   node proxy.js serve
//   node proxy.js link          (print the pairing link for containers again)

const fs = require('fs');
const crypto = require('crypto');
const nacl = require('tweetnacl');
const WebSocket = require('ws');

const CONFIG = process.env.PROXY_CONFIG || '/data/config.json';
const PORT = Number(process.env.PROXY_PORT || 6769);

// Methods a containerized worker needs. Everything else is refused.
// orchestration.send also carries worker_done, heartbeat and escalations.
// The CLI calls status.get before every command, and orchestration commands
// call terminal.resolveActive to find the caller's own handle. Both only read.
const ALLOWED = new Set([
  'status.get',
  'terminal.resolveActive',
  'orchestration.send',
  'orchestration.check',
  'orchestration.reply',
  'orchestration.inbox',
  'orchestration.dispatchShow',
  'orchestration.taskList',
]);

// --- NaCl box framing, same format as Orca's shared/e2ee-crypto.js ----------

const b64 = (bytes) => Buffer.from(bytes).toString('base64');
const unb64 = (text) => Uint8Array.from(Buffer.from(text, 'base64'));

function encrypt(plaintext, key) {
  const nonce = nacl.randomBytes(nacl.box.nonceLength);
  const box = nacl.box.after(new TextEncoder().encode(plaintext), nonce, key);
  const bundle = new Uint8Array(nonce.length + box.length);
  bundle.set(nonce);
  bundle.set(box, nonce.length);
  return b64(bundle);
}

function decrypt(text, key) {
  const bundle = unb64(text);
  if (bundle.length < nacl.box.nonceLength + nacl.box.overheadLength) return null;
  const plain = nacl.box.open.after(bundle.slice(nacl.box.nonceLength), bundle.slice(0, nacl.box.nonceLength), key);
  return plain ? new TextDecoder().decode(plain) : null;
}

// --- pairing links, same format as Orca's shared/pairing.js -----------------

function decodeLink(link) {
  const code = link.trim().replace(/^orca:\/\/pair\?code=/, '');
  return JSON.parse(Buffer.from(code.replace(/-/g, '+').replace(/_/g, '/'), 'base64').toString('utf8'));
}

function encodeLink(offer) {
  const code = Buffer.from(JSON.stringify(offer), 'utf8').toString('base64')
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  return `orca://pair?code=${code}`;
}

function containerLink(config) {
  return encodeLink({
    v: 2,
    endpoint: config.proxy.endpoint,
    deviceToken: config.proxy.deviceToken,
    publicKeyB64: config.proxy.publicKeyB64,
    scope: 'runtime',
  });
}

// --- commands ----------------------------------------------------------------

function init(link, endpoint) {
  const upstream = decodeLink(link);
  const keys = nacl.box.keyPair();
  const config = {
    upstream: { endpoint: upstream.endpoint, deviceToken: upstream.deviceToken, publicKeyB64: upstream.publicKeyB64 },
    proxy: {
      endpoint,
      deviceToken: crypto.randomBytes(32).toString('base64url'),
      publicKeyB64: b64(keys.publicKey),
      secretKeyB64: b64(keys.secretKey),
    },
  };
  fs.writeFileSync(CONFIG, JSON.stringify(config, null, 2), { mode: 0o600 });
  console.log(containerLink(config));
}

function sameToken(a, b) {
  const x = Buffer.from(String(a));
  const y = Buffer.from(String(b));
  return x.length === y.length && crypto.timingSafeEqual(x, y);
}

function serve() {
  const config = JSON.parse(fs.readFileSync(CONFIG, 'utf8'));
  const proxySecret = unb64(config.proxy.secretKeyB64);
  const upstreamPublic = unb64(config.upstream.publicKeyB64);
  const server = new WebSocket.Server({ port: PORT });
  console.log(`orca-proxy: listening on ${PORT}, forwarding to ${config.upstream.endpoint}`);

  server.on('connection', (client, req) => {
    const peer = req.socket.remoteAddress;
    let clientKey = null;   // shared key with the container
    let upstreamKey = null; // shared key with Orca
    let upstream = null;
    let state = 'hello';    // hello -> connecting -> auth -> ready

    const closeBoth = (code, reason) => {
      if (client.readyState === WebSocket.OPEN) client.close(code, reason);
      if (upstream && upstream.readyState === WebSocket.OPEN) upstream.close();
    };
    const toClient = (obj) => client.send(encrypt(JSON.stringify(obj), clientKey));
    const toUpstream = (obj) => upstream.send(encrypt(JSON.stringify(obj), upstreamKey));

    const handleClientFrame = (text) => {
      const plain = decrypt(text, clientKey);
      if (plain === null) return closeBoth(4003, 'decrypt failed');
      const msg = JSON.parse(plain);

      if (state === 'auth') {
        if (msg.type !== 'e2ee_auth' || !sameToken(msg.deviceToken, config.proxy.deviceToken)) {
          console.log(`orca-proxy: ${peer} refused: bad token`);
          toClient({ type: 'e2ee_error', error: { code: 'unauthorized', message: 'Invalid token' } });
          return closeBoth(4001, 'unauthorized');
        }
        state = 'ready';
        return toUpstream({ ...msg, deviceToken: config.upstream.deviceToken });
      }

      if (!ALLOWED.has(msg.method)) {
        console.log(`orca-proxy: ${peer} DENY ${msg.method}`);
        return toClient({
          id: msg.id,
          ok: false,
          error: { code: 'forbidden', message: `agent-box: method '${msg.method}' is not allowed from a container` },
          _meta: { runtimeId: null },
        });
      }
      console.log(`orca-proxy: ${peer} allow ${msg.method}`);
      toUpstream({ ...msg, deviceToken: config.upstream.deviceToken });
    };

    const handleHello = (text) => {
      const hello = JSON.parse(text);
      if (hello.type !== 'e2ee_hello') return closeBoth(4003, 'expected hello');
      clientKey = nacl.box.before(unb64(hello.publicKeyB64), proxySecret);
      state = 'connecting';

      // One upstream connection per container connection, with a fresh key.
      const ours = nacl.box.keyPair();
      upstreamKey = nacl.box.before(upstreamPublic, ours.secretKey);
      upstream = new WebSocket(config.upstream.endpoint);
      upstream.on('open', () => upstream.send(JSON.stringify({ type: 'e2ee_hello', publicKeyB64: b64(ours.publicKey) })));
      upstream.on('message', (up) => {
        const upText = up.toString();
        if (state === 'connecting') {
          if (JSON.parse(upText).type !== 'e2ee_ready') return closeBoth(4003, 'upstream handshake');
          state = 'auth';
          client.send(JSON.stringify({ type: 'e2ee_ready' }));
          return;
        }
        const plain = decrypt(upText, upstreamKey);
        if (plain === null) return closeBoth(4003, 'upstream decrypt failed');
        client.send(encrypt(plain, clientKey));
      });
      upstream.on('close', () => closeBoth(1000, 'upstream closed'));
      upstream.on('error', (err) => {
        console.log(`orca-proxy: upstream error: ${err.message}`);
        closeBoth(1011, 'upstream error');
      });
    };

    client.on('message', (data, isBinary) => {
      if (isBinary) return closeBoth(4003, 'binary frame');
      try {
        if (state === 'hello') handleHello(data.toString());
        // The client waits for e2ee_ready before it sends anything else.
        else if (state === 'connecting') closeBoth(4003, 'frame before ready');
        else handleClientFrame(data.toString());
      } catch (err) {
        console.log(`orca-proxy: ${peer} bad frame: ${err.message}`);
        closeBoth(4003, 'bad frame');
      }
    });
    client.on('close', () => upstream && upstream.readyState === WebSocket.OPEN && upstream.close());
    client.on('error', () => closeBoth(1011, 'client error'));
  });
}

const [command, ...rest] = process.argv.slice(2);
if (command === 'init') init(rest[0], rest[1]);
else if (command === 'serve') serve();
else if (command === 'link') console.log(containerLink(JSON.parse(fs.readFileSync(CONFIG, 'utf8'))));
else {
  console.error('usage: proxy.js init <orca-pairing-link> <endpoint> | serve | link');
  process.exit(2);
}
