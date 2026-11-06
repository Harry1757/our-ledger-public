import React from 'react';
import { ArrowLeftRight, ChevronRight, Copy, CheckCircle2, RefreshCw } from 'lucide-react';
import { won } from './data.js';
import { settlementCopyData, settlementDirection } from './settlement.js';
import './settlement.css';

const statusText = {solo:'두 사람이 연결되면 정산할 수 있어요',unavailable:'정산 정보를 확인해 주세요',complete:'이달 정산을 마쳤어요',empty:'정산할 새 내역이 없어요'};

export function SettlementShortcut({info,me,loading,onOpen}) {
  const transfer=info.transfers.find(t=>t.fromID===me||t.toID===me)||info.transfers[0];
  const overdue=new Set(info.overdue.map(d=>d.month)).size;
  return <button className="settlement-shortcut" onClick={onOpen} disabled={loading} aria-label="생활비 정산 보기">
    <span className="settlement-icon"><ArrowLeftRight size={22}/></span>
    <span className="settlement-shortcut-copy"><span>생활비 정산</span><strong>{loading?'불러오는 중…':transfer?<>{settlementDirection(transfer,me)} <b>{won(transfer.amount)}원</b></>:statusText[info.status]}</strong>
      {overdue>0&&<small>지난달 미정산 {overdue}개월</small>}
    </span><ChevronRight size={18}/>
  </button>;
}

export function SettlementDetails({snapshot,info,month,loading,target,busy,error,demo,onSelect,onBack,onComplete,onCopy,onMonth,onRefresh}) {
  const name=id=>id==='fund'?'공동자금':snapshot.members.find(m=>m.id===id)?.name||'이름 확인 필요';
  if(target)return <div className="settlement-confirm">
    <p className="section-subtitle">{target.month} · 공용 기록 {target.count}건</p>
    <h3>{target.amount===0?'송금 없이 마감할까요?':target.toID===snapshot.me?'입금을 확인하셨나요?':'실제로 주고받은 금액인가요?'}</h3>
    <strong className="settlement-amount">{won(target.amount)}원</strong>
    {target.amount>0&&<p>{name(target.fromID)} → {name(target.toID)}</p>}
    <p className="modal-copy">{target.amount===0?'주고받을 금액이 없는 공용 내역을 완료로 기록해요.':'은행 앱에서 실제 송금·입금을 확인한 뒤 완료해 주세요. 정보 복사만으로는 정산되지 않아요.'}</p>
    {error&&<p className="form-error" role="alert">{error}</p>}
    {error&&<button className="text-button" disabled={busy} onClick={onRefresh}>최신 내역 다시 확인</button>}
    <div className="modal-actions"><button className="secondary" onClick={onBack} disabled={busy} autoFocus>돌아가기</button><button className="primary" onClick={onComplete} disabled={busy}>{busy?'완료 기록 중…':'정산 완료 기록'}</button></div>
  </div>;
  return <div className="settlement-details" aria-busy={loading}>
    <p className="section-subtitle">{month} · 공용 생활비</p>
    {demo&&<p className="modal-copy">체험용 예시예요. 실제 가계부를 연결하면 정산 완료를 기록할 수 있어요.</p>}
    {info.status==='unavailable'?<div className="error-panel" role="alert">정산 정보를 불러오지 못했어요.<button onClick={onRefresh}>다시 불러오기</button></div>:
      info.status!=='pending'&&<div className="settlement-empty"><CheckCircle2 size={24}/><h3>{statusText[info.status]}</h3>{info.status==='solo'&&<p>아이폰 설정에서 상대를 초대해 주세요.</p>}</div>}
    {loading&&<p role="status"><RefreshCw size={16}/> 최신 정산을 불러오는 중…</p>}
    {info.mode==='pool'&&Number.isSafeInteger(info.fundBalance)&&<div className="settlement-balance"><span>선택한 달 말 공동자금 잔액</span><strong>{won(info.fundBalance)}원</strong><small>가계부 기록 기준</small></div>}
    {info.transfers.map(t=>{
      const recipient=snapshot.members.find(m=>m.id===t.toID), copy=settlementCopyData(month,t,recipient);
      return <section className="settlement-transfer" key={t.memberID||'separate'}>
        <h3>{settlementDirection(t,snapshot.me)}</h3><strong className="settlement-amount">{won(t.amount)}원</strong>
        {t.amount>0&&<p className="settlement-route">{name(t.fromID)} → {name(t.toID)}</p>}
        {t.amount>0&&<div className="settlement-copy">
          <CopyRow label="금액" value={won(t.amount)+'원'} onCopy={()=>onCopy(copy.amount,'금액')}/>
          {copy.all?<><CopyRow label="은행" value={copy.bank} onCopy={()=>onCopy(copy.bank,'은행')}/><CopyRow label="계좌번호" value={copy.account} onCopy={()=>onCopy(copy.account,'계좌번호')}/><CopyRow label="예금주" value={copy.holder} onCopy={()=>onCopy(copy.holder,'예금주')}/><button className="secondary full" onClick={()=>onCopy(copy.all,'송금 정보')}><Copy size={16}/> 송금 정보 한 번에 복사</button></>:
            <p className="settlement-account-empty">{t.toID==='fund'?'공동자금 계좌는 은행 앱에서 확인해 주세요.':'받는 분의 정산 계좌를 아이폰 설정에서 등록해 주세요.'}</p>}
        </div>}
        <button className="primary full" disabled={loading||demo} onClick={()=>onSelect(t)}>{t.amount===0?'송금 없이 마감':t.toID===snapshot.me?'입금을 확인했어요':t.fromID===snapshot.me?'송금을 마쳤어요':'주고받은 내역을 확인했어요'}</button>
      </section>;
    })}
    {info.pending.length>0&&<details className="settlement-section"><summary>정산에 포함한 공용 기록 {info.pending.length}건</summary><div className="settlement-entries">{info.pending.map(e=><div key={e.id}><span><strong>{e.note}</strong><small>{name(e.payer)} · {e.day}</small></span><b>{['income','refund'].includes(e.kind)?'−':''}{won(e.amount)}원</b></div>)}</div></details>}
    {info.memberAmounts.length>0&&info.status!=='unavailable'&&<details className="settlement-section"><summary>정산 계산 방식</summary><p>{info.mode==='separate'?'공용 지출·환불·수입을 반영한 각자의 부담액을 반반 나누고, 이미 완료한 정산을 반영해요.':'개인 돈으로 낸 공용 지출에서 환불·개인 계좌로 받은 공용 수입을 빼요.'}</p>{info.memberAmounts.map(p=><div className="settlement-basis" key={p.id}><span>{name(p.id)}</span><b>{won(p.amount)}원</b></div>)}</details>}
    {info.overdue.length>0&&<section className="settlement-section"><h3>지난달 미정산</h3>{info.overdue.map(d=><button className="settlement-due" key={d.month+':'+(d.memberID||'')} onClick={()=>onMonth(d.month)} disabled={loading||month===d.month}><span><strong>{d.month}{month===d.month?' · 보는 중':''}</strong><small>{name(d.fromID)} → {name(d.toID)}</small></span><b>{won(d.amount)}원</b><ChevronRight size={16}/></button>)}</section>}
    {info.history.length>0&&<section className="settlement-section"><h3>완료한 정산</h3>{info.history.map(r=><div className="settlement-history" key={r.id}><span><strong>{r.amount===0?'송금 없이 마감':name(r.fromID)+' → '+name(r.toID)}</strong><small>{r.date?.slice(0,10)} · {r.count}개 내역</small></span><b>{won(r.amount)}원</b><CheckCircle2 size={16}/></div>)}</section>}
    <p className="settlement-footnote">송금은 은행 앱에서 진행해 주세요. 완료 기록은 두 사람의 가계부에 함께 반영돼요.</p>
  </div>;
}

function CopyRow({label,value,onCopy}) {
  return <div className="settlement-copy-row"><span>{label}</span><strong>{value}</strong><button className="icon-button" aria-label={label+' 복사'} onClick={onCopy}><Copy size={16}/></button></div>;
}
