export const won = (value) => new Intl.NumberFormat("ko-KR").format(value || 0);
export function today() {
  return new Intl.DateTimeFormat("sv-SE", { timeZone: "Asia/Seoul" }).format(
    new Date(),
  );
}
export function shiftMonth(month, delta) {
  const [year, m] = month.split("-").map(Number);
  const date = new Date(0);
  date.setUTCFullYear(year, m - 1 + delta, 1);
  return (
    String(date.getUTCFullYear()).padStart(4, '0') +
    "-" +
    String(date.getUTCMonth() + 1).padStart(2, "0")
  );
}
export function scopeEntries(snapshot, scope) {
  return snapshot.entries.filter(
    (e) => e.scope === scope && (scope === "shared" || e.owner === snapshot.me),
  );
}
export function totals(entries) {
  return {
    expense: entries.reduce(
      (a, e) =>
        a +
        (e.kind === "expense" ? e.amount : e.kind === "refund" ? -e.amount : 0),
      0,
    ),
    income: entries.reduce(
      (a, e) => a + (["income", "deposit"].includes(e.kind) ? e.amount : 0),
      0,
    ),
  };
}
export function expenseLabel(value) {
  return (value < 0 ? '+' : '−') + won(Math.abs(value));
}
export function categoryBreakdown(categories, entries) {
  const groups=categories.map(c=>({...c,total:totals(entries.filter(e=>e.category===c.id)).expense})).filter(c=>c.total!==0).sort((a,b)=>b.total-a.total);
  const positiveTotal=groups.reduce((sum,g)=>sum+Math.max(0,g.total),0);
  return groups.map(g=>({...g,percent:g.total>0?Math.round(g.total/positiveTotal*100):null}));
}
export function recommended(snapshot, note) {
  const key = note.replace(/\s/g, "").toLowerCase();
  if (!key) return "";
  const learned = snapshot.classificationRules?.[key];
  if (learned && snapshot.categories.some((c) => c.id === learned))
    return learned;
  const matches = snapshot.categories.filter((c) =>
    c.keywords.some(
      (w) => w.trim() && key.includes(w.replace(/\s/g, "").toLowerCase()),
    ),
  );
  return matches.length === 1 ? matches[0].id : "";
}
export function verifySaved(entry, sent) {
  for (const field of [
    "amount",
    "note",
    "scope",
    "kind",
    "payer",
    "day",
    "funding",
    "category",
  ]) {
    if (field in sent && entry[field] !== sent[field])
      throw new Error(
        "이전 요청이 이미 다른 내용으로 저장됐어요. 내역을 새로고침해 확인한 뒤 새 기록으로 입력해 주세요.",
      );
  }
}
export function demoSnapshot(month) {
  const me = "demo-me",
    other = "demo-partner";
  const categories = [
    { id: "food", name: "식비", keywords: ["점심", "밥", "빵", "저녁"] },
    { id: "cafe", name: "카페·간식", keywords: ["커피", "카페", "콜라"] },
    { id: "living", name: "생활", keywords: ["다이소", "생필품"] },
    { id: "travel", name: "교통", keywords: ["교통", "택시"] },
    { id: "health", name: "건강", keywords: ["약", "병원"] },
    { id: "etc", name: "미분류", keywords: [] },
  ];
  const fixture = [
    ["오늘 장보기", 42800, "living", "shared", me, "expense", 3],
    ["둘이 먹은 저녁", 32000, "food", "shared", other, "expense", 3],
    ["아이스 아메리카노", 4500, "cafe", "personal", me, "expense", 3],
    ["생활비 입금", 300000, "etc", "shared", me, "income", 2],
    ["다이소 생필품", 12800, "living", "shared", me, "expense", 2],
    ["점심", 11000, "food", "personal", me, "expense", 2],
    ["주말 브런치", 28600, "food", "shared", other, "expense", 1],
    ["버스 교통비", 3000, "travel", "personal", me, "expense", 1],
    ["동네 카페", 9600, "cafe", "shared", me, "expense", 1],
  ];
  return {
    me,
    household: {
      id: "demo",
      name: "우리 가계부",
      mode: "separate",
      budget: 1000000,
    },
    members: [
      { id: me, name: "다온", bank: "", account: "", holder: "" },
      { id: other, name: "하늘", bank: "예시은행", account: "000-0000-0000", holder: "하늘" },
    ],
    categories,
    classificationRules: {},
    entries: fixture.map(
      ([note, amount, category, scope, payer, kind, d], i) => ({
        id: "demo-" + i,
        note,
        amount,
        category,
        scope,
        payer,
        kind,
        day: `${month}-${String(d).padStart(2, "0")}`,
        owner: me,
        funding: "personal",
      }),
    ),
    settlement: { kind:'separate',fromID:me,toID:other,amount:147700,count:6,memberAmounts:[{id:me,amount:-234800},{id:other,amount:60600}],revision:'d'.repeat(64) },
    history: [],
    pendingSettlements: [],
    stats: {},
    personalStats: {},
  };
}
