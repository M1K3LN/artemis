'use strict';
// Artemis relay: serves the web apps and forwards live locations from a child's
// phone to their parent's headset. Nothing is written to disk; the last known
// position is held in memory only while the child is connected.
const http = require('http');
const https = require('https');
const fs = require('fs');
const path = require('path');
const { WebSocketServer } = require('ws');

const PORT = Number(process.env.PORT) || 8080;
const PUBLIC = path.join(__dirname, 'public');
const TYPES = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.css': 'text/css', '.json': 'application/json', '.svg': 'image/svg+xml' };
const CODE_RE = /^[A-Z0-9]{8,16}$/;

// Location updates from native watch apps arrive over plain HTTPS POST,
// since watchOS restricts WebSockets. Body: {family,id,name,lat,lon,acc,battery}
const lastPost = new Map();
function handleLocPost(req, res) {
  let body = '';
  req.on('data', c => { body += c; if (body.length > 4096) req.destroy(); });
  req.on('end', () => {
    const reply = (code, obj) => { res.writeHead(code, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(obj)); };
    let m; try { m = JSON.parse(body); } catch { return reply(400, { error: 'Invalid JSON' }); }
    const code = String(m.family || '').toUpperCase();
    const id = String(m.id || '').slice(0, 40);
    const lat = +m.lat, lon = +m.lon, now = Date.now();
    if (!CODE_RE.test(code) || !id) return reply(400, { error: 'Missing or invalid family code or device id' });
    if (!isFinite(lat) || !isFinite(lon) || Math.abs(lat) > 90 || Math.abs(lon) > 180) return reply(400, { error: 'Invalid coordinates' });
    const key = code + '/' + id;
    if (now - (lastPost.get(key) || 0) < 2000) return reply(429, { error: 'Too many updates' });
    lastPost.set(key, now);
    const f = family(code);
    const name = String(m.name || 'Child').slice(0, 24);
    if (!f.kids.has(id)) toParents(f, { type: 'hello', id, name, ts: now });
    const msg = { type: 'loc', id, name, lat, lon,
      acc: isFinite(+m.acc) ? Math.round(+m.acc) : null,
      battery: m.battery != null && isFinite(+m.battery) ? Math.round(+m.battery) : null,
      wrist: m.wrist === 'on' || m.wrist === 'off' ? m.wrist : null, // watch on/off wrist; no health values
      wristTs: m.wristTs && isFinite(+m.wristTs) ? Math.round(+m.wristTs) : null, ts: now };
    f.kids.set(id, msg);
    toParents(f, msg);
    reply(200, { ok: true, parentsOnline: f.parents.size });
  });
}
// Forget watch positions that stopped reporting 10 minutes ago.
setInterval(() => {
  const cutoff = Date.now() - 10 * 60 * 1000;
  for (const [code, f] of families) {
    for (const [id, k] of f.kids) if (k.ts < cutoff) { f.kids.delete(id); toParents(f, { type: 'left', id, ts: Date.now() }); }
    if (f.parents.size === 0 && f.kids.size === 0) families.delete(code);
  }
  for (const [k, t] of lastPost) if (t < cutoff) lastPost.delete(k);
}, 60 * 1000).unref();

function handler(req, res) {
  if (req.method === 'POST' && (req.url || '').split('?')[0] === '/api/loc') return handleLocPost(req, res);
  let p;
  try { p = decodeURIComponent((req.url || '/').split('?')[0]); } catch { res.writeHead(400); return res.end(); }
  if (p === '/') p = '/parent.html';
  const file = path.join(PUBLIC, path.normalize(p));
  if (!file.startsWith(PUBLIC + path.sep)) { res.writeHead(403); return res.end(); }
  fs.readFile(file, (err, data) => {
    if (err) { res.writeHead(404); return res.end('Not found'); }
    res.writeHead(200, { 'Content-Type': TYPES[path.extname(file)] || 'application/octet-stream', 'Cache-Control': 'no-store' });
    res.end(data);
  });
}

const useTls = process.env.TLS_CERT && process.env.TLS_KEY;
const server = useTls
  ? https.createServer({ cert: fs.readFileSync(process.env.TLS_CERT), key: fs.readFileSync(process.env.TLS_KEY) }, handler)
  : http.createServer(handler);

const wss = new WebSocketServer({ server, maxPayload: 4096 });
const families = new Map(); // code -> { parents:Set<ws>, kids:Map<id, lastLocMsg> }

const family = code => {
  let f = families.get(code);
  if (!f) { f = { parents: new Set(), kids: new Map() }; families.set(code, f); }
  return f;
};
const send = (ws, obj) => { if (ws.readyState === 1) ws.send(JSON.stringify(obj)); };
const toParents = (f, obj) => { for (const p of f.parents) send(p, obj); };

wss.on('connection', ws => {
  ws.role = null; ws.family = null; ws.lastMsg = 0;

  ws.on('message', raw => {
    let m; try { m = JSON.parse(raw); } catch { return; }
    const now = Date.now();

    if (m.type === 'join' && !ws.role) {
      const code = String(m.family || '').toUpperCase();
      if (!CODE_RE.test(code)) return send(ws, { type: 'error', error: 'That family code isn\'t valid. Check it and try again.' });
      const f = family(code);
      ws.family = code;
      if (m.role === 'parent') {
        ws.role = 'parent';
        f.parents.add(ws);
        send(ws, { type: 'joined', role: 'parent' });
        for (const k of f.kids.values()) send(ws, k);
      } else if (m.role === 'child') {
        const id = String(m.id || '').slice(0, 40);
        if (!id) return send(ws, { type: 'error', error: 'Missing device id.' });
        ws.role = 'child';
        ws.childId = id;
        ws.childName = String(m.name || 'Child').slice(0, 24);
        send(ws, { type: 'joined', role: 'child', parentsOnline: f.parents.size });
        toParents(f, { type: 'hello', id, name: ws.childName, ts: now });
      }
      return;
    }

    if (m.type === 'loc' && ws.role === 'child') {
      if (now - ws.lastMsg < 500) return; // simple rate limit
      ws.lastMsg = now;
      const lat = +m.lat, lon = +m.lon;
      if (!isFinite(lat) || !isFinite(lon) || Math.abs(lat) > 90 || Math.abs(lon) > 180) return;
      const msg = {
        type: 'loc', id: ws.childId, name: ws.childName, lat, lon,
        acc: isFinite(+m.acc) ? Math.round(+m.acc) : null,
        battery: m.battery != null && isFinite(+m.battery) ? Math.round(+m.battery) : null,
        ts: now
      };
      const f = families.get(ws.family);
      if (!f) return;
      f.kids.set(ws.childId, msg);
      toParents(f, msg);
    }
  });

  ws.on('close', () => {
    const f = families.get(ws.family);
    if (!f) return;
    if (ws.role === 'parent') f.parents.delete(ws);
    if (ws.role === 'child') {
      f.kids.delete(ws.childId);
      toParents(f, { type: 'left', id: ws.childId, ts: Date.now() });
    }
    if (f.parents.size === 0 && f.kids.size === 0) families.delete(ws.family);
  });
});

server.listen(PORT, () => {
  console.log(`Artemis running on ${useTls ? 'https' : 'http'}://localhost:${PORT}`);
  console.log(`  Parent HUD:  /parent.html   Child sharing page:  /child.html`);
});
