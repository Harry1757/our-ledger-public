import {
  bodyOf,
  respond,
  setSession,
  tokenOf,
  upstream,
  validMutation,
} from "../lib/upstream.js";
export default async function handler(req, res) {
  if (!["POST", "DELETE"].includes(req.method))
    return respond(res, 405, { error: "지원하지 않는 요청이에요." });
  if (!validMutation(req))
    return respond(res, 403, { error: "이 페이지에서 다시 연결해 주세요." });
  try {
    if (req.method === "DELETE") {
      const token = tokenOf(req);
      if (token) {
        const { status, data } = await upstream("/session", {token, method: "DELETE", body: {}});
        if (status !== 200 || data?.ok !== true)
          throw new Error("Session revocation failed");
      }
      setSession(res, "", req);
      return respond(res, 200, { ok: true });
    }
    const { code } = bodyOf(req);
    if (typeof code !== "string" || code.length > 80 || code.trim().length < 12)
      return respond(res, 400, {
        error: "아이폰에서 받은 연결 코드를 입력해 주세요.",
      });
    const { status, data } = await upstream("/device-links/redeem", {
      method: "POST",
      body: { code },
    });
    if (status !== 200)
      return respond(res, status, {
        error: data.error || "연결하지 못했어요. 새 코드를 받아 주세요.",
      });
    if (
      typeof data.token !== "string" ||
      !/^[A-Za-z0-9_-]{32,200}$/.test(data.token)
    )
      throw new Error("Invalid session");
    setSession(res, data.token, req);
    return respond(res, 200, { ok: true });
  } catch {
    return respond(res, 502, {
      error: "서버에 연결하지 못했어요. 잠시 후 다시 시도해 주세요.",
    });
  }
}
