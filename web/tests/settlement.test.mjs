import { test } from 'node:test';
import assert from 'node:assert/strict';
import { settlementInfo, settlementDirection, settlementCopyData, verifySettlementSaved } from '../src/settlement.js';

const revision = 'a'.repeat(64);
const row = (id, payer, kind='expense', funding='personal', extra={}) => ({id,payer,kind,funding,scope:'shared',day:'2026-11-03',amount:1000,settlement:null,...extra});
function fixture(mode='separate') {
  return {me:'a',household:{mode},members:[{id:'a',name:'다온'},{id:'b',name:'하늘'}],
    entries:[row('one','a'),row('two','b')],history:[],pendingSettlements:[],stats:{fundBalance:12345},
    settlement:{kind:mode,fromID:'a',toID:'b',amount:47300,count:2,revision,
      memberAmounts:[{id:'a',amount:1000},{id:'b',amount:95600}]}};
}
test('separate settlement displays server amount and direction rather than recomputing money',()=>{
  const s=fixture();const info=settlementInfo(s,'2026-11');
  assert.equal(info.status,'pending');assert.equal(info.transfers[0].amount,47300);
  assert.equal(settlementDirection(info.transfers[0],s.me),'내가 보낼 돈');
  assert.equal(settlementDirection(info.transfers[0],'b'),'내가 받을 돈');
  assert.equal(info.transfers[0].revision,revision);
});
test('only unsettled shared records enter the settlement details',()=>{
  const s=fixture();s.entries.push(row('private','a','expense','personal',{scope:'personal'}),row('done','a','expense','personal',{settlement:'old'}),row('old','a','expense','personal',{day:'2026-10-03'}),row('fund-income','a','income','fund'));
  assert.deepEqual(settlementInfo(s,'2026-11').pending.map(e=>e.id),['one','two']);
});
test('zero pending, balanced pending, completed, solo and missing response remain distinct',()=>{
  const s=fixture();s.settlement.amount=0;assert.equal(settlementInfo(s,'2026-11').status,'pending');
  s.entries=[];s.settlement.count=0;assert.equal(settlementInfo(s,'2026-11').status,'empty');
  s.history=[{id:'done',month:'2026-11',amount:1000}];assert.equal(settlementInfo(s,'2026-11').status,'complete');
  s.settlement=null;assert.equal(settlementInfo(s,'2026-11').status,'unavailable');
  s.members.pop();assert.equal(settlementInfo(s,'2026-11').status,'solo');
});
test('pool reimbursements use signed server balances and never reassign the payer from funding',()=>{
  const s=fixture('pool');s.entries.push(row('bank','a','expense','fund'));
  s.settlement.memberAmounts=[{id:'a',amount:5000},{id:'b',amount:-2000}];
  const info=settlementInfo(s,'2026-11');
  assert.equal(info.fundBalance,12345);assert.equal(info.transfers.length,2);
  assert.deepEqual(info.transfers.map(t=>[t.fromID,t.toID,t.amount,t.memberID]),[['fund','a',5000,'a'],['b','fund',2000,'b']]);
  assert.deepEqual(info.pending.map(e=>e.id),['one','two']);
});
test('overdue months are server-provided and invalid monetary responses do not become zero',()=>{
  const s=fixture();s.pendingSettlements=[{month:'2026-10',fromID:'a',toID:'b',amount:900,count:1,revision},{month:'2026-11',fromID:'a',toID:'b',amount:100,count:1,revision}];
  assert.equal(settlementInfo(s,'2026-11','2026-11').overdue.length,1);
  s.settlement.amount=NaN;assert.equal(settlementInfo(s,'2026-11').status,'unavailable');
  s.settlement.amount=1;s.settlement.fromID='unknown';assert.equal(settlementInfo(s,'2026-11').status,'unavailable');
});
test('copy data keeps a raw amount separate and requires a complete recipient account',()=>{
  const t={amount:1010000};const recipient={bank:'예시은행',account:'000-0000-0000',holder:'하늘'};
  const data=settlementCopyData('2026-11',t,recipient);
  assert.equal(data.amount,'1010000');assert.match(data.all,/금액 1,010,000원/);assert.match(data.all,/계좌번호 000-0000-0000/);
  assert.equal(settlementCopyData('2026-11',t,{...recipient,holder:''}).all,null);
});
test('a successful completion must match the frozen amount, direction, month and count',()=>{
  const t={month:'2026-11',amount:100,fromID:'a',toID:'b',count:2};
  verifySettlementSaved({id:'record',...t},t);
  for(const change of [{amount:101},{month:'2026-10'},{fromID:'b'},{toID:'a'},{count:1}])assert.throws(()=>verifySettlementSaved({id:'record',...t,...change},t));
});
