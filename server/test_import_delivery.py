"""Bounded, credential-free import delivery diagnostics using synthetic data only.

Firestore tests exercise the production run/_household callbacks with a local
optimistic-transaction double. They do not verify the Google SDK or live service.
"""
from concurrent.futures import ThreadPoolExecutor
import copy
import threading
from types import SimpleNamespace
import unittest

from auth import digest
import firestore_store as F
import ledger as L
import test_api as API


def receipt(amount=10000, minute='00', extra=''):
    return f'합성은행 출금 {amount:,}원\n가맹점: 합성상점\n2026/10/26 13:{minute}\n{extra}'


class ImportDeliveryHTTPTests(unittest.TestCase):
    setUp = API.APITests.setUp
    tearDown = API.APITests.tearDown
    call = API.APITests.call
    create = API.APITests.create

    def pair(self, first, second):
        token = self.create()
        barrier = threading.Barrier(2)

        def send(payload):
            barrier.wait(timeout=5)
            return self.call('/imports', payload, token)

        with ThreadPoolExecutor(max_workers=2) as workers:
            replies = list(workers.map(send, (first, second)))
        self.assertEqual([code for code, _ in replies], [200, 200])
        view = self.call('/state?month=2026-10', token=token)[1]
        saved = self.db.run(token, lambda state, actor: state)
        return replies, view, saved

    def test_distinct_amounts_and_equal_amounts_without_reference_survive_concurrency(self):
        for amounts in ((10000, 23000), (10000, 10000)):
            with self.subTest(amounts=amounts):
                replies, view, saved = self.pair(
                    dict(text=receipt(amounts[0]), eventID=L.uid()),
                    dict(text=receipt(amounts[1], '01'), eventID=L.uid()))
                self.assertEqual(len({reply['id'] for _, reply in replies}), 2)
                self.assertEqual(len(view['inbox']), 2)
                self.assertEqual(len(saved['imports']), 2)
                self.assertEqual(saved['entries'], [])

    def test_equal_amount_same_minute_distinct_bank_texts_and_refs_without_card_stay_separate(self):
        for extras in (('받는 분: 합성가', '받는 분: 합성나'),
                       ('거래번호 778899\n받는 분: 합성가', '거래번호 778899\n받는 분: 합성나')):
            with self.subTest(extras=extras):
                _, view, saved = self.pair(
                    dict(text=receipt(extra=extras[0]), eventID=L.uid()),
                    dict(text=receipt(extra=extras[1]), eventID=L.uid()))
                self.assertEqual((len(saved['imports']), len(view['inbox'])), (2, 2))
                self.assertTrue(any(item['candidates'] for item in view['inbox']))

    def test_same_reference_with_distinct_amount_time_or_merchant_is_not_merged(self):
        first = receipt(extra='카드 1234\n거래번호 778899')
        for second in (first.replace('10,000', '23,000'), first.replace('13:00', '13:01'),
                       first.replace('합성상점', '다른합성상점')):
            with self.subTest(second=second):
                _, view, saved = self.pair(dict(text=first, eventID=L.uid()), dict(text=second, eventID=L.uid()))
                self.assertEqual((len(saved['imports']), len(view['inbox'])), (2, 2))

    def test_same_parsed_reference_merges_even_when_raw_text_differs(self):
        first = receipt(extra='카드 1234\n거래번호 778899\n잔액 90,000원')
        second = first.replace('잔액 90,000', '잔액 80,000')
        replies, view, saved = self.pair(dict(text=first, eventID=L.uid()), dict(text=second, eventID=L.uid()))
        self.assertEqual(replies[0][1]['id'], replies[1][1]['id'])
        self.assertEqual((len(saved['imports']), len(view['inbox'])), (1, 1))
        self.assertEqual(len(saved['imports'][0]['events']), 2)

    def test_reused_event_key_returns_old_record_even_for_different_amount_and_text(self):
        token = self.create()
        first = self.call('/imports', dict(text=receipt(), source='shortcut', eventID='same-key'), token)[1]
        second = self.call('/imports', dict(text=receipt(23000, '01'), source='shortcut', eventID='same-key'), token)[1]
        self.assertEqual((second['id'], second['amount'], second['raw']), (first['id'], 10000, first['raw']))
        entry = dict(amount=10000, note='합성 지출', day='2026-10-26', scope='personal', importID=first['id'])
        self.assertEqual(self.call('/entries', entry, token)[0], 200)
        third = self.call('/imports', dict(text=receipt(34000, '02'), source='shortcut', eventID='same-key'), token)[1]
        self.assertEqual((third['id'], third['status']), (first['id'], 'recorded'))
        self.assertEqual(self.call('/state?month=2026-10', token=token)[1]['inbox'], [])


class LocalFirestoreDouble:
    """Versioned in-memory documents; no SDK, credentials, network or real DB."""
    def __init__(self):
        self.state = L.new_household('합성 저장', '합성본인', 'separate')
        self.actor = self.state['members'][0]['id']
        self.token = 'synthetic-session-only'
        self.data = F._encode(self.state)
        self.version = 0
        self.lock = threading.Lock()
        self.first_reads = threading.Barrier(2)
        self.attempts = 0
        self.conflicts = 0

    def store(self):
        store = object.__new__(F.FirestoreStore)
        store.client = SimpleNamespace(transaction=lambda: SimpleNamespace())
        store._retry_aborted = lambda action: action
        store._transactional = self.transactional
        store.sessions = SimpleNamespace(document=lambda key: SimpleNamespace(get=lambda transaction:
            SimpleNamespace(exists=key == digest(self.token), to_dict=lambda:
                dict(household=self.state['id'], member=self.actor))))

        def document(key):
            def get(transaction):
                return SimpleNamespace(exists=key == self.state['id'], to_dict=lambda: dict(data=transaction.data))
            return SimpleNamespace(id=key, get=get)

        store.households = SimpleNamespace(document=document)
        return store

    def transactional(self, action):
        def run(transaction):
            for attempt in range(3):
                with self.lock:
                    self.attempts += 1
                    transaction.data, version = self.data, self.version
                transaction.pending = None
                transaction.update = lambda reference, fields: setattr(transaction, 'pending', fields['data'])
                if attempt == 0:
                    self.first_reads.wait(timeout=5)
                result = action(transaction)
                with self.lock:
                    if version != self.version:
                        self.conflicts += 1
                        continue
                    if transaction.pending is not None:
                        self.data = transaction.pending
                        self.version += 1
                    return result
            raise AssertionError('Synthetic retry budget exhausted')
        return run


class ImportDeliveryFirestoreCallbackTests(unittest.TestCase):
    def test_conflicting_callback_retry_rereads_and_preserves_both_imports(self):
        for amounts in ((10000, 23000), (10000, 10000)):
            with self.subTest(amounts=amounts):
                backend = LocalFirestoreDouble()
                store = backend.store()
                payloads = [dict(text=receipt(amount, f'{index:02}'), eventID=f'event-{index}')
                            for index, amount in enumerate(amounts)]
                with ThreadPoolExecutor(max_workers=2) as workers:
                    results = list(workers.map(lambda payload: store.run(backend.token,
                        lambda state, actor: L.import_message(state, actor, payload)), payloads))
                saved = F._decode(backend.data)
                self.assertEqual((backend.attempts, backend.conflicts), (3, 1))
                self.assertEqual(len(saved['imports']), 2)
                self.assertEqual({result['id'] for result in results}, {item['id'] for item in saved['imports']})
                self.assertEqual(len(L.snapshot(saved, backend.actor, '2026-10')['inbox']), 2)

    def test_callback_failure_does_not_persist_partial_import(self):
        backend = LocalFirestoreDouble()
        backend.first_reads = threading.Barrier(1)
        store = backend.store()
        before = copy.deepcopy(backend.data)

        def fail(state, actor):
            L.import_message(state, actor, dict(text=receipt(), eventID='partial'))
            raise RuntimeError('synthetic aborted action')

        with self.assertRaises(RuntimeError):
            store.run(backend.token, fail)
        self.assertEqual(backend.data, before)
