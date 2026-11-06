import { createHash } from "node:crypto";

const production = Boolean(process.env.VERCEL) || process.env.NODE_ENV === "production";
function localDevelopment(req) {
  return !production && /^(localhost|127\.0\.0\.1|\[::1\])(:\d+)?$/.test(req?.headers.host || "");
}
function cookieName(req) {
  return localDevelopment(req) ? "ledger_session" : "__Host-ledger_session";
}
export function setSession(res, token = "", req) {
  res.setHeader(
    "Set-Cookie",
    `${cookieName(req)}=${token}; Path=/; HttpOnly; SameSite=Strict; Max-Age=${token ? 60 * 60 * 24 * 30 : 0}${localDevelopment(req) ? "" : "; Secure"}`,
  );
}
export function tokenOf(req) {
  const name = cookieName(req);
  const value =
    (req.headers.cookie || "")
      .split(";")
      .map((s) => s.trim())
      .find((s) => s.startsWith(name + "="))
      ?.slice(name.length + 1) || "";
  return /^[A-Za-z0-9_-]{32,200}$/.test(value) ? value : "";
}
// A write precondition only; authentication still uses the HttpOnly cookie.
export function sessionBinding(token) {
  return createHash("sha256").update(token).digest("hex");
}
export function respond(res, status, data) {
  res.setHeader("Cache-Control", "no-store, private");
  res.setHeader("Vercel-CDN-Cache-Control", "no-store");
  res.setHeader("Content-Type", "application/json; charset=utf-8");
  res.setHeader("X-Content-Type-Options", "nosniff");
  res.statusCode = status;
  res.end(JSON.stringify(data));
}
export function validMutation(req) {
  const scheme = localDevelopment(req) ? "http" : "https";
  return (
    req.headers.origin === `${scheme}://${req.headers.host}` &&
    req.headers["content-type"]?.split(";")[0].trim() === "application/json"
  );
}
export async function upstream(path, { token, method = "GET", body } = {}) {
  // Only administrator environment configuration chooses the upstream, never request data.
  const base =
    process.env.LEDGER_API_URL ||
    (production ? "" : "http://127.0.0.1:8817");
  const target = new URL(base);
  if (
    target.username ||
    target.password ||
    target.search ||
    target.hash ||
    !["", "/"].includes(target.pathname) ||
    (target.protocol !== "https:" && !(
      !production && target.protocol === "http:" &&
      ["localhost", "127.0.0.1", "[::1]"].includes(target.hostname)
    ))
  )
    throw new Error("Invalid server");
  const response = await fetch(target.origin + path, {
    method,
    headers: {
      "Content-Type": "application/json",
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
    ...(body ? { body: JSON.stringify(body) } : {}),
    cache: "no-store",
    redirect: "error",
    signal: AbortSignal.timeout(20_000),
  });
  const data = await response.json();
  return { status: response.status, data };
}
export function bodyOf(req) {
  const body = typeof req.body === "string" ? JSON.parse(req.body) : req.body;
  if (
    !body ||
    typeof body !== "object" ||
    Array.isArray(body) ||
    Buffer.byteLength(JSON.stringify(body)) > 32768
  )
    throw new Error("Invalid body");
  return body;
}
