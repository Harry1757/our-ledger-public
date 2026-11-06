import { test } from "node:test";
import assert from "node:assert/strict";
import {
  demoSnapshot,
  scopeEntries,
  totals,
  won,
  recommended,
  verifySaved,
  shiftMonth,
} from "../src/data.js";
import ledger from "../api/ledger.js";
import session from "../api/session.js";
import { tokenOf, validMutation } from "../lib/upstream.js";
const cookieName = "ledger_session";
const token = "x".repeat(43);
const binding = "cc0b1c2c66f3bb9fd1a081c626ba1bef62f6f96441a43be15268523776ac26a1";
const settlement = {
  month: "2026-11",
  revision: "a1".repeat(32),
  memberID: null,
  requestID: "12345678-1234-4234-8234-123456789abc",
};
function response() {
  return {
    headers: {},
    setHeader(k, v) {
      this.headers[k] = v;
    },
    end(body) {
      this.body = JSON.parse(body);
    },
  };
}
const req = (method, body = {}, extra = {}) => ({
  method,
  body,
  query: { month: "2026-11" },
  headers: {
    host: "localhost:5183",
    origin: "http://localhost:5183",
    "content-type": "application/json",
    cookie: `${cookieName}=${token}`,
  },
  ...extra,
});
test("money, scopes, income and refunds retain their meaning", () => {
  const s = demoSnapshot("2026-11");
  s.entries.push({
    ...s.entries[0],
    scope: "personal",
    owner: "someone-else",
    amount: 999999,
  });
  assert.equal(won(3000000), "3,000,000");
  assert.equal(scopeEntries(s, "personal").length, 3);
  assert.deepEqual(
    totals([
      { amount: 5000, kind: "expense" },
      { amount: 1000, kind: "refund" },
      { amount: 7000, kind: "income" },
    ]),
    { expense: 4000, income: 7000 },
  );
  assert.equal(shiftMonth("2026-01", -1), "2025-12");
  assert.equal(shiftMonth("2026-12", 1), "2027-01");
});
test("classification follows user rules and keeps ambiguity explicit", () => {
  const s = demoSnapshot("2026-11");
  assert.equal(recommended(s, "점심"), "food");
  assert.equal(recommended(s, "아무거나"), "");
  s.classificationRules = { 점심: "living" };
  assert.equal(recommended(s, "점 심"), "living");
  assert.equal(recommended(s, "점심 약"), "");
});
test("an idempotent retry cannot silently replace a changed draft", () => {
  const entry = {
    amount: 3000,
    note: "점심",
    scope: "personal",
    kind: "expense",
    payer: "me",
    day: "2026-11-03",
    funding: "personal",
  };
  verifySaved({ ...entry, category: "food" }, entry);
  for (const [key, value] of Object.entries({
    amount: 4000,
    note: "다른 기록",
    scope: "shared",
    kind: "income",
    payer: "other",
    day: "2026-11-01",
    funding: "fund",
  }))
    assert.throws(() => verifySaved({ ...entry, [key]: value }, entry));
});
test("proxy rejects anonymous, foreign origins, arbitrary routes and invalid months", async () => {
  let calls = 0;
  const original = globalThis.fetch;
  globalThis.fetch = async () => {
    calls++;
    throw new Error("must not fetch");
  };
  try {
    for (const [request, status] of [
      [req("GET", {}, { headers: {}, query: { month: "2026-11" } }), 401],
      [req("POST", { action: "create", entry: {}, webSession: binding }, {
        headers: { ...req("POST").headers, cookie: "" },
      }), 401],
      [
        req(
          "POST",
          { action: "create", entry: {}, webSession: binding },
          {
            headers: {
              ...req("POST").headers,
              origin: "https://attacker.example",
            },
          },
        ),
        403,
      ],
      [req("GET", {}, { query: { month: "2026-11&token=bad" } }), 400],
      [req("POST", { action: "proxy", url: "https://attacker.example", webSession: binding }), 400],
    ]) {
      const res = response();
      await ledger(request, res);
      assert.equal(res.statusCode, status);
      assert.match(res.headers["Cache-Control"], /no-store/);
    }
    assert.equal(calls, 0);
  } finally {
    globalThis.fetch = original;
  }
});
test("session redemption returns only an opaque httpOnly cookie, never token JSON", async () => {
  const original = globalThis.fetch;
  globalThis.fetch = async (url, options) => {
    assert.equal(url, "http://127.0.0.1:8817" +
      (options.method === "DELETE" ? "/session" : "/device-links/redeem"));
    if (options.method === "DELETE")
      return {status: 200, json: async () => ({ok: true})};
    assert.equal(options.redirect, "error");
    return {
      status: 200,
      json: async () => ({ token, memberID: "me", householdID: "h" }),
    };
  };
  try {
    const res = response();
    await session(req("POST", { code: "23456789ABCDEFGH" }), res);
    assert.equal(res.statusCode, 200);
    assert.deepEqual(res.body, { ok: true });
    assert.match(res.headers["Set-Cookie"], /HttpOnly; SameSite=Strict/);
    assert.ok(!JSON.stringify(res.body).includes(token));
    const cleared = response();
    await session(req("DELETE"), cleared);
    assert.match(cleared.headers["Set-Cookie"], /Max-Age=0/);
  } finally {
    globalThis.fetch = original;
  }
});
test("upstream authorization is per browser and restricted to known operations", async () => {
  const original = globalThis.fetch;
  globalThis.fetch = async (url, options) => {
    assert.equal(
      url,
      "http://127.0.0.1:8817/entries/e-1",
    );
    assert.equal(options.method, "PATCH");
    assert.equal(options.headers.Authorization, `Bearer ${token}`);
    return { status: 200, json: async () => ({ ok: true }) };
  };
  try {
    const res = response();
    await ledger(
      req("POST", { action: "update", id: "e-1", entry: { note: "점심" }, webSession: binding }),
      res,
    );
    assert.equal(res.statusCode, 200);
    assert.equal(
      tokenOf({ headers: { cookie: "ledger_session=invalid" } }),
      "",
    );
    assert.equal(validMutation(req("POST")), true);
  } finally {
    globalThis.fetch = original;
  }
});

test("sessionBinding derives a stable SHA-256 precondition for each cookie token", async () => {
  const { sessionBinding } = await import("../lib/upstream.js");
  assert.equal(typeof sessionBinding, "function");
  assert.equal(sessionBinding(token), binding);
  assert.notEqual(sessionBinding("y".repeat(43)), binding);
});

test("ledger GET binds the snapshot to its cookie without exposing the token", async () => {
  const original = globalThis.fetch;
  const snapshot = demoSnapshot("2026-11");
  globalThis.fetch = async (url, options) => {
    assert.equal(url, "http://127.0.0.1:8817/state?month=2026-11");
    assert.equal(options.headers.Authorization, `Bearer ${token}`);
    return { status: 200, json: async () => snapshot };
  };
  try {
    const res = response();
    await ledger(req("GET"), res);
    assert.equal(res.statusCode, 200);
    assert.deepEqual(res.body, { ...snapshot, webSession: binding });
    assert.ok(!JSON.stringify(res.body).includes(token));
    assert.equal(res.headers["Set-Cookie"], undefined);
    assert.match(res.headers["Cache-Control"], /no-store/);
  } finally {
    globalThis.fetch = original;
  }
});

test("every mutation rejects missing or stale session bindings before upstream fetch", async () => {
  const original = globalThis.fetch;
  let calls = 0;
  globalThis.fetch = async () => {
    calls++;
    return { status: 200, json: async () => ({ ok: true }) };
  };
  try {
    for (const action of ["create", "update", "delete", "category", "settle"]) {
      for (const webSession of [undefined, null, "", "stale-session", token]) {
        const res = response();
        await ledger(req("POST", { action, id: "e-1", entry: settlement, webSession }), res);
        assert.equal(res.statusCode, 409, `${action}: ${webSession}`);
        assert.match(res.body.error, /새로고침/);
      }
      const res = response();
      await ledger(req("POST", { action, id: "e-1", entry: settlement, webSession: binding }, {
        headers: { ...req("POST").headers, cookie: `${cookieName}=${"y".repeat(43)}` },
      }), res);
      assert.equal(res.statusCode, 409, action);
    }
    assert.equal(calls, 0);
  } finally {
    globalThis.fetch = original;
  }
});

test("matching session bindings permit each mutation without forwarding the precondition", async () => {
  const original = globalThis.fetch;
  let calls = 0;
  const operations = [
    ["create", "/entries", "POST", { note: "점심" }],
    ["update", "/entries/e-1", "PATCH", { note: "점심" }],
    ["delete", "/entries/e-1", "DELETE", {}],
    ["category", "/categories", "POST", { name: "식비", keywords: "점심" }],
  ];
  try {
    for (const [action, path, method, entry] of operations) {
      globalThis.fetch = async (url, options) => {
        calls++;
        assert.equal(url, "http://127.0.0.1:8817" + path);
        assert.equal(options.method, method);
        assert.equal(options.headers.Authorization, `Bearer ${token}`);
        assert.deepEqual(JSON.parse(options.body), entry);
        return { status: 200, json: async () => ({ ok: true }) };
      };
      const res = response();
      await ledger(req("POST", { action, id: "e-1", entry, webSession: binding }), res);
      assert.equal(res.statusCode, 200, action);
    }
    assert.equal(calls, operations.length);
  } finally {
    globalThis.fetch = original;
  }
});

test("settle posts only whitelisted fields to the fixed authenticated endpoint", async () => {
  const original = globalThis.fetch;
  const calls = [];
  globalThis.fetch = async (url, options) => {
    calls.push({ url, options });
    return { status: 200, json: async () => ({ id: "settled-1" }) };
  };
  try {
    for (const memberID of [null, "member_1-A", "12345678-1234-4234-8234-123456789abc"]) {
      const entry = { ...settlement, memberID };
      const res = response();
      await ledger(req("POST", {
        action: "settle", webSession: binding, path: "/imports", token: "untrusted",
        entry: { ...entry, token: "untrusted", path: "/imports", importID: "not-allowed", amount: 1, webSession: binding },
      }), res);
      assert.equal(res.statusCode, 200);
      assert.deepEqual(res.body, { id: "settled-1" });
      assert.match(res.headers["Cache-Control"], /no-store/);
      assert.equal(res.headers["Vercel-CDN-Cache-Control"], "no-store");
      const { url, options } = calls.at(-1);
      assert.equal(url, "http://127.0.0.1:8817/settle");
      assert.equal(options.method, "POST");
      assert.equal(options.headers.Authorization, `Bearer ${token}`);
      assert.equal(options.cache, "no-store");
      assert.equal(options.redirect, "error");
      assert.deepEqual(JSON.parse(options.body), entry);
    }
    assert.equal(calls.length, 3);
  } finally {
    globalThis.fetch = original;
  }
});

test("settle rejects malformed fields and entries without upstream fetch", async () => {
  const original = globalThis.fetch;
  let calls = 0;
  globalThis.fetch = async () => {
    calls++;
    return { status: 200, json: async () => ({}) };
  };
  try {
    const invalid = [undefined, null, [], "invalid", 1];
    for (const [key, values] of Object.entries({
      month: [undefined, null, 202611, "0000-11", "2026-00", "2026-13", "2026-1", "2026-11&token=x", "2026-11\n"],
      revision: [undefined, null, 1, "", "a".repeat(63), "a".repeat(65), "g".repeat(64), "a".repeat(64) + "\n"],
      requestID: [undefined, null, 1, "", "12345678123442348234123456789abc", "{12345678-1234-4234-8234-123456789abc}", "12345678-1234-4234-8234-123456789abg", settlement.requestID + "\n"],
      memberID: [undefined, 1, false, {}, [], "", "a".repeat(81), "a/b", "a b", "member\n"],
    })) {
      for (const value of values) invalid.push({ ...settlement, [key]: value });
    }
    for (const entry of invalid) {
      const res = response();
      await ledger(req("POST", { action: "settle", webSession: binding, entry }), res);
      assert.equal(res.statusCode, 400, JSON.stringify(entry));
      assert.match(res.headers["Cache-Control"], /no-store/);
    }
    assert.equal(calls, 0);
  } finally {
    globalThis.fetch = original;
  }
});

test("settle requires cookie authentication and same-origin JSON writes", async () => {
  const original = globalThis.fetch;
  let calls = 0;
  globalThis.fetch = async () => {
    calls++;
    return { status: 200, json: async () => ({}) };
  };
  try {
    for (const [headers, status] of [
      [{ cookie: "" }, 401],
      [{ origin: "https://attacker.example" }, 403],
      [{ origin: undefined }, 403],
      [{ "content-type": "text/plain" }, 403],
    ]) {
      const res = response();
      await ledger(req("POST", { action: "settle", webSession: binding, entry: settlement }, {
        headers: { ...req("POST").headers, ...headers },
      }), res);
      assert.equal(res.statusCode, status);
      assert.match(res.headers["Cache-Control"], /no-store/);
    }
    assert.equal(calls, 0);
  } finally {
    globalThis.fetch = original;
  }
});

test("settle passes through stale revision errors and identical replay records", async () => {
  const original = globalThis.fetch;
  const record = {
    id: "settled-1", month: "2026-11", fromID: "member-b", toID: "member-a",
    amount: 5000, kind: "separate", signedAmount: 0,
    date: "2026-11-03T12:00:00+09:00", actor: "member-b", count: 2,
  };
  const results = [
    { status: 400, data: { error: "정산 내역이 바뀌었어요. 새 금액을 확인한 뒤 다시 진행해 주세요." } },
    { status: 200, data: record },
    { status: 200, data: record },
  ];
  const bodies = [];
  try {
    for (const result of results) {
      globalThis.fetch = async (_url, options) => {
        bodies.push(JSON.parse(options.body));
        return { status: result.status, json: async () => result.data };
      };
      const res = response();
      await ledger(req("POST", { action: "settle", webSession: binding, entry: settlement }), res);
      assert.equal(res.statusCode, result.status);
      assert.deepEqual(res.body, result.data);
      assert.match(res.headers["Cache-Control"], /no-store/);
    }
    assert.deepEqual(bodies, [settlement, settlement, settlement]);
  } finally {
    globalThis.fetch = original;
  }
});


test("disconnect requires confirmed server revocation before clearing the cookie", async () => {
  const original = globalThis.fetch;
  try {
    for (const result of [
      {status: 500, data: {error: "Failed"}},
      {status: 401, data: {error: "Unauthorized"}},
      {status: 200, data: {}},
      null,
      {status: 200, data: {ok: true}},
    ]) {
      let called = false;
      globalThis.fetch = async (url, options) => {
        called = true;
        assert.equal(url, "http://127.0.0.1:8817/session");
        assert.equal(options.method, "DELETE");
        assert.equal(options.headers.Authorization, `Bearer ${token}`);
        if (!result) throw new Error("Network failed");
        return {status: result.status, json: async () => result.data};
      };
      const res = response();
      await session(req("DELETE"), res);
      assert.equal(called, true);
      if (result?.data.ok) {
        assert.equal(res.statusCode, 200);
        assert.match(res.headers["Set-Cookie"], /Max-Age=0/);
      } else {
        assert.equal(res.statusCode, 502);
        assert.equal(res.headers["Set-Cookie"], undefined);
        assert.ok(res.body.error);
      }
    }
    globalThis.fetch = async () => { throw new Error("No cookie: must not fetch"); };
    const res = response();
    await session(req("DELETE", {}, {headers: {...req("DELETE").headers, cookie: ""}}), res);
    assert.equal(res.statusCode, 200);
  } finally {
    globalThis.fetch = original;
  }
});
