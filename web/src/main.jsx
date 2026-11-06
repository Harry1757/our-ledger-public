import React, { useEffect, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import {
  BookOpen,
  CalendarDays,
  ChartNoAxesColumnIncreasing,
  Settings2,
  ArrowUpRight,
  ArrowDownLeft,
  ChevronLeft,
  ChevronRight,
  Plus,
  Search,
  X,
  LockKeyhole,
  UsersRound,
  RefreshCw,
  LogOut,
  Check,
  Monitor,
  Smartphone,
  ArrowRight,
  CircleHelp,
  ShoppingBasket,
  Coffee,
  Utensils,
  Bus,
  HeartPulse,
  Ellipsis,
  Pencil,
  Trash2,
  FolderPlus,
  CheckCircle2,
} from "lucide-react";
import {
  demoSnapshot,
  recommended,
  scopeEntries,
  shiftMonth,
  today,
  totals,
  verifySaved,
  expenseLabel,
  categoryBreakdown,
  won,
} from "./data.js";
import "./style.css";
import { settlementInfo, verifySettlementSaved } from './settlement.js';
import { SettlementShortcut, SettlementDetails } from './Settlement.jsx';

const icons = {
  food: Utensils,
  cafe: Coffee,
  living: ShoppingBasket,
  travel: Bus,
  health: HeartPulse,
};
const navItems = [
  { id: "ledger", title: "가계부", icon: BookOpen },
  { id: "calendar", title: "달력", icon: CalendarDays },
  { id: "stats", title: "통계", icon: ChartNoAxesColumnIncreasing },
  { id: "settings", title: "설정", icon: Settings2 },
];
async function api(path, options = {}) {
  const response = await fetch("/api/" + path, {
    ...options,
    headers: { "Content-Type": "application/json", ...options.headers },
    cache: "no-store",
  });
  const data = await response.json();
  if (!response.ok) {
    const error = new Error(data.error || "요청을 처리하지 못했어요.");
    error.status = response.status;
    throw error;
  }
  return data;
}
const freshDraft = (scope, me, day = today()) => ({
  note: "",
  amount: "",
  kind: "expense",
  scope,
  payer: me,
  category: "",
  funding: "personal",
  day,
});
function Segments({ value, onChange, choices, label }) {
  return (
    <div className="segments" role="group" aria-label={label}>
      {choices.map((c) => (
        <button
          key={c.value}
          type="button"
          aria-pressed={value === c.value}
          className={value === c.value ? "selected" : ""}
          onClick={() => onChange(c.value)}
        >
          {c.icon && <c.icon size={16} />} {c.label}
        </button>
      ))}
    </div>
  );
}
function Modal({ title, children, onClose, className = '', busy = false }) {
  const ref = useRef(null);
  useEffect(() => {
    const el = ref.current;
    el.querySelector('[data-initial-focus]')?.setAttribute('autofocus', '');
    el.showModal();
    return () => el.close();
  }, []);
  return (
    <dialog ref={ref} className={className} onClose={onClose} onCancel={e=>{if(busy)e.preventDefault();}} aria-labelledby="modal-title">
      <div className="modal-head">
        <h2 id="modal-title">{title}</h2>
        <button
          className="icon-button"
          aria-label="닫기"
          disabled={busy}
          onClick={() => ref.current.close()}
        >
          <X size={20} />
        </button>
      </div>
      {children}
    </dialog>
  );
}
function App() {
  const [snapshot, setSnapshot] = useState(null),
    [month, setMonth] = useState(today().slice(0, 7)),
    [scope, setScope] = useState(() =>
      localStorage.getItem("ledger-scope") === "personal"
        ? "personal"
        : "shared",
    );
  const [page, setPage] = useState("ledger"),
    [demo, setDemo] = useState(false),
    [loading, setLoading] = useState(true),
    [connected, setConnected] = useState(false),
    [rev, setRev] = useState(0);
  const [error, setError] = useState(""),
    [toast, setToast] = useState(""),
    [query, setQuery] = useState(""),
    [kindFilter, setKindFilter] = useState("all"),
    [dayFilter, setDayFilter] = useState("");
  const [draft, setDraft] = useState(null),
    [editing, setEditing] = useState(null),
    [saving, setSaving] = useState(false),
    [saveError, setSaveError] = useState(""),
    [modal, setModal] = useState(null);
  const [settlementTarget,setSettlementTarget]=useState(null),
    [settlementBusy,setSettlementBusy]=useState(false),
    [settlementError,setSettlementError]=useState('');
  const [code, setCode] = useState(""),
    [connecting, setConnecting] = useState(false),
    [connectError, setConnectError] = useState("");
  const amountRef = useRef(null),
    noteRef = useRef(null),
    createID = useRef(null),
    demos = useRef(new Map()),
    requestSerial = useRef(0),
    loadedView = useRef(''),
    focusAfterSave = useRef(false),
    identity = useRef(''),
    authGeneration = useRef(0);
  function clearAccount() {
    authGeneration.current += 1; requestSerial.current += 1;
    identity.current = ''; loadedView.current = ''; createID.current = null;
    focusAfterSave.current = false;
    setSnapshot(null); setDraft(null); setEditing(null); setSaving(false);
    setModal(null); setQuery(''); setSaveError(''); setConnected(false);
    setSettlementTarget(null); setSettlementBusy(false); setSettlementError('');
  }
  function adoptIdentity(data) {
    const next = `${data.household.id}:${data.me}:${data.webSession || 'demo'}`;
    if (identity.current !== next) {
      authGeneration.current += 1; identity.current = next;
      createID.current = null; focusAfterSave.current = false;
      setDraft(null); setEditing(null); setSaving(false); setSaveError(''); setQuery(''); setModal(null);
      setSettlementTarget(null); setSettlementBusy(false); setSettlementError('');
    }
  }
  useEffect(() => {
    localStorage.setItem("ledger-scope", scope);
    setDayFilter("");
  }, [scope]);
  useEffect(() => {
    setDayFilter("");
  }, [month]);
  useEffect(() => {
    setDraft((d) =>
      d && !editing && !saving && !d.note && !d.amount
        ? {
            ...d,
            scope,
            ...(scope === "personal" && snapshot
              ? { payer: snapshot.me, funding: "personal" }
              : {}),
            day: month === today().slice(0, 7) ? today() : month + "-01",
          }
        : d,
    );
  }, [scope, month]);
  useEffect(() => {
    if (toast) {
      const timer = setTimeout(() => setToast(""), 4500);
      return () => clearTimeout(timer);
    }
  }, [toast]);
  useEffect(() => {
    const callback = () => setRev((r) => r + 1);
    const changed = e => { if(e.key==='ledger-auth-change'){clearAccount();setRev(r=>r+1);} };
    window.addEventListener("focus", callback);
    window.addEventListener('storage',changed);
    return () => {window.removeEventListener("focus", callback);window.removeEventListener('storage',changed);};
  }, []);
  useEffect(() => {
    const serial = ++requestSerial.current,
      controller = new AbortController();
    setLoading(true);
    if (loadedView.current !== `${demo}:${month}`) setSnapshot(null);
    setError("");
    if (demo) {
      if (!demos.current.has(month))
        demos.current.set(month, demoSnapshot(month));
      adoptIdentity(demos.current.get(month));
      setSnapshot(demos.current.get(month));
      loadedView.current = `${demo}:${month}`;
      setLoading(false);
      return;
    }
    api("ledger?month=" + month, { signal: controller.signal })
      .then((data) => {
        if (serial !== requestSerial.current) return;
        adoptIdentity(data);
        setSnapshot(data);
        loadedView.current = `${demo}:${month}`;
        setConnected(true);
      })
      .catch((e) => {
        if (e.name === "AbortError" || serial !== requestSerial.current) return;
        if (e.status === 401) {
          clearAccount(); setLoading(false);
        } else setError(e.message);
      })
      .finally(() => {
        if (serial === requestSerial.current) setLoading(false);
      });
    return () => controller.abort();
  }, [month, rev, demo]);
  useEffect(() => {
    if (snapshot && focusAfterSave.current) {
      focusAfterSave.current = false;
      requestAnimationFrame(() => amountRef.current?.focus());
    }
    if (snapshot && !draft)
      setDraft(
        freshDraft(
          scope,
          snapshot.me,
          month === today().slice(0, 7) ? today() : month + "-01",
        ),
      );
  }, [snapshot]);
  useEffect(() => {
    function shortcuts(e) {
      if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "k") {
        e.preventDefault();
        document.getElementById("record-search")?.focus();
      }
      if (
        e.key === "n" &&
        !e.ctrlKey &&
        !e.metaKey &&
        !/INPUT|TEXTAREA|SELECT/.test(e.target.tagName) &&
        !document.querySelector("dialog[open]")
      ) {
        e.preventDefault();
        newEntry();
      }
    }
    window.addEventListener("keydown", shortcuts);
    return () => window.removeEventListener("keydown", shortcuts);
  }, [scope, snapshot, month, saving]);
  function startDemo() {
    setDemo(true);
    setConnected(false);
    setError("");
    setDraft(null);
  }
  async function connect(e) {
    e.preventDefault();
    if (connecting) return;
    setConnecting(true);
    setConnectError("");
    try {
      await api("session", { method: "POST", body: JSON.stringify({ code }) });
      clearAccount();
      localStorage.setItem('ledger-auth-change',crypto.randomUUID());
      setCode("");
      setDemo(false);
      setRev((r) => r + 1);
    } catch (e) {
      setConnectError(e.message);
    } finally {
      setConnecting(false);
    }
  }
  async function logout() {
    if (!demo) await api("session", { method: "DELETE", body: "{}" });
    clearAccount();
    if(!demo)localStorage.setItem('ledger-auth-change',crypto.randomUUID());
    setDemo(false);
    setConnected(false);
    setSnapshot(null);
    setDraft(null);
    setRev((r) => r + 1);
  }
  function newEntry() {
    if (!snapshot || saving) return;
    createID.current = null;
    setEditing(null);
    setSaveError("");
    setDraft(
      freshDraft(
        scope,
        snapshot.me,
        dayFilter || (month === today().slice(0, 7) ? today() : month + "-01"),
      ),
    );
    requestAnimationFrame(() => amountRef.current?.focus());
  }
  function editEntry(entry) {
    if (saving) return;
    setEditing(entry);
    setSaveError("");
    createID.current = null;
    setDraft({ ...entry, amount: won(entry.amount) });
    requestAnimationFrame(() => noteRef.current?.focus());
  }
  function changeDraft(change) {
    setSaveError("");
    setDraft((d) => ({ ...d, ...change }));
  }
  const memberName = (id) =>
    id === "fund"
      ? "공동자금"
      : snapshot?.members.find((m) => m.id === id)?.name || "나";
  const categoryName = (id) =>
    snapshot?.categories.find((c) => c.id === id)?.name || "미분류";
  const all = snapshot ? scopeEntries(snapshot, scope) : [],
    summary = totals(all);
  const settlement = snapshot ? settlementInfo(snapshot,month) : null;
  const rows = all.filter(
    (e) =>
      (!dayFilter || e.day === dayFilter) &&
      (kindFilter === "all" ||
        (kindFilter === "income"
          ? ["income", "deposit"].includes(e.kind)
          : ["expense", "refund"].includes(e.kind))) &&
      [
        e.note,
        categoryName(e.category),
        memberName(e.payer),
        String(e.amount),
        won(e.amount),
      ].some((v) => v.toLowerCase().includes(query.toLowerCase())),
  );
  const automatic = draft && snapshot ? recommended(snapshot, draft.note) : "";
  async function saveEntry(e) {
    e.preventDefault();
    if (saving || !snapshot || !draft) return;
    const amount = Number(draft.amount.replace(/,/g, ""));
    if (!Number.isSafeInteger(amount) || amount <= 0 || amount > 100000000000) {
      setSaveError("금액은 1원부터 1천억 원까지 입력해 주세요.");
      return;
    }
    if (!draft.note.trim()) {
      setSaveError("어디에 썼는지 한 줄만 적어 주세요.");
      noteRef.current?.focus();
      return;
    }
    const entry = {
      amount,
      note: draft.note.trim(),
      scope: draft.scope,
      kind: draft.kind,
      payer: draft.scope === "personal" ? snapshot.me : draft.payer,
      day: draft.day,
      funding: draft.scope === "personal" ? "personal" : draft.funding,
      ...(draft.category ? { category: draft.category } : {}),
    };
    if (editing && !entry.category)
      entry.category = automatic || editing.category;
    if (!editing) {
      createID.current ||= crypto.randomUUID();
      entry.id = createID.current;
    }
    setSaving(true);
    setSaveError("");
    const generation = authGeneration.current;
    try {
      if (demo) {
        const current = demos.current.get(month);
        let entries = current.entries;
        if (editing) entries = entries.filter((r) => r.id !== editing.id);
        const saved = {
          ...editing,
          ...entry,
          id: editing?.id || entry.id,
          owner: editing?.owner || snapshot.me,
          category:
            entry.category || automatic || snapshot.categories.at(-1).id,
        };
        const targetMonth = entry.day.slice(0, 7);
        if (!demos.current.has(targetMonth))
          demos.current.set(targetMonth, demoSnapshot(targetMonth));
        demos.current.set(month, {
          ...current,
          settlement:null,
          entries: entries.filter((r) => r.id !== saved.id),
        });
        const target = demos.current.get(targetMonth);
        demos.current.set(targetMonth, {
          ...target,
          settlement:null,
          entries: [saved, ...target.entries.filter((r) => r.id !== saved.id)],
        });
      } else {
        const saved = await api("ledger", {
          method: "POST",
          body: JSON.stringify({
            action: editing ? "update" : "create",
            webSession: snapshot.webSession,
            ...(editing ? { id: editing.id } : {}),
            entry,
          }),
        });
        verifySaved(saved, entry);
      }
      if (generation !== authGeneration.current) return;
      setToast(
        editing
          ? "기록을 수정했어요."
          : `${entry.scope === "shared" ? "공용" : "개인"} ${entry.kind === "income" ? "수입" : "지출"}을 기록했어요.`,
      );
      setScope(entry.scope);
      setMonth(entry.day.slice(0, 7));
      setDayFilter("");
      setQuery("");
      setKindFilter("all");
      setEditing(null);
      createID.current = null;
      setDraft(freshDraft(entry.scope, snapshot.me, entry.day));
      focusAfterSave.current = true;
      setRev((r) => r + 1);
      requestAnimationFrame(() => amountRef.current?.focus());
    } catch (e) {
      if (generation !== authGeneration.current) return;
      if(e.status===401||e.status===409){clearAccount();setRev(r=>r+1);setToast('연결이 바뀌어 이전 입력을 지웠어요.');return;}
      setSaveError(e.message);
    } finally {
      if (generation === authGeneration.current) setSaving(false);
    }
  }
  async function deleteEntry() {
    if (saving || !editing) return;
    setSaving(true);
    setSaveError("");
    const generation = authGeneration.current;
    try {
      if (demo) {
        const current = demos.current.get(month);
        demos.current.set(month, {
          ...current,
          settlement:null,
          entries: current.entries.filter((e) => e.id !== editing.id),
        });
      } else
        await api("ledger", {
          method: "POST",
          body: JSON.stringify({ action: "delete", id: editing.id, webSession:snapshot.webSession }),
        });
      if(generation!==authGeneration.current)return;
      setModal(null);
      setEditing(null);
      setDraft(freshDraft(scope, snapshot.me,dayFilter || (month===today().slice(0,7)?today():month+'-01')));
      setRev((r) => r + 1);
      setToast("기록을 삭제했어요.");
    } catch (e) {
      if(generation!==authGeneration.current)return;
      if(e.status===401||e.status===409){clearAccount();setRev(r=>r+1);return;}
      setSaveError(e.message);
      setModal(null);
    } finally {
      if(generation===authGeneration.current)setSaving(false);
    }
  }
  async function copySettlement(value,label) {
    try { await navigator.clipboard.writeText(value); setToast(label+' 복사했어요.'); }
    catch { setToast('복사하지 못했어요. 내용을 직접 선택해 복사해 주세요.'); }
  }
  async function completeSettlement() {
    if(settlementBusy||!settlementTarget||!snapshot||demo)return;
    const target=settlementTarget,generation=authGeneration.current;
    setSettlementBusy(true);setSettlementError('');
    try {
      const saved=await api('ledger',{method:'POST',body:JSON.stringify({action:'settle',webSession:snapshot.webSession,entry:{month:target.month,revision:target.revision,memberID:target.memberID,requestID:target.requestID}})});
      verifySettlementSaved(saved,target);
      if(generation!==authGeneration.current)return;
      setModal(null);setSettlementTarget(null);setRev(r=>r+1);setToast('정산 완료를 기록했어요.');
    } catch(e) {
      if(generation!==authGeneration.current)return;
      if(e.status===401||e.status===409){clearAccount();setRev(r=>r+1);setToast('연결이 변경됐어요. 다시 연결해 주세요.');return;}
      setSettlementError(e.message);
    } finally { if(generation===authGeneration.current)setSettlementBusy(false); }
  }
  function categoryIcon(id) {
    const name = categoryName(id);
    return (
      icons[id] ||
      (name.includes("식")
        ? Utensils
        : name.includes("카페")
          ? Coffee
          : name.includes("교통")
            ? Bus
            : name.includes("건강")
              ? HeartPulse
              : ShoppingBasket)
    );
  }

  if (!demo && !connected)
    return (
      <main className="welcome">
        <div className="welcome-brand">
          <span className="brand-mark">
            <BookOpen size={23} />
          </span>{" "}
          우리 가계부
        </div>
        <div className="welcome-layout">
          <section className="welcome-copy">
            <div className="eyebrow">
              <Monitor size={17} /> 우리 가계부 PC
            </div>
            <h1>
              함께 쓴 돈도,
              <br />
              내가 쓴 돈도.
              <br />
              <span>편하게 기록해요.</span>
            </h1>
            <p>
              아이폰에서 보던 가계부 그대로.
              <br />
              넓은 화면과 키보드로 가볍게 정리하세요.
            </p>
            <div className="welcome-tags">
              <span>
                <UsersRound size={16} /> 공용은 함께
              </span>
              <span>
                <LockKeyhole size={16} /> 개인은 나만
              </span>
            </div>
            <div className="mini-ledger">
              <div className="mini-icon">
                <Utensils size={24} />
              </div>
              <div>
                <strong>오늘 둘이 먹은 저녁</strong>
                <small>식비 · 공용</small>
              </div>
              <b>32,000원</b>
              <span className="mini-check">
                <Check size={15} />
              </span>
            </div>
          </section>
          <section className="connect-card">
            <span className="connect-icon">
              <Smartphone size={28} />
            </span>
            <h2>내 가계부 연결하기</h2>
            <p>
              아이폰의 <strong>설정 → PC에서 기록하기</strong>에서
              <br />
              연결 코드를 받아 주세요.
            </p>
            <form onSubmit={connect}>
              <label htmlFor="connection-code">연결 코드</label>
              <input
                id="connection-code"
                value={code}
                onChange={(e) => setCode(e.target.value)}
                placeholder="아이폰에서 받은 코드 붙여넣기"
                autoComplete="off"
                spellCheck={false}
                maxLength={80}
                required
              />
              <small>코드는 5분 동안 한 번만 사용할 수 있어요.</small>
              {connectError && (
                <p className="form-error" role="alert">
                  {connectError}
                </p>
              )}
              <button
                className="primary full"
                disabled={connecting || code.trim().length < 12}
              >
                {connecting ? "연결하는 중…" : "가계부 연결하기"}{" "}
                <ArrowRight size={18} />
              </button>
            </form>
            {error && (
              <p className="form-error" role="alert">
                {error}
              </p>
            )}
            <div className="demo-choice">
              <span>먼저 둘러보고 싶다면</span>
              <button className="text-button" onClick={startDemo}>
                체험 가계부 열기 <ArrowRight size={15} />
              </button>
            </div>
          </section>
        </div>
        <footer>둘이 쓰는 생활비, 우리 가계부</footer>
      </main>
    );

  return (
    <div className="app-shell">
      <aside className="sidebar">
        <a
          className="brand"
          href="#"
          onClick={(e) => {
            e.preventDefault();
            setPage("ledger");
          }}
        >
          <span className="brand-mark">
            <BookOpen size={22} />
          </span>
          <strong>우리 가계부</strong>
        </a>
        <div className="household-label">
          {snapshot?.household.name || "내 가계부"}
        </div>
        <nav aria-label="주 메뉴">
          {navItems.map((item) => (
            <button
              key={item.id}
              className={page === item.id ? "nav-item active" : "nav-item"}
              aria-current={page === item.id ? "page" : undefined}
              aria-label={item.title}
              onClick={() => {
                setPage(item.id);
                setDayFilter("");
              }}
            >
              <item.icon size={20} />
              <span>{item.title}</span>
              {item.id === "ledger" && <kbd>N</kbd>}
            </button>
          ))}
        </nav>
        <div className="sidebar-bottom">
          <div className="connection-state">
            <span />
            {demo ? "체험 가계부" : "아이폰과 함께 기록 중"}
          </div>
          <p>
            {demo
              ? "체험 기록은 실제 가계부에 저장되지 않아요."
              : "공용 내역만 상대방과 공유돼요."}
          </p>
          <button className="profile" onClick={() => setPage("settings")}>
            <span className="avatar">
              {demo ? "나" : memberName(snapshot?.me).slice(0, 1)}
            </span>
            <span>
              <strong>{demo ? "체험 사용자" : memberName(snapshot?.me)}</strong>
              <small>{demo ? "연결 없이 둘러보기" : "내 가계부"}</small>
            </span>
            <Settings2 size={17} />
          </button>
        </div>
      </aside>
      <div className="workspace">
        <header className="topbar">
          <div className="scope-switch">
            <Segments
              label="조회 범위"
              value={scope}
              onChange={setScope}
              choices={[
                { value: "shared", label: "공용", icon: UsersRound },
                { value: "personal", label: "개인", icon: LockKeyhole },
              ]}
            />
            <span className="scope-caption">
              {scope === "shared" ? "함께 쓰는 생활비" : "나만 보는 개인 기록"}
            </span>
          </div>
          <div className="top-actions">
            {demo && <span className="demo-badge">체험 중</span>}
            <button
              className="icon-button"
              aria-label="새로고침"
              disabled={loading}
              onClick={() => setRev((r) => r + 1)}
            >
              <RefreshCw size={18} className={loading ? "spin" : ""} />
            </button>
            <button className="secondary compact" onClick={newEntry}>
              <Plus size={17} /> 기록하기
            </button>
          </div>
        </header>
        <main className="main-grid">
          <div className="main-content">
            <div className="page-heading">
              <div>
                <h1>
                  {page === "settings" ? (
                    "설정"
                  ) : page === "stats" ? (
                    "통계"
                  ) : (
                    <>
                      <span>{Number(month.slice(0, 4))}년</span>{" "}
                      {Number(month.slice(5))}월
                    </>
                  )}
                </h1>
                {page === 'stats' && <p className="stats-month">{Number(month.slice(0,4))}년 {Number(month.slice(5))}월</p>}
              </div>
              {page !== "settings" && (
                <div className="month-nav">
                  <button
                    className="icon-button"
                    aria-label="이전 달"
                    onClick={() => setMonth((m) => shiftMonth(m, -1))}
                    disabled={loading || month === "0001-01"}
                  >
                    <ChevronLeft size={21} />
                  </button>
                  <button
                    className="text-button month-today"
                    onClick={() => setMonth(today().slice(0, 7))}
                  >
                    이번 달
                  </button>
                  <button
                    className="icon-button"
                    aria-label="다음 달"
                    onClick={() => setMonth((m) => shiftMonth(m, 1))}
                    disabled={loading || month === "9999-12"}
                  >
                    <ChevronRight size={21} />
                  </button>
                </div>
              )}
            </div>
            {error && (
              <div className="error-panel" role="alert">
                {error}
                <button onClick={() => setRev((r) => r + 1)}>다시 시도</button>
              </div>
            )}
            {loading && !snapshot ? (
              <div className="loading-area" role="status">
                <RefreshCw className="spin" size={22} />
                <span>가계부를 불러오고 있어요</span>
              </div>
            ) : (
              snapshot && (
                <>
                  {page !== "settings" && (
                    <section
                      className={
                        "summary " +
                        (scope === "personal" ? "private-summary" : "")
                      }
                      aria-label="월 요약"
                    >
                      <div className="summary-main">
                        <span>
                          {scope === "shared" ? "함께 쓴 돈" : "내가 쓴 돈"}
                        </span>
                        <strong>
                          {won(summary.expense)}
                          <small>원</small>
                        </strong>
                        <p>
                          {scope === "shared"
                            ? `${snapshot.members.length}명이 함께 관리하는 공용 기록`
                            : "개인 기록은 상대방에게 보이지 않아요"}
                        </p>
                      </div>
                      <div className="summary-side">
                        <span>
                          <ArrowDownLeft size={16} /> 들어온 돈
                        </span>
                        <strong className="income">
                          +{won(summary.income)}원
                        </strong>
                        <span className="summary-count">
                          이번 달 기록 <b>{all.length}건</b>
                        </span>
                      </div>
                    </section>
                  )}
                  {scope==='shared'&&page!=='settings'&&<SettlementShortcut info={settlement} me={snapshot.me} loading={loading} onOpen={()=>{setSettlementTarget(null);setSettlementError('');setModal('settlement');}}/>}
                  {page === "ledger" && (
                    <section className="records-section">
                      <div className="section-heading">
                        <h2>
                          거래 내역 <span>{rows.length}</span>
                        </h2>
                        <button
                          className="text-button"
                          onClick={() => setPage("calendar")}
                        >
                          <CalendarDays size={16} /> 달력으로 보기
                        </button>
                      </div>
                      <div className="record-tools">
                        <div className="search-field">
                          <Search size={18} />
                          <input
                            id="record-search"
                            type="search"
                            value={query}
                            onChange={(e) => setQuery(e.target.value)}
                            placeholder="내용, 분류, 결제자 검색"
                            aria-label="거래 검색"
                          />
                          <kbd>⌘ K</kbd>
                        </div>
                        <select
                          value={kindFilter}
                          onChange={(e) => setKindFilter(e.target.value)}
                          aria-label="거래 종류 필터"
                        >
                          <option value="all">전체 내역</option>
                          <option value="expense">지출</option>
                          <option value="income">수입</option>
                        </select>
                      </div>
                      <Records
                        rows={rows}
                        me={snapshot.me}
                        categoryName={categoryName}
                        memberName={memberName}
                        iconFor={categoryIcon}
                        onEdit={editEntry}
                        selectedID={editing?.id}
                      />
                    </section>
                  )}
                  {page === "calendar" && (
                    <section className="records-section">
                      <div className="section-heading">
                        <h2>거래 달력</h2>
                        <span className="calendar-legend">
                          <i /> 지출 <i /> 수입
                        </span>
                      </div>
                      <Calendar
                        month={month}
                        entries={all}
                        selected={dayFilter}
                        onSelect={(d) => setDayFilter(dayFilter === d ? "" : d)}
                      />
                      <div className="section-heading day-heading">
                        <h2>
                          {dayFilter
                            ? `${Number(dayFilter.slice(-2))}일 기록`
                            : "이번 달 기록"}{" "}
                          <span>{rows.length}</span>
                        </h2>
                        {dayFilter && (
                          <button
                            className="text-button"
                            onClick={() => setDayFilter("")}
                          >
                            월 전체 보기
                          </button>
                        )}
                      </div>
                      <Records
                        rows={rows}
                        me={snapshot.me}
                        categoryName={categoryName}
                        memberName={memberName}
                        iconFor={categoryIcon}
                        onEdit={editEntry}
                        selectedID={editing?.id}
                      />
                    </section>
                  )}
                  {page === "stats" && (
                    <Stats
                      entries={all}
                      snapshot={snapshot}
                      scope={scope}
                      categoryName={categoryName}
                      iconFor={categoryIcon}
                    />
                  )}
                  {page === "settings" && (
                    <section className="settings-panel">
                      <h2>내 가계부</h2>
                      <div className="setting-row">
                        <span className="setting-icon"><UsersRound size={21} /></span>
                        <div>
                          <strong>{snapshot.household.name}</strong>
                          <p>
                            {snapshot.household.mode === "pool"
                              ? "돈을 모아서 함께 사용해요"
                              : "각자 결제하고 생활비를 정산해요"}
                          </p>
                        </div>
                        <span className="pill">
                          {snapshot.members.length}명
                        </span>
                      </div>
                      <div className="setting-row">
                        <span className="setting-icon"><LockKeyhole size={21} /></span>
                        <div>
                          <strong>{memberName(snapshot.me)}</strong>
                          <p>
                            이 PC는 내 아이폰과 같은 사람으로 연결돼 있어요.
                          </p>
                        </div>
                      </div>
                      <div className="section-heading settings-categories">
                        <h2>카테고리</h2>
                        <button
                          className="text-button"
                          onClick={() => setModal("category")}
                        >
                          <Plus size={17} /> 추가
                        </button>
                      </div>
                      <div className="category-chips">
                        {snapshot.categories.map((c) => (
                          <span key={c.id}>{c.name}</span>
                        ))}
                      </div>
                      <div className="setting-row disconnect">
                        <div>
                          <strong>PC 연결 해제</strong>
                          <p>아이폰과 가계부 기록은 그대로 유지돼요.</p>
                        </div>
                        <button
                          className="secondary"
                          onClick={() => setModal("logout")}
                        >
                          <LogOut size={16} />{" "}
                          {demo ? "체험 끝내기" : "연결 해제"}
                        </button>
                      </div>
                    </section>
                  )}
                </>
              )
            )}
          </div>
          <aside className="entry-pane" aria-label="기록 입력">
            <div className="entry-title">
              <span className="entry-symbol">
                {editing ? <Pencil size={20} /> : <Plus size={22} />}
              </span>
              <h2>{editing ? "기록 수정" : "빠르게 기록하기"}</h2>
              {editing && (
                <button
                  className="icon-button"
                  aria-label="수정 취소"
                  onClick={newEntry}
                  disabled={saving}
                >
                  <X size={18} />
                </button>
              )}
            </div>
            {draft && snapshot ? (
              <form
                onSubmit={saveEntry}
                onKeyDown={(e) => {
                  if (
                    e.key === "Enter" &&
                    (e.nativeEvent.isComposing || e.nativeEvent.keyCode === 229)
                  )
                    e.preventDefault();
                  if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
                    e.preventDefault();
                    e.currentTarget.requestSubmit();
                  }
                }}
              >
                <fieldset
                  disabled={
                    saving ||
                    Boolean(
                      editing &&
                      (editing.settlement ||
                        editing.owner !== snapshot.me ||
                        snapshot.entries.some(
                          (e) => e.refundOf === editing.id,
                        )),
                    )
                  }
                >
                  <Segments
                    label="거래 종류"
                    value={draft.kind}
                    onChange={(kind) => changeDraft({ kind })}
                    choices={
                      ["refund", "deposit"].includes(editing?.kind)
                        ? [
                            {
                              value: editing.kind,
                              label:
                                editing.kind === "refund"
                                  ? "기존 환불"
                                  : "공동자금 입금",
                            },
                          ]
                        : [
                            { value: "expense", label: "지출" },
                            { value: "income", label: "수입" },
                          ]
                    }
                  />
                  <div className="amount-field">
                    <label htmlFor="entry-amount">금액</label>
                    <div>
                      <input
                        ref={amountRef}
                        id="entry-amount"
                        inputMode="numeric"
                        autoComplete="off"
                        value={draft.amount}
                        placeholder="0"
                        maxLength={18}
                        onChange={(e) => {
                          const raw = e.target.value.replace(/[^0-9]/g, "");
                          changeDraft({ amount: raw ? won(Number(raw)) : "" });
                        }}
                        required
                      />
                      <span>원</span>
                    </div>
                  </div>
                  <label className="input-label" htmlFor="entry-note">
                    {draft.kind === "income"
                      ? "어떤 수입인가요?"
                      : "어디에 썼나요?"}
                  </label>
                  <div className="note-field">
                    <input
                      ref={noteRef}
                      id="entry-note"
                      value={draft.note}
                      onChange={(e) => changeDraft({ note: e.target.value })}
                      maxLength={120}
                      autoComplete="off"
                      placeholder={
                        draft.kind === "income"
                          ? "예: 이번 달 생활비"
                          : "예: 점심, 장보기, 커피"
                      }
                      required
                    />
                    {draft.note && (
                      <button
                        type="button"
                        className="icon-button"
                        aria-label="내용 모두 지우기"
                        onClick={() => {
                          changeDraft({ note: "" });
                          noteRef.current?.focus();
                        }}
                      >
                        <X size={17} />
                      </button>
                    )}
                  </div>
                  <div className="scope-entry">
                    <label className="input-label">
                      누구를 위한 기록인가요?
                    </label>
                    <Segments
                      label="기록 공개 범위"
                      value={draft.scope}
                      onChange={(value) =>
                        changeDraft({
                          scope: value,
                          ...(value === "personal"
                            ? { payer: snapshot.me, funding: "personal" }
                            : {}),
                        })
                      }
                      choices={[
                        { value: "shared", label: "공용", icon: UsersRound },
                        { value: "personal", label: "개인", icon: LockKeyhole },
                      ]}
                    />
                    <p>
                      {draft.scope === "shared"
                        ? "상대방과 함께 보는 기록이에요."
                        : "나만 볼 수 있는 기록이에요."}
                    </p>
                  </div>
                  <div className="form-details">
                    <label>
                      날짜
                      <input
                        type="date"
                        value={draft.day}
                        onChange={(e) => changeDraft({ day: e.target.value })}
                        required
                      />
                    </label>
                    <label>
                      카테고리
                      <select
                        value={draft.category}
                        onChange={(e) =>
                          changeDraft({ category: e.target.value })
                        }
                      >
                        <option value="">
                          자동 분류
                          {automatic ? " · " + categoryName(automatic) : ""}
                        </option>
                        {snapshot.categories.map((c) => (
                          <option key={c.id} value={c.id}>
                            {c.name}
                          </option>
                        ))}
                      </select>
                    </label>
                    <label>
                      {draft.kind === "income" ? "받은 사람" : "결제한 사람"}
                      <select
                        value={
                          draft.scope === "personal" ? snapshot.me : draft.payer
                        }
                        onChange={(e) => changeDraft({ payer: e.target.value })}
                        disabled={draft.scope === "personal"}
                      >
                        {snapshot.members.map((m) => (
                          <option key={m.id} value={m.id}>
                            {m.id === snapshot.me ? "나 · " : ""}
                            {m.name}
                          </option>
                        ))}
                      </select>
                    </label>
                    {snapshot.household.mode === "pool" &&
                      draft.scope === "shared" && (
                        <label>
                          {draft.kind === "income" ? "받은 계좌" : "결제한 돈"}
                          <select
                            value={draft.funding}
                            onChange={(e) =>
                              changeDraft({ funding: e.target.value })
                            }
                          >
                            <option value="personal">개인 돈</option>
                            <option value="fund">공동자금</option>
                          </select>
                        </label>
                      )}
                  </div>
                  <button
                    className="primary full save-button"
                    type="submit"
                    disabled={
                      saving ||
                      !draft.note.trim() ||
                      !Number(draft.amount.replace(/,/g, ""))
                    }
                  >
                    {saving ? (
                      <RefreshCw size={18} className="spin" />
                    ) : (
                      <Check size={18} />
                    )}{" "}
                    {saving
                      ? "저장하는 중…"
                      : editing
                        ? "수정 저장하기"
                        : "기록하기"}
                    <kbd>↵</kbd>
                  </button>
                </fieldset>
                {editing &&
                  (editing.settlement ||
                    editing.owner !== snapshot.me ||
                    snapshot.entries.some(
                      (e) => e.refundOf === editing.id,
                    )) && (
                    <p className="form-info">
                      <LockKeyhole size={16} />
                      {editing.owner !== snapshot.me
                        ? "작성한 사람만 수정할 수 있어요."
                        : editing.settlement
                          ? "정산한 기록은 수정·삭제할 수 없어요."
                          : "환불이 연결된 원래 기록은 수정할 수 없어요."}
                    </p>
                  )}
                {saveError && (
                  <p className="form-error" role="alert">
                    {saveError}
                  </p>
                )}
                {editing &&
                  !editing.settlement &&
                  editing.owner === snapshot.me &&
                  !snapshot.entries.some((e) => e.refundOf === editing.id) && (
                    <button
                      type="button"
                      className="delete-entry text-button"
                      onClick={() => setModal("delete")}
                      disabled={saving}
                    >
                      <Trash2 size={15} /> 이 기록 삭제
                    </button>
                  )}
                {!editing && (
                  <p className="entry-tip">
                    저장 후 바로 다음 기록을 입력할 수 있어요.
                  </p>
                )}
              </form>
            ) : (
              <div className="entry-placeholder">
                가계부를 불러오면 기록할 수 있어요.
              </div>
            )}
          </aside>
        </main>
      </div>
      {toast && (
        <div className="toast" role="status">
          <CheckCircle2 size={19} />
          {toast}
        </div>
      )}
      {modal==='settlement'&&snapshot&&<Modal title="생활비 정산" className="settlement-dialog" busy={settlementBusy} onClose={()=>{setModal(null);setSettlementTarget(null);setSettlementError('');}}>
        <SettlementDetails snapshot={snapshot} info={settlement} month={month} loading={loading} target={settlementTarget} busy={settlementBusy} error={settlementError} demo={demo}
          onSelect={t=>{setSettlementError('');setSettlementTarget({...t,requestID:crypto.randomUUID()});}}
          onBack={()=>{setSettlementTarget(null);setSettlementError('');}}
          onComplete={completeSettlement} onCopy={copySettlement}
          onMonth={m=>{setModal(null);setSettlementTarget(null);setMonth(m);}}
          onRefresh={()=>{setSettlementTarget(null);setSettlementError('');setRev(r=>r+1);}}/>
      </Modal>}
      {modal === "delete" && (
        <Modal title="이 기록을 삭제할까요?" onClose={() => setModal(null)}>
          <p className="modal-copy">
            {editing?.note}
            <br />
            <strong>{won(editing?.amount)}원</strong>
          </p>
          <p className="modal-copy">삭제하면 가계부에서 제외돼요.</p>
          <div className="modal-actions">
            <button
              className="secondary"
              data-initial-focus
              onClick={() => setModal(null)}
              disabled={saving}
            >
              유지하기
            </button>
            <button className="danger" onClick={deleteEntry} disabled={saving}>
              {saving ? "삭제 중…" : "삭제하기"}
            </button>
          </div>
        </Modal>
      )}
      {modal === "logout" && (
        <Modal
          title={demo ? "체험을 끝낼까요?" : "이 PC의 연결을 해제할까요?"}
          onClose={() => setModal(null)}
        >
          <p className="modal-copy">
            {demo
              ? "체험 중 입력한 기록은 사라져요."
              : "다시 연결하려면 아이폰에서 새 코드를 받아 주세요. 기존 기록은 지워지지 않아요."}
          </p>
          <div className="modal-actions">
            <button
              className="secondary"
              data-initial-focus
              onClick={() => setModal(null)}
            >
              취소
            </button>
            <button
              className="primary"
              onClick={async () => {
                try {
                  await logout();
                  setModal(null);
                } catch (e) {
                  setError(e.message);
                  setModal(null);
                }
              }}
            >
              연결 해제
            </button>
          </div>
        </Modal>
      )}
      {modal === "category" && (
        <CategoryModal
          onClose={() => setModal(null)}
          onSave={async (name, keywords) => {
            const generation=authGeneration.current;
            if (demo) {
              const current = demos.current.get(month);
              const updated = {
                ...current,
                categories: [
                  ...current.categories,
                  {
                    id: crypto.randomUUID(),
                    name,
                    keywords: keywords
                      .split(",")
                      .map((s) => s.trim())
                      .filter(Boolean),
                  },
                ],
              };
              demos.current.set(month, updated);
              setSnapshot(updated);
            } else
              await api("ledger", {
                method: "POST",
                body: JSON.stringify({
                  action: "category",
                  webSession:snapshot.webSession,
                  entry: { name, keywords },
                }),
              });
            if(generation!==authGeneration.current)throw new Error('연결이 변경됐어요. 다시 확인해 주세요.');
            setRev((r) => r + 1);
            setToast("카테고리를 추가했어요.");
          }}
        />
      )}
    </div>
  );
}
function Records({
  rows,
  me,
  categoryName,
  memberName,
  iconFor,
  onEdit,
  selectedID,
}) {
  if (!rows.length)
    return (
      <div className="empty">
        <BookOpen size={30} />
        <h3>아직 기록이 없어요</h3>
        <p>
          오른쪽에서 첫 기록을 남겨보세요.
          <br />
          검색 중이라면 다른 단어로 찾아보세요.
        </p>
      </div>
    );
  const groups = Object.groupBy(
    [...rows].sort((a, b) => b.day.localeCompare(a.day)),
    (e) => e.day,
  );
  return (
    <div className="record-list">
      {Object.entries(groups).map(([day, entries]) => (
        <section key={day} className="day-group">
          <div className="day-group-title">
            <h3>
              {Number(day.slice(5, 7))}월 {Number(day.slice(-2))}일{" "}
              <span>
                {new Intl.DateTimeFormat("ko", { weekday: "short" }).format(
                  new Date(day + "T12:00:00"),
                )}
                요일
              </span>
            </h3>
            <span>지출 {won(totals(entries).expense)}원</span>
          </div>
          {entries.map((entry) => {
            const Icon = iconFor(entry.category),
              income = ["income", "deposit", "refund"].includes(entry.kind),
              payerRole = entry.payer === "fund" ? "fund" : entry.payer === me ? "me" : "other",
              payerLabel = payerRole === "fund" ? "공동자금" : payerRole === "me" ? "나" : memberName(entry.payer);
            return (
              <button
                className={
                  "record-row " +
                  (selectedID === entry.id ? "record-selected" : "")
                }
                key={entry.id}
                onClick={() => onEdit(entry)}
              >
                <span
                  className={"category-icon " + (income ? "income-icon" : "")}
                >
                  <Icon size={21} />
                </span>
                <span className="record-description">
                  <strong>{entry.note}</strong>
                  <small>
                    {categoryName(entry.category)}
                    <span
                      className={"payer-badge payer-" + payerRole}
                      title={memberName(entry.payer)}
                      aria-label={(income ? "받은 사람: " : "결제자: ") + (payerRole==='me'?'나 · ':'') + memberName(entry.payer)}
                    >
                      {payerLabel}
                    </span>
                    {entry.settlement && <LockKeyhole size={12} />}
                  </small>
                </span>
                <span className={"record-amount " + (income ? "income" : "")}>
                  {income ? "+" : "−"}
                  {won(entry.amount)}
                  <small>원</small>
                </span>
                <ChevronRight size={16} className="record-chevron" />
              </button>
            );
          })}
        </section>
      ))}
    </div>
  );
}
function Calendar({ month, entries, selected, onSelect }) {
  const [year, m] = month.split("-").map(Number),
    first = new Date(year, m - 1, 1).getDay(),
    days = new Date(year, m, 0).getDate();
  return (
    <div className="calendar">
      <div className="calendar-weekdays">
        {["일", "월", "화", "수", "목", "금", "토"].map((d) => (
          <span key={d}>{d}</span>
        ))}
      </div>
      <div className="calendar-cells">
        {Array.from({ length: first }, (_, i) => (
          <div className="calendar-blank" key={"blank" + i} />
        ))}
        {Array.from({ length: days }, (_, i) => {
          const day = month + "-" + String(i + 1).padStart(2, "0"),
            t = totals(entries.filter((e) => e.day === day));
          return (
            <button
              className={
                "calendar-cell " +
                (selected === day ? "calendar-selected" : "") +
                (day === today() ? " calendar-today" : "")
              }
              key={day}
              aria-label={`${i + 1}일 지출 ${won(t.expense)}원 수입 ${won(t.income)}원`}
              aria-pressed={selected === day}
              onClick={() => onSelect(day)}
            >
              <span>{i + 1}</span>
              <div>
                {t.expense !== 0 && (
                  <small className={t.expense<0?'income':'expense'}>{expenseLabel(t.expense)}</small>
                )}
                {t.income !== 0 && (
                  <small className="income">+{won(t.income)}</small>
                )}
              </div>
            </button>
          );
        })}
      </div>
    </div>
  );
}
function Stats({ entries, snapshot, scope, categoryName, iconFor }) {
  const groups = categoryBreakdown(snapshot.categories, entries);
  return (
    <section className="stats-panel">
      <h2>어디에 많이 썼을까요?</h2>
      <p className="section-subtitle">
        {scope === "shared" ? "공용" : "개인"} 지출을 카테고리별로 살펴봐요.
      </p>
      {groups.length ? (
        <>
          <div className="category-stack" aria-label="카테고리별 비중">
            {groups.filter(g=>g.total>0).map((g, i) => (
              <span
                key={g.id}
                title={g.name}
                style={{
                  flex: g.total,
                  background: [
                    "#ed600a",
                    "#ff9d50",
                    "#ffc18b",
                    "#ffdcb9",
                    "#f7eadd",
                  ][i % 5],
                }}
              />
            ))}
          </div>
          <div className="stats-categories">
            {groups.map((g) => {
              const Icon = iconFor(g.id);
              return (
                <div className="stats-category" key={g.id}>
                  <span className="category-icon">
                    <Icon size={20} />
                  </span>
                  <span>
                    <strong>{g.name}</strong>
                    <small>
                      {g.percent===null?'환불':g.percent+'%'}
                    </small>
                  </span>
                  <b className={g.total<0?'income':''}>{won(g.total)}원</b>
                </div>
              );
            })}
          </div>
        </>
      ) : (
        <div className="empty">
          <ChartNoAxesColumnIncreasing size={32} />
          <h3>첫 기록이 통계의 시작이에요</h3>
          <p>지출을 기록하면 분류별 흐름을 보여드려요.</p>
        </div>
      )}
      <div className="stats-insight">
        <span>
          <BookOpen size={19} />
        </span>
        <p>
          이번 달 <strong>{entries.length}건</strong>을 기록했어요.
          <br />
          {scope === "shared"
            ? "함께 쓴 돈을 차근차근 모아보고 있어요."
            : "나의 소비 습관을 조금씩 알아가고 있어요."}
        </p>
      </div>
    </section>
  );
}
function CategoryModal({ onSave, onClose }) {
  const [name, setName] = useState(""),
    [keywords, setKeywords] = useState(""),
    [busy, setBusy] = useState(false),
    [error, setError] = useState("");
  return (
    <Modal title="카테고리 추가" onClose={onClose}>
      <form
        onSubmit={async (e) => {
          e.preventDefault();
          if (busy) return;
          setBusy(true);
          try {
            await onSave(name.trim(), keywords);
            onClose();
          } catch (e) {
            setError(e.message);
          } finally {
            setBusy(false);
          }
        }}
      >
        <label className="input-label" htmlFor="category-name">
          이름
        </label>
        <input
          id="category-name"
          className="standard-input"
          data-initial-focus
          value={name}
          onChange={(e) => setName(e.target.value)}
          required
          maxLength={30}
        />
        <label className="input-label" htmlFor="category-keywords">
          자동 분류할 단어
        </label>
        <input
          id="category-keywords"
          className="standard-input"
          value={keywords}
          onChange={(e) => setKeywords(e.target.value)}
          placeholder="예: 약, 병원, 비타민"
          maxLength={300}
        />
        <p className="modal-copy">쉼표로 구분해요. 비워두어도 괜찮아요.</p>
        {error && (
          <p className="form-error" role="alert">
            {error}
          </p>
        )}
        <button className="primary full" disabled={busy || !name.trim()}>
          {busy ? "추가하는 중…" : "추가하기"}
        </button>
      </form>
    </Modal>
  );
}
createRoot(document.getElementById("root")).render(<App />);
