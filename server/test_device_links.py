"""PC pairing with synthetic SQLite, transactional doubles, and optional ADC tests."""
from concurrent.futures import ThreadPoolExecutor
import copy
import json
import math
import os
from pathlib import Path
import sqlite3
import tempfile
import threading
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import uuid

import app
import firestore_store as F
import ledger as L
import test_api as API


class DeviceLinkContract:
    def create(self):
        return self.store.create(dict(name='합성 가계부', memberName='합성 본인', mode='separate'))

    def race(self, operation):
        barrier = threading.Barrier(2)

        def worker(_):
            barrier.wait(timeout=10)
            try:
                return operation(self.reopen())
            except L.LedgerError as error:
                return error

        with ThreadPoolExecutor(max_workers=2) as pool:
            return list(pool.map(worker, range(2)))

    def test_same_identity_with_two_members_and_private_data(self):
        owner = self.create()
        partner = self.store.join(dict(invite=self.store.invite(owner['token'])['invite'], memberName='합성 상대'))
        self.store.run(owner['token'], lambda s, a: L.add_entry(s, a, dict(
            id='synthetic-private', amount=100, note='합성 비공개', day='2026-11-03', scope='personal')))
        before = self.store.run(owner['token'], lambda s, a: s)
        links = [self.store.device_link(member['token']) for member in (owner, partner)]
        with patch.object(L, 'add_member', side_effect=AssertionError('Pairing must not add members')):
            for member, link in zip((owner, partner), links):
                paired = self.reopen().redeem_device_link(dict(code=link['code']))
                self.assertEqual(set(paired), {'token', 'memberID', 'householdID'})
                self.assertEqual((paired['memberID'], paired['householdID']),
                                 (member['memberID'], member['householdID']))
                self.assertNotEqual(paired['token'], member['token'])
                phone = self.store.run(member['token'], lambda s, a: L.snapshot(s, a, '2026-11'))
                pc = self.store.run(paired['token'], lambda s, a: L.snapshot(s, a, '2026-11'))
                self.assertEqual(pc, phone)
        self.assertEqual(self.store.run(owner['token'], lambda s, a: s), before)

    def test_unambiguous_entropy_expiry_and_hashed_storage(self):
        owner = self.create()
        issued_at = int(time.time())
        link = self.store.device_link(owner['token'])
        self.assertEqual(set(link), {'code', 'expiresIn'})
        self.assertEqual(link['expiresIn'], 300)
        alphabet = '23456789ABCDEFGHJKMNPQRSTVWXYZ'
        self.assertEqual(len(link['code']), 16)
        self.assertTrue(set(link['code']) <= set(alphabet))
        self.assertGreaterEqual(len(link['code']) * math.log2(len(alphabet)), 60)
        records = self.link_documents()
        self.assertEqual(set(records), {app.digest(link['code'])})
        self.assertGreaterEqual(records[app.digest(link['code'])]['expires'], issued_at + 300)
        self.assertNotIn(link['code'], repr(records))
        self.assertNotIn(owner['token'], repr(records))

    def test_wrong_invalid_huge_and_unicode_codes_leave_valid_code_usable(self):
        owner = self.create()
        code = self.store.device_link(owner['token'])['code']
        wrong = ('2' if code[0] != '2' else '3') + code[1:]
        for invalid in (wrong, None, False, 123, [], {}, '', '2' * 15, '2' * 17,
                        'A' * 100_000, '0' * 16, 'I' * 16, 'Ｊ' * 16, 'ſ' * 16, '\t' + code):
            with self.subTest(type=type(invalid).__name__), self.assertRaises(L.LedgerError):
                self.store.redeem_device_link(dict(code=invalid))
        self.assertEqual(self.store.redeem_device_link(dict(code=code))['memberID'], owner['memberID'])

    def test_normalized_code_is_single_use(self):
        code = self.store.device_link(self.create()['token'])['code']
        formatted = ' ' + '-'.join(code[i:i + 4].lower() for i in range(0, 16, 4)) + ' '
        self.store.redeem_device_link(dict(code=formatted))
        with self.assertRaises(L.LedgerError):
            self.reopen().redeem_device_link(dict(code=code))
        self.assertEqual(self.link_documents(), {})

    def test_expired_code_rejected_and_next_issue_removes_old_storage(self):
        owner = self.create()
        code = self.store.device_link(owner['token'])['code']
        self.expire(code)
        with self.assertRaises(L.LedgerError):
            self.store.redeem_device_link(dict(code=code))
        latest = self.store.device_link(owner['token'])['code']
        self.assertEqual(set(self.link_documents()), {app.digest(latest)})
        self.store.redeem_device_link(dict(code=latest))

    def test_expiration_boundary_is_exclusive(self):
        owner = self.create()
        clock = SimpleNamespace(time=lambda: 1000)
        with patch.object(app, 'time', clock), patch.object(F, 'time', clock):
            code = self.store.device_link(owner['token'])['code']
            clock.time = lambda: 1300
            with self.assertRaises(L.LedgerError):
                self.store.redeem_device_link(dict(code=code))

    def test_only_newest_code_for_member_survives_concurrent_issuance(self):
        owner = self.create()
        stale = self.store.device_link(owner['token'])['code']
        issued = self.race(lambda store: store.device_link(owner['token']))
        self.assertTrue(all(isinstance(result, dict) for result in issued))
        records = self.link_documents()
        self.assertEqual(len(records), 1)
        with self.assertRaises(L.LedgerError):
            self.store.redeem_device_link(dict(code=stale))
        active = next(link['code'] for link in issued if app.digest(link['code']) in records)
        stale = next(link['code'] for link in issued if app.digest(link['code']) not in records)
        with self.assertRaises(L.LedgerError):
            self.store.redeem_device_link(dict(code=stale))
        self.store.redeem_device_link(dict(code=active))

    def test_concurrent_redemption_issues_exactly_one_session(self):
        owner = self.create()
        code = self.store.device_link(owner['token'])['code']
        results = self.race(lambda store: store.redeem_device_link(dict(code=code)))
        self.assertEqual(sum(isinstance(result, dict) for result in results), 1)
        self.assertEqual(sum(isinstance(result, L.LedgerError) for result in results), 1)
        self.assertEqual(self.session_count(), 2)
        winner = next(result for result in results if isinstance(result, dict))
        self.assertEqual(self.store.run(winner['token'], lambda s, a: a), owner['memberID'])

    def test_newest_link_is_per_member_across_sessions_and_other_households(self):
        owner, other = self.create(), self.create()
        pc = self.store.redeem_device_link(dict(code=self.store.device_link(owner['token'])['code']))
        stale = self.store.device_link(owner['token'])['code']
        other_code = self.store.device_link(other['token'])['code']
        with self.assertRaises(app.Unauthorized):
            self.store.device_link(pc['token'])
        latest = self.store.device_link(owner['token'])['code']
        with self.assertRaises(L.LedgerError):
            self.store.redeem_device_link(dict(code=stale))
        self.assertEqual(self.store.redeem_device_link(dict(code=other_code))['householdID'], other['householdID'])
        self.assertEqual(self.store.redeem_device_link(dict(code=latest))['memberID'], owner['memberID'])

    def test_web_session_expires_at_30_days_without_affecting_native_token(self):
        owner = self.create()
        with patch.object(app.time, 'time', return_value=1_000_000):
            pc = self.store.redeem_device_link(dict(code=self.store.device_link(owner['token'])['code']))
        with patch.object(app.time, 'time', return_value=3_591_999):
            self.assertEqual(self.reopen().run(pc['token'], lambda s, a: a), owner['memberID'])
        with patch.object(app.time, 'time', return_value=3_592_000):
            with self.assertRaises(app.Unauthorized):
                self.reopen().run(pc['token'], lambda s, a: L.add_category(s, 'must-not-save'))
            self.assertEqual(self.store.run(owner['token'], lambda s, a: a), owner['memberID'])
            self.assertNotIn('must-not-save', [c['name'] for c in self.store.run(owner['token'], lambda s, a: s)['categories']])

    def test_revoke_is_persistent_idempotent_and_preserves_other_sessions(self):
        owner = self.create()
        pc = self.store.redeem_device_link(dict(code=self.store.device_link(owner['token'])['code']))
        other = self.store.redeem_device_link(dict(code=self.store.device_link(owner['token'])['code']))
        for _ in range(2):
            self.assertEqual(self.reopen().revoke_session(pc['token']), dict(ok=True))
        with self.assertRaises(app.Unauthorized):
            self.reopen().run(pc['token'], lambda s, a: a)
        for session in (owner, other):
            self.assertEqual(self.store.run(session['token'], lambda s, a: a), owner['memberID'])

    def test_pc_parent_cannot_issue_link_or_replace_pending_native_link(self):
        owner = self.create()
        pc = self.store.redeem_device_link(dict(code=self.store.device_link(owner['token'])['code']))
        pending = self.store.device_link(owner['token'])['code']
        with self.assertRaises(app.Unauthorized):
            self.reopen().device_link(pc['token'])
        self.assertEqual(self.store.redeem_device_link(dict(code=pending))['memberID'], owner['memberID'])

    def test_pc_parent_cannot_redeem_preexisting_link(self):
        owner = self.create()
        pc = self.store.redeem_device_link(dict(code=self.store.device_link(owner['token'])['code']))
        pending = self.store.device_link(owner['token'])['code']
        self.replace_link_parent(pending, pc['token'])
        with self.assertRaises(L.LedgerError):
            self.store.redeem_device_link(dict(code=pending))
        self.assertEqual(self.session_count(), 2)

    def test_issuer_and_household_membership_must_remain_valid(self):
        for invalidation in ('session', 'session-member', 'household', 'member', 'household-id'):
            owner = self.create()
            code = self.store.device_link(owner['token'])['code']
            self.invalidate(owner, invalidation)
            with self.subTest(invalidation=invalidation):
                with self.assertRaises((app.Unauthorized, L.LedgerError)):
                    self.store.redeem_device_link(dict(code=code))
                with self.assertRaises(app.Unauthorized):
                    self.store.device_link(owner['token'])


class SQLiteDeviceLinkTests(DeviceLinkContract, unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.store = app.Store(Path(self.tmp.name) / 'synthetic.sqlite')

    def reopen(self):
        return app.Store(self.store.path)

    def link_documents(self):
        with self.store.connect() as db:
            db.row_factory = sqlite3.Row
            return {row['hash']: dict(row) for row in db.execute('SELECT * FROM device_links')}

    def expire(self, code):
        with self.store.connect() as db:
            db.execute('UPDATE device_links SET expires=0 WHERE hash=?', (app.digest(code),))

    def session_count(self):
        with self.store.connect() as db:
            return db.execute('SELECT COUNT(*) FROM sessions').fetchone()[0]

    def replace_link_parent(self, code, token):
        with self.store.connect() as db:
            db.execute('UPDATE device_links SET session=? WHERE hash=?', (app.digest(token), app.digest(code)))

    def invalidate(self, owner, kind):
        with self.store.connect() as db:
            if kind == 'session':
                db.execute('DELETE FROM sessions WHERE hash=?', (app.digest(owner['token']),))
            elif kind == 'session-member':
                db.execute('UPDATE sessions SET member=? WHERE hash=?', ('missing', app.digest(owner['token'])))
            elif kind == 'household':
                db.execute('DELETE FROM households WHERE id=?', (owner['householdID'],))
            else:
                state = json.loads(db.execute('SELECT data FROM households WHERE id=?', (owner['householdID'],)).fetchone()[0])
                if kind == 'member':
                    state['members'] = []
                else:
                    state['id'] = 'mismatch'
                db.execute('UPDATE households SET data=? WHERE id=?', (json.dumps(state), owner['householdID']))

    def test_failed_session_insert_does_not_consume_code(self):
        owner = self.create()
        code = self.store.device_link(owner['token'])['code']
        with self.store.connect() as db:
            db.execute("CREATE TRIGGER fail_session BEFORE INSERT ON sessions BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END")
        with self.assertRaises(sqlite3.IntegrityError):
            self.store.redeem_device_link(dict(code=code))
        with self.store.connect() as db:
            db.execute('DROP TRIGGER fail_session')
        self.store.redeem_device_link(dict(code=code))

    def test_failed_revoke_rolls_back_session_deletion(self):
        owner = self.create()
        pc = self.store.redeem_device_link(dict(code=self.store.device_link(owner['token'])['code']))
        with self.store.connect() as db:
            db.execute("CREATE TRIGGER fail_revoke BEFORE DELETE ON sessions BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END")
        with self.assertRaises(sqlite3.IntegrityError):
            self.store.revoke_session(pc['token'])
        self.assertEqual(self.store.run(pc['token'], lambda s, a: a), owner['memberID'])

    def test_legacy_three_column_sessions_upgrade_preserves_native_access(self):
        owner = self.create()
        with self.store.connect() as db:
            db.execute('ALTER TABLE sessions RENAME TO old_sessions')
            db.execute('CREATE TABLE sessions (hash TEXT PRIMARY KEY, household TEXT NOT NULL, member TEXT NOT NULL)')
            db.execute('INSERT INTO sessions SELECT hash, household, member FROM old_sessions')
            db.execute('DROP TABLE old_sessions')
        self.store = self.reopen()
        self.assertEqual(self.store.run(owner['token'], lambda s, a: a), owner['memberID'])
        self.store.redeem_device_link(dict(code=self.store.device_link(owner['token'])['code']))

    def test_existing_database_preserved_and_expired_cleanup_is_bounded(self):
        owner = self.create()
        with self.store.connect() as db:
            for index in range(105):
                db.execute('INSERT INTO device_links VALUES (?, ?, ?, ?, ?)',
                           (app.digest(str(index)), 'synthetic-household', str(index), 'synthetic-session', 0))
        self.store = self.reopen()
        self.store.device_link(owner['token'])
        self.assertEqual(len(self.link_documents()), 6)
        self.assertEqual(self.store.run(owner['token'], lambda s, a: a), owner['memberID'])

    def test_upgrade_from_existing_schema_preserves_household_and_session(self):
        owner = self.create()
        before = self.store.run(owner['token'], lambda s, a: s)
        with self.store.connect() as db:
            db.execute('DROP TABLE device_links')
        self.store = self.reopen()
        self.assertEqual(self.store.run(owner['token'], lambda s, a: s), before)
        paired = self.store.redeem_device_link(dict(code=self.store.device_link(owner['token'])['code']))
        self.assertEqual(paired['memberID'], owner['memberID'])


class DeviceLinkHTTPTests(unittest.TestCase):
    setUp = API.APITests.setUp
    tearDown = API.APITests.tearDown
    call = API.APITests.call

    def test_endpoint_auth_bodyless_issue_and_unauthenticated_redeem(self):
        owner = self.db.create(dict(name='합성 HTTP', memberName='합성 본인', mode='separate'))
        for token in (None, 'invalid'):
            self.assertEqual(self.call('/device-links', {}, token)[0], 401)
        status, link = self.call('/device-links', token=owner['token'], method='POST')
        self.assertEqual(status, 200)
        self.assertEqual(link['expiresIn'], 300)
        status, paired = self.call('/device-links/redeem', dict(code=link['code']))
        self.assertEqual(status, 200)
        self.assertEqual((paired['memberID'], paired['householdID']), (owner['memberID'], owner['householdID']))
        self.assertEqual(self.call('/state?month=2026-11', token=paired['token'])[0], 200)
        self.assertEqual(self.call('/device-links/redeem', dict(code=link['code']))[0], 400)

    def test_http_revoke_expiration_and_parent_rejection(self):
        owner = self.db.create(dict(name='Synthetic', memberName='Owner', mode='separate'))
        pc = self.call('/device-links/redeem', dict(code=self.call('/device-links', {}, owner['token'])[1]['code']))[1]
        self.assertEqual(self.call('/device-links', {}, pc['token'])[0], 401)
        self.assertEqual(self.call('/session', method='DELETE')[0], 401)
        with patch.object(app.time, 'time', return_value=4_102_444_800):
            self.assertEqual(self.call('/state?month=2026-11', token=pc['token'])[0], 401)
        with patch.object(self.db, 'revoke_session', side_effect=RuntimeError('Synthetic failure'), create=True):
            self.assertEqual(self.call('/session', {}, pc['token'], 'DELETE')[0], 500)
        self.assertEqual(self.call('/state?month=2026-11', token=pc['token'])[0], 200)
        for _ in range(2):
            self.assertEqual(self.call('/session', token=pc['token'], method='DELETE')[0], 200)
        self.assertEqual(self.call('/state?month=2026-11', token=pc['token'])[0], 401)
        self.assertEqual(self.call('/state?month=2026-11', token=owner['token'])[0], 200)

    def test_http_invalid_codes_and_concurrent_redeem(self):
        owner = self.db.create(dict(name='합성 HTTP', memberName='합성 본인', mode='separate'))
        for payload in ({}, {'code': None}, {'code': 'A' * 65}, {'code': 'A' * 40000}):
            self.assertEqual(self.call('/device-links/redeem', payload)[0], 400)
        code = self.call('/device-links', {}, owner['token'])[1]['code']
        barrier = threading.Barrier(2)

        def redeem(_):
            barrier.wait(timeout=10)
            return self.call('/device-links/redeem', dict(code=code))[0]

        with ThreadPoolExecutor(max_workers=2) as pool:
            self.assertEqual(sorted(pool.map(redeem, range(2))), [200, 400])


class FirestoreDeviceLinkContract(DeviceLinkContract):
    def reopen(self):
        return F.FirestoreStore(self.client, self.prefix)

    def link_documents(self):
        return {doc.id: doc.to_dict() for doc in self.store.device_links.stream()}

    def expire(self, code):
        self.store.device_links.document(app.digest(code)).update({'expires': 0})

    def session_count(self):
        return len(list(self.store.sessions.stream()))

    def replace_link_parent(self, code, token):
        self.store.device_links.document(app.digest(code)).update({'session': app.digest(token)})

    def invalidate(self, owner, kind):
        session = self.store.sessions.document(app.digest(owner['token']))
        household = self.store.households.document(owner['householdID'])
        if kind == 'session':
            session.delete()
        elif kind == 'session-member':
            session.update({'member': 'missing'})
        elif kind == 'household':
            household.delete()
        else:
            state = F._decode(household.get().get('data'))
            if kind == 'member':
                state['members'] = []
            else:
                state['id'] = 'mismatch'
            household.update({'data': F._encode(state)})


class MemoryFirestore:
    """Document-only optimistic transactions; never opens a Google connection."""
    def __init__(self):
        self.data = {}
        self.version = 0
        self.lock = threading.Lock()
        self.first_attempts = None
        self.conflicts = 0
        self.fail_commit = False

    def collection(self, name):
        backend = self

        class Reference:
            def __init__(self, key):
                self.id = key
                self.key = (name, key)

            def get(self, transaction=None):
                if transaction:
                    if transaction.written:
                        raise AssertionError('Firestore reads must precede writes')
                    data = copy.deepcopy(transaction.data.get(self.key))
                else:
                    with backend.lock:
                        data = copy.deepcopy(backend.data.get(self.key))
                reference = self

                class Snapshot:
                    id = reference.id
                    exists = data is not None

                    def to_dict(self):
                        return copy.deepcopy(data)

                    def get(self, field):
                        return data[field]

                return Snapshot()

            def update(self, fields):
                with backend.lock:
                    backend.data[self.key].update(copy.deepcopy(fields))
                    backend.version += 1

            def delete(self):
                with backend.lock:
                    backend.data.pop(self.key, None)
                    backend.version += 1

        class Collection:
            document = staticmethod(Reference)

            def stream(self):
                with backend.lock:
                    keys = [key for collection, key in backend.data if collection == name]
                return [Reference(key).get() for key in keys]

        return Collection()

    def transaction(self):
        class Transaction:
            written = False

            def create(self, reference, fields):
                if reference.key in self.data:
                    raise AssertionError('Document already exists')
                self.data[reference.key] = copy.deepcopy(fields)
                self.written = True

            def update(self, reference, fields):
                self.data[reference.key].update(copy.deepcopy(fields))
                self.written = True

            def delete(self, reference):
                self.data.pop(reference.key, None)
                self.written = True

        return Transaction()

    def transactional(self, action):
        def run(transaction):
            for attempt in range(20):
                with self.lock:
                    transaction.data, version = copy.deepcopy(self.data), self.version
                transaction.written = False
                if attempt == 0 and self.first_attempts:
                    self.first_attempts.wait(timeout=10)
                result = action(transaction)
                with self.lock:
                    if self.version != version:
                        self.conflicts += 1
                        continue
                    if self.fail_commit:
                        raise RuntimeError('Synthetic commit failure')
                    if transaction.written:
                        self.data = transaction.data
                        self.version += 1
                    return result
            raise AssertionError('Synthetic transaction retries exhausted')
        return run

    def store(self, prefix):
        store = object.__new__(F.FirestoreStore)
        store.client = self
        for suffix in ('households', 'sessions', 'invites', 'device_links'):
            setattr(store, suffix, self.collection(prefix + '_' + suffix))
        store._transactional = self.transactional
        store._retry_aborted = lambda action: action
        return store


class FirestoreDoubleDeviceLinkTests(FirestoreDeviceLinkContract, unittest.TestCase):
    def setUp(self):
        self.client = MemoryFirestore()
        self.prefix = 'synthetic'
        self.store = self.reopen()

    def reopen(self):
        return self.client.store(self.prefix)

    def race(self, operation):
        before = self.client.conflicts
        self.client.first_attempts = threading.Barrier(2)
        try:
            result = super().race(operation)
        finally:
            self.client.first_attempts = None
        self.assertGreater(self.client.conflicts, before)
        return result

    def test_failed_commit_does_not_consume_code(self):
        owner = self.create()
        code = self.store.device_link(owner['token'])['code']
        self.client.fail_commit = True
        with self.assertRaises(RuntimeError):
            self.store.redeem_device_link(dict(code=code))
        self.client.fail_commit = False
        self.assertEqual(self.session_count(), 1)
        self.assertEqual(self.store.redeem_device_link(dict(code=code))['memberID'], owner['memberID'])


    def test_failed_revoke_commit_keeps_session_usable(self):
        owner = self.create()
        pc = self.store.redeem_device_link(dict(code=self.store.device_link(owner['token'])['code']))
        self.client.fail_commit = True
        with self.assertRaises(RuntimeError):
            self.store.revoke_session(pc['token'])
        self.client.fail_commit = False
        self.assertEqual(self.store.run(pc['token'], lambda s, a: a), owner['memberID'])


@unittest.skipUnless(os.getenv('OURLEDGER_LIVE_FIRESTORE_TESTS') == '1', 'Live Firestore tests are opt-in')
class FirestoreADCDeviceLinkTests(FirestoreDeviceLinkContract, unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if os.getenv('FIRESTORE_EMULATOR_HOST'):
            raise unittest.SkipTest('Unset FIRESTORE_EMULATOR_HOST for live ADC tests')
        try:
            import google.auth
            from google.auth.exceptions import DefaultCredentialsError
            from google.cloud import firestore
        except ImportError:
            raise unittest.SkipTest('Firestore SDK unavailable; live ADC pairing not verified')
        try:
            credentials, project = google.auth.default()
        except DefaultCredentialsError:
            raise unittest.SkipTest('ADC unavailable; live Firestore pairing not verified')
        if not project:
            raise unittest.SkipTest('ADC project unavailable')
        cls.client = firestore.Client(project=project, credentials=credentials)
        cls.addClassCleanup(cls.client.close)

    def setUp(self):
        self.prefix = 'ourledger_test_pc_' + uuid.uuid4().hex
        self.store = F.FirestoreStore(self.client, self.prefix)
        self.addCleanup(self.cleanup_prefix)

    def cleanup_prefix(self):
        for suffix in ('households', 'sessions', 'invites', 'device_links'):
            for doc in self.client.collection(self.prefix + '_' + suffix).stream():
                doc.reference.delete()


if __name__ == '__main__':
    unittest.main()
