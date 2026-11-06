import copy
import json
import unittest
from unittest.mock import patch
import ledger as L


class LedgerTests(unittest.TestCase):
    def setUp(self):
        clock = patch('ledger.now', return_value='2026-10-21T12:00:00+09:00')
        clock.start()
        self.addCleanup(clock.stop)
        self.s = L.new_household('우리집', '순환', 'separate')
        self.a = self.s['members'][0]['id']
        self.b = L.add_member(self.s, '주희')['id']

    def entry(self, actor=None, **overrides):
        p = dict(amount=30000, note='저녁 식사', day='2026-10-20', scope='shared', kind='expense', funding='personal')
        p.update(overrides)
        return L.add_entry(self.s, actor or self.a, p)

    def test_separate_settlement(self):
        self.entry(amount=300000)
        self.entry(self.b, amount=200000)
        v = L.snapshot(self.s, self.a, '2026-10')
        self.assertEqual(v['stats']['total'], 500000)
        self.assertEqual((v['settlement']['fromID'], v['settlement']['toID'], v['settlement']['amount']), (self.b, self.a, 50000))

    def test_personal_statistics_history_income_and_privacy(self):
        self.entry(amount=10000, scope='personal', day='2026-10-05')
        self.entry(amount=3000, scope='personal', kind='refund', day='2026-10-06')
        self.entry(amount=2000, scope='personal', day='2026-10-25')
        self.entry(amount=5000, scope='personal', day='2026-09-10')
        self.entry(amount=8000, scope='personal', day='2026-09-25')
        self.entry(amount=6000, scope='personal', day='2026-08-01')
        self.entry(amount=70000, scope='personal', kind='income')
        before = L.snapshot(self.s, self.a, '2026-10')['personalStats']
        self.entry(self.b, amount=999000, scope='personal')
        self.entry(self.b, amount=888000, scope='personal', day='2026-09-01')
        self.entry(self.b, amount=777000, scope='personal', kind='income')
        self.entry(amount=100000, scope='shared')
        self.entry(amount=200000, scope='shared', kind='income')
        after = L.snapshot(self.s, self.a, '2026-10')['personalStats']
        self.assertEqual(after, before, 'Other members and shared records cannot affect personal statistics')
        self.assertEqual((after['total'], after['previousTotal'], after['delta']), (9000, 13000, -4000))
        self.assertEqual((after['comparisonTotal'], after['comparisonPreviousTotal'], after['comparisonThroughDay']), (7000, 5000, 21))
        self.assertEqual(after['incomeTotal'], 70000)
        self.assertEqual(sum(d['amount'] for d in after['daily']), 9000)
        self.assertEqual(sum(c['amount'] for c in after['byCategory']), 9000)
        self.assertEqual([t['amount'] for t in after['trend']][-3:], [6000, 13000, 9000])
        self.assertEqual(after['byMember'], [])
        self.assertEqual(L.snapshot(self.s, self.b, '2026-10')['personalStats']['total'], 999000)
        historical = L.snapshot(self.s, self.a, '2026-09')['personalStats']
        self.assertIsNone(historical['comparisonThroughDay'])
        self.assertEqual(historical['comparisonTotal'], 13000)

    def test_capture_date_only_does_not_invent_time_or_merge(self):
        raw = '카드 결제\n13,760원\n가맹점: 검증백화점\n거래일: 2026-10-25'
        parsed = L.parse_message(raw)
        self.assertEqual((parsed['amount'], parsed['merchant'], parsed['time']), (13760, '검증백화점', '2026-10-25'))
        self.assertIsNone(L.parse_message(raw.replace('2026-10-25', '2026-02-30'))['time'])
        timed = L.import_message(self.s, self.a, dict(text='카드 승인 13,760원\n가맹점: 검증백화점\n10/25 19:43'))
        capture = L.import_message(self.s, self.a, dict(text=raw, source='paste'))
        self.assertNotEqual(capture['id'], timed['id'])
        self.assertEqual(capture['candidates'], [], 'A date alone is not evidence for a ten-minute duplicate')

    def test_review_only_mixed_capture_stays_pending_without_financial_metadata(self):
        raw = ('  발신 알림: 금액 확인 필요\n카드 1234 승인 18,400원\n'
               '가맹점: 합성상점\n2026/10/21 12:00\n승인번호 TEST1234\n출금 예정 65,720원  ')
        before = L.snapshot(self.s, self.a, '2026-10')
        payload = dict(text=raw, source='paste', eventID='review-mixed', reviewOnly=True)
        item = L.import_message(self.s, self.a, payload)
        self.assertEqual(item['status'], 'pending')
        self.assertEqual(item['raw'], raw)
        self.assertEqual((item['amount'], item['kind'], item['merchant'], item['time']),
                         (None, 'unknown', '', None))
        self.assertEqual((item['card'], item['reference'], item['candidates']), ('', '', []))
        self.assertTrue(item['requiresReview'])
        self.assertIn('직접 확인', item['reason'])
        self.assertEqual(L.import_message(self.s, self.a, payload)['id'], item['id'])
        self.assertEqual(len(self.s['imports']), 1)
        after = L.snapshot(self.s, self.a, '2026-10')
        for key in ('entries', 'stats', 'settlement', 'recurringPayments'):
            self.assertEqual(after[key], before[key], key)
        self.assertEqual([i['id'] for i in after['inbox']], [item['id']])
        self.assertEqual(L.snapshot(self.s, self.b, '2026-10')['inbox'], [])
        L.resolve_import(self.s, self.a, item['id'])
        self.assertEqual(L.import_message(self.s, self.a, payload)['status'], 'ignored')

    def test_review_only_does_not_merge_inferred_reference_or_resurrect_recorded_event(self):
        raw = '카드 1234 승인 18,400원\n가맹점: 합성상점\n2026/10/21 12:00\n승인번호 TEST1234'
        ordinary = L.import_message(self.s, self.a, dict(text=raw, source='paste', eventID='ordinary'))
        first = L.import_message(self.s, self.a, dict(text=raw, source='paste', eventID='review-1', reviewOnly=True))
        second = L.import_message(self.s, self.a, dict(text=raw, source='paste', eventID='review-2', reviewOnly=True))
        self.assertEqual(len({ordinary['id'], first['id'], second['id']}), 3)
        self.assertEqual((first['candidates'], second['candidates']), ([], []))
        saved = self.entry(amount=18400, scope='personal', importID=first['id'])
        retry = L.import_message(self.s, self.a, dict(text=raw, source='paste', eventID='review-1', reviewOnly=True))
        self.assertEqual((retry['status'], retry['entryID']), ('recorded', saved['id']))
        self.assertEqual(len(self.s['entries']), 1)

    def test_review_only_import_rejects_non_boolean_and_non_paste_without_mutation(self):
        invalid = [dict(reviewOnly=value, source='paste') for value in (None, 0, 1, 'true', 'false', [], {})]
        invalid += [dict(reviewOnly=True, source=source) for source in ('sms', 'app', 'shortcut', None)]
        invalid.append(dict(reviewOnly=True))
        before = copy.deepcopy(self.s)
        for options in invalid:
            with self.subTest(options=options), self.assertRaises(L.LedgerError):
                L.import_message(self.s, self.a, dict(text='출금 예정 10,000원', **options))
            self.assertEqual(self.s, before)

    def test_review_only_parser_option_keeps_automatic_fields_empty(self):
        for raw in ('카드 1234 승인 18,400원\n가맹점: 합성상점\n거래일: 2026-10-21',
                    '잔액 18,400원', '출금 예정 18,400원'):
            parsed = L.parse_message(raw, review_only=True)
            self.assertEqual((parsed['amount'], parsed['kind'], parsed['merchant'], parsed['time']),
                             (None, 'unknown', '', None))
            self.assertTrue(parsed['requiresReview'])
            self.assertEqual(L.parse_message(raw, review_only=False), L.parse_message(raw))
        for value in (None, 0, 1, 'true', [], {}):
            with self.subTest(value=value), self.assertRaises(L.LedgerError):
                L.parse_message('카드 승인 1,000원', review_only=value)

    def test_review_only_false_and_prefix_alone_keep_notice_filter(self):
        raw = '발신 알림: 금액 확인 필요\n카드 승인 18,400원\n출금 예정 65,720원'
        for options in ({}, {'reviewOnly': False}):
            item = L.import_message(self.s, self.a, dict(text=raw, source='paste', **options))
            self.assertEqual(item['status'], 'ignored')
        self.assertEqual(self.s['entries'], [])

    def test_shared_income_changes_settlement_but_not_spending(self):
        self.s['budget'] = 100000
        original = self.entry(amount=30000)
        self.entry(self.b, amount=10000)
        self.entry(amount=2000, kind='refund', refundOf=original['id'])
        self.entry(amount=7000, scope='personal')
        self.entry(amount=9000, day='2026-09-01')
        before = L.snapshot(self.s, self.a, '2026-10')
        income = self.entry(kind='income', amount=100000, note='공용 수입')
        self.entry(self.b, kind='income', amount=50000)
        self.entry(kind='income', amount=300000, scope='personal')
        self.entry(kind='income', amount=800000, day='2026-09-01')
        after = L.snapshot(self.s, self.a, '2026-10')
        self.assertEqual(after['stats']['incomeTotal'], 150000)
        self.assertEqual(after['stats']['personalIncomeTotal'], 300000)
        for key, value in before['stats'].items():
            if key not in ('incomeTotal', 'personalIncomeTotal'):
                self.assertEqual(after['stats'][key], value, key)
        self.assertEqual((after['settlement']['fromID'], after['settlement']['toID'], after['settlement']['amount']), (self.a, self.b, 16000))
        self.assertNotEqual(after['settlement']['revision'], before['settlement']['revision'])
        record = L.settle(self.s, self.a, '2026-10', expected_revision=after['settlement']['revision'])
        self.assertEqual((record['amount'], record['count']), (16000, 5))
        self.assertEqual(income['settlement'], record['id'])
        self.assertEqual(L.signed(income), 0)

    def test_shared_income_offsets_pool_reimbursement_and_can_enter_fund(self):
        self.s['mode'] = 'pool'
        self.entry(kind='deposit', amount=100000, funding='fund')
        expense = self.entry(amount=30000)
        self.entry(kind='refund', amount=10000, refundOf=expense['id'])
        self.entry(amount=5000, funding='fund')
        income = self.entry(kind='income', amount=8000)
        direct_income = self.entry(kind='income', funding='fund', amount=50000)
        before = L.snapshot(self.s, self.a, '2026-10')
        self.assertEqual(before['stats']['fundBalance'], 145000)
        self.assertEqual(before['settlement']['memberAmounts'][0]['amount'], 12000)
        record = L.settle(self.s, self.a, '2026-10', self.a)
        self.assertEqual((record['fromID'], record['toID'], record['amount'], record['count']), ('fund', self.a, 12000, 3))
        after = L.snapshot(self.s, self.a, '2026-10')
        self.assertEqual(after['stats']['fundBalance'], 133000)
        self.assertEqual(after['stats']['total'], 25000)
        self.assertEqual(after['stats']['incomeTotal'], 58000)
        self.assertEqual(income['settlement'], record['id'])
        self.assertIsNone(direct_income['settlement'])
        with self.assertRaises(L.LedgerError):
            L.settle(self.s, self.a, '2026-10', self.a)

    def test_shared_gift_net_settlement_cases(self):
        # Literal balances: expenses minus money held for both partners.
        cases = [(150000, 0, 100000, 0, 'b', 'a', 25000),
                 (150000, 0, 0, 100000, 'b', 'a', 125000),
                 (0, 0, 100000, 0, 'a', 'b', 50000),
                 (0, 0, 1, 0, 'a', 'b', 1),
                 (0, 0, 0, 1, 'a', 'b', 0)]
        for expense_a, expense_b, income_a, income_b, sender, recipient, expected in cases:
            with self.subTest(amounts=(expense_a, expense_b, income_a, income_b)):
                self.s['entries'] = []; self.s['settlements'] = []
                for actor, expense, income in [(self.a, expense_a, income_a), (self.b, expense_b, income_b)]:
                    if expense: self.entry(actor, amount=expense)
                    if income: self.entry(actor, kind='income', amount=income)
                view = L.snapshot(self.s, self.a, '2026-10')
                ids = {'a': self.a, 'b': self.b}
                self.assertEqual((view['settlement']['fromID'], view['settlement']['toID'], view['settlement']['amount']), (ids[sender], ids[recipient], expected))
                record = L.settle(self.s, self.a, '2026-10', expected_revision=view['settlement']['revision'])
                self.assertEqual(record['amount'], expected)
                self.assertTrue(all(e['settlement'] == record['id'] for e in self.s['entries']))
                self.assertEqual(L.settlement_for(self.s, '2026-10')['amount'], 0)
                with self.assertRaises(L.LedgerError): L.settle(self.s, self.a, '2026-10')

    def test_later_shared_income_adjusts_completed_settlement_without_rewriting_history(self):
        self.entry(amount=150000)
        first = L.settle(self.s, self.a, '2026-10')
        self.assertEqual(first['amount'], 75000)
        old_record = copy.deepcopy(first)
        income = self.entry(kind='income', amount=100000)
        view = L.settlement_for(self.s, '2026-10')
        self.assertEqual((view['fromID'], view['toID'], view['amount'], view['count']), (self.a, self.b, 50000, 1))
        second = L.settle(self.s, self.a, '2026-10', expected_revision=view['revision'])
        self.assertEqual(second['amount'], 50000)
        self.assertEqual(first, old_record)
        self.assertEqual(L.settlement_for(self.s, '2026-10')['amount'], 0)
        with self.assertRaises(L.LedgerError): L.update_entry(self.s, self.a, income['id'], {'amount': 1})

    def test_pool_income_only_is_returned_to_fund_once(self):
        self.s['mode'] = 'pool'
        self.entry(kind='income', amount=9000)
        record = L.settle(self.s, self.a, '2026-10', self.a)
        self.assertEqual((record['fromID'], record['toID'], record['amount'], record['signedAmount']), (self.a, 'fund', 9000, -9000))
        self.assertEqual(L.snapshot(self.s, self.a, '2026-10')['stats']['fundBalance'], 9000)
        with self.assertRaises(L.LedgerError): L.settle(self.s, self.a, '2026-10', self.a)

    def test_private_income_never_changes_settlement_or_fund(self):
        for mode in ('separate', 'pool'):
            with self.subTest(mode=mode):
                self.s['mode'] = mode
                before = L.snapshot(self.s, self.a, '2026-10')
                self.entry(kind='income', amount=3000000, scope='personal')
                after = L.snapshot(self.s, self.a, '2026-10')
                self.assertEqual(before['settlement'], after['settlement'])
                self.assertEqual(after['stats']['fundBalance'], 0)
                with self.assertRaises(L.LedgerError):
                    self.entry(kind='income', funding='fund', scope='personal', amount=1000)

    def test_private_income_is_not_in_partner_snapshot_or_rules(self):
        category = self.s['categories'][0]['id']
        income = self.entry(kind='income', scope='personal', amount=321987, note='비밀급여', category=category)
        self.entry(kind='income', amount=2000)
        partner = L.snapshot(self.s, self.b, '2026-10')
        self.assertEqual(partner['stats']['incomeTotal'], 2000)
        self.assertEqual(partner['stats']['personalIncomeTotal'], 0)
        self.assertEqual(partner['stats']['total'], 0)
        encoded = json.dumps(partner, ensure_ascii=False)
        self.assertNotIn('비밀급여', encoded)
        self.assertNotIn('321987', encoded)
        self.assertNotIn(income['id'], encoded)
        with self.assertRaises(L.LedgerError):
            L.update_entry(self.s, self.b, income['id'], dict(amount=1))

    def test_income_update_void_and_validation(self):
        entry = self.entry(amount=6000)
        L.update_entry(self.s, self.a, entry['id'], dict(kind='income', amount=8000, scope='personal'))
        view = L.snapshot(self.s, self.a, '2026-10')
        self.assertEqual((view['stats']['total'], view['stats']['personalTotal'], view['stats']['personalIncomeTotal']), (0, 0, 8000))
        for changes in (dict(amount=-1), dict(amount=True), dict(funding='fund'), dict(kind='transfer')):
            with self.subTest(changes=changes), self.assertRaises(L.LedgerError):
                L.update_entry(self.s, self.a, entry['id'], changes)
        self.assertEqual(entry['amount'], 8000)
        L.update_entry(self.s, self.a, entry['id'], dict(kind='expense', scope='shared'))
        self.assertEqual(L.snapshot(self.s, self.a, '2026-10')['stats']['total'], 8000)
        L.update_entry(self.s, self.a, entry['id'], dict(kind='income'))
        L.update_entry(self.s, self.a, entry['id'], dict(voided=True))
        self.assertEqual(L.snapshot(self.s, self.a, '2026-10')['stats']['incomeTotal'], 0)

    def test_income_cannot_replace_a_linked_refund_or_recurring_expense(self):
        expense = self.entry(amount=10000)
        refund = self.entry(kind='refund', amount=1000, refundOf=expense['id'])
        with self.assertRaises(L.LedgerError):
            L.update_entry(self.s, self.a, refund['id'], dict(kind='income'))
        with self.assertRaises(L.LedgerError):
            L.update_entry(self.s, self.a, expense['id'], dict(kind='income'))
        template = L.add_recurring(self.s, self.a, dict(note='월세', amount=10000, scope='shared',
            payer=self.a, funding='personal', startDay='2026-01-01', dayOfMonth=20))
        with self.assertRaises(L.LedgerError):
            self.entry(kind='income', recurringID=template['id'], recurringMonth='2026-10')

    def test_income_bank_credit_import_stays_pending_until_explicit_recording(self):
        raw = '우리은행 입금 3,000,000원\n테스트회사\n잔액 9,000,000원\n10/21 12:00'
        imported = L.import_message(self.s, self.a, dict(text=raw, source='sms', eventID='salary'))
        self.assertEqual((imported['kind'], imported['amount'], imported['status']), ('income', 3000000, 'pending'))
        self.assertTrue(imported['requiresReview'], 'Bank credits can still be own-account transfers')
        self.assertEqual(self.s['entries'], [])
        self.assertEqual(L.snapshot(self.s, self.b, '2026-10')['inbox'], [])
        self.entry(kind='income', scope='personal', amount=3000000, note='급여', importID=imported['id'])
        self.assertEqual(imported['status'], 'recorded')
        self.assertEqual(L.snapshot(self.s, self.a, '2026-10')['stats']['personalIncomeTotal'], 3000000)

    def test_income_parser_preserves_transfer_ambiguity_and_rejects_ads(self):
        for raw in ('우리은행 출금 50,000원\n홍길동', '토스 송금 50,000원\n홍길동',
                    '우리은행 이체입금 50,000원\n홍길동', '우리은행 입금 50,000원\n내 계좌 이동'):
            with self.subTest(raw=raw):
                parsed = L.parse_message(raw)
                self.assertEqual(parsed['kind'], 'transfer')
                self.assertEqual(parsed['amount'], 50000)
                self.assertTrue(parsed['requiresReview'])
        for raw in ('[광고] 입금하면 10,000원 지급', '카드 결제 예정 10,000원', '[광고] 10,000원 할인 승인 혜택'):
            parsed = L.parse_message(raw)
            self.assertEqual(parsed['kind'], 'unknown')
            self.assertIsNone(parsed['amount'])

    def test_income_parser_salary_paid_is_income_but_offers_and_plans_are_not(self):
        for raw in ('급여 3,000,000원 지급\n테스트회사', '3,000,000원 지급 완료\n급여'):
            with self.subTest(raw=raw):
                parsed = L.parse_message(raw)
                self.assertEqual((parsed['kind'], parsed['amount']), ('income', 3000000))
                self.assertTrue(parsed['requiresReview'])
        for raw in ('급여 3,000,000원 지급 예정', '3,000,000원 입금 예정\n테스트회사',
                    '10,000원 입금하면 혜택 지급', '10,000원 입금 시 할인', '결제하면 10,000원 지급'):
            with self.subTest(raw=raw):
                parsed = L.parse_message(raw)
                self.assertEqual(parsed['kind'], 'unknown')
                self.assertIsNone(parsed['amount'])

    def test_private_isolation(self):
        secret = self.entry(scope='personal', note='비공개 구매')
        v = L.snapshot(self.s, self.b, '2026-10')
        self.assertEqual(v['entries'], [])
        self.assertEqual(v['stats']['total'], 0)
        with self.assertRaises(L.LedgerError):
            L.update_entry(self.s, self.b, secret['id'], {'note': '바꿈'})

    def test_amount_validation(self):
        for value in [0, -1, 1.5, True, '3000', 100000000001]:
            with self.subTest(value=value), self.assertRaises(L.LedgerError):
                self.entry(amount=value)

    def test_new_entry_requires_explicit_scope(self):
        payload = dict(amount=1000, note='검증 지출', day='2026-10-21')
        with self.assertRaises(L.LedgerError):
            L.add_entry(self.s, self.a, payload)
        self.assertEqual(self.s['entries'], [])

    def test_qa_retry_import_rechecks_visibility_after_partner_makes_entry_private(self):
        raw = '카드 1234 승인 10,000원\n가맹점: 테스트상점\n승인번호 998877\n2026/10/20 13:00'
        first = self.imported(text=raw)
        second = self.imported(self.b, text=raw)
        original = self.entry(amount=10000, importID=first['id'])
        self.assertEqual(self.entry(self.b, amount=10000, importID=second['id'])['id'], original['id'])
        L.update_entry(self.s, self.a, original['id'], dict(scope='personal', note='새 개인 메모', amount=12345))
        before = copy.deepcopy(self.s)
        self.assertEqual(L.snapshot(self.s, self.b, '2026-10')['entries'], [])
        with self.assertRaises(L.LedgerError):
            self.entry(self.b, amount=10000, importID=second['id'])
        self.assertEqual(self.s, before)
        self.assertEqual(self.entry(importID=first['id'])['note'], '새 개인 메모')

    def test_qa_retry_rejects_deleted_entries_by_id_and_import(self):
        imported = self.imported()
        original = self.entry(id='deleted-retry', importID=imported['id'])
        L.update_entry(self.s, self.a, original['id'], {'voided': True})
        before = copy.deepcopy(self.s)
        for payload in ({'id': original['id']}, {'importID': imported['id']}):
            with self.subTest(payload=payload), self.assertRaises(L.LedgerError):
                self.entry(**payload)
        self.assertEqual(self.s, before)

    def test_qa_refund_help_is_not_a_refund_but_real_refunds_survive(self):
        for help_text in ('취소 문의 1588-0000', '환불은 구매처에 문의하세요', '취소 및 환불 문의',
                          '환불 정책 안내', '취소/환불 불가'):
            for prefix, expected in (('카드 1234 승인', 'expense'), ('카드 1234 승인취소', 'refund'),
                                     ('환불 완료', 'refund'), ('환불', 'refund'), ('환불 안내', 'refund')):
                with self.subTest(help=help_text, prefix=prefix):
                    parsed = L.parse_message(f'{prefix} 10,000원\n가맹점: 테스트상점\n{help_text}')
                    self.assertEqual(parsed['kind'], expected)
                    self.assertEqual(parsed['amount'], 10000)
                    self.assertFalse(parsed['requiresReview'])

    def test_qa_refund_help_alone_requires_review(self):
        for raw in ('취소 문의 10000원\n가맹점: 테스트', '환불은 구매처에 문의하세요\n10000원\n가맹점: 테스트'):
            with self.subTest(raw=raw):
                parsed = L.parse_message(raw)
                self.assertEqual(parsed['kind'], 'unknown')
                self.assertTrue(parsed['requiresReview'])

    def test_qa_daily_classification_and_ambiguous_charging(self):
        cases = [('콜라', '식비'), ('빵', '식비'), ('코 약', '의료'), ('코약', '의료'), ('약', '의료'),
                 ('다이소', '생활용품'), ('전기차 충전', '교통'), ('티머니 충전', '교통'),
                 ('충전', '미분류'), ('휴대폰 충전', '미분류'), ('충전기 구매', '미분류'),
                 ('예약', '미분류'), ('약속', '미분류'), ('계약', '미분류')]
        before = copy.deepcopy(self.s)
        for note, expected in cases:
            with self.subTest(note=note):
                view = L.snapshot(self.s, self.a, '2026-10')
                category = L.category_for(self.s, self.a, note)
                self.assertEqual(next(c['name'] for c in view['categories'] if c['id'] == category), expected)
        self.assertEqual(self.s, before)

    def test_qa_medical_category_read_only_stable_and_usable_through_save_refund_stats(self):
        before = copy.deepcopy(self.s)
        view = L.snapshot(self.s, self.a, '2026-10')
        medical = next((c for c in view['categories'] if c['name'] == '의료'), None)
        self.assertIsNotNone(medical)
        self.assertEqual(self.s, before)
        reopened = json.loads(json.dumps(self.s))
        self.assertIn(medical, L.snapshot(reopened, self.a, '2026-10')['categories'])
        entry = self.entry(amount=10000, note='코 약', category=medical['id'])
        self.assertEqual(self.entry(note='약', scope='personal')['category'], medical['id'])
        refund = self.entry(amount=2000, kind='refund', note='약 환불', refundOf=entry['id'])
        self.assertEqual(refund['category'], medical['id'])
        view = L.snapshot(self.s, self.a, '2026-10')
        self.assertEqual(next(c['amount'] for c in view['stats']['byCategory'] if c['id'] == medical['id']), 8000)
        self.assertEqual(next(c['amount'] for c in view['personalStats']['byCategory'] if c['id'] == medical['id']), 30000)
        self.assertEqual(view['classificationRules']['코약'], medical['id'])
        with self.assertRaises(L.LedgerError):
            L.add_category(self.s, '의료')
        with self.assertRaises(L.LedgerError):
            self.entry(category='not-a-category')
        plan = L.add_recurring(self.s, self.a, dict(note='코 약', amount=1000, scope='personal',
                            category=medical['id'], startDay='2026-10-01', dayOfMonth=20))
        self.assertEqual(plan['category'], medical['id'])
        self.assertEqual(L.update_recurring(self.s, self.a, plan['id'], {'amount': 2000})['category'], medical['id'])

    def test_qa_daily_defaults_respect_existing_categories_keywords_and_personal_choices(self):
        # A pre-existing user category keeps its identity and stored keywords.
        medical = dict(id='existing-medical', name='의료', keywords=['치료'])
        self.s['categories'].append(medical)
        custom = L.add_category(self.s, '나의 식재료', '콜라')['id']
        self.assertEqual(L.category_for(self.s, self.a, '콜라'), custom)
        self.assertEqual(L.category_for(self.s, self.a, '약'), medical['id'])
        self.entry(note='빵', category=custom)
        self.assertEqual(L.category_for(self.s, self.a, '빵'), custom)
        self.assertNotEqual(L.category_for(self.s, self.b, '빵'), custom)
        self.assertEqual(medical, dict(id='existing-medical', name='의료', keywords=['치료']))

    def test_classification_effective_categories_are_detached_and_idempotent(self):
        before = copy.deepcopy(self.s)
        effective = L.effective_categories(self.s)
        self.assertEqual([c['id'] for c in effective[:-1]], [c['id'] for c in before['categories']])
        self.assertEqual([c['name'] for c in effective[:-1]], [c['name'] for c in before['categories']])
        self.assertEqual(effective[-1]['name'], '의료')
        self.assertEqual(effective, L.effective_categories({**self.s, 'categories': effective}))
        self.assertEqual(self.s, before)
        for category in effective:
            category['keywords'].append('검사용 단어')
            category['name'] = '검사용 이름'
        self.assertEqual(self.s, before, 'Effective dictionaries and keyword lists must not alias storage')

    def test_classification_ui_copied_unclassified_remains_explicit_without_learning(self):
        entry = self.entry(note='처음 보는 상점')
        other = entry['category']
        updated = L.update_entry(self.s, self.a, entry['id'], dict(note='점심 식사', category=other))
        self.assertEqual(updated['category'], other, 'An explicit unclassified selection must be respected')
        self.assertEqual(self.s['rules'], {})
        self.assertNotEqual(self.entry(note='점심 식사')['category'], other)

    def test_classification_old_household_uses_clear_keywords_without_migration(self):
        before = copy.deepcopy(self.s)
        for note, expected in (('치킨', '식비'), ('피자', '식비'), ('햄버거', '식비'),
                               ('국밥', '식비'), ('돈까스', '식비'), ('슈퍼마켓', '장보기'),
                               ('다이소', '생활용품'), ('지하철', '교통'), ('버스', '교통'),
                               ('기차', '교통'), ('이디야', '카페'), ('빽다방', '카페'), ('투썸', '카페')):
            with self.subTest(note=note):
                category = L.category_for(self.s, self.a, note)
                self.assertEqual(next(c['name'] for c in self.s['categories'] if c['id'] == category), expected)
        self.assertEqual(self.s, before, 'Recommendations must not migrate categories or old entries')

    def test_classification_unknown_and_conflicting_keywords_remain_unclassified(self):
        other = next(c['id'] for c in self.s['categories'] if c['name'] == '미분류')
        for note in ('처음 보는 상점', '치킨 커피', '다이소 지하철', '커피 여행'):
            with self.subTest(note=note):
                self.assertEqual(L.category_for(self.s, self.a, note), other)
        self.s['categories'] = [c for c in self.s['categories'] if c['name'] != '카페']
        self.assertEqual(L.category_for(self.s, self.a, '이디야'), other)

    def test_classification_exact_personal_rule_overrides_keywords(self):
        chosen = L.add_category(self.s, '내 맞춤 분류', '')['id']
        self.entry(note='치킨', category=chosen)
        self.assertEqual(L.category_for(self.s, self.a, ' 치 킨 '), chosen)
        food = next(c['id'] for c in self.s['categories'] if c['name'] == '식비')
        self.assertEqual(L.category_for(self.s, self.b, '치킨'), food)
        self.assertEqual(L.category_for(self.s, self.a, '다른 치킨'), food)

    def test_classification_legacy_unclassified_and_missing_rules_fall_back(self):
        other = next(c['id'] for c in self.s['categories'] if c['name'] == '미분류')
        food = next(c['id'] for c in self.s['categories'] if c['name'] == '식비')
        for learned in (other, 'deleted-category'):
            with self.subTest(learned=learned):
                self.s['rules'][self.a + ':점심'] = learned
                before = copy.deepcopy(self.s)
                self.assertEqual(L.category_for(self.s, self.a, '점심'), food)
                self.assertEqual(self.s, before)

    def test_classification_explicit_unclassified_is_saved_but_not_learned(self):
        other = next(c['id'] for c in self.s['categories'] if c['name'] == '미분류')
        first = self.entry(note='점심', category=other)
        self.assertEqual(first['category'], other)
        self.assertNotIn(self.a + ':점심', self.s['rules'])
        self.assertNotEqual(self.entry(note='점심')['category'], other)
        self.assertEqual(first['category'], other, 'Previously saved entries must not be reclassified')

    def test_classification_ui_auto_selection_omits_category_and_reclassifies_same_note(self):
        other = next(c['id'] for c in self.s['categories'] if c['name'] == '미분류')
        entry = self.entry(note='점심 식사', category=other)
        # EntryForm omits category when the user picks automatic classification.
        updated = L.update_entry(self.s, self.a, entry['id'], dict(note='점심 식사', amount=30000))
        food = next(c['id'] for c in self.s['categories'] if c['name'] == '식비')
        self.assertEqual(updated['category'], food)
        self.assertEqual(self.s['rules'], {})

    def test_classification_note_edit_without_category_reclassifies_without_learning(self):
        entry = self.entry(note='처음 보는 상점')
        food = next(c['id'] for c in self.s['categories'] if c['name'] == '식비')
        updated = L.update_entry(self.s, self.a, entry['id'], dict(note='점심 식사'))
        self.assertEqual(updated['category'], food)
        self.assertEqual(self.s['rules'], {})
        self.assertEqual(self.entry(note='점심 식사')['category'], food)

    def test_classification_amount_edit_does_not_learn_inherited_category(self):
        entry = self.entry(note='새로운 상점')
        L.update_entry(self.s, self.a, entry['id'], dict(amount=5000))
        self.assertEqual(self.s['rules'], {})
        custom = L.add_category(self.s, '맞춤 분류', '새로운 상점')['id']
        self.assertEqual(self.entry(note='새로운 상점')['category'], custom)

    def test_classification_automatic_edit_preserves_unrelated_manual_rules(self):
        manual = L.add_category(self.s, '직접 고른 분류', '')['id']
        entry = self.entry(note='처음 보는 상점', category=manual)
        before = dict(self.s['rules'])
        updated = L.update_entry(self.s, self.a, entry['id'], dict(amount=5000))
        self.assertEqual(updated['category'], manual)
        self.assertEqual(self.s['rules'], before)
        updated = L.update_entry(self.s, self.a, entry['id'], dict(note='커피', category=''))
        cafe = next(c['id'] for c in self.s['categories'] if c['name'] == '카페')
        self.assertEqual(updated['category'], cafe)
        self.assertEqual(self.s['rules'], before)
        L.update_entry(self.s, self.a, entry['id'], dict(note='점심', category=manual))
        self.assertEqual(L.category_for(self.s, self.a, '점심'), manual)

    def test_classification_refund_note_edit_retains_original_category(self):
        original = self.entry(note='점심')
        refund = self.entry(note='환불', kind='refund', refundOf=original['id'], amount=1000)
        updated = L.update_entry(self.s, self.a, refund['id'], dict(note='커피 반환'))
        self.assertEqual(updated['category'], original['category'])
        self.assertEqual(self.s['rules'], {})

    def test_classification_failed_edit_does_not_change_rules_or_entries(self):
        entry = self.entry(note='새로운 상점')
        category = self.s['categories'][0]['id']
        before = copy.deepcopy(self.s)
        with self.assertRaises(L.LedgerError):
            L.update_entry(self.s, self.a, entry['id'], dict(note='점심', category=category, amount=-1))
        self.assertEqual(self.s, before)

    def test_category_rules_and_custom_category(self):
        c = L.add_category(self.s, '반려생활', '사료,동물병원')
        self.entry(note='동물병원 진료')
        self.assertEqual(self.s['entries'][0]['category'], c['id'])
        e = self.entry(note='쿠팡 주문', category=c['id'])
        e2 = self.entry(note='쿠팡 주문')
        self.assertEqual(e2['category'], e['category'])

    def test_unknown_text_stays_uncategorized_after_custom_category(self):
        L.add_category(self.s, '반려생활', '사료')
        e = self.entry(note='처음 보는 내용')
        category = next(c for c in self.s['categories'] if c['id'] == e['category'])
        self.assertEqual(category['name'], '미분류')

    def test_category_keywords_do_not_match_member_identifier(self):
        L.add_category(self.s, '멤버 ID와 우연히 같은 단어', self.a[:8])
        e = self.entry(note='설명에 분류 단어가 없는 기록')
        category = next(c for c in self.s['categories'] if c['id'] == e['category'])
        self.assertEqual(category['name'], '미분류')

    def test_cannot_merge_into_a_recorded_import_with_deleted_entry(self):
        first = L.import_message(self.s, self.a, {'text': '카드 1234 승인 1200원 가맹점: 테스트마트 승인번호 111111', 'source': 'sms', 'eventID': 'first'})
        entry = self.entry(amount=1200, note='테스트마트', importID=first['id'])
        second = L.import_message(self.s, self.a, {'text': '카드 1234 승인 1200원 가맹점: 테스트마트 승인번호 222222', 'source': 'app', 'eventID': 'second'})
        L.update_entry(self.s, self.a, entry['id'], {'voided': True})
        with self.assertRaises(L.LedgerError):
            L.resolve_import(self.s, self.a, second['id'], first['id'])
        self.assertEqual(second['status'], 'pending')

    def test_refund_cannot_change_shared_to_private(self):
        e = self.entry()
        refund = self.entry(self.b, amount=10000, kind='refund', refundOf=e['id'])
        with self.assertRaises(L.LedgerError):
            L.update_entry(self.s, self.b, refund['id'], {'scope': 'personal'})

    def test_private_refund_of_shared_expense_is_rejected(self):
        original = self.entry()
        with self.assertRaises(L.LedgerError):
            self.entry(kind='refund', refundOf=original['id'], scope='personal', note='개인 메모')

    def test_settlement_rejects_changed_amount_after_preview(self):
        self.entry(amount=30000)
        revision = L.snapshot(self.s, self.a, '2026-10')['settlement'].get('revision', '')
        self.entry(self.b, amount=10000)
        with self.assertRaises(L.LedgerError):
            L.settle(self.s, self.a, '2026-10', expected_revision=revision)
        self.assertTrue(all(e['settlement'] is None for e in self.s['entries']))

    def test_different_merchants_and_times_do_not_auto_merge(self):
        a = L.import_message(self.s, self.a, dict(text='삼성카드 1234 승인 32,000원\n가맹점: 마트\n승인번호 998877\n10/20 13:00', source='sms', eventID='1'))
        b = L.import_message(self.s, self.a, dict(text='신한카드 1234 승인 32,000원\n가맹점: 식당\n승인번호 998877\n10/20 22:00', source='app', eventID='2'))
        self.assertNotEqual(a['id'], b['id'])

    def test_full_odd_refund_exactly_reverses_previous_transfer(self):
        original = self.entry(amount=10001)
        L.settle(self.s, self.a, '2026-10')
        self.entry(kind='refund', amount=10001, refundOf=original['id'])
        self.assertEqual(L.snapshot(self.s, self.a, '2026-10')['settlement']['amount'], 5000)

    def test_duplicate_sources_can_be_manually_merged_before_recording(self):
        text = '카드 승인 10,000원\n카페\n10/20 13:00'
        a = L.import_message(self.s, self.a, dict(text=text, source='sms', eventID='1'))
        b = L.import_message(self.s, self.a, dict(text=text.replace('13:00', '13:01'), source='app', eventID='2'))
        L.resolve_import(self.s, self.a, b['id'], a['id'])
        with self.assertRaises(L.LedgerError):
            self.entry(amount=10000, importID=b['id'])

    def test_private_category_choice_does_not_reveal_to_partner(self):
        private = self.entry(scope='personal', note='특별한 개인품목', category=self.s['categories'][0]['id'])
        shared = self.entry(self.b, note='특별한 개인품목')
        self.assertNotEqual(private['category'], shared['category'])

    def test_odd_split(self):
        self.entry(amount=10001)
        v = L.snapshot(self.s, self.a, '2026-10')
        self.assertEqual(v['settlement']['amount'], 5000)

    def test_rounding_carries_across_partial_settlements(self):
        self.entry(amount=1)
        L.settle(self.s, self.a, '2026-10')
        self.entry(amount=1)
        self.assertEqual(L.snapshot(self.s, self.a, '2026-10')['settlement']['amount'], 1)

    def test_same_card_shared_purchase_not_recorded_twice_by_partners(self):
        p = dict(text='카드 1234 승인 32,000원\n마트\n승인번호 998877\n10/20 13:00', source='sms', eventID='1')
        a = L.import_message(self.s, self.a, p)
        self.entry(importID=a['id'], amount=32000)
        b = L.import_message(self.s, self.b, {**p, 'source': 'app'})
        self.entry(self.b, importID=b['id'], amount=32000)
        self.assertEqual(L.snapshot(self.s, self.a, '2026-10')['stats']['total'], 32000)

    def test_same_card_private_purchase_never_leaks_to_partner(self):
        p = dict(text='카드 1234 승인 32,000원\n마트\n승인번호 998877\n10/20 13:00', source='sms', eventID='1')
        a = L.import_message(self.s, self.a, p)
        self.entry(importID=a['id'], amount=32000, scope='personal')
        b = L.import_message(self.s, self.b, {**p, 'source': 'app'})
        self.assertEqual(b['status'], 'pending')
        self.assertIsNone(b.get('entryID'))

    def test_repeat_settlement(self):
        self.entry(amount=30000)
        L.settle(self.s, self.a, '2026-10')
        self.assertEqual(L.snapshot(self.s, self.b, '2026-10')['settlement']['amount'], 0)
        with self.assertRaises(L.LedgerError):
            L.settle(self.s, self.a, '2026-10')

    def test_refund_after_settle(self):
        e = self.entry(amount=30000)
        L.settle(self.s, self.a, '2026-10')
        with self.assertRaises(L.LedgerError):
            L.update_entry(self.s, self.a, e['id'], {'amount': 10000})
        self.entry(amount=10000, kind='refund', refundOf=e['id'])
        v = L.snapshot(self.s, self.a, '2026-10')
        self.assertEqual(v['stats']['total'], 20000)
        self.assertEqual((v['settlement']['fromID'], v['settlement']['toID'], v['settlement']['amount']), (self.a, self.b, 5000))

    def test_pool_balance(self):
        self.s['mode'] = 'pool'
        self.entry(amount=200000, kind='deposit', funding='fund')
        self.entry(amount=30000, funding='fund')
        self.entry(amount=20000, funding='personal')
        v = L.snapshot(self.s, self.a, '2026-10')
        self.assertEqual((v['stats']['total'], v['stats']['fundBalance']), (50000, 170000))
        self.assertEqual(v['settlement']['memberAmounts'][0]['amount'], 20000)
        L.settle(self.s, self.a, '2026-10', self.a)
        self.assertEqual(L.snapshot(self.s, self.a, '2026-10')['stats']['fundBalance'], 150000)

    def test_month_boundary_and_budget(self):
        self.s['budget'] = 100000
        self.entry(amount=40000, day='2026-09-30')
        self.entry(amount=30000)
        v = L.snapshot(self.s, self.a, '2026-10')
        self.assertEqual((v['stats']['previousTotal'], v['stats']['delta'], v['stats']['budgetRemaining']), (40000, -10000, 70000))

    def test_parse_approval_and_balance(self):
        p = L.parse_message('[Web발신]\n삼성카드 1234 승인\n10/20 18:30\n32,000원\n이마트\n누적 180,000원', '2026-10-20T18:31:00+09:00')
        self.assertEqual(p['amount'], 32000)
        self.assertEqual(p['card'], '1234')
        self.assertEqual(p['merchant'], '이마트')
        self.assertEqual(p['time'], '2026-10-20T18:30:00+09:00')

    def test_ambiguous_amount(self):
        p = L.parse_message('승인 10,000원 20,000원', '2026-10-20T18:31:00+09:00')
        self.assertIsNone(p['amount'])
        self.assertTrue(p['requiresReview'])

    def test_parser_excludes_scheduled_and_billing_notices(self):
        # Synthetic messages; real bank notification wording is not yet available.
        for notice in ('출금 예정', '오늘 출금예정', '결제 예정', '청구 예정',
                       '출금할 예정', '결제될 예정', '출금 예정이에요',
                       '청구 안내', '결제일 안내', '결제예정일: 10/30',
                       '입금 예정', '지급 예정', '송금 예정', '이체 예정'):
            with self.subTest(notice=notice):
                parsed = L.parse_message(f'테스트은행 {notice}\n38,000원\n가맹점: 테스트상점')
                self.assertEqual(parsed['kind'], 'unknown')
                self.assertIsNone(parsed['amount'])
                self.assertTrue(parsed['requiresReview'])
                self.assertIn('실제 거래', parsed['reason'])

    def test_parser_excludes_coupon_delivery_with_nonrefundable_terms(self):
        raw = ('[Web발신] 안녕하세요, T다이렉트샵입니다. 다이렉트 플랜을 이용해주신 '
               '고객님께 감사의 마음으로 쿠폰을 드립니다. (6개월 간 유지 시 매월 지급) '
               '상품명: 카카오페이 38,000원 쿠폰번호: TEST-ONLY [유의사항] 등록기간 ... '
               '등록기간이 만료된 쿠폰은 효력이 상실되며 연장 및 환불이 불가하오니 기간 내 꼭 등록바랍니다.')
        for sample in (raw, '쿠폰 발송 안내\n38,000원\n취소/환불 불가',
                       '쿠폰번호: TEST-ONLY\n38,000원\n승인번호: TEST1234\n환불 불가'):
            with self.subTest(sample=sample):
                parsed = L.parse_message(sample)
                self.assertEqual(parsed['kind'], 'unknown')
                self.assertIsNone(parsed['amount'])
                self.assertIn('쿠폰', parsed['reason'])

    def test_parser_preserves_real_transactions_with_due_dates_and_terms(self):
        for event, kind in (('카드 1234 승인', 'expense'), ('출금 완료', 'transfer'),
                            ('입금 완료', 'income'), ('환불 완료', 'refund'),
                            ('카드 1234 승인취소', 'refund')):
            for extra in ('', '\n결제예정일: 11/25', '\n결제 예정일: 2026-11-25',
                          '\n[유의사항] 쿠폰은 연장 및 환불이 불가합니다.',
                          '\n[유의사항] 쿠폰 취소/환불 불가',
                          '\n쿠폰 안내: 쿠폰번호 TEST-ONLY, 환불이 불가합니다.',
                          '\n결제예정일: 11/25\n쿠폰 안내: 환불 불가'):
                with self.subTest(event=event, extra=extra):
                    parsed = L.parse_message(f'{event}\n38,000원\n가맹점: 테스트상점{extra}')
                    self.assertEqual((parsed['kind'], parsed['amount']), (kind, 38000))
                    self.assertEqual(parsed['merchant'], '테스트상점')

    def test_coupon_word_alone_does_not_reject_a_transaction(self):
        for raw, kind in (('결제 38,000원\n가맹점: 쿠폰상점', 'expense'),
                          ('환불 38,000원\n가맹점: 쿠폰상점', 'refund'),
                          ('입금 38,000원\n쿠폰 판매대금', 'income')):
            with self.subTest(raw=raw):
                parsed = L.parse_message(raw)
                self.assertEqual((parsed['kind'], parsed['amount']), (kind, 38000))

    def test_notice_imports_are_ignored_without_candidates_or_entries(self):
        for index, raw in enumerate(('오늘 출금예정 38,000원\n가맹점: 테스트상점',
                                     '자동이체\n오늘 테스트보험 외 1곳에서 119,970원\n출금할 예정이에요. 토스뱅크 통장 (0000)에서\n출금돼요.',
                                     '청구 안내 38,000원\n가맹점: 테스트상점',
                                     '쿠폰 발송 안내 38,000원\n환불 불가')):
            with self.subTest(raw=raw):
                payload = dict(text=raw, source='sms', eventID=f'notice-{index}')
                imported = L.import_message(self.s, self.a, payload)
                self.assertEqual(imported['status'], 'ignored')
                self.assertEqual(imported['candidates'], [])
                self.assertIsNone(imported['amount'])
                self.assertTrue(imported['reason'])
                self.assertEqual(L.import_message(self.s, self.a, payload)['id'], imported['id'])
        self.assertEqual(self.s['entries'], [])
        self.assertEqual(L.snapshot(self.s, self.a, '2026-10')['inbox'], [])
        self.assertEqual(L.snapshot(self.s, self.b, '2026-10')['inbox'], [])
        real = L.import_message(self.s, self.a, dict(text='출금 완료 38,000원\n가맹점: 테스트상점', eventID='actual'))
        self.assertEqual((real['status'], real['kind'], real['amount']), ('pending', 'transfer', 38000))
        self.assertEqual(real['candidates'], [])

    def test_ignore_marketing(self):
        p = L.parse_message('[광고] 이번 달 10,000원 캐시백 혜택', '2026-10-20T18:31:00+09:00')
        self.assertEqual(p['kind'], 'unknown')
        self.assertIsNone(p['amount'])

    def test_same_amount_not_auto_merged(self):
        a = L.import_message(self.s, self.a, dict(text='카드 승인 10,000원\n카페\n10/20 13:00', source='sms', eventID='1'))
        b = L.import_message(self.s, self.a, dict(text='카드 승인 10,000원\n카페\n10/20 13:01', source='sms', eventID='2'))
        self.assertNotEqual(a['id'], b['id'])
        self.assertIn(a['id'], b['candidates'])

    def test_reference_merges_sms_and_app(self):
        payload = dict(text='카드 1234 승인 32,000원\n마트\n승인번호 998877\n10/20 13:00', source='sms', eventID='1')
        a = L.import_message(self.s, self.a, payload)
        b = L.import_message(self.s, self.a, {**payload, 'source': 'app', 'eventID': '2'})
        self.assertEqual(a['id'], b['id'])
        self.assertEqual(b['sources'], ['sms', 'app'])
        self.assertEqual(len(self.s['imports']), 1)

    def test_same_reference_other_day_is_distinct(self):
        text = '카드 1234 승인 32,000원\n마트\n승인번호 998877\n10/19 13:00'
        a = L.import_message(self.s, self.a, dict(text=text, source='sms', eventID='1'))
        b = L.import_message(self.s, self.a, dict(text=text.replace('10/19', '10/20'), source='app', eventID='2'))
        self.assertNotEqual(a['id'], b['id'])

    def test_import_event_retry_is_idempotent(self):
        p = dict(text='승인 10,000원\n카페', source='sms', eventID='retry')
        a = L.import_message(self.s, self.a, p)
        b = L.import_message(self.s, self.a, p)
        self.assertEqual(a['id'], b['id'])
        self.assertEqual(len(self.s['imports']), 1)

    def test_import_recorded_once(self):
        i = L.import_message(self.s, self.a, dict(text='승인 10,000원\n카페', source='sms', eventID='1'))
        a = self.entry(amount=10000, importID=i['id'])
        b = self.entry(amount=10000, importID=i['id'])
        self.assertEqual(a['id'], b['id'])
        self.assertEqual(len(self.s['entries']), 1)

    def test_refund_is_not_duplicate(self):
        a = L.import_message(self.s, self.a, dict(text='카드 1234 승인 10,000원\n카페\n승인번호 998877', source='sms', eventID='1'))
        b = L.import_message(self.s, self.a, dict(text='카드 1234 승인취소 10,000원\n카페\n승인번호 998877', source='sms', eventID='2'))
        self.assertNotEqual(a['id'], b['id'])
        self.assertEqual(b['kind'], 'refund')

    def test_transfer_requires_explicit_confirmation(self):
        p = L.parse_message('우리은행 출금 50,000원\n홍길동\n잔액 100,000원', '2026-10-20T18:31:00+09:00')
        self.assertEqual(p['amount'], 50000)
        self.assertEqual(p['kind'], 'transfer')
        self.assertTrue(p['requiresReview'])

    def test_snapshot_rules_include_only_own_canonical_notes(self):
        defaults = L.snapshot(self.s, self.a, '2026-10')['classificationRules']
        category = self.s['categories'][0]['id']
        self.entry(note='개인 물품', scope='personal', category=category)
        self.entry(self.b, note='상대 비밀', scope='personal', category=category)
        self.s['rules'].update({'legacy-note': category, self.a + '-other:secret': category})
        before = copy.deepcopy(self.s)
        own = L.snapshot(self.s, self.a, '2026-10')
        partner = L.snapshot(self.s, self.b, '2026-10')
        self.assertEqual(own.get('classificationRules'), {**defaults, '개인물품': category})
        self.assertEqual(partner.get('classificationRules'), {**defaults, '상대비밀': category})
        self.assertNotIn('개인물품', json.dumps(partner, ensure_ascii=False))
        self.assertEqual(self.s, before)

    def imported(self, actor=None, **overrides):
        payload = dict(text='카드 승인 10,000원\n가맹점: 테스트카페\n2026/10/20 13:00',
                       source='sms', eventID=L.uid())
        payload.update(overrides)
        return L.import_message(self.s, actor or self.a, payload)

    def test_pending_candidates_show_current_own_pending_and_recorded_details(self):
        first = self.imported()
        second = self.imported(source='app', text='카드 승인 10,000원\n가맹점: 테스트카페\n2026/10/20 13:01')
        current = self.imported(text='카드 승인 10,000원\n가맹점: 테스트카페\n2026/10/20 13:02')
        self.entry(importID=first['id'], amount=10000)
        first['sources'].append('app')
        before = copy.deepcopy(self.s)
        inbox = L.snapshot(self.s, self.a, '2026-10')['inbox']
        item = next(i for i in inbox if i['id'] == current['id'])
        self.assertEqual(item.get('candidateDetails'), [
            dict(id=first['id'], merchant='테스트카페', kind='expense', status='recorded',
                 amount=10000, time='2026-10-20T13:00:00+09:00', sources=['sms', 'app']),
            dict(id=second['id'], merchant='테스트카페', kind='expense', status='pending',
                 amount=10000, time='2026-10-20T13:01:00+09:00', sources=['app'])])
        self.assertEqual(self.s, before)

    def test_candidate_details_exclude_stale_unreachable_and_other_actor_imports(self):
        def candidate(actor=None):
            minute=len(self.s['imports'])
            return self.imported(actor, text=f'카드 승인 10,000원\n가맹점: 테스트카페\n2026/10/20 13:{minute:02}')
        valid = candidate()
        ignored = candidate()
        L.resolve_import(self.s, self.a, ignored['id'])
        duplicate = candidate()
        L.resolve_import(self.s, self.a, duplicate['id'], valid['id'])
        removed = candidate()
        removed_entry = self.entry(importID=removed['id'])
        L.update_entry(self.s, self.a, removed_entry['id'], {'voided': True})
        missing = candidate()
        missing.update(status='recorded', entryID='missing-entry')
        unlinked = candidate()
        unlinked.update(status='recorded')
        foreign = candidate(self.b)
        hidden = candidate()
        hidden.update(status='recorded', entryID=self.entry(self.b, scope='personal')['id'])
        current = candidate()
        current['candidates'] += [ignored['id'], duplicate['id'], foreign['id'], hidden['id'],
                                  current['id'], 'missing-import', valid['id']]
        item = next(i for i in L.snapshot(self.s, self.a, '2026-10')['inbox'] if i['id'] == current['id'])
        self.assertEqual(item['candidates'], [valid['id']])
        self.assertEqual([c['id'] for c in item.get('candidateDetails', [])], [valid['id']])
        self.assertNotIn('raw', item['candidateDetails'][0])
        self.assertNotIn('events', item['candidateDetails'][0])

    def test_old_state_has_empty_optional_metadata_without_inferred_shortcut_success(self):
        item = self.imported(source='shortcut')
        self.s.pop('importStatus', None)
        item.pop('candidateDetails', None)
        view = L.snapshot(self.s, self.a, '2026-10')
        self.assertEqual(view.get('importStatus'), dict(lastReceivedAt=None, lastShortcutAt=None))
        ids = {c['name']: c['id'] for c in view['categories']}
        self.assertEqual(view.get('classificationRules'), {'콜라': ids['식비'], '빵': ids['식비'],
                         '약': ids['의료'], '코약': ids['의료'], '티머니충전': ids['교통']})
        self.assertEqual(view['inbox'][0].get('candidateDetails'), [])
        # The pre-existing response fields retain their JSON types for old clients.
        decoded = json.loads(json.dumps(view))
        self.assertIsInstance(decoded['inbox'][0]['candidates'], list)
        self.assertIsInstance(decoded['stats']['total'], int)

    def test_receipt_status_is_actor_only_and_tracks_server_receipt_not_message_time(self):
        self.imported(viaShortcut=True, receivedAt='2026-10-01T09:00:00+09:00')
        with patch('ledger.now', return_value='2026-10-22T12:00:00+09:00'):
            self.imported(source='paste', viaShortcut=False)
        view = L.snapshot(self.s, self.a, '2026-10')
        self.assertEqual(view.get('importStatus'), dict(lastReceivedAt='2026-10-22T12:00:00+09:00',
                                                      lastShortcutAt='2026-10-21T12:00:00+09:00'))
        self.assertEqual(L.snapshot(self.s, self.b, '2026-10').get('importStatus'),
                         dict(lastReceivedAt=None, lastShortcutAt=None))

    def test_repeated_event_and_reference_receipts_refresh_status_without_extra_imports(self):
        payload = dict(text='카드 1234 승인 10,000원\n테스트카페\n승인번호 998877\n2026/10/20 13:00',
                       source='sms', eventID='retry')
        original = L.import_message(self.s, self.a, payload)
        self.entry(importID=original['id'])
        for source, event, stamp in [('sms', 'retry', '2026-10-22T12:00:00+09:00'),
                                     ('app', 'other', '2026-10-23T12:00:00+09:00')]:
            with self.subTest(source=source), patch('ledger.now', return_value=stamp):
                result = L.import_message(self.s, self.a, {**payload, 'source': source,
                                                          'eventID': event, 'viaShortcut': True})
                self.assertEqual(result['id'], original['id'])
                self.assertEqual(L.snapshot(self.s, self.a, '2026-10').get('importStatus'),
                                 dict(lastReceivedAt=stamp, lastShortcutAt=stamp))
        self.assertEqual(len(self.s['imports']), 1)
        self.assertEqual(len(self.s['entries']), 1)

    def test_failed_import_and_non_boolean_shortcut_marker_do_not_claim_delivery(self):
        for marker in (None, False, 'true', 1):
            with self.subTest(marker=marker):
                self.imported(source='shortcut', viaShortcut=marker)
                self.assertEqual(L.snapshot(self.s, self.a, '2026-10').get('importStatus'),
                                 dict(lastReceivedAt='2026-10-21T12:00:00+09:00', lastShortcutAt=None))
        before = copy.deepcopy(self.s)
        with patch('ledger.now', return_value='2026-10-22T12:00:00+09:00'):
            with self.assertRaises(L.LedgerError):
                self.imported(text='', viaShortcut=True)
            with self.assertRaises(L.LedgerError):
                self.imported(source='invalid', viaShortcut=True)
        self.assertEqual(self.s, before)

    def test_current_month_comparison_uses_same_days_and_preserves_full_totals(self):
        self.entry(amount=10000, day='2026-10-21')
        self.entry(amount=2000, kind='refund', day='2026-10-01')
        self.entry(amount=50000, day='2026-10-22')
        self.entry(amount=6000, day='2026-09-21')
        self.entry(amount=90000, day='2026-09-22')
        self.entry(self.b, scope='personal', amount=70000)
        self.entry(scope='personal', amount=80000)
        voided = self.entry(amount=99000)
        L.update_entry(self.s, self.a, voided['id'], {'voided': True})
        stats = L.snapshot(self.s, self.a, '2026-10')['stats']
        self.assertEqual((stats.get('comparisonTotal'), stats.get('comparisonPreviousTotal'),
                          stats.get('comparisonThroughDay')), (8000, 6000, 21))
        self.assertEqual((stats['total'], stats['previousTotal'], stats['delta']), (58000, 96000, -38000))

    def test_current_month_comparison_clamps_both_months_to_previous_month_length(self):
        for year, last_day in [(2026, 28), (2028, 29)]:
            with self.subTest(year=year), patch('ledger.now', return_value=f'{year}-03-31T12:00:00+09:00'):
                self.s['entries'] = []
                self.entry(amount=10000, day=f'{year}-03-{last_day}')
                self.entry(amount=90000, day=f'{year}-03-{last_day+1}')
                self.entry(amount=4000, day=f'{year}-02-{last_day}')
                stats = L.snapshot(self.s, self.a, f'{year}-03')['stats']
                self.assertEqual((stats.get('comparisonTotal'), stats.get('comparisonPreviousTotal'),
                                  stats.get('comparisonThroughDay')), (10000, 4000, last_day))

    def test_current_month_comparison_uses_kst_date_at_utc_month_boundary(self):
        self.entry(amount=10000, day='2027-01-01')
        self.entry(amount=90000, day='2027-01-02')
        self.entry(amount=4000, day='2026-12-01')
        self.entry(amount=80000, day='2026-12-02')
        with patch('ledger.now', return_value='2026-12-31T15:30:00+00:00'):
            stats = L.snapshot(self.s, self.a, '2027-01')['stats']
        self.assertEqual((stats.get('comparisonTotal'), stats.get('comparisonPreviousTotal'),
                          stats.get('comparisonThroughDay')), (10000, 4000, 1))

    def test_historical_comparison_uses_whole_months_and_excludes_pool_deposits(self):
        self.s['mode'] = 'pool'
        self.entry(amount=10000, day='2026-09-30')
        self.entry(amount=2000, kind='refund', day='2026-09-01')
        self.entry(amount=100000, kind='deposit', day='2026-09-01')
        self.entry(amount=4000, day='2026-08-31')
        stats = L.snapshot(self.s, self.a, '2026-09')['stats']
        self.assertEqual((stats.get('comparisonTotal'), stats.get('comparisonPreviousTotal'),
                          stats.get('comparisonThroughDay')), (8000, 4000, None))


class SettlementCandidateTests(unittest.TestCase):
    def setUp(self):
        clock = patch('ledger.now', return_value='2026-10-26T16:00:00+09:00')
        clock.start()
        self.addCleanup(clock.stop)
        self.s = L.new_household('합성 정산', '순환', 'separate')
        self.a = self.s['members'][0]['id']
        self.b = L.add_member(self.s, '주희')['id']

    def entry(self, actor=None, **changes):
        return L.add_entry(self.s, actor or self.a, dict(dict(amount=20000, note='공용 식사',
                           day='2026-09-20', scope='shared'), **changes))

    def imported(self, actor, raw='은행 송금 완료 10,000원\n받는 사람: 순환\n2026/10/26 13:00'):
        return L.import_message(self.s, actor, dict(text=raw, eventID=L.uid()))

    def view(self, actor=None):
        result = L.snapshot(self.s, actor or self.b, '2026-10')
        self.assertIn('pendingSettlements', result)
        self.assertIn('settlementCandidates', result)
        return result

    def due(self, actor=None):
        return self.view(actor)['pendingSettlements'][0]

    def confirm(self, due, actor=None, **changes):
        return L.settle(self.s, actor or self.b, due['month'], due['memberID'], due['revision'], **changes)

    def test_due_months_preserve_full_month_accounting_and_exclude_future_months(self):
        self.entry()
        self.entry(day='2026-10-26')
        self.entry(day='2026-10-27', amount=80000)
        self.entry(day='2026-11-01')
        self.entry(day='2026-08-01', scope='personal')
        before = copy.deepcopy(self.s)
        dues = self.view()['pendingSettlements']
        self.assertEqual([(d['month'], d['amount'], d['count'], d['memberID']) for d in dues],
                         [('2026-09', 10000, 1, None), ('2026-10', 50000, 2, None)])
        self.assertEqual(set(dues[0]), {'month', 'fromID', 'toID', 'amount', 'count', 'revision', 'memberID'})
        for due in dues:
            preview = L.snapshot(self.s, self.b, due['month'])['settlement']
            self.assertEqual({k: due[k] for k in ('fromID', 'toID', 'amount', 'count', 'revision')},
                             {k: preview[k] for k in ('fromID', 'toID', 'amount', 'count', 'revision')})
        self.assertEqual(self.s, before)
        self.confirm(dues[1])
        self.assertEqual([e['day'] for e in self.s['entries'] if e.get('settlement')], ['2026-10-26', '2026-10-27'])
        self.assertEqual(self.view()['pendingSettlements'], [dues[0]])
        self.assertEqual([e['day'] for e in L.pending(self.s, '2026-11')], ['2026-11-01'])

    def test_standard_bank_receipts_without_completed_word_are_candidates_only(self):
        self.entry(amount=2020000)
        for actor, word, label, name in ((self.a, '입금', '보낸 분', '주희'),
                                        (self.b, '출금', '받는 분', '순환')):
            with self.subTest(word=word):
                item = self.imported(actor, f'은행 {word} 1,010,000원\n{label}: {name}\n잔액 2,020,000원')
                self.assertEqual(self.view(actor)['settlementCandidates'], [{'importID': item['id'], 'due': self.due(actor)}])
                self.assertEqual(item['status'], 'pending')
        self.assertEqual(len(self.s['settlements']), 0)
        self.assertEqual(len(self.s['entries']), 1)

    def test_bare_bank_notices_and_spaced_counterparty_mismatches_are_excluded(self):
        self.entry(amount=2020000)
        rejected = [
            (self.b, '은행 출금 예정 1,010,000원'),
            (self.b, '은행 출금가능금액 1,010,000원'),
            (self.b, '은행 출금 1,010,000원 잔액안내'),
            (self.b, '은행 출금 1,010,000원 실패'),
            (self.b, '은행 출금 1,010,000원 요청'),
            (self.b, '은행 출금 1,010,000원 카드대금'),
            (self.b, '은행 출금 완료 1,010,000원\n받는 분: 타인'),
            (self.a, '은행 입금 완료 1,010,000원\n보낸 분: 타인'),
            (self.b, '은행 출금 1,010,000원\n받는 분: 타인'),
            (self.a, '은행 입금 1,010,000원\n보낸 분: 타인'),
        ]
        for actor, raw in rejected:
            with self.subTest(raw=raw):
                self.s['imports'] = []
                item = self.imported(actor, raw)
                self.assertEqual(self.view(actor)['settlementCandidates'], [])
                before = copy.deepcopy(self.s)
                with self.assertRaises(L.LedgerError):
                    self.confirm(self.due(actor), actor, import_id=item['id'], request_id=L.uid())
                self.assertEqual(self.s, before)

    def test_candidate_direction_counterparty_and_late_payment_privacy(self):
        self.entry()
        outgoing = self.imported(self.b)
        incoming = self.imported(self.a, '은행 입금 완료 10,000원\n보낸 사람: 주희\n2026/10/26 13:00')
        self.assertTrue(outgoing['requiresReview'])
        self.assertEqual(self.view()['settlementCandidates'], [{'importID': outgoing['id'], 'due': self.due()}])
        own = self.view(self.a)['settlementCandidates']
        self.assertEqual([c['importID'] for c in own], [incoming['id']])
        self.assertNotIn(outgoing['raw'], json.dumps(own, ensure_ascii=False))

    def test_wrong_direction_amount_counterparty_and_nontransfers_are_excluded(self):
        self.entry()
        self.s['members'][0]['account'] = '1234-567890'
        rejected = [
            '은행 입금 완료 10,000원', '은행 송금 완료 9,000원', '은행 송금 완료 0원',
            '은행 송금 완료 10,000원\n받는 사람: 타인',
            '은행 송금 완료 10,000원\n받는 계좌: 9999-567890',
            '카드 승인 10,000원', '카드 결제 출금 완료 10,000원', '은행 환불 입금 완료 10,000원',
            '은행 송금 예정 10,000원', '은행 송금 완료 실패 10,000원',
            '광고 송금 완료 10,000원', '은행 송금 완료되지 않았습니다 10,000원',
            '은행 송금 완료 10,000원\n2026/08/31 10:00',
            '은행 송금 완료 10,000원\n2026/11/01 10:00',
            '은행 송금 완료 입금 완료 10,000원', '본인 계좌 이체 완료 10,000원']
        for raw in rejected:
            with self.subTest(raw=raw):
                self.imported(self.b, raw)
                self.assertEqual(self.view()['settlementCandidates'], [])
        unknown = self.imported(self.b, '은행 송금 완료 10,000원')
        self.assertEqual([c['importID'] for c in self.view()['settlementCandidates']], [unknown['id']])

    def test_pool_positive_negative_zero_and_actor_are_distinct(self):
        self.s['mode'] = 'pool'
        self.entry(amount=10000)
        self.entry(self.b, kind='income', amount=10000)
        self.entry(funding='fund', amount=50000)
        dues = self.view()['pendingSettlements']
        self.assertEqual([(d['fromID'], d['toID'], d['amount'], d['count'], d['memberID']) for d in dues],
                         [('fund', self.a, 10000, 1, self.a), (self.b, 'fund', 10000, 1, self.b)])
        own = self.imported(self.a, '은행 입금 완료 10,000원')
        wrong = self.imported(self.a, '은행 송금 완료 10,000원')
        self.assertEqual(self.view(self.a)['settlementCandidates'], [{'importID': own['id'], 'due': dues[0]}])
        self.assertNotEqual(own['id'], wrong['id'])
        self.confirm(dues[0], self.a, import_id=own['id'], request_id=L.uid())
        self.assertEqual(len(self.view()['pendingSettlements']), 1)
        self.entry(self.b, amount=10000)
        zero = self.due()
        self.assertEqual((zero['amount'], zero['count']), (0, 2))
        self.imported(self.b, '은행 송금 완료 10,000원')
        self.assertEqual(self.view()['settlementCandidates'], [])
        self.confirm(zero)
        self.assertEqual(self.view()['pendingSettlements'], [])

    def test_confirmation_is_atomic_and_exact_request_replay_precedes_revision(self):
        self.entry()
        imported = self.imported(self.b)
        due = self.due()
        request = L.uid()
        count = len(self.s['entries'])
        record = self.confirm(due, import_id=imported['id'], request_id=request)
        self.assertEqual(imported['status'], 'settled')
        self.assertEqual(imported['settlementID'], record['id'])
        self.assertEqual(len(self.s['entries']), count)
        self.entry(amount=4000)
        self.assertEqual(self.confirm(due, import_id=imported['id'], request_id=request), record)
        for kwargs in ({'import_id': imported['id'], 'request_id': L.uid()},
                       {'import_id': imported['id']}, {'request_id': request}):
            before = copy.deepcopy(self.s)
            with self.subTest(kwargs=kwargs), self.assertRaises(L.LedgerError):
                self.confirm(due, **kwargs)
            self.assertEqual(self.s, before)
        shared_history = self.view(self.a)['history'] + L.snapshot(self.s, self.a, '2026-09')['history']
        self.assertNotIn(imported['raw'], json.dumps(shared_history, ensure_ascii=False))
        self.assertNotIn(imported['id'], json.dumps(shared_history))

    def test_pool_negative_bank_receipt_closes_only_target_person(self):
        self.s['mode'] = 'pool'
        self.entry(amount=10000)
        self.entry(self.b, kind='income', amount=10000)
        own = self.imported(self.b, '은행 출금 10,000원')
        due = next(d for d in self.view()['pendingSettlements'] if d['memberID'] == self.b)
        self.assertEqual(self.view()['settlementCandidates'], [{'importID': own['id'], 'due': due}])
        record = self.confirm(due, import_id=own['id'], request_id=L.uid())
        self.assertEqual((record['fromID'], record['toID'], record['amount'], record['signedAmount']),
                         (self.b, 'fund', 10000, -10000))
        self.assertEqual([d['memberID'] for d in self.view()['pendingSettlements']], [self.a])
        self.assertEqual((len(self.s['entries']), own['status']), (2, 'settled'))

    def test_only_pending_import_can_be_selected_even_if_preview_was_valid(self):
        self.entry()
        item = self.imported(self.b)
        due = self.due()
        for status in ('ignored', 'recorded', 'settled'):
            with self.subTest(status=status):
                item['status'] = status
                self.assertEqual(self.view()['settlementCandidates'], [])
                before = copy.deepcopy(self.s)
                with self.assertRaises(L.LedgerError):
                    self.confirm(due, import_id=item['id'], request_id=L.uid())
                self.assertEqual(self.s, before)

    def test_legacy_manual_request_without_import_and_uuid_replay_preserves_old_pending(self):
        self.entry()
        self.entry(day='2026-10-01')
        due = next(d for d in self.view()['pendingSettlements'] if d['month'] == '2026-10')
        request = L.uid()
        record = self.confirm(due, request_id=request)
        self.assertEqual(self.confirm(due, request_id=request), record)
        self.assertEqual(len(self.s['settlements']), 1)
        self.assertEqual([d['month'] for d in self.view()['pendingSettlements']], ['2026-09'])
        older = self.due()
        manual = self.confirm(older)
        self.assertEqual(manual['amount'], 10000)
        self.assertEqual(self.view()['pendingSettlements'], [])

    def test_revalidate_stale_foreign_consumed_partial_and_bad_uuid_without_mutation(self):
        self.entry()
        due = self.due()
        foreign = self.imported(self.a, '은행 입금 완료 10,000원')
        partial = self.imported(self.b, '은행 송금 완료 5,000원')
        valid = self.imported(self.b)
        for import_id, request_id in ((foreign['id'], L.uid()), (partial['id'], L.uid()),
                                      (valid['id'], 'not-a-uuid')):
            before = copy.deepcopy(self.s)
            with self.subTest(import_id=import_id), self.assertRaises(L.LedgerError):
                self.confirm(due, import_id=import_id, request_id=request_id)
            self.assertEqual(self.s, before)
        self.entry(amount=1000)
        before = copy.deepcopy(self.s)
        with self.assertRaises(L.LedgerError):
            self.confirm(due, import_id=valid['id'], request_id=L.uid())
        self.assertEqual(self.s, before)

    def test_same_amount_months_require_selection_and_zero_remains_manual(self):
        self.entry()
        self.entry(day='2026-08-20')
        imported = self.imported(self.b)
        self.assertEqual([c['due']['month'] for c in self.view()['settlementCandidates']], ['2026-08', '2026-09'])
        chosen = self.view()['pendingSettlements'][0]
        self.confirm(chosen, import_id=imported['id'], request_id=L.uid())
        self.assertEqual([d['month'] for d in self.view()['pendingSettlements']], ['2026-09'])
        self.entry(self.b)
        self.assertEqual(self.due()['amount'], 0)
        self.assertEqual(self.view()['settlementCandidates'], [])
        self.confirm(self.due())


class RecurringTests(unittest.TestCase):
    def setUp(self):
        self.s = L.new_household('반복 테스트', '본인', 'separate')
        self.a = self.s['members'][0]['id']
        self.b = L.add_member(self.s, '상대')['id']
        self.category = self.s['categories'][0]['id']

    def schedule(self, **overrides):
        payload = dict(note='월 정기 결제', amount=30000, scope='shared', category=self.category,
                       payer=self.a, funding='personal', startDay='2026-01-01', dayOfMonth=31)
        payload.update(overrides)
        return L.add_recurring(self.s, self.a, payload)

    def record(self, recurring, **overrides):
        payload = dict(id=L.uid(), note='검토한 결제', amount=31000, scope=recurring['scope'],
                       category=self.category, payer=recurring['payer'], funding=recurring['funding'],
                       day='2026-10-31', recurringID=recurring['id'], recurringMonth='2026-10')
        payload.update(overrides)
        return L.add_entry(self.s, self.a, payload)

    def view(self, actor=None, month='2026-10'):
        return L.snapshot(self.s, actor or self.a, month)['recurringPayments']

    def test_old_state_and_reads_do_not_write_or_count_plans_as_actual(self):
        before = copy.deepcopy(self.s)
        self.assertEqual(self.view(), [])
        self.assertEqual(self.s, before)
        recurring = self.schedule()
        before = copy.deepcopy(self.s)
        self.assertEqual(self.view()[0]['dueDay'], '2026-10-31')
        self.assertIsNone(self.view()[0]['entryID'])
        self.assertEqual(self.s, before)
        self.assertEqual(L.snapshot(self.s, self.a, '2026-10')['stats']['total'], 0)
        ordinary = L.add_entry(self.s, self.a, dict(amount=100, note='일반', scope='shared', day='2026-10-01'))
        self.assertNotIn('recurringID', ordinary)
        self.assertNotIn('recurringMonth', ordinary)
        self.assertEqual(recurring['owner'], self.a)

    def test_shared_visibility_personal_isolation_and_owner_only_mutations(self):
        shared = self.schedule()
        private = self.schedule(scope='personal', note='비밀 일정')
        self.assertEqual([r['id'] for r in self.view(self.b)], [shared['id']])
        self.assertNotIn('비밀 일정', json.dumps(L.snapshot(self.s, self.b, '2026-10'), ensure_ascii=False))
        for recurring_id in (shared['id'], private['id'], 'foreign-or-missing'):
            with self.assertRaises(L.LedgerError):
                L.update_recurring(self.s, self.b, recurring_id, {'note': '수정'})
            with self.assertRaises(L.LedgerError):
                L.delete_recurring(self.s, self.b, recurring_id)
            with self.assertRaises(L.LedgerError):
                L.link_recurring(self.s, self.b, recurring_id, dict(month='2026-10', entryID='missing'))
            with self.assertRaises(L.LedgerError):
                L.add_entry(self.s, self.b, dict(amount=30000, note='침범', scope='shared', day='2026-10-31',
                                               recurringID=recurring_id, recurringMonth='2026-10'))
        self.assertEqual(len(self.view()), 2)

    def test_invalid_schedule_fields_do_not_mutate_state(self):
        invalid = [('amount', v) for v in (0, -1, True, 1.5, '3000', 100_000_000_001)]
        invalid += [('dayOfMonth', v) for v in (0, 32, True, 1.5, '31')]
        invalid += [('active', v) for v in (1, 'true', None)]
        invalid += [('startDay', '2026-02-30'), ('startDay', '2026-1-01'), ('scope', 'private'),
                    ('category', 'missing'), ('payer', 'foreign'),
                    ('funding', 'fund'), ('note', ''), ('note', 'x' * 121)]
        for field, value in invalid:
            before = copy.deepcopy(self.s)
            with self.subTest(field=field, value=value), self.assertRaises(L.LedgerError):
                self.schedule(**{field: value})
            self.assertEqual(self.s, before)
        for missing in ('scope', 'startDay', 'dayOfMonth'):
            payload = dict(note='필드 누락', amount=1000, scope='shared', category=self.category,
                           startDay='2026-01-01', dayOfMonth=31)
            payload.pop(missing)
            with self.subTest(missing=missing), self.assertRaises(L.LedgerError):
                L.add_recurring(self.s, self.a, payload)
        with self.assertRaises(L.LedgerError):
            self.schedule(scope='personal', payer=self.b)
        self.s['mode'] = 'pool'
        self.assertEqual(self.schedule(funding='fund')['funding'], 'fund')

    def test_month_end_leap_start_date_and_selected_future_confirmation(self):
        recurring = self.schedule(startDay='2024-01-01')
        for month, due in (('2024-02', '2024-02-29'), ('2025-02', '2025-02-28'),
                           ('2026-04', '2026-04-30'), ('2026-12', '2026-12-31')):
            with self.subTest(month=month):
                self.assertEqual(self.view(month=month)[0]['dueDay'], due)
                entry = self.record(recurring, day=due, recurringMonth=month)
                self.assertEqual(self.view(month=month)[0]['entryID'], entry['id'])
        late = self.schedule(startDay='2026-10-20', dayOfMonth=10)
        self.assertIsNone(next(r for r in self.view() if r['id'] == late['id'])['dueDay'])
        with self.assertRaises(L.LedgerError):
            self.record(late, day='2026-10-10')
        self.assertIsNone(next(r for r in self.view(month='2025-10') if r['id'] == late['id'])['dueDay'])
        self.assertEqual(self.record(late, day='2026-11-10', recurringMonth='2026-11')['day'], '2026-11-10')
        exact = self.schedule(startDay='2026-10-31')
        self.assertEqual(self.record(exact)['day'], '2026-10-31')

    def test_record_review_retry_void_and_new_attempt(self):
        recurring = self.schedule()
        entry = self.record(recurring, id='first', amount=35000, note='검토 후 변경', category=self.s['categories'][1]['id'])
        self.assertEqual((entry['recurringID'], entry['recurringMonth'], entry['amount']), (recurring['id'], '2026-10', 35000))
        self.assertEqual(self.record(recurring, id='second'), entry)
        self.assertEqual(len(self.s['entries']), 1)
        L.update_entry(self.s, self.a, entry['id'], {'voided': True})
        self.assertIsNone(self.view()[0]['entryID'])
        with self.assertRaises(L.LedgerError):
            self.record(recurring, id='first')
        new = self.record(recurring, id='fresh')
        self.assertEqual(self.view()[0]['entryID'], new['id'])
        self.assertEqual(len(self.s['entries']), 2)

    def test_record_rejects_mismatched_fields_and_arbitrary_entry_ids(self):
        recurring = self.schedule()
        ordinary = L.add_entry(self.s, self.a, dict(id='ordinary', amount=30000, note='일반', scope='shared', day='2026-10-31'))
        foreign = L.add_entry(self.s, self.b, dict(id='foreign', amount=30000, note='상대', scope='shared', day='2026-10-31'))
        invalid = [dict(day='2026-10-32'), dict(day='2026-11-30'), dict(scope='personal'),
                   dict(payer=self.b), dict(funding='fund'), dict(kind='refund'), dict(kind='deposit'),
                   dict(recurringMonth='2026-13'), dict(recurringMonth='2026-1'), dict(recurringMonth=None),
                   dict(recurringID='missing'), dict(recurringID=None), dict(id=ordinary['id']), dict(id=foreign['id']),
                   dict(amount=-1), dict(category='missing')]
        for overrides in invalid:
            before = copy.deepcopy(self.s)
            with self.subTest(overrides=overrides), self.assertRaises(L.LedgerError):
                self.record(recurring, **overrides)
            self.assertEqual(self.s, before)
        with self.assertRaises(L.LedgerError):
            L.add_entry(self.s, self.a, dict(amount=30000, note='짝 없는 월', scope='shared', day='2026-10-31', recurringMonth='2026-10'))
        self.record(recurring)
        with self.assertRaises(L.LedgerError):
            self.record(recurring, id=ordinary['id'])

    def test_pause_delete_and_template_edits_leave_actual_entries_editable(self):
        recurring = self.schedule()
        entry = self.record(recurring)
        before = copy.deepcopy(entry)
        L.update_recurring(self.s, self.a, recurring['id'], dict(amount=40000, dayOfMonth=15, active=False))
        self.assertEqual(entry, before)
        self.assertIsNone(self.view()[0]['dueDay'])
        self.assertEqual(self.view()[0]['entryID'], entry['id'])
        with self.assertRaises(L.LedgerError):
            self.record(recurring, day='2026-11-15', recurringMonth='2026-11')
        L.update_entry(self.s, self.a, entry['id'], dict(amount=32000, day='2026-10-29', note='실제 거래 수정'))
        L.delete_recurring(self.s, self.a, recurring['id'])
        self.assertEqual(self.view(), [])
        self.assertEqual(L.snapshot(self.s, self.a, '2026-10')['stats']['total'], 32000)
        L.update_entry(self.s, self.a, entry['id'], {'note': '삭제 후 수정'})
        self.assertEqual(entry['note'], '삭제 후 수정')
        self.assertEqual(entry['recurringID'], recurring['id'])
        for operation in (lambda: self.record(recurring),
                          lambda: L.update_recurring(self.s, self.a, recurring['id'], {'active': True}),
                          lambda: L.link_recurring(self.s, self.a, recurring['id'], dict(month='2026-10', entryID=entry['id']))):
            with self.assertRaises(L.LedgerError):
                operation()

    def test_current_template_matching_and_private_actual_entry_id_not_leaked(self):
        recurring = self.schedule()
        L.update_recurring(self.s, self.a, recurring['id'], dict(payer=self.b))
        with self.assertRaises(L.LedgerError):
            self.record(recurring, payer=self.a)
        entry = self.record(recurring, payer=self.b)
        L.update_entry(self.s, self.a, entry['id'], dict(scope='personal', payer=self.a))
        self.assertIsNone(self.view(self.b)[0]['entryID'])
        self.assertNotIn(entry['id'], json.dumps(L.snapshot(self.s, self.b, '2026-10')))
        self.assertIsNone(self.view()[0]['entryID'])
        self.assertNotIn('recurringID', entry)
        self.assertNotIn('recurringMonth', entry)

    def test_link_existing_imported_expense_without_duplicate(self):
        recurring = self.schedule()
        imported = L.import_message(self.s, self.a, dict(text='카드 승인 30,000원 가맹점: 식사', source='sms', eventID='one'))
        entry = L.add_entry(self.s, self.a, dict(amount=30000, note='가져온 결제', scope='shared', day='2026-10-20', importID=imported['id']))
        linked = L.link_recurring(self.s, self.a, recurring['id'], dict(month='2026-10', entryID=entry['id']))
        self.assertEqual(linked['id'], entry['id'])
        self.assertEqual(L.link_recurring(self.s, self.a, recurring['id'], dict(month='2026-10', entryID=entry['id'])), linked)
        self.assertEqual(self.record(recurring)['id'], entry['id'])
        self.assertEqual(len(self.s['entries']), 1)
        self.assertEqual(self.view()[0]['entryID'], entry['id'])
        self.assertEqual(entry['importID'], imported['id'])

    def test_link_rejects_wrong_month_owner_kind_scope_payer_funding_amount_and_existing_link(self):
        self.s['mode'] = 'pool'
        recurring = self.schedule()
        good = dict(amount=30000, note='후보', scope='shared', day='2026-10-01')
        for overrides in (dict(amount=31000), dict(day='2026-09-30'), dict(scope='personal'),
                          dict(payer=self.b), dict(funding='fund'), dict(kind='refund'), dict(kind='deposit')):
            entry = L.add_entry(self.s, self.a, {**good, **overrides})
            with self.subTest(overrides=overrides), self.assertRaises(L.LedgerError):
                L.link_recurring(self.s, self.a, recurring['id'], dict(month='2026-10', entryID=entry['id']))
        foreign = L.add_entry(self.s, self.b, {**good, 'payer': self.a})
        with self.assertRaises(L.LedgerError):
            L.link_recurring(self.s, self.a, recurring['id'], dict(month='2026-10', entryID=foreign['id']))
        voided = L.add_entry(self.s, self.a, good)
        L.update_entry(self.s, self.a, voided['id'], {'voided': True})
        for entry_id in ('missing', voided['id']):
            with self.assertRaises(L.LedgerError):
                L.link_recurring(self.s, self.a, recurring['id'], dict(month='2026-10', entryID=entry_id))
        entry = L.add_entry(self.s, self.a, good)
        L.link_recurring(self.s, self.a, recurring['id'], dict(month='2026-10', entryID=entry['id']))
        other = self.schedule()
        with self.assertRaises(L.LedgerError):
            L.link_recurring(self.s, self.a, other['id'], dict(month='2026-10', entryID=entry['id']))
        alternative = L.add_entry(self.s, self.a, good)
        with self.assertRaises(L.LedgerError):
            L.link_recurring(self.s, self.a, recurring['id'], dict(month='2026-10', entryID=alternative['id']))

    def test_link_rejects_inactive_prestart_and_invalid_month(self):
        recurring = self.schedule(startDay='2026-11-01')
        entry = L.add_entry(self.s, self.a, dict(amount=30000, note='후보', scope='shared', day='2026-10-31'))
        for month in ('2026-10', 'bad', None):
            with self.assertRaises(L.LedgerError):
                L.link_recurring(self.s, self.a, recurring['id'], dict(month=month, entryID=entry['id']))
        L.update_recurring(self.s, self.a, recurring['id'], dict(startDay='2026-01-01', active=False))
        with self.assertRaises(L.LedgerError):
            L.link_recurring(self.s, self.a, recurring['id'], dict(month='2026-10', entryID=entry['id']))


    def test_whitespace_schedule_id_cannot_bypass_occurrence_uniqueness(self):
        recurring = self.schedule()
        first = self.record(recurring, recurringID=' ' + recurring['id'] + ' ')
        self.assertEqual(first['recurringID'], recurring['id'])
        self.assertEqual(self.record(recurring)['id'], first['id'])
        self.assertEqual(len(self.s['entries']), 1)
        L.update_entry(self.s, self.a, first['id'], {'voided': True})
        candidate = L.add_entry(self.s, self.a, dict(amount=30000, note='연결', scope='shared', day='2026-10-01'))
        linked = L.link_recurring(self.s, self.a, ' ' + recurring['id'] + ' ', dict(month='2026-10', entryID=candidate['id']))
        self.assertEqual(linked['recurringID'], recurring['id'])
        self.assertEqual(self.record(recurring)['id'], candidate['id'])

    def test_import_request_cannot_bypass_recurring_validation(self):
        recurring = self.schedule()
        imported = L.import_message(self.s, self.a, dict(text='카드 승인 30,000원', source='sms', eventID='guard-import'))
        ordinary = L.add_entry(self.s, self.a, dict(amount=30000, note='일반', scope='shared', day='2026-10-20', importID=imported['id']))
        with self.assertRaises(L.LedgerError):
            self.record(recurring, importID=imported['id'])
        with self.assertRaises(L.LedgerError):
            self.record(recurring, importID=imported['id'], recurringID='missing')
        self.assertNotIn('recurringID', ordinary)
        self.assertIsNone(self.view()[0]['entryID'])


    def test_auto_category_create_update_reuses_rules_without_learning_or_entries(self):
        personal_category = self.s['categories'][1]['id']
        self.s['rules'][self.a + ':' + L.normal('내 분류 메모')] = personal_category
        before_rules = copy.deepcopy(self.s['rules'])
        recurring = self.schedule(category='', note='내 분류 메모', scope='personal')
        self.assertEqual(recurring['category'], personal_category)
        updated = L.update_recurring(self.s, self.a, recurring['id'], dict(category='', note='저녁 식사'))
        self.assertEqual(updated['category'], L.category_for(self.s, self.a, '저녁 식사'))
        # Missing/null categories retain the ordinary entry path's automatic selection, too.
        payload = dict(note='저녁 식사', amount=1000, scope='shared', startDay='2026-01-01', dayOfMonth=1)
        self.assertEqual(L.add_recurring(self.s, self.a, payload)['category'], updated['category'])
        self.assertEqual(self.schedule(category=None, note='저녁 식사')['category'], updated['category'])
        self.schedule(category=personal_category, note='분류 학습 금지')
        self.assertEqual(self.s['entries'], [])
        self.assertEqual(self.s['rules'], before_rules)
        self.assertNotIn('내 분류 메모', json.dumps(L.snapshot(self.s, self.b, '2026-10'), ensure_ascii=False))

    def test_actual_day_review_before_after_due_and_start_boundary(self):
        for actual_day in ('2026-10-20', '2026-10-24', '2026-10-26', '2026-10-31'):
            with self.subTest(actual_day=actual_day):
                recurring = self.schedule(startDay='2026-10-20', dayOfMonth=25)
                entry = self.record(recurring, day=actual_day)
                self.assertEqual(entry['day'], actual_day)
                self.assertEqual(entry['recurringMonth'], '2026-10')
                view = next(r for r in self.view() if r['id'] == recurring['id'])
                self.assertEqual((view['dueDay'], view['entryID']), ('2026-10-25', entry['id']))
        recurring = self.schedule(startDay='2026-10-20', dayOfMonth=25)
        for invalid_day in ('2026-09-30', '2026-11-01', '2026-10-19', '2026-10-32', None):
            before = copy.deepcopy(self.s)
            with self.subTest(invalid_day=invalid_day), self.assertRaises(L.LedgerError):
                self.record(recurring, day=invalid_day)
            self.assertEqual(self.s, before)
        no_occurrence = self.schedule(startDay='2026-10-20', dayOfMonth=10)
        with self.assertRaises(L.LedgerError):
            self.record(no_occurrence, day='2026-10-25')

    def test_client_schedule_id_retry_and_conflict_ownership(self):
        recurring = self.schedule(id='create-request-1')
        self.assertEqual(recurring['id'], 'create-request-1')
        before = copy.deepcopy(self.s)
        self.assertEqual(self.schedule(id='create-request-1'), recurring)
        self.assertEqual(self.s, before)
        for change in (dict(amount=30001), dict(dayOfMonth=30), dict(note='다른 일정'),
                       dict(scope='personal'), dict(active=False)):
            with self.subTest(change=change), self.assertRaises(L.LedgerError):
                self.schedule(id='create-request-1', **change)
            self.assertEqual(self.s, before)
        payload = {k: v for k, v in recurring.items() if k != 'owner'}
        with self.assertRaises(L.LedgerError):
            L.add_recurring(self.s, self.b, payload)
        self.assertEqual(self.s, before)
        L.delete_recurring(self.s, self.a, recurring['id'])
        with self.assertRaises(L.LedgerError):
            self.schedule(id='create-request-1')
        self.assertEqual(self.view(), [])
        self.assertNotEqual(self.schedule()['id'], self.schedule()['id'])

    def test_client_schedule_id_validation_preserves_state(self):
        for invalid_id in ('', '  ', None, True, 0, [], {}, 'x' * 81):
            before = copy.deepcopy(self.s)
            with self.subTest(invalid_id=invalid_id), self.assertRaises(L.LedgerError):
                self.schedule(id=invalid_id)
            self.assertEqual(self.s, before)


    def test_legacy_nonexpense_tags_do_not_complete_or_replay_occurrence(self):
        self.s['mode'] = 'pool'
        for kind in ('refund', 'deposit'):
            with self.subTest(kind=kind):
                recurring = self.schedule()
                legacy = self.record(recurring, amount=30000)
                # Reproduce a state already saved by the old update path; reads must not rewrite it.
                legacy['kind'] = kind
                if kind == 'deposit':
                    legacy['funding'] = 'fund'
                before = copy.deepcopy(self.s)
                self.assertIsNone(L.recurring_entry(self.s, recurring['id'], '2026-10'))
                self.assertIsNone(next(r for r in self.view() if r['id'] == recurring['id'])['entryID'])
                self.assertEqual(self.s, before)
                with self.assertRaises(L.LedgerError):
                    self.record(recurring, id=legacy['id'])
                replacement = self.record(recurring, amount=30000)
                self.assertEqual(replacement['kind'], 'expense')
                self.assertNotEqual(replacement['id'], legacy['id'])

    def test_changing_to_refund_or_deposit_unlinks_and_allows_new_expense(self):
        self.s['mode'] = 'pool'
        for kind in ('refund', 'deposit'):
            with self.subTest(kind=kind):
                recurring = self.schedule()
                entry = self.record(recurring, amount=30000)
                original_id = entry['id']
                result = L.update_entry(self.s, self.a, original_id, dict(kind=kind))
                self.assertEqual((result['id'], result['kind']), (original_id, kind))
                self.assertNotIn('recurringID', result)
                self.assertNotIn('recurringMonth', result)
                self.assertIsNone(next(r for r in self.view() if r['id'] == recurring['id'])['entryID'])
                with self.assertRaises(L.LedgerError):
                    self.record(recurring, id=original_id)
                replacement = self.record(recurring, amount=30000)
                self.assertEqual(replacement['kind'], 'expense')
                self.assertEqual(self.record(recurring)['id'], replacement['id'])
                self.assertEqual(entry['kind'], kind)

    def test_cross_month_or_scope_expense_edit_unlinks_without_reassigning(self):
        for changes in (dict(day='2026-11-01'), dict(scope='personal')):
            with self.subTest(changes=changes):
                recurring = self.schedule()
                entry = self.record(recurring)
                L.update_entry(self.s, self.a, entry['id'], changes)
                self.assertEqual(entry['kind'], 'expense')
                self.assertNotIn('recurringID', entry)
                self.assertNotIn('recurringMonth', entry)
                self.assertIsNone(next(r for r in self.view() if r['id'] == recurring['id'])['entryID'])
                if 'scope' in changes:
                    self.assertNotIn(entry['id'], json.dumps(L.snapshot(self.s, self.b, '2026-10')))
                else:
                    self.assertIn(entry['id'], [e['id'] for e in L.snapshot(self.s, self.a, '2026-11')['entries']])
                    self.assertTrue(all(r['entryID'] is None for r in self.view(month='2026-11')))
                replacement = self.record(recurring)
                self.assertNotEqual(replacement['id'], entry['id'])

    def test_same_month_expense_review_keeps_link_and_failed_edit_is_atomic(self):
        recurring = self.schedule()
        entry = self.record(recurring)
        before = copy.deepcopy(self.s)
        with self.assertRaises(L.LedgerError):
            L.update_entry(self.s, self.a, entry['id'], dict(kind='refund', amount=-1))
        self.assertEqual(self.s, before)
        L.update_entry(self.s, self.a, entry['id'], dict(day='2026-10-02', amount=35000, note='실제 결제 수정', category=self.s['categories'][1]['id']))
        self.assertEqual((entry['recurringID'], entry['recurringMonth']), (recurring['id'], '2026-10'))
        self.assertEqual(self.view()[0]['entryID'], entry['id'])
        self.assertEqual(self.record(recurring)['id'], entry['id'])
        self.assertEqual(len(self.s['entries']), 1)


if __name__ == '__main__':
    unittest.main()
