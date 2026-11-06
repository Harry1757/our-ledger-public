"""Local development server. Use a TLS reverse proxy before remote use."""
import argparse
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import secrets
import sqlite3
import time
from urllib.parse import parse_qs, urlsplit
import ledger as L
from auth import Unauthorized, WEB_SESSION_SECONDS, digest
from firestore_store import DEVICE_LINK_ERROR, DEVICE_LINK_SECONDS, device_code_hash, new_device_code


class Store:
    def __init__(self, path):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self.connect() as db:
            db.executescript('''
                CREATE TABLE IF NOT EXISTS households (id TEXT PRIMARY KEY, data TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS sessions (hash TEXT PRIMARY KEY, household TEXT NOT NULL, member TEXT NOT NULL, expires INTEGER);
                CREATE TABLE IF NOT EXISTS invites (hash TEXT PRIMARY KEY, household TEXT NOT NULL, expires INTEGER NOT NULL);
                CREATE TABLE IF NOT EXISTS device_links (
                    hash TEXT PRIMARY KEY, household TEXT NOT NULL, member TEXT NOT NULL,
                    session TEXT NOT NULL, expires INTEGER NOT NULL, UNIQUE(household, member));
                CREATE INDEX IF NOT EXISTS device_links_expires ON device_links(expires);
            ''')
            db.execute('BEGIN IMMEDIATE')
            if 'expires' not in {row[1] for row in db.execute('PRAGMA table_info(sessions)')}:
                db.execute('ALTER TABLE sessions ADD COLUMN expires INTEGER')
        self.path.chmod(0o600)

    @contextmanager
    def connect(self):
        db = sqlite3.connect(self.path, timeout=15, isolation_level=None)
        try:
            db.execute('BEGIN IMMEDIATE')
            yield db
            db.commit()
        except Exception:
            db.rollback()
            raise
        finally:
            db.close()

    def create(self, payload):
        state = L.new_household(payload.get('name'), payload.get('memberName'), payload.get('mode'))
        token = secrets.token_urlsafe(32)
        member_id = state['members'][0]['id']
        with self.connect() as db:
            db.execute('INSERT INTO households VALUES (?, ?)', (state['id'], json.dumps(state, ensure_ascii=False)))
            db.execute('INSERT INTO sessions (hash, household, member) VALUES (?, ?, ?)', (digest(token), state['id'], member_id))
        return dict(token=token, memberID=member_id, householdID=state['id'])

    def _household(self, db, session_hash, native_only=False):
        member = db.execute('SELECT household, member, expires FROM sessions WHERE hash=?', (session_hash,)).fetchone()
        if not member or (member[2] is not None and (native_only or member[2] <= time.time())):
            raise Unauthorized()
        household_id, actor = member[:2]
        household = db.execute('SELECT data FROM households WHERE id=?', (household_id,)).fetchone()
        if not household:
            raise Unauthorized()
        state = json.loads(household[0])
        if state['id'] != household_id or not any(m['id'] == actor for m in state['members']):
            raise Unauthorized()
        return state, actor

    def run(self, token, action):
        with self.connect() as db:
            state, actor = self._household(db, digest(token))
            household_id = state['id']
            before = json.dumps(state, ensure_ascii=False)
            result = action(state, actor)
            data = json.dumps(state, ensure_ascii=False)
            if data != before:
                db.execute('UPDATE households SET data=? WHERE id=?', (data, household_id))
            return result

    def invite(self, token):
        household = self.run(token, lambda s, a: s['id'] if len(s['members']) < 2 else None)
        if not household:
            raise L.LedgerError('두 사람이 이미 참여하고 있어요.')
        invite = secrets.token_urlsafe(32)
        with self.connect() as db:
            db.execute('DELETE FROM invites WHERE household=? OR expires<?', (household, int(time.time())))
            db.execute('INSERT INTO invites VALUES (?, ?, ?)', (digest(invite), household, int(time.time()) + 86400))
        return dict(invite=invite, expiresIn=86400)

    def device_link(self, token):
        code = new_device_code()
        with self.connect() as db:
            state, actor = self._household(db, digest(token), native_only=True)
            now = int(time.time())
            db.execute('DELETE FROM device_links WHERE hash IN '
                       '(SELECT hash FROM device_links WHERE expires<=? ORDER BY expires LIMIT 100)', (now,))
            db.execute('DELETE FROM device_links WHERE household=? AND member=?', (state['id'], actor))
            db.execute('INSERT INTO device_links VALUES (?, ?, ?, ?, ?)',
                       (digest(code), state['id'], actor, digest(token), now + DEVICE_LINK_SECONDS))
        return dict(code=code, expiresIn=DEVICE_LINK_SECONDS)

    def redeem_device_link(self, payload):
        code_hash = device_code_hash(payload.get('code'))
        with self.connect() as db:
            link = db.execute('SELECT household, member, session, expires FROM device_links WHERE hash=?',
                              (code_hash,)).fetchone()
            if not link or link[3] <= time.time():
                raise L.LedgerError(DEVICE_LINK_ERROR)
            try:
                state, actor = self._household(db, link[2], native_only=True)
            except Unauthorized:
                raise L.LedgerError(DEVICE_LINK_ERROR) from None
            if (state['id'], actor) != link[:2]:
                raise L.LedgerError(DEVICE_LINK_ERROR)
            token = secrets.token_urlsafe(32)
            db.execute('INSERT INTO sessions (hash, household, member, expires) VALUES (?, ?, ?, ?)',
                       (digest(token), state['id'], actor, int(time.time()) + WEB_SESSION_SECONDS))
            db.execute('DELETE FROM device_links WHERE hash=?', (code_hash,))
        return dict(token=token, memberID=actor, householdID=state['id'])

    def revoke_session(self, token):
        with self.connect() as db:
            db.execute('DELETE FROM sessions WHERE hash=?', (digest(token),))
        return dict(ok=True)

    def join(self, payload):
        invite = L.text(payload.get('invite'), '초대 링크', 200)
        with self.connect() as db:
            row = db.execute('SELECT household, expires FROM invites WHERE hash=?', (digest(invite),)).fetchone()
            if not row or row[1] < time.time():
                raise L.LedgerError('사용했거나 만료된 초대예요. 새 링크를 받아 주세요.')
            state = json.loads(db.execute('SELECT data FROM households WHERE id=?', (row[0],)).fetchone()[0])
            member = L.add_member(state, payload.get('memberName'))
            token = secrets.token_urlsafe(32)
            db.execute('INSERT INTO sessions (hash, household, member) VALUES (?, ?, ?)', (digest(token), state['id'], member['id']))
            db.execute('UPDATE households SET data=? WHERE id=?', (json.dumps(state, ensure_ascii=False), state['id']))
            db.execute('DELETE FROM invites WHERE hash=?', (digest(invite),))
        return dict(token=token, memberID=member['id'], householdID=state['id'])


def settings(state, actor, payload):
    member = next(m for m in state['members'] if m['id'] == actor)
    for field in ('bank', 'account', 'holder'):
        if field in payload:
            if not isinstance(payload[field], str) or len(payload[field]) > 100:
                raise L.LedgerError('계좌 정보를 확인해 주세요.')
            member[field] = payload[field].strip()
    if 'budget' in payload:
        state['budget'] = L.money(payload['budget'], allow_zero=True)
    if 'mode' in payload and payload['mode'] != state['mode']:
        if state['entries']:
            raise L.LedgerError('기록이 있는 가계부의 관리 방식은 변경할 수 없어요.')
        if payload['mode'] not in ('pool', 'separate'):
            raise L.LedgerError('관리 방식을 확인해 주세요.')
        state['mode'] = payload['mode']
    return dict(ok=True)


def make_server(host, port, store, setup_code='', review_setup_code='', review_setup_expires=0):
    class Handler(BaseHTTPRequestHandler):
        server_version = 'OurLedger'

        def log_message(self, *args):
            pass  # Financial payloads and tokens must never enter access logs.

        def respond(self, status, value):
            data = json.dumps(value, ensure_ascii=False).encode()
            self.send_response(status)
            self.send_header('Content-Type', 'application/json; charset=utf-8')
            self.send_header('Content-Length', str(len(data)))
            self.send_header('Cache-Control', 'no-store')
            self.send_header('X-Content-Type-Options', 'nosniff')
            self.end_headers()
            self.wfile.write(data)

        def handle_request(self):
            try:
                route = urlsplit(self.path)
                path = route.path
                payload = {}
                if self.command != 'GET':
                    length = int(self.headers.get('Content-Length', 0))
                    bodyless = (self.command, path) in (('POST', '/device-links'), ('DELETE', '/session'))
                    if not 0 < length <= 32768 and not (length == 0 and bodyless):
                        raise L.LedgerError('요청 크기를 확인해 주세요.')
                    payload = json.loads(self.rfile.read(length)) if length else {}
                    if not isinstance(payload, dict):
                        raise L.LedgerError('잘못된 요청 형식이에요.')
                if self.command == 'GET' and path == '/health':
                    return self.respond(200, dict(ok=True))
                if self.command == 'POST' and path == '/households':
                    supplied = payload.get('setupCode', '')
                    owner_code = isinstance(supplied, str) and bool(self.server.setup_code) and secrets.compare_digest(
                        supplied.encode(), self.server.setup_code.encode())
                    review_code = (isinstance(supplied, str) and bool(self.server.review_setup_code)
                                   and time.time() < self.server.review_setup_expires
                                   and secrets.compare_digest(supplied.encode(), self.server.review_setup_code.encode()))
                    if (self.server.setup_code or self.server.review_setup_code) and not (owner_code or review_code):
                        return self.respond(403, dict(error='가계부 가입 코드를 확인해 주세요.'))
                    return self.respond(200, store.create(payload))
                if self.command == 'POST' and path == '/join':
                    return self.respond(200, store.join(payload))
                if self.command == 'POST' and path == '/device-links/redeem':
                    return self.respond(200, store.redeem_device_link(payload))
                auth = self.headers.get('Authorization', '')
                if not auth.startswith('Bearer ') or len(auth) > 250:
                    raise Unauthorized()
                token = auth[7:]
                if not token:
                    raise Unauthorized()
                if self.command == 'DELETE' and path == '/session':
                    return self.respond(200, store.revoke_session(token))
                if self.command == 'POST' and path == '/invite':
                    return self.respond(200, store.invite(token))
                if self.command == 'POST' and path == '/device-links':
                    return self.respond(200, store.device_link(token))

                def action(state, actor):
                    if self.command == 'GET' and path == '/state':
                        month = parse_qs(route.query).get('month', [L.now()[:7]])[0]
                        return L.snapshot(state, actor, month)
                    if self.command == 'POST':
                        if path == '/recurring':
                            return L.add_recurring(state, actor, payload)
                        if path.startswith('/recurring/') and path.endswith('/link') and len(path.split('/')) == 4:
                            return L.link_recurring(state, actor, path.split('/')[2], payload)
                        if path == '/entries':
                            return L.add_entry(state, actor, payload)
                        if path == '/imports/preview':
                            return L.parse_message(payload.get('text'),
                                                   review_only=L.review_only_option(payload, allow_missing_source=True))
                        if path == '/imports':
                            return L.import_message(state, actor, payload)
                        if path == '/categories':
                            return L.add_category(state, payload.get('name'), payload.get('keywords', ''))
                        if path == '/settle':
                            month = L.text(payload.get('month'), '정산 월', 7)
                            L.snapshot(state, actor, month)
                            revision = L.text(payload.get('revision'), '확인한 정산 정보', 64)
                            return L.settle(state, actor, month, payload.get('memberID'), revision,
                                            payload.get('importID'), payload.get('requestID'))
                        if path.startswith('/imports/') and path.endswith('/merge'):
                            return L.resolve_import(state, actor, path.split('/')[2], payload.get('targetID'))
                    if self.command == 'PATCH':
                        if path.startswith('/recurring/') and len(path.split('/')) == 3:
                            return L.update_recurring(state, actor, path.split('/')[-1], payload)
                        if path == '/settings':
                            return settings(state, actor, payload)
                        if path.startswith('/entries/'):
                            return L.update_entry(state, actor, path.split('/')[-1], payload)
                    if self.command == 'DELETE':
                        if path.startswith('/recurring/') and len(path.split('/')) == 3:
                            return L.delete_recurring(state, actor, path.split('/')[-1])
                        if path.startswith('/entries/'):
                            return L.update_entry(state, actor, path.split('/')[-1], {'voided': True})
                        if path.startswith('/imports/'):
                            return L.resolve_import(state, actor, path.split('/')[-1])
                    raise FileNotFoundError()

                self.respond(200, store.run(token, action))
            except Unauthorized:
                self.respond(401, dict(error='가계부 연결 정보가 필요해요.'))
            except FileNotFoundError:
                self.respond(404, dict(error='요청한 기능을 찾을 수 없어요.'))
            except (L.LedgerError, ValueError, TypeError, OverflowError, KeyError) as error:
                message = str(error) if isinstance(error, L.LedgerError) else '입력 내용을 확인해 주세요.'
                self.respond(400, dict(error=message))
            except Exception:
                self.respond(500, dict(error='저장하지 못했어요. 잠시 후 다시 시도해 주세요.'))

        do_GET = do_POST = do_PATCH = do_DELETE = handle_request

    server = ThreadingHTTPServer((host, port), Handler)
    server.setup_code = setup_code
    server.review_setup_code = review_setup_code
    server.review_setup_expires = review_setup_expires
    return server


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='우리 가계부 서버')
    parser.add_argument('--host', default='127.0.0.1')
    parser.add_argument('--port', type=int, default=int(os.environ.get('PORT', '8817')))
    parser.add_argument('--db', default=str(Path(__file__).parent / 'ledger.sqlite'))
    parser.add_argument('--store', choices=('sqlite', 'firestore'), default=os.environ.get('LEDGER_STORAGE', 'sqlite'))
    args = parser.parse_args()
    setup_code = os.environ.get('LEDGER_SETUP_CODE', '')
    review_setup_code = os.environ.get('LEDGER_REVIEW_SETUP_CODE', '')
    review_setup_expires = int(os.environ.get('LEDGER_REVIEW_SETUP_EXPIRES', '0'))
    if review_setup_code and (len(review_setup_code) < 16 or review_setup_expires <= 0):
        parser.error('심사용 가입 코드는 16자 이상이며 만료 시각이 필요합니다.')
    if args.store == 'firestore':
        if len(setup_code) < 16:
            parser.error('클라우드 서버에는 16자 이상의 LEDGER_SETUP_CODE가 필요합니다.')
        from firestore_store import FirestoreStore
        store = FirestoreStore()
    else:
        store = Store(args.db)
    server = make_server(args.host, args.port, store, setup_code, review_setup_code, review_setup_expires)
    print(f'우리 가계부 서버: http://{args.host}:{args.port}', flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
