import {
  bodyOf,
  respond,
  sessionBinding,
  tokenOf,
  upstream,
  validMutation,
} from "../lib/upstream.js";
export default async function handler(req, res) {
  const token = tokenOf(req);
  if (!token)
    return respond(res, 401, {
      error: "아이폰에서 연결 코드를 받아 시작해 주세요.",
    });
  if (!["GET", "POST"].includes(req.method))
    return respond(res, 405, { error: "지원하지 않는 요청이에요." });
  try {
    let path,
      method = "GET",
      body;
    if (req.method === "GET") {
      const month = req.query.month;
      if (
        typeof month !== "string" ||
        !/^(?!0000)\d{4}-(0[1-9]|1[0-2])$/.test(month)
      )
        return respond(res, 400, { error: "조회할 월을 확인해 주세요." });
      path = "/state?month=" + month;
    } else {
      if (!validMutation(req))
        return respond(res, 403, {
          error: "페이지를 새로고침하고 다시 시도해 주세요.",
        });
      const input = bodyOf(req);
      if (input.webSession !== sessionBinding(token))
        return respond(res, 409, {
          error: "가계부 연결이 바뀌었어요. 페이지를 새로고침한 뒤 다시 시도해 주세요.",
        });
      body = input.entry;
      if (input.action === "create") {
        path = "/entries";
        method = "POST";
      } else if (
        ["update", "delete"].includes(input.action) &&
        typeof input.id === "string" &&
        /^[A-Za-z0-9_-]{1,80}$/.test(input.id)
      ) {
        path = "/entries/" + input.id;
        method = input.action === "delete" ? "DELETE" : "PATCH";
        if (method === "DELETE") body = {};
      } else if (input.action === "category") {
        path = "/categories";
        method = "POST";
      } else if (input.action === "settle") {
        if (
          !body || typeof body !== "object" || Array.isArray(body) ||
          typeof body.month !== "string" || body.month.length !== 7 ||
          !/^(?!0000)\d{4}-(0[1-9]|1[0-2])$/.test(body.month) ||
          typeof body.revision !== "string" || body.revision.length !== 64 ||
          !/^[a-f0-9]{64}$/i.test(body.revision) ||
          typeof body.requestID !== "string" || body.requestID.length !== 36 ||
          !/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(body.requestID) ||
          (body.memberID !== null && (
            typeof body.memberID !== "string" ||
            body.memberID.length < 1 || body.memberID.length > 80 ||
            /[^A-Za-z0-9_-]/.test(body.memberID)
          ))
        )
          return respond(res, 400, { error: "정산할 내용을 확인해 주세요." });
        body = {
          month: body.month,
          revision: body.revision,
          memberID: body.memberID,
          requestID: body.requestID,
        };
        path = "/settle";
        method = "POST";
      } else
        return respond(res, 400, { error: "요청할 기록을 확인해 주세요." });
      if (!body || typeof body !== "object" || Array.isArray(body))
        return respond(res, 400, { error: "입력 내용을 확인해 주세요." });
    }
    const result = await upstream(path, { token, method, body });
    if (result.status >= 500)
      return respond(res, 502, {
        error:
          "서버에 연결하지 못했어요. 입력 내용을 유지했으니 다시 시도해 주세요.",
      });
    if (req.method === "GET" && result.status === 200)
      return respond(res, 200, { ...result.data, webSession: sessionBinding(token) });
    return respond(res, result.status, result.data);
  } catch {
    return respond(res, 502, {
      error:
        "서버 응답을 확인하지 못했어요. 입력을 유지했으니 다시 시도해 주세요.",
    });
  }
}
