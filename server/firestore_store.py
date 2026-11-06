"""Firestore persistence for the existing ledger and Store interface."""
import json
import secrets
import time
import zlib

from auth import Unauthorized, WEB_SESSION_SECONDS, digest
import ledger as L


MAX_COMPRESSED_BYTES = 900_000
MAX_RAW_BYTES = 16 * 1024 * 1024
DEVICE_CODE_ALPHABET = '23456789ABCDEFGHJKMNPQRSTVWXYZ'
DEVICE_LINK_SECONDS = 300
DEVICE_LINK_ERROR = '사용했거나 만료된 연결 코드예요. 휴대폰에서 새 코드를 받아 주세요.'


def new_device_code():
    # 16 independent choices from 30 symbols provide more than 78 bits of entropy.
    return ''.join(secrets.choice(DEVICE_CODE_ALPHABET) for _ in range(16))


def device_code_hash(value):
    if not isinstance(value, str) or len(value) > 64 or not value.isascii():
        raise L.LedgerError(DEVICE_LINK_ERROR)
    code = value.replace(' ', '').replace('-', '').upper()
    if len(code) != 16 or any(char not in DEVICE_CODE_ALPHABET for char in code):
        raise L.LedgerError(DEVICE_LINK_ERROR)
    return digest(code)


def _encode(state):
    raw = json.dumps(state, ensure_ascii=False, separators=(',', ':'), sort_keys=True).encode('utf-8')
    if len(raw) > MAX_RAW_BYTES:
        raise L.LedgerError('가계부 저장 용량을 초과했어요.')
    data = zlib.compress(raw)
    if len(data) > MAX_COMPRESSED_BYTES:
        raise L.LedgerError('가계부 저장 용량을 초과했어요.')
    return data


def _decode(data):
    if not isinstance(data, bytes) or len(data) > MAX_COMPRESSED_BYTES:
        raise L.LedgerError('저장된 가계부 크기를 확인해 주세요.')
    try:
        decoder = zlib.decompressobj()
        raw = decoder.decompress(data, MAX_RAW_BYTES + 1)
        if len(raw) > MAX_RAW_BYTES or not decoder.eof or decoder.unused_data:
            raise L.LedgerError('저장된 가계부 크기를 확인해 주세요.')
        state = json.loads(raw.decode('utf-8'))
        if not isinstance(state, dict):
            raise L.LedgerError('저장된 가계부를 확인해 주세요.')
        return state
    except (zlib.error, UnicodeError, ValueError) as error:
        raise L.LedgerError('저장된 가계부를 확인해 주세요.') from error


class FirestoreStore:
    def __init__(self, client=None, prefix='ourledger'):
        # Keep the SQLite server and codec tests usable without the optional SDK.
        from google.api_core.exceptions import Aborted
        from google.api_core.retry import Retry, if_exception_type
        from google.cloud import firestore

        if not isinstance(prefix, str) or not prefix or '/' in prefix:
            raise ValueError('Invalid Firestore collection prefix')
        self.client = client if client is not None else firestore.Client()
        self.households = self.client.collection(prefix + '_households')
        self.sessions = self.client.collection(prefix + '_sessions')
        self.invites = self.client.collection(prefix + '_invites')
        self.device_links = self.client.collection(prefix + '_device_links')
        self._transactional = firestore.transactional
        # The SDK retries commit conflicts, but Aborted during reads also needs a fresh transaction.
        self._retry_aborted = Retry(predicate=if_exception_type(Aborted),
                                    initial=0.05, maximum=1, timeout=15)

    def _household(self, transaction, session_hash, native_only=False):
        session = self.sessions.document(session_hash).get(transaction=transaction)
        if not session.exists:
            raise Unauthorized()
        member = session.to_dict()
        expires = member.get('expires')
        if expires is not None and (native_only or expires <= time.time()):
            raise Unauthorized()
        reference = self.households.document(member['household'])
        household = reference.get(transaction=transaction)
        if not household.exists:
            raise Unauthorized()
        document = household.to_dict()
        state = _decode(document['data'])
        actor = member['member']
        if state['id'] != reference.id or not any(m['id'] == actor for m in state['members']):
            raise Unauthorized()
        return reference, document, state, actor

    def create(self, payload):
        state = L.new_household(payload.get('name'), payload.get('memberName'), payload.get('mode'))
        data = _encode(state)
        token = secrets.token_urlsafe(32)
        member_id = state['members'][0]['id']

        @self._transactional
        def create(transaction):
            transaction.create(self.households.document(state['id']), {'data': data, 'activeInvite': None})
            transaction.create(self.sessions.document(digest(token)), {'household': state['id'], 'member': member_id})

        self._retry_aborted(create)(self.client.transaction())
        return dict(token=token, memberID=member_id, householdID=state['id'])

    def run(self, token, action):
        """Actions may be retried by Firestore; they must only mutate the supplied state."""
        @self._transactional
        def run(transaction):
            reference, document, state, actor = self._household(transaction, digest(token))
            result = action(state, actor)
            data = _encode(state)
            if data != document['data']:
                transaction.update(reference, {'data': data})
            return result

        return self._retry_aborted(run)(self.client.transaction())

    def invite(self, token):
        invite = secrets.token_urlsafe(32)
        invite_hash = digest(invite)

        @self._transactional
        def issue(transaction):
            reference, document, state, actor = self._household(transaction, digest(token))
            if len(state['members']) >= 2:
                raise L.LedgerError('두 사람이 이미 참여하고 있어요.')
            previous = document.get('activeInvite')
            if previous:
                transaction.delete(self.invites.document(previous))
            transaction.create(self.invites.document(invite_hash),
                               {'household': state['id'], 'expires': int(time.time()) + 86400})
            transaction.update(reference, {'activeInvite': invite_hash})

        self._retry_aborted(issue)(self.client.transaction())
        return dict(invite=invite, expiresIn=86400)

    def device_link(self, token):
        code = new_device_code()
        code_hash = digest(code)

        @self._transactional
        def issue(transaction):
            reference, document, state, actor = self._household(transaction, digest(token), native_only=True)
            active = dict(document.get('activeDeviceLinks', {}))
            previous = active.get(actor)
            # At most one retained link per member; replacement also removes expired links.
            if previous:
                transaction.delete(self.device_links.document(previous))
            transaction.create(self.device_links.document(code_hash), dict(
                household=state['id'], member=actor, session=digest(token),
                expires=int(time.time()) + DEVICE_LINK_SECONDS))
            active[actor] = code_hash
            transaction.update(reference, {'activeDeviceLinks': active})

        self._retry_aborted(issue)(self.client.transaction())
        return dict(code=code, expiresIn=DEVICE_LINK_SECONDS)

    def redeem_device_link(self, payload):
        code_hash = device_code_hash(payload.get('code'))
        token = secrets.token_urlsafe(32)

        @self._transactional
        def redeem(transaction):
            link_reference = self.device_links.document(code_hash)
            link = link_reference.get(transaction=transaction)
            if not link.exists or link.get('expires') <= time.time():
                raise L.LedgerError(DEVICE_LINK_ERROR)
            try:
                reference, document, state, actor = self._household(transaction, link.get('session'), native_only=True)
            except Unauthorized:
                raise L.LedgerError(DEVICE_LINK_ERROR) from None
            active = dict(document.get('activeDeviceLinks', {}))
            if (state['id'] != link.get('household') or actor != link.get('member')
                    or active.get(actor) != code_hash):
                raise L.LedgerError(DEVICE_LINK_ERROR)
            transaction.create(self.sessions.document(digest(token)), dict(
                household=state['id'], member=actor, expires=int(time.time()) + WEB_SESSION_SECONDS))
            transaction.delete(link_reference)
            del active[actor]
            transaction.update(reference, {'activeDeviceLinks': active})
            return dict(token=token, memberID=actor, householdID=state['id'])

        return self._retry_aborted(redeem)(self.client.transaction())

    def revoke_session(self, token):
        @self._transactional
        def revoke(transaction):
            transaction.delete(self.sessions.document(digest(token)))
            return dict(ok=True)

        return self._retry_aborted(revoke)(self.client.transaction())

    def join(self, payload):
        invite = L.text(payload.get('invite'), '초대 링크', 200)
        invite_hash = digest(invite)
        token = secrets.token_urlsafe(32)

        @self._transactional
        def join(transaction):
            invite_reference = self.invites.document(invite_hash)
            invitation = invite_reference.get(transaction=transaction)
            if not invitation.exists or invitation.get('expires') <= time.time():
                raise L.LedgerError('사용했거나 만료된 초대예요. 새 링크를 받아 주세요.')
            reference = self.households.document(invitation.get('household'))
            household = reference.get(transaction=transaction)
            if not household.exists or household.get('activeInvite') != invite_hash:
                raise L.LedgerError('사용했거나 만료된 초대예요. 새 링크를 받아 주세요.')
            state = _decode(household.get('data'))
            if state['id'] != reference.id:
                raise L.LedgerError('저장된 가계부를 확인해 주세요.')
            member = L.add_member(state, payload.get('memberName'))
            data = _encode(state)
            transaction.create(self.sessions.document(digest(token)),
                               {'household': state['id'], 'member': member['id']})
            transaction.update(reference, {'data': data, 'activeInvite': None})
            transaction.delete(invite_reference)
            return dict(token=token, memberID=member['id'], householdID=state['id'])

        return self._retry_aborted(join)(self.client.transaction())
