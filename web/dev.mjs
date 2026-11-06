import http from 'node:http';
import {createServer as createViteServer} from 'vite';
import session from './api/session.js';
import ledger from './api/ledger.js';
const vite = await createViteServer({server: {middlewareMode: true}, appType: 'spa'});
const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');
  const handler = {'/api/session': session, '/api/ledger': ledger}[url.pathname];
  if (!handler) return vite.middlewares(req, res);
  req.query = Object.fromEntries(url.searchParams);
  try {
    let bytes = 0, raw = '';
    for await (const chunk of req) { bytes += chunk.length; if (bytes > 32768) { res.writeHead(413); res.end(); return; } raw += chunk; }
    req.body = raw ? JSON.parse(raw) : {};
    await handler(req, res);
  } catch { res.writeHead(400, {'Content-Type':'application/json'}); res.end(JSON.stringify({error:'입력 내용을 확인해 주세요.'})); }
});
server.listen(Number(process.env.PORT || 5183), '127.0.0.1', () => console.log('Our Ledger web: http://127.0.0.1:' + (process.env.PORT || 5183)));
