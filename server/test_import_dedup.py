import unittest
from concurrent.futures import ThreadPoolExecutor
from unittest.mock import patch
import ledger as L
import firestore_store as F
import test_import_delivery as delivery


class NotificationDedupTests(unittest.TestCase):
    def setUp(self):
        clock = patch('ledger.now', return_value='2026-11-05T12:00:05+09:00')
        clock.start()
        self.addCleanup(clock.stop)
        self.state = L.new_household('합성 중복 검사', '다온', 'separate')
        self.me = self.state['members'][0]['id']
        self.other = L.add_member(self.state, '하늘')['id']

    def notice(self, event, source='app', amount=8400, at='11/05 12:00', merchant='합성상점', extra='', actor=None):
        return L.import_message(self.state, actor or self.me, dict(
            text=f'카드 승인 {amount:,}원\n가맹점: {merchant}\n{at}\n{extra}',
            source=source, eventID=event))

    def test_same_payment_with_different_notification_texts_is_one_inbox_item(self):
        first = self.notice('card', merchant='합성상점 카드알림')
        second = self.notice('sms', source='sms', merchant='합성상점 문자알림')
        self.assertEqual(first['id'], second['id'])
        self.assertEqual(second['sources'], ['app', 'sms'])
        self.assertEqual(len(L.snapshot(self.state, self.me, '2026-11')['inbox']), 1)
        self.assertEqual(len(self.state['entries']), 0)

    def test_later_duplicate_cannot_be_recorded_twice(self):
        first = self.notice('first')
        body = dict(amount=8400, note='장보기', scope='shared', kind='expense', funding='personal', day='2026-11-05', importID=first['id'])
        saved = L.add_entry(self.state, self.me, body)
        second = self.notice('later', source='sms')
        self.assertEqual(second['id'], first['id'])
        self.assertEqual(second['status'], 'recorded')
        self.assertEqual(L.add_entry(self.state, self.me, {**body, 'importID':second['id']})['id'], saved['id'])
        self.assertEqual(len(self.state['entries']), 1)

    def test_no_time_auto_notifications_use_short_receipt_window(self):
        first = self.notice('first', at='')
        with patch('ledger.now', return_value='2026-11-05T12:00:17+09:00'):
            second = self.notice('second', source='sms', at='', merchant='다른 알림 문구')
        self.assertEqual(first['id'], second['id'])
        with patch('ledger.now', return_value='2026-11-05T12:00:35+09:00'):
            third = self.notice('third', at='')
        self.assertNotEqual(first['id'], third['id'])

    def test_independent_payments_keep_distinct_ids(self):
        self.notice('first', extra='카드 1234 승인번호 AAAA')
        for event, options in [('amount',dict(amount=8500)), ('time',dict(at='11/05 12:01')),
                               ('card',dict(extra='카드 5678 승인번호 AAAA')),
                               ('reference',dict(extra='카드 1234 승인번호 BBBB')),
                               ('owner',dict(actor=self.other))]:
            with self.subTest(event=event):
                self.assertNotEqual(self.notice(event, **options)['id'], self.state['imports'][0]['id'])
        self.assertEqual(len(self.state['imports']), 6)

    def test_manual_ambiguous_and_date_only_captures_are_not_receipt_duplicates(self):
        raw='카드 승인 8,400원\n가맹점: 합성상점\n거래일: 2026-11-05'
        for event in ('date1','date2'):
            L.import_message(self.state,self.me,dict(text=raw,source='paste',eventID=event))
        for event in ('review1','review2'):
            L.import_message(self.state,self.me,dict(text=raw,source='paste',eventID=event,reviewOnly=True))
        self.assertEqual(len(self.state['imports']),4)

    def test_merge_retains_new_reference_to_distinguish_next_real_payment(self):
        first=self.notice('first')
        second=self.notice('second',source='sms',extra='카드 1234 승인번호 AAAA')
        third=self.notice('third',extra='카드 1234 승인번호 BBBB')
        self.assertEqual(first['id'],second['id'])
        self.assertEqual(second['reference'],'AAAA')
        self.assertNotEqual(first['id'],third['id'])

    def test_missing_time_with_old_explicit_time_cannot_merge(self):
        first=self.notice('old',at='11/04 12:00')
        self.assertNotEqual(first['id'],self.notice('now',at='')['id'])

    def test_refund_income_and_transfer_direction_do_not_hide_an_expense(self):
        first=self.notice('expense')
        for raw in ('취소 8,400원','입금 완료 8,400원','송금 완료 8,400원'):
            item=L.import_message(self.state,self.me,dict(text=raw,source='sms',eventID=raw))
            self.assertNotEqual(first['id'],item['id'])


class ConcurrentNotificationDedupTests(unittest.TestCase):
    setUp=delivery.ImportDeliveryHTTPTests.setUp
    tearDown=delivery.ImportDeliveryHTTPTests.tearDown
    call=delivery.ImportDeliveryHTTPTests.call
    create=delivery.ImportDeliveryHTTPTests.create
    pair=delivery.ImportDeliveryHTTPTests.pair

    def test_http_concurrent_sources_return_one_canonical_id(self):
        replies,view,saved=self.pair(
            dict(text='카드 승인 8,400원\n가맹점: 합성 카드상점\n2026/10/26 12:00',source='app',eventID='app'),
            dict(text='승인 8,400원\n가맹점: 합성 문자상점\n2026/10/26 12:00',source='sms',eventID='sms'))
        self.assertEqual(len({r['id'] for _,r in replies}),1)
        self.assertEqual(len(view['inbox']),1)
        self.assertEqual(len(saved['imports']),1)
        self.assertEqual(set(saved['imports'][0]['sources']),{'app','sms'})
        self.assertEqual(saved['entries'],[])

    def test_firestore_conflict_retries_merge_one_notification(self):
        backend=delivery.LocalFirestoreDouble();store=backend.store()
        payloads=[dict(text=f'카드 승인 8,400원\n가맹점: 합성 {source}상점\n2026/10/26 12:00',source=source,eventID=source) for source in ('app','sms')]
        with ThreadPoolExecutor(max_workers=2) as workers:
            results=list(workers.map(lambda p:store.run(backend.token,lambda s,a:L.import_message(s,a,p)),payloads))
        saved=F._decode(backend.data)
        self.assertEqual((backend.attempts,backend.conflicts),(3,1))
        self.assertEqual(len({r['id'] for r in results}),1)
        self.assertEqual(len(saved['imports']),1)
        self.assertEqual(set(saved['imports'][0]['sources']),{'app','sms'})


if __name__ == '__main__':
    unittest.main()
