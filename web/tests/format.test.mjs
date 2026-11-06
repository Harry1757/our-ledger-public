import {test} from 'node:test';
import assert from 'node:assert/strict';
import {categoryBreakdown,expenseLabel,shiftMonth} from '../src/data.js';
test('refunds never create a duplicate sign or category shares above 100%',()=>{
  assert.equal(expenseLabel(9000),'−9,000'); assert.equal(expenseLabel(-9000),'+9,000');
  const groups=categoryBreakdown([{id:'a'},{id:'b'}],[{category:'a',kind:'expense',amount:10000},{category:'b',kind:'refund',amount:9000}]);
  assert.equal(groups[0].percent,100);assert.equal(groups[1].percent,null);assert.equal(groups[1].total,-9000);
});
test('month movement preserves year padding rather than treating early years as 1900',()=>{
  assert.equal(shiftMonth('0001-12',1),'0002-01');assert.equal(shiftMonth('0099-01',1),'0099-02');
});
