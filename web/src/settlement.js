import { today, won } from './data.js';

const money = n => Number.isSafeInteger(n) && n >= 0;
const monthPattern = /^(?!0000)\d{4}-(0[1-9]|1[0-2])$/;

export function settlementInfo(snapshot, month, currentMonth=today().slice(0,7)) {
  const mode=snapshot.household.mode, preview=snapshot.settlement;
  const history=(snapshot.history||[]).filter(r=>r.month===month);
  const overdue=(snapshot.pendingSettlements||[]).filter(r=>monthPattern.test(r.month)&&r.month<currentMonth&&money(r.amount)&&money(r.count));
  const pending=snapshot.entries.filter(e=>e.scope==='shared'&&e.day.startsWith(month)&&!e.settlement&&
    (['expense','refund'].includes(e.kind)||(e.kind==='income'&&e.funding==='personal'))&&
    (mode==='separate'||e.funding==='personal'));
  const base={mode,history,overdue,pending,transfers:[],memberAmounts:preview?.memberAmounts||[],fundBalance:snapshot.stats?.fundBalance};
  if(snapshot.members.length<2)return {...base,status:'solo'};
  if(!preview||!money(preview.amount)||!money(preview.count)||!/^[a-f0-9]{64}$/i.test(preview.revision||''))return {...base,status:'unavailable'};
  const transfers=[];
  if(mode==='separate'&&preview.count>0) {
    const ids=snapshot.members.map(m=>m.id);
    if(!ids.includes(preview.fromID)||!ids.includes(preview.toID)||preview.fromID===preview.toID)return {...base,status:'unavailable'};
    transfers.push({fromID:preview.fromID,toID:preview.toID,amount:preview.amount,count:preview.count,memberID:null,month,revision:preview.revision});
  } else if(mode==='pool') {
    for(const member of snapshot.members) {
      const own=pending.filter(e=>e.payer===member.id);
      if(!own.length)continue;
      const balance=preview.memberAmounts?.find(p=>p.id===member.id)?.amount;
      if(!Number.isSafeInteger(balance))return {...base,status:'unavailable'};
      transfers.push({fromID:balance>=0?'fund':member.id,toID:balance>=0?member.id:'fund',amount:Math.abs(balance),count:own.length,memberID:member.id,month,revision:preview.revision});
    }
  }
  return {...base,transfers,status:transfers.length?'pending':history.length?'complete':'empty'};
}

export function settlementDirection(transfer, me) {
  if(transfer.amount===0)return '주고받을 금액이 없어요';
  if(transfer.fromID===me)return transfer.toID==='fund'?'공동자금으로 돌려줄 돈':'내가 보낼 돈';
  if(transfer.toID===me)return transfer.fromID==='fund'?'공동자금에서 돌려받을 돈':'내가 받을 돈';
  return '생활비 정산';
}

export function settlementCopyData(month, transfer, recipient) {
  const amount=String(transfer.amount);
  const bank=recipient?.bank?.trim()||'', account=recipient?.account?.trim()||'', holder=recipient?.holder?.trim()||'';
  const complete=Boolean(bank&&account&&holder);
  return {amount,bank,account,holder,all:complete?`${month} 생활비 정산\n금액 ${won(transfer.amount)}원\n은행 ${bank}\n계좌번호 ${account}\n예금주 ${holder}`:null};
}

export function verifySettlementSaved(record, target) {
  if(!record?.id||['month','amount','fromID','toID','count'].some(k=>record[k]!==target[k]))
    throw new Error('정산 완료 응답을 확인하지 못했어요. 같은 요청으로 다시 확인해 주세요.');
}
