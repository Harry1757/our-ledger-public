import {test} from 'node:test';
import assert from 'node:assert/strict';

let sequence = 0;
async function configured(config, check) {
  const keys = ['NODE_ENV', 'VERCEL', 'LEDGER_API_URL'];
  const previous = Object.fromEntries(keys.map(key => [key, process.env[key]]));
  const originalFetch = globalThis.fetch;
  for (const key of keys) {
    if (config[key] === undefined) delete process.env[key];
    else process.env[key] = config[key];
  }
  globalThis.fetch = async () => { throw new Error('Unexpected network request'); };
  try {
    await check(await import(`../lib/upstream.js?config=${sequence++}`));
  } finally {
    globalThis.fetch = originalFetch;
    for (const key of keys) {
      if (previous[key] === undefined) delete process.env[key];
      else process.env[key] = previous[key];
    }
  }
}
const request = (host, scheme) => ({headers: {
  host, origin: `${scheme}://${host}`, 'content-type': 'application/json',
}});
function response() {
  return {headers: {}, setHeader(key, value) { this.headers[key] = value; }};
}

test('only explicit loopback development uses HTTP and non-Secure cookies', async () => {
  for (const env of [{}, {NODE_ENV: 'production'}, {VERCEL: '1'}]) {
    await configured(env, async U => {
      for (const host of ['localhost:5183', '127.0.0.1:5183', '[::1]:5183', 'ledger.example', 'localhost.attacker.example']) {
        const local = !env.NODE_ENV && !env.VERCEL && ['localhost:5183', '127.0.0.1:5183', '[::1]:5183'].includes(host);
        const req = request(host, local ? 'http' : 'https');
        const res = response();
        U.setSession(res, 'x'.repeat(43), req);
        assert.equal(/; Secure(?:;|$)/.test(res.headers['Set-Cookie']), !local);
        assert.equal(res.headers['Set-Cookie'].startsWith('__Host-'), !local);
        assert.equal(U.validMutation(req), true);
        assert.equal(U.validMutation(request(host, local ? 'https' : 'http')), false);
        assert.equal(U.tokenOf({headers: {...req.headers, cookie: res.headers['Set-Cookie'].split(';')[0]}}), 'x'.repeat(43));
      }
    });
  }
});

test('local upstream default is loopback; production requires explicit HTTPS admin configuration', async () => {
  for (const [env, expected] of [
    [{}, 'http://127.0.0.1:8817/state?month=2026-11'],
    [{NODE_ENV: 'production'}, null],
    [{VERCEL: '1'}, null],
    [{NODE_ENV: 'production', LEDGER_API_URL: 'https://ledger.example/'}, 'https://ledger.example/state?month=2026-11'],
    [{VERCEL: '1', LEDGER_API_URL: 'https://ledger.example:8443'}, 'https://ledger.example:8443/state?month=2026-11'],
    [{LEDGER_API_URL: 'http://localhost:8817'}, 'http://localhost:8817/state?month=2026-11'],
    [{LEDGER_API_URL: 'http://[::1]:8817'}, 'http://[::1]:8817/state?month=2026-11'],
    [{NODE_ENV: 'production', LEDGER_API_URL: 'http://127.0.0.1:8817'}, null],
    [{LEDGER_API_URL: 'http://ledger.example'}, null],
    [{LEDGER_API_URL: 'ftp://localhost'}, null],
    [{LEDGER_API_URL: 'https://user:password@ledger.example'}, null],
    [{LEDGER_API_URL: 'https://ledger.example/path'}, null],
    [{LEDGER_API_URL: 'https://ledger.example?query=yes'}, null],
    [{LEDGER_API_URL: 'https://ledger.example#fragment'}, null],
  ]) {
    await configured(env, async U => {
      let calls = 0;
      globalThis.fetch = async (url, options) => {
        calls++;
        assert.equal(url, expected);
        assert.equal(options.headers.Authorization, 'Bearer synthetic-token');
        assert.equal(options.redirect, 'error');
        return {status: 200, json: async () => ({ok: true})};
      };
      if (expected) {
        assert.deepEqual(await U.upstream('/state?month=2026-11', {token: 'synthetic-token'}), {status: 200, data: {ok: true}});
        assert.equal(calls, 1);
      } else {
        await assert.rejects(() => U.upstream('/state?month=2026-11', {token: 'synthetic-token'}));
        assert.equal(calls, 0);
      }
    });
  }
});
