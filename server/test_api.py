from concurrent.futures import ThreadPoolExecutor
import json
import sqlite3
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch
import urllib.request
import urllib.error
import app


class APITests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.db = app.Store(Path(self.tmp.name) / 'ledger.sqlite')
        self.server = app.make_server('127.0.0.1', 0, self.db)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.url = f'http://127.0.0.1:{self.server.server_port}'

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.tmp.cleanup()

    def test_notification_preview_uses_parser_without_writing(self):
        sample = '테스트카드 1234 승인\n8,400원\n가맹점: CU 테스트점\n10/21 16:35'
        self.assertEqual(self.call('/imports/preview', {'text': sample})[0], 401)
        _, owner = self.call('/households', {'name': '미리보기 검증', 'memberName': '검증', 'mode': 'separate'})
        token = owner['token']
        _, before = self.call('/state?month=2026-10', token=token)
        code, parsed = self.call('/imports/preview', {'text': sample}, token)
        self.assertEqual(code, 200)
        self.assertEqual(parsed['amount'], 8400)
        self.assertEqual(parsed['merchant'], 'CU 테스트점')
        self.assertEqual(parsed['card'], '1234')
        self.assertEqual(parsed['kind'], 'expense')
        self.assertFalse(parsed['requiresReview'])
        self.assertEqual(self.call('/imports/preview', {'text': '승인 1000원 2000원'}, token)[1]['amount'], None)
        self.assertEqual(self.call('/imports/preview', {'text': []}, token)[0], 400)
        _, after = self.call('/state?month=2026-10', token=token)
        self.assertEqual(before, after, '미리보기는 거래/확인함/전달기록/예산/통계를 쓰면 안 됨')

    def test_review_only_preview_and_import_contract(self):
        token = self.create()
        raw = ('발신 알림: 금액 확인 필요\n카드 1234 승인 18,400원\n'
               '가맹점: 합성상점\n2026/10/21 12:00\n승인번호 TEST1234\n출금 예정 65,720원')
        payload = dict(text=raw, source='paste', reviewOnly=True)
        for path in ('/imports/preview', '/imports'):
            self.assertEqual(self.call(path, payload)[0], 401)
        before = self.call('/state?month=2026-10', token=token)[1]
        for source in ({}, {'source': 'paste'}):
            code, parsed = self.call('/imports/preview', dict(text=raw, reviewOnly=True, **source), token)
            self.assertEqual(code, 200)
            self.assertEqual((parsed['amount'], parsed['kind'], parsed['merchant'], parsed['time']),
                             (None, 'unknown', '', None))
            self.assertEqual((parsed['card'], parsed['reference']), ('', ''))
            self.assertTrue(parsed['requiresReview'])
            self.assertIn('직접 확인', parsed['reason'])
        self.assertEqual(self.call('/state?month=2026-10', token=token)[1], before)
        payload['eventID'] = 'review-capture'
        code, item = self.call('/imports', payload, token)
        self.assertEqual(code, 200)
        self.assertEqual(item['status'], 'pending')
        self.assertEqual(item['raw'], raw)
        for key in ('amount', 'kind', 'merchant', 'time', 'card', 'reference', 'requiresReview', 'reason'):
            self.assertEqual(item[key], parsed[key], key)
        self.assertEqual(self.call('/imports', payload, token)[1]['id'], item['id'])
        after = self.call('/state?month=2026-10', token=token)[1]
        self.assertEqual([i['id'] for i in after['inbox']], [item['id']])
        for key in ('entries', 'stats', 'settlement', 'recurringPayments'):
            self.assertEqual(after[key], before[key], key)

    def test_review_only_api_rejects_invalid_types_and_sources_without_writing(self):
        token = self.create()
        before = self.call('/state?month=2026-10', token=token)[1]
        for path in ('/imports/preview', '/imports'):
            invalid = [dict(reviewOnly=value, source='paste') for value in (None, 0, 1, 'true', 'false', [], {})]
            invalid += [dict(reviewOnly=True, source=source) for source in ('sms', 'app', 'shortcut', None)]
            if path == '/imports':
                invalid.append(dict(reviewOnly=True))
            for options in invalid:
                with self.subTest(path=path, options=options):
                    self.assertEqual(self.call(path, dict(text='카드 승인 1,000원', **options), token)[0], 400)
            for raw in ('', [], None):
                self.assertEqual(self.call(path, dict(text=raw, source='paste', reviewOnly=True), token)[0], 400)
        self.assertEqual(self.call('/state?month=2026-10', token=token)[1], before)

    def test_review_only_false_preserves_existing_preview_and_import_behavior(self):
        token = self.create()
        for raw in ('카드 승인 1,000원\n가맹점: 합성상점', '출금 예정 1,000원'):
            normal = self.call('/imports/preview', dict(text=raw), token)[1]
            self.assertEqual(self.call('/imports/preview', dict(text=raw, reviewOnly=False), token)[1], normal)
            code, item = self.call('/imports', dict(text=raw, source='sms', reviewOnly=False), token)
            self.assertEqual(code, 200)
            self.assertEqual(item['status'], 'ignored' if '예정' in raw else 'pending')
        self.assertEqual(self.call('/state?month=2026-10', token=token)[1]['entries'], [])

    def test_review_only_uses_same_routes_with_firestore_callback(self):
        from test_import_delivery import LocalFirestoreDouble
        backend = LocalFirestoreDouble()
        backend.first_reads = threading.Barrier(1)
        server = app.make_server('127.0.0.1', 0, backend.store())
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        original_url = self.url
        self.url = f'http://127.0.0.1:{server.server_port}'
        try:
            payload = dict(text='카드 승인 1,000원\n가맹점: 합성상점\n출금 예정 5,000원',
                           source='paste', reviewOnly=True, eventID='firestore-review')
            before = backend.data
            code, preview = self.call('/imports/preview', payload, backend.token)
            self.assertEqual(code, 200)
            self.assertEqual((preview['amount'], preview['kind'], preview['merchant'], preview['time']),
                             (None, 'unknown', '', None))
            self.assertEqual(backend.data, before)
            code, item = self.call('/imports', payload, backend.token)
            self.assertEqual(code, 200)
            self.assertEqual((item['status'], item['raw']), ('pending', payload['text']))
            self.assertEqual(self.call('/imports', payload, backend.token)[1]['id'], item['id'])
            view = self.call('/state?month=2026-10', token=backend.token)[1]
            self.assertEqual([i['id'] for i in view['inbox']], [item['id']])
            self.assertEqual(view['entries'], [])
        finally:
            self.url = original_url
            server.shutdown()
            server.server_close()
            thread.join()

    def test_notice_preview_and_import_do_not_create_transaction_candidates(self):
        token = self.create()
        for index, raw in enumerate(('오늘 출금예정 38,000원', '청구 안내 38,000원',
                                     '자동이체\n오늘 테스트보험 외 1곳에서 119,970원\n출금할 예정이에요. 토스뱅크 통장 (0000)에서\n출금돼요.',
                                     '쿠폰 발송 안내 38,000원\n환불이 불가합니다.')):
            with self.subTest(raw=raw):
                before = self.call('/state?month=2026-10', token=token)[1]
                code, parsed = self.call('/imports/preview', dict(text=raw), token)
                self.assertEqual(code, 200)
                self.assertEqual(parsed['kind'], 'unknown')
                self.assertIsNone(parsed['amount'])
                self.assertTrue(parsed['reason'])
                self.assertEqual(self.call('/state?month=2026-10', token=token)[1], before)
                code, imported = self.call('/imports', dict(text=raw, eventID=f'notice-{index}'), token)
                self.assertEqual(code, 200)
                self.assertEqual(imported['status'], 'ignored')
                after = self.call('/state?month=2026-10', token=token)[1]
                for key in ('inbox', 'entries', 'stats', 'settlement', 'recurringPayments'):
                    self.assertEqual(after[key], before[key], key)

    def test_income_preview_import_recording_and_partner_privacy(self):
        a = self.create()
        _, invitation = self.call('/invite', {}, a)
        code, joined = self.call('/join', dict(invite=invitation['invite'], memberName='상대'))
        self.assertEqual(code, 200)
        b = joined['token']
        raw = '우리은행 입금 123,456원\n테스트회사\n잔액 200,000원\n10/21 12:00'
        _, before = self.call('/state?month=2026-10', token=a)
        code, preview = self.call('/imports/preview', dict(text=raw), a)
        self.assertEqual(code, 200)
        self.assertEqual((preview['kind'], preview['amount']), ('income', 123456))
        self.assertTrue(preview['requiresReview'])
        self.assertEqual(self.call('/state?month=2026-10', token=a)[1], before)
        code, imported = self.call('/imports', dict(text=raw, source='sms', eventID='salary'), a)
        self.assertEqual(code, 200)
        self.assertEqual(imported['status'], 'pending')
        self.assertEqual(self.call('/state?month=2026-10', token=a)[1]['entries'], [])
        code, saved = self.call('/entries', dict(kind='income', scope='personal', funding='personal',
            amount=123456, note='비밀 급여', day='2026-10-21', importID=imported['id']), a)
        self.assertEqual(code, 200)
        self.assertEqual(saved['kind'], 'income')
        view = self.call('/state?month=2026-10', token=a)[1]
        self.assertEqual((view['stats']['incomeTotal'], view['stats']['personalIncomeTotal'], view['stats']['total']), (0, 123456, 0))
        partner = self.call('/state?month=2026-10', token=b)[1]
        self.assertEqual((partner['entries'], partner['inbox']), ([], []))
        self.assertEqual(partner['stats']['personalIncomeTotal'], 0)
        self.assertNotIn('123456', json.dumps(partner))
        self.assertEqual(self.call('/entries/' + saved['id'], dict(scope='shared'), b, 'PATCH')[0], 400)
        self.assertEqual(self.call('/entries/' + saved['id'], dict(scope='shared', amount=50000), a, 'PATCH')[0], 200)
        partner = self.call('/state?month=2026-10', token=b)[1]
        self.assertEqual(partner['stats']['incomeTotal'], 50000)
        self.assertEqual((partner['stats']['total'], partner['settlement']['count']), (0, 1))
        self.assertEqual(self.call('/entries/' + saved['id'], dict(funding='fund'), a, 'PATCH')[0], 400)

    def test_shared_income_invalidates_stale_settlement_preview(self):
        a = self.create()
        _, invitation = self.call('/invite', {}, a)
        self.assertEqual(self.call('/join', dict(invite=invitation['invite'], memberName='상대'))[0], 200)
        code, expense = self.call('/entries', dict(amount=10000, note='식사', day='2026-10-21', scope='shared'), a)
        self.assertEqual(code, 200)
        before = self.call('/state?month=2026-10', token=a)[1]
        self.assertEqual(self.call('/entries', dict(kind='income', amount=20000, note='공용 수입', day='2026-10-21', scope='shared'), a)[0], 200)
        after = self.call('/state?month=2026-10', token=a)[1]
        self.assertNotEqual(after['settlement']['revision'], before['settlement']['revision'])
        code, _ = self.call('/settle', dict(month='2026-10', revision=before['settlement']['revision']), a)
        self.assertEqual(code, 400)
        current = self.call('/state?month=2026-10', token=a)[1]
        self.assertTrue(all(e['settlement'] is None for e in current['entries']))
        code, record = self.call('/settle', dict(month='2026-10', revision=current['settlement']['revision']), a)
        self.assertEqual(code, 200)
        self.assertEqual((record['amount'], record['count']), (5000, 2))
        self.assertEqual(record['fromID'], current['me'])

    def call(self, path, payload=None, token=None, method=None):
        data = json.dumps(payload).encode() if payload is not None else None
        headers = {'Content-Type': 'application/json'}
        if token:
            headers['Authorization'] = 'Bearer ' + token
        request = urllib.request.Request(self.url + path, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(request) as response:
                return response.status, json.load(response)
        except urllib.error.HTTPError as error:
            return error.code, json.load(error)

    def create(self):
        code, result = self.call('/households', dict(name='우리집', memberName='순환', mode='separate'))
        self.assertEqual(code, 200)
        return result['token']

    def test_qa_private_import_retry_is_rejected_by_real_http_path(self):
        a = self.create()
        _, invitation = self.call('/invite', {}, a)
        code, joined = self.call('/join', dict(invite=invitation['invite'], memberName='B'))
        self.assertEqual(code, 200)
        b = joined['token']
        raw = '카드 1234 승인 10,000원\n가맹점: 테스트상점\n승인번호 998877\n2026/10/20 13:00'
        first = self.call('/imports', dict(text=raw, eventID='A'), a)[1]
        second = self.call('/imports', dict(text=raw, eventID='B'), b)[1]
        payload = dict(amount=10000, note='공용', day='2026-10-20', scope='shared')
        code, entry = self.call('/entries', dict(payload, importID=first['id']), a)
        self.assertEqual(code, 200)
        self.assertEqual(self.call('/entries', dict(payload, importID=second['id']), b)[1]['id'], entry['id'])
        self.assertEqual(self.call('/entries/' + entry['id'], dict(scope='personal', note='새 개인 메모', amount=12345), a, 'PATCH')[0], 200)
        self.assertEqual(self.call('/state?month=2026-10', token=b)[1]['entries'], [])
        code, response = self.call('/entries', dict(payload, importID=second['id']), b)
        self.assertEqual(code, 400)
        self.assertEqual(set(response), {'error'})
        self.assertNotIn('새 개인 메모', json.dumps(response, ensure_ascii=False))
        self.assertNotIn('12345', json.dumps(response))

    def test_qa_deleted_retry_is_http_error_for_id_and_import(self):
        a = self.create()
        imported = self.call('/imports', dict(text='승인 10000원\n가맹점: 테스트', eventID='delete'), a)[1]
        payload = dict(id='deleted-retry', amount=10000, note='테스트', day='2026-10-20', scope='personal')
        self.assertEqual(self.call('/entries', dict(payload, importID=imported['id']), a)[0], 200)
        self.assertEqual(self.call('/entries/deleted-retry', {}, a, 'DELETE')[0], 200)
        for body in (payload, dict(payload, importID=imported['id'])):
            with self.subTest(body=body):
                code, response = self.call('/entries', body, a)
                self.assertEqual(code, 400)
                self.assertEqual(set(response), {'error'})
        self.assertEqual(self.call('/state?month=2026-10', token=a)[1]['entries'], [])

    def test_qa_refund_help_preview_remains_expense(self):
        a = self.create()
        before = self.call('/state?month=2026-10', token=a)[1]
        for suffix in ('취소 문의 1588-0000', '환불은 구매처에 문의하세요'):
            code, parsed = self.call('/imports/preview', {'text': '카드 승인 10000원\n가맹점: 테스트\n' + suffix}, a)
            self.assertEqual(code, 200)
            self.assertEqual((parsed['kind'], parsed['amount'], parsed['requiresReview']), ('expense', 10000, False))
        self.assertEqual(self.call('/state?month=2026-10', token=a)[1], before)

    def test_qa_medical_category_from_snapshot_is_accepted_and_survives_reopen(self):
        a = self.create()
        view = self.call('/state?month=2026-10', token=a)[1]
        medical = next((c for c in view['categories'] if c['name'] == '의료'), None)
        self.assertIsNotNone(medical)
        code, entry = self.call('/entries', dict(amount=1000, note='코 약', day='2026-10-20',
                                                scope='personal', category=medical['id']), a)
        self.assertEqual(code, 200)
        reopened = app.Store(Path(self.tmp.name) / 'ledger.sqlite')
        restored = reopened.run(a, lambda state, actor: app.L.snapshot(state, actor, '2026-10'))
        self.assertEqual(restored['entries'][0]['category'], medical['id'])
        self.assertEqual(next(c['name'] for c in restored['categories'] if c['id'] == entry['category']), '의료')

    def test_shared_flow_privacy_and_invite_reuse(self):
        a = self.create()
        _, invitation = self.call('/invite', {}, a)
        code, b = self.call('/join', dict(invite=invitation['invite'], memberName='주희'))
        self.assertEqual(code, 200)
        self.assertNotEqual(b['token'], a)
        self.assertEqual(self.call('/join', dict(invite=invitation['invite'], memberName='제3자'))[0], 400)
        p = dict(id='expense-1', amount=300000, note='공용 식사', scope='shared', day='2026-10-20')
        self.assertEqual(self.call('/entries', p, a)[0], 200)
        self.call('/entries', dict(amount=90000, note='비공개', scope='personal', day='2026-10-20'), a)
        self.call('/entries', {**p, 'id': 'expense-2', 'amount': 200000}, b['token'])
        _, view = self.call('/state?month=2026-10', token=b['token'])
        self.assertEqual(len(view['entries']), 2)
        self.assertEqual(view['settlement']['amount'], 50000)
        self.assertNotIn('비공개', json.dumps(view, ensure_ascii=False))
        self.call('/entries', p, a)
        self.assertEqual(len(self.call('/state?month=2026-10', token=a)[1]['entries']), 3)
        revision = self.call('/state?month=2026-10', token=a)[1]['settlement']['revision']
        self.assertEqual(self.call('/settle', {'month': '2026-10', 'revision': revision}, a)[0], 200)
        self.assertEqual(self.call('/state?month=2026-10', token=a)[1]['settlement']['amount'], 0)

    def settlement_fixture(self):
        clock = patch('ledger.now', return_value='2026-10-26T16:00:00+09:00')
        clock.start()
        self.addCleanup(clock.stop)
        a = self.create()
        invitation = self.call('/invite', {}, a)[1]['invite']
        b = self.call('/join', dict(invite=invitation, memberName='주희'))[1]['token']
        self.assertEqual(self.call('/entries', dict(amount=20000, note='공용', scope='shared', day='2026-09-20'), a)[0], 200)
        incoming = self.call('/imports', dict(text='은행 입금 완료 10000원\n보낸 사람: 주희', eventID='incoming'), a)[1]
        outgoing = self.call('/imports', dict(text='은행 송금 완료 10000원\n받는 사람: 순환', eventID='outgoing'), b)[1]
        view = self.call('/state?month=2026-10', token=b)[1]
        self.assertIn('pendingSettlements', view)
        due = view['pendingSettlements'][0]
        payload = dict(month=due['month'], revision=due['revision'], memberID=due['memberID'],
                       importID=outgoing['id'], requestID=app.L.uid())
        return a, b, incoming, outgoing, payload

    def test_settlement_import_atomic_replay_and_payload_security_over_http(self):
        a, b, incoming, outgoing, payload = self.settlement_fixture()
        code, record = self.call('/settle', payload, b)
        self.assertEqual(code, 200)
        for _ in range(2):
            self.assertEqual(self.call('/settle', payload, b), (200, record))
        for changed in (dict(payload, importID=incoming['id']), dict(payload, requestID=app.L.uid()),
                        dict(payload, month='2026-10'), dict(payload, revision='different')):
            self.assertEqual(self.call('/settle', changed, b)[0], 400)
        self.assertEqual(self.call('/settle', payload, a)[0], 400)
        reopened = app.Store(Path(self.tmp.name) / 'ledger.sqlite')
        state = reopened.run(b, lambda s, actor: s)
        self.assertEqual((len(state['settlements']), len(state['entries'])), (1, 1))
        item = next(i for i in state['imports'] if i['id'] == outgoing['id'])
        self.assertEqual((item['status'], item['settlementID']), ('settled', record['id']))
        visible = self.call('/state?month=2026-09', token=a)[1]
        self.assertNotIn(outgoing['raw'], json.dumps(visible, ensure_ascii=False))
        self.assertNotIn(outgoing['id'], json.dumps(visible))

    def test_settlement_two_actor_concurrency_closes_once_and_leaves_loser_import_pending(self):
        a, b, incoming, outgoing, payload = self.settlement_fixture()
        other = dict(payload, importID=incoming['id'], requestID=app.L.uid())
        with ThreadPoolExecutor(max_workers=2) as executor:
            responses = list(executor.map(lambda args: self.call('/settle', args[1], args[0]), [(a, other), (b, payload)]))
        self.assertEqual(sorted(code for code, _ in responses), [200, 400])
        state = self.db.run(a, lambda s, actor: s)
        self.assertEqual(len(state['settlements']), 1)
        self.assertEqual(sorted(i['status'] for i in state['imports']), ['pending', 'settled'])

    def test_settlement_rejected_candidate_does_not_write_and_manual_still_works(self):
        a, b, incoming, outgoing, payload = self.settlement_fixture()
        before = self.db.run(a, lambda s, actor: s)
        self.assertEqual(self.call('/settle', dict(payload, importID=incoming['id']), b)[0], 400)
        self.assertEqual(self.call('/settle', dict(payload, requestID='invalid'), b)[0], 400)
        self.assertEqual(self.db.run(a, lambda s, actor: s), before)
        self.assertEqual(self.call('/settle', dict(month=payload['month'], revision=payload['revision']), b)[0], 200)
        state = self.db.run(a, lambda s, actor: s)
        self.assertTrue(all(i['status'] == 'pending' for i in state['imports']))

    def test_settlement_bank_receipt_http_matches_full_current_month_and_rejects_other_person(self):
        a, b, _, _, _ = self.settlement_fixture()
        for day, amount in (('2026-10-26', 20000), ('2026-10-27', 80000), ('2026-11-01', 20000)):
            self.assertEqual(self.call('/entries', dict(amount=amount, note='공용', scope='shared', day=day), a)[0], 200)
        view = self.call('/state?month=2026-10', token=b)[1]
        due = next(d for d in view['pendingSettlements'] if d['month'] == '2026-10')
        self.assertEqual((due['amount'], due['count'], due['revision']),
                         (50000, 2, view['settlement']['revision']))
        self.assertNotIn('2026-11', [d['month'] for d in view['pendingSettlements']])
        for raw in ('은행 출금 50,000원\n받는 분: 타인', '은행 출금예정 50,000원',
                    '은행 출금가능금액 50,000원', '은행 출금 50,000원 잔액안내'):
            item = self.call('/imports', dict(text=raw, eventID=app.L.uid()), b)[1]
            self.assertEqual(self.call('/settle', dict(month=due['month'], revision=due['revision'],
                              importID=item['id'], requestID=app.L.uid()), b)[0], 400)
        imported = dict(text='은행 출금 50,000원\n받는 분: 순환', eventID=app.L.uid())
        item = self.call('/imports', imported, b)[1]
        view = self.call('/state?month=2026-10', token=b)[1]
        self.assertIn(dict(importID=item['id'], due=due), view['settlementCandidates'])
        payload = dict(month=due['month'], revision=due['revision'], importID=item['id'], requestID=app.L.uid())
        code, record = self.call('/settle', payload, b)
        self.assertEqual((code, record['amount'], record['count']), (200, 50000, 2))
        self.assertEqual(self.call('/settle', payload, b), (200, record))
        duplicate = self.call('/imports', imported, b)[1]
        self.assertEqual((duplicate['id'], duplicate['status']), (item['id'], 'settled'))
        state = self.db.run(a, lambda s, actor: s)
        self.assertEqual((len(state['settlements']), len(state['entries'])), (1, 4))
        self.assertEqual([e['day'] for e in state['entries'] if e.get('settlement')], ['2026-10-26', '2026-10-27'])

    def test_auth_and_cross_household(self):
        a, other = self.create(), self.create()
        self.assertEqual(self.call('/state?month=2026-10')[0], 401)
        self.assertEqual(self.call('/state?month=2026-10', token='invalid')[0], 401)
        code, entry = self.call('/entries', dict(amount=10000, note='식사', day='2026-10-20', scope='shared'), a)
        self.assertEqual(code, 200)
        self.assertEqual(self.call('/entries/' + entry['id'], {'note': '수정'}, other, 'PATCH')[0], 400)
        self.assertEqual(self.call('/state?month=2026-10', token=other)[1]['entries'], [])

    def test_month_navigation_preserves_connection_and_hides_private_months(self):
        with patch('ledger.now', return_value='2026-10-21T12:00:00+09:00'):
            a, other = self.create(), self.create()
            _, invitation = self.call('/invite', {}, a)
            _, joined = self.call('/join', dict(invite=invitation['invite'], memberName='상대'))
            b = joined['token']
            for day, scope in [('2026-02-01', 'shared'), ('2027-03-01', 'personal')]:
                self.assertEqual(self.call('/entries', dict(amount=1000, note='월 이동 검사',
                    day=day, scope=scope), a)[0], 200)
            self.recurring(a, scope='personal', startDay='2028-04-01')
            for token, expected in [(a, dict(previous='2026-02', next='2027-03')),
                                    (b, dict(previous='2026-02', next=None)),
                                    (other, dict(previous=None, next=None))]:
                code, view = self.call('/state?month=2026-10', token=token)
                self.assertEqual(code, 200)
                self.assertEqual(view.get('monthNavigation'), expected)
            identity = self.call('/state?month=2026-10', token=a)[1]
            for month in ['2026-02', '2026-06', '2026-10', '2027-03', '2028-04']:
                code, view = self.call('/state?month=' + month, token=a)
                self.assertEqual(code, 200)
                self.assertEqual((view['me'], view['household']['id'], view['members']),
                                 (identity['me'], identity['household']['id'], identity['members']))
            self.assertEqual(self.call('/state?month=2027-05', token=a)[1]['monthNavigation']['next'], '2028-04')
            self.assertIsNone(self.call('/state?month=2027-05', token=b)[1]['monthNavigation']['next'])

    def test_restart_persists_and_tokens_hashed(self):
        token = self.create()
        self.assertEqual(self.call('/entries', dict(amount=18000, note='시장 반찬', day='2026-10-20', scope='shared'), token)[0], 200)
        reopened = app.Store(self.db.path)
        view = reopened.run(token, lambda s, a: app.L.snapshot(s, a, '2026-10'))
        self.assertEqual(view['stats']['total'], 18000)
        self.assertNotIn(token.encode(), self.db.path.read_bytes())

    def test_unknown_category_and_malformed_request(self):
        token = self.create()
        self.assertEqual(self.call('/entries', dict(amount=10000, note='식사', day='2026-10-20', scope='shared', category='missing'), token)[0], 400)
        self.assertEqual(self.call('/entries', [], token)[0], 400)
        self.assertEqual(self.call('/state?month=bad', token=token)[0], 400)

    def test_private_server_requires_setup_code_only_for_new_household(self):
        self.server.setup_code = 'test-private-code'
        payload = dict(name='우리집', memberName='순환', mode='separate')
        self.assertEqual(self.call('/households', payload)[0], 403)
        self.assertEqual(self.call('/households', {**payload, 'setupCode': 'wrong'})[0], 403)
        self.assertEqual(self.call('/households', {**payload, 'setupCode': []})[0], 403)
        code, owner = self.call('/households', {**payload, 'setupCode': self.server.setup_code})
        self.assertEqual(code, 200)
        invitation = self.call('/invite', {}, owner['token'])[1]['invite']
        self.assertEqual(self.call('/join', dict(invite=invitation, memberName='주희'))[0], 200)
        self.assertEqual(self.call('/health')[0], 200)

    def test_review_signup_expires_and_creates_isolated_households(self):
        self.server.setup_code = 'owner-code-at-least-16'
        self.server.review_setup_code = 'review-code-at-least-16'
        self.server.review_setup_expires = 2000
        payload = dict(name='심사 가계부', memberName='심사자', mode='separate')
        with patch('app.time.time', return_value=1000):
            _, owner = self.call('/households', {**payload, 'setupCode': self.server.setup_code})
            code, review = self.call('/households', {**payload, 'setupCode': self.server.review_setup_code})
            self.assertEqual(code, 200)
            self.assertNotEqual(owner['householdID'], review['householdID'])
            self.assertEqual(self.call('/entries', dict(amount=3000, note='비공개 검증', day='2026-10-23', scope='shared'), owner['token'])[0], 200)
            _, state = self.call('/state?month=2026-10', token=review['token'])
            self.assertEqual(state['stats']['total'], 0)
            self.assertEqual(self.call('/state', token=self.server.review_setup_code)[0], 401)
            for invalid in ('', 'wrong', [], '한글잘못된코드'):
                self.assertEqual(self.call('/households', {**payload, 'setupCode': invalid})[0], 403)
        with patch('app.time.time', return_value=2000):
            self.assertEqual(self.call('/households', {**payload, 'setupCode': self.server.review_setup_code})[0], 403)
            self.assertEqual(self.call('/households', {**payload, 'setupCode': self.server.setup_code})[0], 200)
            self.assertEqual(self.call('/state', token=review['token'])[0], 200)
        self.server.review_setup_code = ''
        with patch('app.time.time', return_value=1000):
            self.assertEqual(self.call('/households', {**payload, 'setupCode': 'review-code-at-least-16'})[0], 403)

    def test_metadata_and_scope_validation_through_authenticated_http(self):
        a = self.create()
        invitation = self.call('/invite', {}, a)[1]['invite']
        b = self.call('/join', dict(invite=invitation, memberName='검증 상대'))[1]['token']
        defaults = self.call('/state?month=2026-10', token=b)[1]['classificationRules']
        code, _ = self.call('/entries', dict(amount=1000, note='범위 미선택', day='2026-10-21'), a)
        self.assertEqual(code, 400)
        category = next(c['id'] for c in self.call('/state?month=2026-10', token=a)[1]['categories'] if c['name'] == '카페')
        self.assertEqual(self.call('/entries', dict(amount=1000, note='비공개커피', scope='personal', category=category, day='2026-10-21'), a)[0], 200)
        sample = '카드 1234 승인 1000원\n가맹점: 비공개알림상호\n승인번호 123456\n10/21 13:00'
        self.assertEqual(self.call('/imports', dict(text=sample, source='sms', eventID='test-receipt', viaShortcut=True), a)[0], 200)
        own = self.call('/state?month=2026-10', token=a)[1]
        self.assertIn('비공개커피', own['classificationRules'])
        self.assertIsNotNone(own['importStatus']['lastShortcutAt'])
        other = self.call('/state?month=2026-10', token=b)[1]
        self.assertEqual(other['classificationRules'], defaults)
        self.assertEqual(other['importStatus'], {'lastReceivedAt': None, 'lastShortcutAt': None})
        self.assertEqual(other['inbox'], [])
        self.assertNotIn('비공개', json.dumps(other, ensure_ascii=False))

    def test_stale_settlement_confirmation_does_not_lock_entries(self):
        a = self.create()
        invitation = self.call('/invite', {}, a)[1]['invite']
        b = self.call('/join', dict(invite=invitation, memberName='주희'))[1]['token']
        self.assertEqual(self.call('/entries', dict(amount=30000, note='식사', day='2026-10-20', scope='shared'), a)[0], 200)
        preview = self.call('/state?month=2026-10', token=a)[1]['settlement']
        self.assertEqual(preview['amount'], 15000)
        self.assertEqual(self.call('/entries', dict(amount=10000, note='교통', day='2026-10-20', scope='shared'), b)[0], 200)
        self.assertEqual(self.call('/settle', dict(month='2026-10', revision=preview['revision']), a)[0], 400)
        view = self.call('/state?month=2026-10', token=a)[1]
        self.assertEqual(view['settlement']['amount'], 10000)
        self.assertTrue(all(e['settlement'] is None for e in view['entries']))
        self.assertEqual(self.call('/settle', dict(month='2026-10'), a)[0], 400)


    def recurring(self, token, **overrides):
        view = self.call('/state?month=2026-10', token=token)[1]
        payload = dict(note='정기 결제', amount=30000, scope='shared', category=view['categories'][0]['id'],
                       payer=view['me'], funding='personal', startDay='2026-01-01', dayOfMonth=31)
        payload.update(overrides)
        code, result = self.call('/recurring', payload, token)
        self.assertEqual(code, 200, result)
        return result

    def scheduled_payload(self, recurring, **overrides):
        result = dict(id='scheduled-1', amount=30000, note='확인한 결제', scope=recurring['scope'],
                      payer=recurring['payer'], funding=recurring['funding'], category=recurring['category'],
                      day='2026-10-31', recurringID=recurring['id'], recurringMonth='2026-10')
        result.update(overrides)
        return result

    def test_recurring_routes_privacy_owner_permissions_and_soft_delete(self):
        a, other = self.create(), self.create()
        invitation = self.call('/invite', {}, a)[1]['invite']
        b = self.call('/join', dict(invite=invitation, memberName='상대'))[1]['token']
        shared = self.recurring(a)
        self.recurring(a, scope='personal', note='숨긴 반복결제')
        own = self.call('/state?month=2026-10', token=a)[1]
        partner = self.call('/state?month=2026-10', token=b)[1]
        self.assertEqual(len(own['recurringPayments']), 2)
        self.assertEqual(len(partner['recurringPayments']), 1)
        self.assertNotIn('숨긴 반복결제', json.dumps(partner, ensure_ascii=False))
        route = '/recurring/' + shared['id']
        for token in (b, other):
            for path, payload, method in ((route, {'note': '침범'}, 'PATCH'), (route, {}, 'DELETE'),
                                          (route + '/link', dict(month='2026-10', entryID='missing'), 'POST'),
                                          ('/entries', self.scheduled_payload(shared), 'POST')):
                self.assertEqual(self.call(path, payload, token, method)[0], 400)
        self.assertEqual(self.call(route, {'note': '승인된 수정'}, a, 'PATCH')[0], 200)
        code, entry = self.call('/entries', self.scheduled_payload(shared), a)
        self.assertEqual(code, 200)
        self.assertEqual(self.call(route, {}, a, 'DELETE')[0], 200)
        view = self.call('/state?month=2026-10', token=a)[1]
        self.assertEqual(len(view['recurringPayments']), 1)
        self.assertEqual(view['entries'][0]['id'], entry['id'])
        self.assertEqual(self.call('/entries', self.scheduled_payload(shared, id='new'), a)[0], 400)

    def test_recurring_concurrent_confirmations_retry_and_void_are_atomic(self):
        token = self.create()
        recurring = self.recurring(token)
        barrier = threading.Barrier(2)
        def worker(index):
            barrier.wait(timeout=10)
            return self.call('/entries', self.scheduled_payload(recurring, id='race-' + str(index)), token)
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(worker, range(2)))
        self.assertEqual([code for code, _ in results], [200, 200])
        self.assertEqual(results[0][1], results[1][1])
        self.assertEqual(len(self.call('/state?month=2026-10', token=token)[1]['entries']), 1)
        entry = results[0][1]
        self.assertEqual(self.call('/entries/' + entry['id'], {}, token, 'DELETE')[0], 200)
        self.assertEqual(self.call('/entries', self.scheduled_payload(recurring, id=entry['id']), token)[0], 400)
        self.assertEqual(self.call('/entries', self.scheduled_payload(recurring, id='new-attempt'), token)[0], 200)
        reopened = app.Store(self.db.path)
        self.assertEqual(len(reopened.run(token, lambda s, a: [e for e in s['entries'] if not e['voided']])), 1)

    def test_recurring_link_existing_and_record_race_cannot_duplicate(self):
        token = self.create()
        recurring = self.recurring(token)
        code, imported = self.call('/imports', dict(text='카드 승인 30,000원 가맹점: 테스트', source='sms', eventID='link-import'), token)
        self.assertEqual(code, 200)
        payload = self.scheduled_payload(recurring, id='imported-expense', importID=imported['id'], day='2026-10-20')
        payload.pop('recurringID')
        payload.pop('recurringMonth')
        code, entry = self.call('/entries', payload, token)
        self.assertEqual(code, 200)
        route = '/recurring/' + recurring['id'] + '/link'
        self.assertEqual(self.call(route, dict(month='2026-10', entryID=entry['id']), token)[0], 200)
        barrier = threading.Barrier(2)
        def worker(index):
            barrier.wait(timeout=10)
            return (self.call(route, dict(month='2026-10', entryID=entry['id']), token) if index == 0 else
                    self.call('/entries', self.scheduled_payload(recurring, id='would-duplicate'), token))
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(worker, range(2)))
        self.assertEqual([code for code, _ in results], [200, 200])
        self.assertEqual([r['id'] for _, r in results], [entry['id'], entry['id']])
        view = self.call('/state?month=2026-10', token=token)[1]
        self.assertEqual(len(view['entries']), 1)
        self.assertEqual(view['stats']['total'], 30000)

    def test_recurring_invalid_requests_rollback_and_reads_do_not_write(self):
        token = self.create()
        recurring = self.recurring(token)
        route = '/recurring/' + recurring['id']
        before = self.db.run(token, lambda s, a: json.dumps(s, sort_keys=True))
        for path, payload, method in ((route, {'amount': -1}, 'PATCH'),
                                      (route, {'scope': 'personal', 'payer': 'missing'}, 'PATCH'),
                                      (route, {'active': 1}, 'PATCH'),
                                      (route + '/link', dict(month='bad', entryID='missing'), 'POST'),
                                      ('/entries', self.scheduled_payload(recurring, day='2026-11-01'), 'POST')):
            self.assertEqual(self.call(path, payload, token, method)[0], 400)
            self.assertEqual(self.db.run(token, lambda s, a: json.dumps(s, sort_keys=True)), before)
        with sqlite3.connect(self.db.path) as observer:
            version = observer.execute('PRAGMA data_version').fetchone()[0]
            for month in ('2026-02', '2026-10', '2027-02'):
                self.assertEqual(self.call('/state?month=' + month, token=token)[0], 200)
            self.assertEqual(observer.execute('PRAGMA data_version').fetchone()[0], version)


    def test_recurring_client_id_response_loss_and_concurrent_retries(self):
        token = self.create()
        view = self.call('/state?month=2026-10', token=token)[1]
        payload = dict(id='schedule-create-request', note='저녁 식사', amount=30000, scope='shared', category='',
                       payer=view['me'], funding='personal', startDay='2026-01-01', dayOfMonth=25)
        barrier = threading.Barrier(2)
        def create(_):
            barrier.wait(timeout=10)
            return self.call('/recurring', payload, token)
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(create, range(2)))
        self.assertEqual([code for code, _ in results], [200, 200])
        self.assertEqual(results[0][1], results[1][1])
        self.assertEqual(results[0][1]['id'], payload['id'])
        # Discard the first responses; the client retries the same draft after a lost response.
        with sqlite3.connect(self.db.path) as observer:
            version = observer.execute('PRAGMA data_version').fetchone()[0]
            self.assertEqual(self.call('/recurring', payload, token), results[0])
            self.assertEqual(observer.execute('PRAGMA data_version').fetchone()[0], version)
        self.assertEqual(len(self.call('/state?month=2026-10', token=token)[1]['recurringPayments']), 1)
        self.assertEqual(self.call('/recurring', {**payload, 'amount': 31000}, token)[0], 400)
        invitation = self.call('/invite', {}, token)[1]['invite']
        partner = self.call('/join', dict(invite=invitation, memberName='상대'))[1]['token']
        self.assertEqual(self.call('/recurring', payload, partner)[0], 400)
        recurring = results[0][1]
        code, entry = self.call('/entries', self.scheduled_payload(recurring, day='2026-10-24'), token)
        self.assertEqual(code, 200)
        self.assertEqual(entry['day'], '2026-10-24')
        self.assertEqual(self.call('/entries/' + entry['id'], dict(note='실제 결제 수정'), token, 'PATCH')[0], 200)
        saved = self.call('/state?month=2026-10', token=token)[1]['entries'][0]
        self.assertEqual((saved['recurringID'], saved['recurringMonth']), (recurring['id'], '2026-10'))


    def test_recurring_expense_to_refund_reopens_occurrence_and_survives_restart(self):
        token = self.create()
        recurring = self.recurring(token)
        code, expense = self.call('/entries', self.scheduled_payload(recurring), token)
        self.assertEqual(code, 200)
        code, refund = self.call('/entries/' + expense['id'], dict(kind='refund'), token, 'PATCH')
        self.assertEqual(code, 200)
        self.assertNotIn('recurringID', refund)
        self.assertNotIn('recurringMonth', refund)
        reopened = app.Store(self.db.path)
        pending = reopened.run(token, lambda s, a: app.L.snapshot(s, a, '2026-10'))
        self.assertEqual(pending['stats']['total'], -30000)
        self.assertIsNone(pending['recurringPayments'][0]['entryID'])
        self.assertEqual(self.call('/entries', self.scheduled_payload(recurring), token)[0], 400)
        code, replacement = self.call('/entries', self.scheduled_payload(recurring, id='new-expense'), token)
        self.assertEqual(code, 200)
        self.assertEqual((replacement['id'], replacement['kind']), ('new-expense', 'expense'))
        saved = reopened.run(token, lambda s, a: app.L.snapshot(s, a, '2026-10'))
        self.assertEqual(saved['recurringPayments'][0]['entryID'], 'new-expense')
        self.assertEqual(sorted(e['kind'] for e in saved['entries']), ['expense', 'refund'])
        self.assertEqual(saved['stats']['total'], 0)


if __name__ == '__main__':
    unittest.main()
