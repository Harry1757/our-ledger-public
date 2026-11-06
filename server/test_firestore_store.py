"""Real Firestore tests opt in with OURLEDGER_FIRESTORE_PROJECT and OURLEDGER_GCLOUD."""
from concurrent.futures import ThreadPoolExecutor
import json
import os
import re
import secrets
import subprocess
import threading
import time
import unittest
from unittest.mock import patch
import uuid
import zlib

import app
import ledger as L
import firestore_store as F


class CodecTests(unittest.TestCase):
    def test_round_trip_unicode_and_compressed_bytes(self):
        state = {'name': '우리집', 'entries': [], 'budget': 123}
        encoded = F._encode(state)
        self.assertIsInstance(encoded, bytes)
        self.assertEqual(json.loads(zlib.decompress(encoded)), state)
        self.assertEqual(F._decode(encoded), state)

    def test_raw_limit_even_when_highly_compressible(self):
        state = {'blob': 'x' * (16 * 1024 * 1024 - 11)}
        self.assertEqual(F._decode(F._encode(state)), state)
        state['blob'] += 'x'
        with self.assertRaises(L.LedgerError):
            F._encode(state)
        with self.assertRaises(L.LedgerError):
            F._decode(zlib.compress(json.dumps(state).encode()))

    def test_compressed_limit_and_corrupt_data(self):
        with self.assertRaises(L.LedgerError):
            F._encode({'blob': secrets.token_hex(1_000_000)})
        for data in (b'x' * 900_001, b'broken', zlib.compress(b'[]'),
                     zlib.compress(b'{'), zlib.compress(b'{}')[:-1],
                     zlib.compress(b'{}') + b'extra'):
            with self.subTest(size=len(data)), self.assertRaises(L.LedgerError):
                F._decode(data)


@unittest.skipUnless(os.getenv('OURLEDGER_FIRESTORE_PROJECT') and os.getenv('OURLEDGER_GCLOUD'),
                     'Set OURLEDGER_FIRESTORE_PROJECT and OURLEDGER_GCLOUD for real Firestore tests')
class FirestoreTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        from google.cloud import firestore
        from google.oauth2.credentials import Credentials

        if os.getenv('FIRESTORE_EMULATOR_HOST'):
            raise RuntimeError('Unset FIRESTORE_EMULATOR_HOST to test real Firestore')
        auth = subprocess.run([os.environ['OURLEDGER_GCLOUD'], 'auth', 'print-access-token'],
                              capture_output=True, text=True, timeout=60)
        if auth.returncode or not auth.stdout.strip():
            raise RuntimeError('gcloud auth print-access-token failed')
        cls.client = firestore.Client(project=os.environ['OURLEDGER_FIRESTORE_PROJECT'],
                                      credentials=Credentials(auth.stdout.strip()))
        cls.addClassCleanup(cls.client.close)

    def setUp(self):
        self.prefix = 'ourledger_test_' + uuid.uuid4().hex
        self.store = F.FirestoreStore(self.client, self.prefix)
        self.addCleanup(self.cleanup_prefix)

    def cleanup_prefix(self):
        if not re.fullmatch(r'ourledger_test_[0-9a-f]{32}', self.prefix):
            raise RuntimeError('Refusing to clean a non-test namespace')
        # Only these four exact, randomly named collections belong to this test.
        for suffix in ('households', 'sessions', 'invites', 'device_links'):
            collection = self.client.collection(self.prefix + '_' + suffix)
            for doc in collection.stream():
                doc.reference.delete()
            self.assertFalse(list(collection.limit(1).stream()), 'Temporary collection cleanup incomplete')

    def create(self):
        return self.store.create(dict(name='우리집', memberName='순환', mode='separate'))

    def household(self, registration):
        return self.client.collection(self.prefix + '_households').document(registration['householdID'])

    def documents(self):
        return {suffix: {d.id: (d.to_dict(), d.update_time)
                         for d in self.client.collection(self.prefix + '_' + suffix).stream()}
                for suffix in ('households', 'sessions', 'invites', 'device_links')}

    def entry(self, token, **overrides):
        payload = dict(id='expense-1', amount=30000, note='저녁 식사',
                       day='2026-10-20', scope='shared', kind='expense', funding='personal')
        payload.update(overrides)
        return self.store.run(token, lambda s, a: L.add_entry(s, a, payload))

    def snapshot(self, token):
        return self.store.run(token, lambda s, a: L.snapshot(s, a, '2026-10'))

    def race(self, operation):
        barrier = threading.Barrier(2)

        def worker(index):
            barrier.wait(timeout=20)
            try:
                return operation(index)
            except L.LedgerError as error:
                return error

        with ThreadPoolExecutor(max_workers=2) as pool:
            return list(pool.map(worker, range(2)))

    def test_device_link_expiry_and_hashed_storage(self):
        owner = self.create()
        issued_at = int(time.time())
        link = self.store.device_link(owner['token'])
        self.assertEqual(link['expiresIn'], 300)
        code_hash = app.digest(link['code'])
        documents = self.documents()
        self.assertEqual(set(documents['device_links']), {code_hash})
        stored = documents['device_links'][code_hash][0]
        self.assertGreaterEqual(stored['expires'], issued_at + 300)
        self.assertEqual((stored['household'], stored['member'], stored['session']),
                         (owner['householdID'], owner['memberID'], app.digest(owner['token'])))
        for secret in (link['code'], owner['token']):
            self.assertFalse(secret in repr(documents), 'Plaintext pairing secret stored')
        self.store.device_links.document(code_hash).update({'expires': 0})
        before = self.documents()
        with self.assertRaises(L.LedgerError):
            self.store.redeem_device_link(dict(code=link['code']))
        self.assertTrue(self.documents() == before, 'Expired redemption changed stored documents')
        latest = self.store.device_link(owner['token'])
        self.assertEqual(set(self.documents()['device_links']), {app.digest(latest['code'])})
        self.store.redeem_device_link(dict(code=latest['code']))

    def test_device_link_latest_is_per_member(self):
        owner = self.create()
        partner = self.store.join(dict(invite=self.store.invite(owner['token'])['invite'], memberName='합성 상대'))
        old = self.store.device_link(owner['token'])['code']
        partner_code = self.store.device_link(partner['token'])['code']
        latest = self.store.device_link(owner['token'])['code']
        active = self.household(owner).get().get('activeDeviceLinks')
        self.assertEqual(active, {owner['memberID']: app.digest(latest), partner['memberID']: app.digest(partner_code)})
        self.assertEqual(set(self.documents()['device_links']), {app.digest(latest), app.digest(partner_code)})
        with self.assertRaises(L.LedgerError):
            self.store.redeem_device_link(dict(code=old))
        for member, code in ((owner, latest), (partner, partner_code)):
            paired = self.store.redeem_device_link(dict(code=code))
            self.assertEqual(paired['memberID'], member['memberID'])
        self.assertEqual(self.documents()['device_links'], {})

    def test_device_link_wrong_code_and_replay_do_not_create_sessions(self):
        owner = self.create()
        code = self.store.device_link(owner['token'])['code']
        wrong = ('2' if code[0] != '2' else '3') + code[1:]
        before = self.documents()
        with self.assertRaises(L.LedgerError):
            self.store.redeem_device_link(dict(code=wrong))
        self.assertTrue(self.documents() == before, 'Wrong code changed stored documents')
        paired = self.store.redeem_device_link(dict(code=code))
        self.assertTrue(paired['token'] != owner['token'], 'PC session must have a fresh token')
        self.assertEqual(len(self.documents()['sessions']), 2)
        self.assertEqual(self.household(owner).get().get('activeDeviceLinks'), {})
        before = self.documents()
        with self.assertRaises(L.LedgerError):
            F.FirestoreStore(self.client, self.prefix).redeem_device_link(dict(code=code))
        self.assertTrue(self.documents() == before, 'Replay changed stored documents')

    def test_device_link_two_member_identity_preserves_ledger(self):
        owner = self.create()
        partner = self.store.join(dict(invite=self.store.invite(owner['token'])['invite'], memberName='합성 상대'))
        self.entry(owner['token'], scope='personal', note='합성 비공개')
        before = self.household(owner).get().get('data')
        with patch.object(L, 'add_member', side_effect=AssertionError('Pairing must not add a member')):
            for member in (owner, partner):
                link = self.store.device_link(member['token'])
                paired = F.FirestoreStore(self.client, self.prefix).redeem_device_link(dict(code=link['code']))
                self.assertEqual(set(paired), {'token', 'memberID', 'householdID'})
                self.assertEqual((paired['memberID'], paired['householdID']), (member['memberID'], member['householdID']))
                self.assertEqual(self.store.run(paired['token'], lambda s, actor: actor), member['memberID'])
                self.assertTrue(self.snapshot(paired['token']) == self.snapshot(member['token']),
                                'PC visibility differs from the issuing member')
        self.assertEqual(len(self.snapshot(owner['token'])['members']), 2)
        self.assertTrue(self.household(owner).get().get('data') == before, 'Pairing modified ledger data')

    def test_device_link_concurrent_redemption_creates_one_session(self):
        owner = self.create()
        code = self.store.device_link(owner['token'])['code']
        results = self.race(lambda _: F.FirestoreStore(self.client, self.prefix).redeem_device_link(dict(code=code)))
        self.assertEqual(sum(isinstance(result, dict) for result in results), 1)
        self.assertEqual(sum(isinstance(result, L.LedgerError) for result in results), 1)
        winner = next(result for result in results if isinstance(result, dict))
        self.assertEqual(self.store.run(winner['token'], lambda s, actor: actor), owner['memberID'])
        documents = self.documents()
        self.assertEqual(len(documents['sessions']), 2)
        self.assertEqual(documents['device_links'], {})
        self.assertEqual(self.household(owner).get().get('activeDeviceLinks'), {})

    def test_device_link_concurrent_issuance_retains_only_latest(self):
        owner = self.create()
        results = self.race(lambda _: F.FirestoreStore(self.client, self.prefix).device_link(owner['token']))
        self.assertTrue(all(isinstance(result, dict) for result in results), 'Concurrent issuance failed')
        documents = self.documents()['device_links']
        self.assertEqual(len(documents), 1)
        active = self.household(owner).get().get('activeDeviceLinks')[owner['memberID']]
        self.assertEqual(set(documents), {active})
        valid = next(result['code'] for result in results if app.digest(result['code']) == active)
        stale = next(result['code'] for result in results if app.digest(result['code']) != active)
        with self.assertRaises(L.LedgerError):
            self.store.redeem_device_link(dict(code=stale))
        self.assertEqual(self.store.redeem_device_link(dict(code=valid))['memberID'], owner['memberID'])

    def test_shared_income_settlement_persists_and_rejects_stale_preview(self):
        a = self.create()
        invite = self.store.invite(a['token'])['invite']
        b = self.store.join(dict(invite=invite, memberName='상대'))
        self.entry(a['token'], amount=150000)
        old = self.snapshot(a['token'])['settlement']
        income = self.entry(a['token'], id='shared-gift', kind='income', amount=100000, note='함께 쓸 용돈')
        self.entry(a['token'], id='private-income', kind='income', scope='personal', amount=3000000)
        with self.assertRaises(L.LedgerError):
            self.store.run(a['token'], lambda s, actor: L.settle(s, actor, '2026-10', expected_revision=old['revision']))
        reopened = F.FirestoreStore(self.client, self.prefix)
        view = reopened.run(b['token'], lambda s, actor: L.snapshot(s, actor, '2026-10'))
        self.assertEqual((view['settlement']['fromID'], view['settlement']['toID'], view['settlement']['amount'], view['settlement']['count']), (b['memberID'], a['memberID'], 25000, 2))
        self.assertEqual(view['stats']['personalIncomeTotal'], 0)
        record = reopened.run(a['token'], lambda s, actor: L.settle(s, actor, '2026-10', expected_revision=view['settlement']['revision']))
        final = self.snapshot(a['token'])
        self.assertEqual(final['settlement']['count'], 0)
        self.assertEqual(next(e['settlement'] for e in final['entries'] if e['id'] == income['id']), record['id'])
        with self.assertRaises(L.LedgerError):
            self.store.run(a['token'], lambda s, actor: L.update_entry(s, actor, income['id'], dict(amount=1)))

    def test_persistence_session_validation_and_hashed_secrets(self):
        a = self.create()
        self.entry(a['token'])
        invite = self.store.invite(a['token'])['invite']
        reopened = F.FirestoreStore(self.client, self.prefix)
        self.assertEqual(reopened.run(a['token'], lambda s, actor: s['entries'][0]['amount']), 30000)
        docs = self.documents()
        self.assertIn(app.digest(a['token']), docs['sessions'])
        self.assertIn(app.digest(invite), docs['invites'])
        for secret in (a['token'], invite):
            self.assertNotIn(secret, repr(docs))
            self.assertNotIn(secret.encode(), zlib.decompress(self.household(a).get().get('data')))
        for token in ('invalid', ''):
            with self.assertRaises(app.Unauthorized):
                self.snapshot(token)
            with self.assertRaises(app.Unauthorized):
                self.store.invite(token)
        session = self.client.collection(self.prefix + '_sessions').document(app.digest(a['token']))
        session.update({'member': 'not-a-member'})
        with self.assertRaises(app.Unauthorized):
            self.snapshot(a['token'])
        session.update({'member': a['memberID']})
        self.household(a).delete()
        with self.assertRaises(app.Unauthorized):
            self.snapshot(a['token'])

    def test_private_entries_imports_and_cross_household_access(self):
        a, other = self.create(), self.create()
        invite = self.store.invite(a['token'])['invite']
        b = self.store.join(dict(invite=invite, memberName='주희'))
        secret = self.entry(a['token'], scope='personal', note='비공개 구매')
        self.store.run(a['token'], lambda s, actor: L.import_message(
            s, actor, dict(text='카드 승인 10,000원 비밀', source='sms', eventID='private-import')))
        self.assertNotIn('비공개 구매', json.dumps(self.snapshot(b['token']), ensure_ascii=False))
        self.assertEqual(self.snapshot(b['token'])['inbox'], [])
        self.assertEqual(self.snapshot(other['token'])['entries'], [])
        for token in (b['token'], other['token']):
            with self.assertRaises(L.LedgerError):
                self.store.run(token, lambda s, actor: L.update_entry(s, actor, secret['id'], {'note': '수정'}))
        self.assertEqual(self.snapshot(a['token'])['entries'][0]['note'], '비공개 구매')

    def test_reads_and_identical_id_retries_do_not_write(self):
        a = self.create()
        before = self.documents()
        self.snapshot(a['token'])
        self.assertEqual(self.documents(), before)
        results = self.race(lambda _: self.entry(a['token']))
        self.assertTrue(all(isinstance(result, dict) for result in results))
        self.assertEqual(results[0], results[1])
        before = self.documents()
        self.entry(a['token'])
        self.assertEqual(self.documents(), before)
        self.assertEqual(len(self.snapshot(a['token'])['entries']), 1)

    def test_concurrent_distinct_updates_are_not_lost(self):
        a = self.create()
        self.race(lambda index: self.entry(a['token'], id='expense-' + str(index)))
        self.assertEqual(self.snapshot(a['token'])['stats']['total'], 60000)

    def test_only_latest_invite_works_and_it_is_single_use(self):
        a = self.create()
        old = self.store.invite(a['token'])['invite']
        latest = self.store.invite(a['token'])['invite']
        before = self.documents()
        with self.assertRaises(L.LedgerError):
            self.store.join(dict(invite=old, memberName='이전 초대'))
        with self.assertRaises(L.LedgerError):
            self.store.join(dict(invite=latest, memberName=''))
        self.assertEqual(self.documents(), before)
        results = self.race(lambda index: self.store.join(dict(invite=latest, memberName='참여자' + str(index))))
        self.assertEqual(sum(isinstance(r, dict) for r in results), 1)
        self.assertEqual(sum(isinstance(r, L.LedgerError) for r in results), 1)
        winner = next(r for r in results if isinstance(r, dict))
        self.assertEqual(winner['householdID'], a['householdID'])
        self.assertEqual(len(self.snapshot(a['token'])['members']), 2)
        self.assertEqual(len(self.documents()['sessions']), 2)
        self.assertEqual(self.documents()['invites'], {})
        with self.assertRaises(L.LedgerError):
            self.store.join(dict(invite=latest, memberName='재사용'))
        with self.assertRaises(L.LedgerError):
            self.store.invite(a['token'])

    def test_racing_invites_have_one_active_hash_and_expiration(self):
        a = self.create()
        results = self.race(lambda _: self.store.invite(a['token']))
        docs = self.documents()['invites']
        self.assertEqual(len(docs), 1)
        active = self.household(a).get().get('activeInvite')
        valid = next(r['invite'] for r in results if app.digest(r['invite']) == active)
        stale = next(r['invite'] for r in results if app.digest(r['invite']) != active)
        with self.assertRaises(L.LedgerError):
            self.store.join(dict(invite=stale, memberName='이전 초대'))
        self.client.collection(self.prefix + '_invites').document(active).update({'expires': 0})
        before = self.documents()
        with self.assertRaises(L.LedgerError):
            self.store.join(dict(invite=valid, memberName='만료 초대'))
        self.assertEqual(self.documents(), before)

    def test_action_exception_leaves_every_document_unchanged(self):
        a = self.create()
        self.store.invite(a['token'])
        before = self.documents()

        def fail(state, actor):
            L.add_entry(state, actor, dict(amount=5000, note='실패', day='2026-10-20', scope='shared'))
            raise L.LedgerError('입력 실패')

        with self.assertRaises(L.LedgerError):
            self.store.run(a['token'], fail)
        self.assertEqual(self.documents(), before)

    def test_aborted_transaction_retries_without_partial_changes(self):
        from google.api_core.exceptions import Aborted

        a = self.create()
        attempts = 0

        def action(state, actor):
            nonlocal attempts
            attempts += 1
            self.assertEqual(state['entries'], [])
            entry = L.add_entry(state, actor, dict(id='retry-entry', amount=5000,
                                                  note='재시도', day='2026-10-20', scope='shared'))
            if attempts == 1:
                raise Aborted('test transaction contention')
            return entry

        self.assertEqual(self.store.run(a['token'], action)['id'], 'retry-entry')
        self.assertEqual(attempts, 2)
        self.assertEqual(len(self.snapshot(a['token'])['entries']), 1)

    def test_oversize_run_create_and_join_preserve_documents(self):
        a = self.create()
        invite = self.store.invite(a['token'])['invite']
        before = self.documents()
        for blob in ('x' * (16 * 1024 * 1024), secrets.token_hex(1_000_000)):
            with self.subTest(size=len(blob)), self.assertRaises(L.LedgerError):
                self.store.run(a['token'], lambda s, actor: s.update(blob=blob))
            self.assertEqual(self.documents(), before)
        new_household = L.new_household

        def oversized(*args):
            state = new_household(*args)
            state['blob'] = 'x' * (16 * 1024 * 1024)
            return state

        with patch.object(L, 'new_household', oversized), self.assertRaises(L.LedgerError):
            self.create()
        self.assertEqual(self.documents(), before)
        add_member = L.add_member

        def oversized_member(state, name):
            member = add_member(state, name)
            state['blob'] = 'x' * (16 * 1024 * 1024)
            return member

        with patch.object(L, 'add_member', oversized_member), self.assertRaises(L.LedgerError):
            self.store.join(dict(invite=invite, memberName='주희'))
        self.assertEqual(self.documents(), before)
        self.store.join(dict(invite=invite, memberName='주희'))


    def test_recurring_occurrence_race_no_write_reads_and_retries(self):
        a = self.create()
        recurring = self.store.run(a['token'], lambda s, actor: L.add_recurring(s, actor,
            dict(note='정기 결제', amount=30000, scope='shared', payer=actor, funding='personal',
                 category=s['categories'][0]['id'], startDay='2026-01-01', dayOfMonth=31)))
        before = self.documents()
        self.snapshot(a['token'])
        self.assertEqual(self.documents(), before)
        results = self.race(lambda index: self.entry(a['token'], id='occurrence-' + str(index),
            day='2026-10-31', recurringID=recurring['id'], recurringMonth='2026-10'))
        self.assertTrue(all(isinstance(result, dict) for result in results), results)
        self.assertEqual(results[0], results[1])
        before = self.documents()
        self.assertEqual(self.entry(a['token'], id='retry-new-id', day='2026-10-31',
            recurringID=recurring['id'], recurringMonth='2026-10'), results[0])
        self.assertEqual(self.documents(), before)
        view = self.snapshot(a['token'])
        self.assertEqual(len(view['entries']), 1)
        self.assertEqual(view['recurringPayments'][0]['entryID'], results[0]['id'])


if __name__ == '__main__':
    unittest.main()
