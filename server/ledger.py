"""Two-person KRW ledger. All money is integer won; no AI or network calls."""
import calendar
import copy
import hashlib
import json
from datetime import date, datetime, timedelta, timezone
import re
import uuid

KST = timezone(timedelta(hours=9))


class LedgerError(ValueError):
    pass


def uid():
    return str(uuid.uuid4())


def now():
    return datetime.now(KST).isoformat(timespec='seconds')


def text(value, label, limit=120):
    if not isinstance(value, str) or not value.strip() or len(value) > limit:
        raise LedgerError(f'{label}을(를) 확인해 주세요.')
    return value.strip()


def money(value, allow_zero=False):
    if type(value) is not int or value < (0 if allow_zero else 1) or value > 100_000_000_000:
        raise LedgerError('금액은 1원 이상 1천억 원 이하의 정수로 입력해 주세요.')
    return value


def normal(value):
    return re.sub(r'\s+', '', value).casefold()


def new_household(name, member_name, mode):
    if mode not in ('separate', 'pool'):
        raise LedgerError('생활비 관리 방식을 선택해 주세요.')
    state = dict(id=uid(), name=text(name, '가계부 이름'), mode=mode, budget=0,
                 members=[], categories=[], rules={}, entries=[], imports=[], settlements=[])
    add_member(state, member_name)
    for name, keywords in [('식비', '식사,점심,저녁,아침,식당,배달,김밥,삼겹살'),
                           ('장보기', '장보기,마트,식료품,이마트,코스트코,반찬'),
                           ('생활용품', '세제,휴지,생활용품,청소'), ('교통', '택시,주차,교통,주유,하이패스'),
                           ('주거', '월세,관리비,가스요금,전기요금'), ('카페', '카페,커피,스타벅스'),
                           ('여행', '여행,숙소,호텔,캠핑'), ('미분류', '')]:
        add_category(state, name, keywords)
    return state


def add_member(state, name):
    if len(state['members']) >= 2:
        raise LedgerError('두 사람이 이미 참여한 가계부예요.')
    member = dict(id=uid(), name=text(name, '이름', 30), bank='', account='', holder='')
    state['members'].append(member)
    return member


def add_category(state, name, keywords=''):
    name = text(name, '카테고리', 30)
    if any(normal(c['name']) == normal(name) for c in effective_categories(state)):
        raise LedgerError('같은 이름의 카테고리가 있어요.')
    if not isinstance(keywords, str) or len(keywords) > 300:
        raise LedgerError('분류 단어를 300자 이내로 입력해 주세요.')
    item = dict(id=uid(), name=name, keywords=[k.strip() for k in keywords.split(',') if k.strip()])
    state['categories'].append(item)
    return item


def effective_categories(state):
    # Extend existing households at lookup time without rewriting their categories or transactions.
    additional = {'식비': ('치킨', '피자', '햄버거', '국밥', '돈까스', '코카콜라', '제로콜라', '빵집', '베이커리'), '장보기': ('슈퍼마켓',),
                  '생활용품': ('다이소',), '교통': ('지하철', '버스', '기차'),
                  '카페': ('이디야', '빽다방', '투썸'), '의료': ('약국', '감기약', '비염약')}
    categories = list(state['categories'])
    if not any(normal(c['name']) == '의료' for c in categories):
        # A stable virtual category supports old households without a write-on-read migration.
        categories.append(dict(id=str(uuid.uuid5(uuid.NAMESPACE_URL, 'ourledger:' + state['id'] + ':medical')),
                               name='의료', keywords=[]))
    return [{**c, 'keywords': list(dict.fromkeys(k for k in (*c['keywords'], *additional.get(normal(c['name']), ()))
                                              if normal(k)))} for c in categories]


def classification_rules(state, actor, categories):
    # Exact defaults avoid matching 약 inside 예약/계약 and use the existing client rule format.
    defaults = {'식비': ('콜라', '빵'), '의료': ('약', '코약'),
                '교통': ('티머니충전', '교통카드충전', '전기차충전')}
    rules = {note: c['id'] for c in categories for note in defaults.get(normal(c['name']), ())
             if not any(normal(k) in note for candidate in categories for k in candidate['keywords'])}
    prefix = actor + ':'
    valid = {c['id'] for c in categories if c['name'] != '미분류'}
    rules.update({k[len(prefix):]: v for k, v in state.get('rules', {}).items() if k.startswith(prefix) and v in valid})
    return rules


def category_for(state, actor, note):
    normalized_note = normal(note)
    categories = effective_categories(state)
    rule = classification_rules(state, actor, categories).get(normalized_note)
    if rule:
        return rule
    matches = [c for c in categories if any(normal(k) in normalized_note for k in c['keywords'])]
    return matches[0]['id'] if len(matches) == 1 else next(c['id'] for c in categories if c['name'] == '미분류')


def valid_day(value):
    try:
        if not isinstance(value, str) or not re.fullmatch(r'\d{4}-\d{2}-\d{2}', value):
            raise ValueError()
        date.fromisoformat(value)
    except (ValueError, TypeError):
        raise LedgerError('날짜를 확인해 주세요.')
    return value


def visible(entry, actor):
    return not entry.get('voided') and (entry['scope'] == 'shared' or entry['owner'] == actor)


def owned_recurring(state, actor, recurring_id):
    recurring_id = text(recurring_id, '반복 결제 식별자', 80)
    recurring = next((r for r in state.get('recurringPayments', [])
                      if r['id'] == recurring_id and r['owner'] == actor and not r.get('deleted')), None)
    if not recurring:
        raise LedgerError('내 반복 결제만 변경하거나 기록할 수 있어요.')
    return recurring


def recurring_due(recurring, month):
    first = valid_day(text(month, '반복 결제 월', 7) + '-01')
    year, mo = map(int, first[:7].split('-'))
    due = f"{month}-{min(recurring['dayOfMonth'], calendar.monthrange(year, mo)[1]):02}"
    return due if recurring['active'] and not recurring.get('deleted') and due >= recurring['startDay'] else None


def recurring_entry(state, recurring_id, month):
    return next((e for e in state['entries'] if e.get('recurringID') == recurring_id
                 and e.get('recurringMonth') == month and e['kind'] == 'expense' and not e.get('voided')), None)


def recurring_values(state, actor, payload):
    start = valid_day(payload.get('startDay'))
    day = payload.get('dayOfMonth')
    active = payload.get('active', True)
    if type(day) is not int or not 1 <= day <= 31 or type(active) is not bool:
        raise LedgerError('매월 결제일과 사용 여부를 확인해 주세요.')
    # Validate with the ordinary expense path without saving entries or learning classification rules.
    trial = copy.deepcopy(state)
    entry = add_entry(trial, actor, {**{k: payload[k] for k in
        ('note', 'amount', 'scope', 'category', 'payer', 'funding') if k in payload}, 'day': start})
    return {**{k: entry[k] for k in ('note', 'amount', 'scope', 'category', 'payer', 'funding')},
            'startDay': start, 'dayOfMonth': day, 'active': active}


def add_recurring(state, actor, payload):
    recurring_id = text(payload['id'], '반복 결제 식별자', 80) if 'id' in payload else uid()
    values = recurring_values(state, actor, payload)
    existing = next((r for r in state.get('recurringPayments', []) if r['id'] == recurring_id), None)
    if existing:
        if (existing['owner'] != actor or existing.get('deleted')
                or any(existing[k] != v for k, v in values.items())):
            raise LedgerError('반복 결제 식별자가 중복되었어요. 변경은 기존 일정을 수정해 주세요.')
        return existing
    recurring = dict(id=recurring_id, owner=actor, **values)
    state.setdefault('recurringPayments', []).append(recurring)
    return recurring


def update_recurring(state, actor, recurring_id, payload):
    recurring = owned_recurring(state, actor, recurring_id)
    values = recurring_values(state, actor, {**recurring, **{k: v for k, v in payload.items() if k in
        ('note', 'amount', 'scope', 'category', 'payer', 'funding', 'startDay', 'dayOfMonth', 'active')}})
    recurring.update(values)
    return recurring


def delete_recurring(state, actor, recurring_id):
    recurring = owned_recurring(state, actor, recurring_id)
    recurring.update(deleted=True, active=False)
    return dict(ok=True)


def link_recurring(state, actor, recurring_id, payload):
    recurring = owned_recurring(state, actor, recurring_id)
    month = payload.get('month')
    if not recurring_due(recurring, month):
        raise LedgerError('이 월에는 예정된 반복 결제가 없어요.')
    entry_id = text(payload.get('entryID'), '연결할 거래', 80)
    entry = next((e for e in state['entries'] if e['id'] == entry_id and e['owner'] == actor
                  and not e.get('voided')), None)
    existing = recurring_entry(state, recurring['id'], month)
    if existing and existing['id'] == entry_id:
        return existing
    if (not entry or entry['kind'] != 'expense' or entry['day'][:7] != month
            or any(entry[k] != recurring[k] for k in ('scope', 'payer', 'funding', 'amount'))
            or entry.get('recurringID') or existing):
        raise LedgerError('같은 월·범위·결제자·자금·금액의 내 지출만 연결할 수 있어요.')
    entry.update(recurringID=recurring['id'], recurringMonth=month)
    return entry


def scheduled_occurrence(state, actor, payload):
    recurring_id = text(payload.get('recurringID'), '반복 결제 식별자', 80)
    month = payload.get('recurringMonth')
    recurring = owned_recurring(state, actor, recurring_id)
    due = recurring_due(recurring, month)
    actual_day = valid_day(payload.get('day'))
    if (not due or actual_day[:7] != month or actual_day < recurring['startDay']
            or payload.get('kind', 'expense') != 'expense'
            or payload.get('refundOf') or payload.get('importID')
            or payload.get('scope') != recurring['scope']
            or payload.get('payer', actor) != recurring['payer']
            or payload.get('funding', 'personal') != recurring['funding']):
        raise LedgerError('예정일과 현재 반복 결제의 범위·결제자·자금을 확인해 주세요. 이미 기록한 알림은 연결해 주세요.')
    by_id = next((e for e in state['entries'] if e['id'] == payload.get('id')), None)
    if by_id and (by_id['owner'] != actor or by_id.get('voided') or by_id['kind'] != 'expense'
                  or by_id.get('recurringID') != recurring_id or by_id.get('recurringMonth') != month):
        raise LedgerError('반복 결제를 새 거래 식별자로 다시 확인해 주세요.')
    return recurring, recurring_entry(state, recurring_id, month)


def add_entry(state, actor, payload):
    scheduled = 'recurringID' in payload or 'recurringMonth' in payload
    recurring, occurrence = scheduled_occurrence(state, actor, payload) if scheduled else (None, None)
    imported = None
    if payload.get('importID'):
        imported = next((i for i in state['imports'] if i['id'] == payload['importID'] and i['owner'] == actor), None)
        if not imported:
            raise LedgerError('내 알림만 기록할 수 있어요.')
        if imported.get('entryID'):
            existing = next((e for e in state['entries'] if e['id'] == imported['entryID'] and visible(e, actor)), None)
            if not existing:
                raise LedgerError('기존 기록을 확인할 수 없어요. 가계부에서 다시 확인해 주세요.')
            return existing
        if imported['status'] != 'pending':
            raise LedgerError('이미 제외하거나 병합한 알림이에요.')
    scope = payload.get('scope')
    kind = payload.get('kind', 'expense')
    funding = payload.get('funding', 'personal')
    payer = payload.get('payer', actor)
    if scope not in ('shared', 'personal') or kind not in ('expense', 'refund', 'deposit', 'income') or funding not in ('personal', 'fund'):
        raise LedgerError('거래 종류와 사용 범위를 확인해 주세요.')
    if payer not in [m['id'] for m in state['members']] or (scope == 'personal' and payer != actor):
        raise LedgerError('결제자를 확인해 주세요.')
    if (funding == 'fund' or kind == 'deposit') and (state['mode'] != 'pool' or scope != 'shared'):
        raise LedgerError('공동자금 방식의 공용 내역에만 사용할 수 있어요.')
    if kind == 'deposit':
        funding = 'fund'
    note = text(payload.get('note'), '사용 내역')
    categories = effective_categories(state)
    category = payload.get('category') or category_for(state, actor, note)
    if category not in [c['id'] for c in categories]:
        raise LedgerError('카테고리를 확인해 주세요.')
    item = dict(id=payload.get('id') or uid(), owner=actor, payer=payer, scope=scope, kind=kind,
                funding=funding, amount=money(payload.get('amount')), note=note, category=category,
                day=valid_day(payload.get('day')), settlement=None, createdAt=now(), voided=False,
                importID=imported['id'] if imported else None)
    if not isinstance(item['id'], str) or len(item['id']) > 80:
        raise LedgerError('거래 식별자를 확인해 주세요.')
    if scheduled:
        item.update(recurringID=recurring['id'], recurringMonth=payload['recurringMonth'])
        if occurrence:
            return occurrence
    existing = next((e for e in state['entries'] if e['id'] == item['id']), None)
    if existing:
        if existing['owner'] != actor:
            raise LedgerError('거래 식별자가 중복되었어요.')
        if existing.get('voided'):
            raise LedgerError('삭제된 기록이에요. 새 거래로 다시 입력해 주세요.')
        return existing
    if imported and scope == 'shared':
        for other in state['imports']:
            if other['id'] == imported['id'] or not other.get('entryID') or not same_reference(imported, other):
                continue
            match = next((e for e in state['entries'] if e['id'] == other['entryID'] and e['scope'] == 'shared' and not e.get('voided')), None)
            if match:
                imported.update(status='recorded', entryID=match['id'])
                return match
    if payload.get('refundOf'):
        original = next((e for e in state['entries'] if e['id'] == payload['refundOf'] and visible(e, actor)), None)
        if not original or kind != 'refund' or original['kind'] != 'expense':
            raise LedgerError('환불할 원래 지출을 확인해 주세요.')
        if any(field in payload and payload[field] != original[field] for field in ('scope', 'payer', 'funding', 'category')):
            raise LedgerError('연결된 환불의 공개 범위와 결제 정보는 원래 지출과 같아야 해요.')
        refunded = sum(e['amount'] for e in state['entries'] if e.get('refundOf') == original['id'] and not e.get('voided'))
        if refunded + item['amount'] > original['amount']:
            raise LedgerError('원래 지출보다 많이 환불할 수 없어요.')
        for field in ('payer', 'scope', 'funding', 'category'):
            item[field] = original[field]
        item['refundOf'] = original['id']
    state['entries'].append(item)
    if payload.get('category') and any(c['id'] == category and c['name'] != '미분류' for c in categories):
        state['rules'][actor + ':' + normal(note)] = category
    if imported:
        imported['status'], imported['entryID'] = 'recorded', item['id']
    return item


def update_entry(state, actor, entry_id, payload):
    entry = next((e for e in state['entries'] if e['id'] == entry_id and visible(e, actor)), None)
    if not entry or entry['owner'] != actor:
        raise LedgerError('작성한 사람만 수정할 수 있어요.')
    if entry.get('settlement'):
        raise LedgerError('정산한 내역은 바꿀 수 없어요. 환불은 새 조정 내역으로 기록해 주세요.')
    if any(e.get('refundOf') == entry_id and not e.get('voided') for e in state['entries']):
        raise LedgerError('환불이 연결된 원래 내역은 수정할 수 없어요.')
    if payload.get('voided'):
        entry['voided'] = True
        return entry
    merged = {**entry, **{k: v for k, v in payload.items() if k in ('amount', 'note', 'day', 'scope', 'kind', 'funding', 'payer', 'category')}}
    if 'note' in payload and not payload.get('category') and not entry.get('refundOf'):
        merged.pop('category', None)
    trial = copy.deepcopy(state)
    trial['entries'] = [e for e in trial['entries'] if e['id'] != entry_id]
    merged.pop('importID', None)
    # Confirmed expenses remain editable even if the template changes, pauses or is deleted.
    merged.pop('recurringID', None)
    merged.pop('recurringMonth', None)
    replacement = add_entry(trial, actor, merged)
    replacement.update(createdAt=entry['createdAt'], importID=entry.get('importID'))
    if entry.get('recurringID') and (replacement['kind'] != 'expense'
            or replacement['day'][:7] != entry.get('recurringMonth') or replacement['scope'] != entry['scope']):
        entry.pop('recurringID', None)
        entry.pop('recurringMonth', None)
    entry.update(replacement)
    if payload.get('category'):
        state['rules'] = trial['rules']
    return entry


def signed(entry):
    if entry['kind'] == 'income':
        return 0
    return -entry['amount'] if entry['kind'] == 'refund' else entry['amount']


def contribution(entry):
    return -entry['amount'] if entry['kind'] == 'income' else signed(entry)


def pending(state, month):
    return [e for e in state['entries'] if not e.get('voided') and e['scope'] == 'shared'
            and (e['kind'] in ('expense', 'refund') or (e['kind'] == 'income' and e['funding'] == 'personal'))
            and e['day'].startswith(month) and not e.get('settlement')]


def settlement_for(state, month):
    rows = pending(state, month)
    members = state['members']
    monthly_rows = [e for e in state['entries'] if not e.get('voided') and e['scope'] == 'shared'
                    and (e['kind'] in ('expense', 'refund') or (e['kind'] == 'income' and e['funding'] == 'personal'))
                    and e['day'].startswith(month)]
    basis = monthly_rows if state['mode'] == 'separate' else rows
    paid = [dict(id=m['id'], name=m['name'], amount=sum(contribution(e) for e in basis if e['payer'] == m['id'] and e['funding'] == 'personal')) for m in members]
    revision_data = dict(entries=monthly_rows, history=[r for r in state['settlements'] if r['month'] == month],
                         mode=state['mode'], members=[m['id'] for m in members])
    revision = hashlib.sha256(json.dumps(revision_data, sort_keys=True, ensure_ascii=False).encode()).hexdigest()
    result = dict(fromID='', toID='', amount=0, count=len(rows), memberAmounts=paid, kind=state['mode'], revision=revision)
    if state['mode'] == 'separate' and len(members) == 2:
        total = sum(p['amount'] for p in paid)
        first_share = (total + 1) // 2
        received = sum(r['amount'] * (1 if r['toID'] == members[0]['id'] else -1)
                       for r in state['settlements'] if r['month'] == month and r['kind'] == 'separate')
        balance = paid[0]['amount'] - first_share - received
        result.update(fromID=members[1 if balance > 0 else 0]['id'], toID=members[0 if balance > 0 else 1]['id'], amount=abs(balance))
    return result


def pending_settlements(state):
    if len(state['members']) != 2:
        return []
    current_month = now()[:7]
    months = sorted({e['day'][:7] for e in state['entries']
                     if not e.get('voided') and e['scope'] == 'shared' and e['day'][:7] <= current_month})
    dues = []
    for month in months:
        rows = pending(state, month)
        if not rows:
            continue
        preview = settlement_for(state, month)
        if state['mode'] == 'separate':
            dues.append(dict(month=month, memberID=None, **{k: preview[k] for k in ('fromID', 'toID', 'amount', 'count', 'revision')}))
        else:
            for member in state['members']:
                own = [e for e in rows if e['funding'] == 'personal' and e['payer'] == member['id']]
                if own:
                    amount = sum(contribution(e) for e in own)
                    dues.append(dict(month=month, memberID=member['id'], count=len(own), revision=preview['revision'],
                                     fromID='fund' if amount >= 0 else member['id'],
                                     toID=member['id'] if amount >= 0 else 'fund', amount=abs(amount)))
    return dues


def settlement_transfer_direction(item):
    raw = item['raw']
    if (item.get('kind') not in ('transfer', 'income') or not item.get('amount')
            or notification_notice_reason(raw)
            or re.search(r'광고|예정|안내|실패|거절|오류|취소|환불|카드|승인|결제|급여|않|대기|접수|요청|내\s*계좌|본인\s*계좌|계좌\s*이동', raw)):
        return None
    receipt_amount = r'\s*[:：]?\s*(\d{1,3}(?:,\d{3})+|\d+)\s*원'
    incoming = bool(re.search(r'입금\s*(?:완료|되었|됐)', raw)) or any(
        int(amount.replace(',', '')) == item['amount'] for amount in re.findall(r'입금' + receipt_amount, raw))
    outgoing = bool(re.search(r'(?:출금|송금|이체)\s*(?:완료|되었|됐)', raw)) or any(
        int(amount.replace(',', '')) == item['amount'] for amount in re.findall(r'출금' + receipt_amount, raw))
    return ('incoming' if incoming else 'outgoing') if incoming != outgoing else None


def settlement_counterparty_matches(state, due, direction, raw):
    other_id = due['fromID'] if direction == 'incoming' else due['toID']
    other = next((m for m in state['members'] if m['id'] == other_id), None)
    if other is None:  # The fund has no modeled bank account; the user must verify it.
        return True
    labels = r'보낸\s*(?:사람|분)|송금인|입금자' if direction == 'incoming' else r'받는\s*(?:사람|분)|수취인'
    for name in re.findall(r'(?m)^\s*(?:' + labels + r'|상대방|거래상대)\s*[:：]\s*([^\n]+)', raw):
        if re.fullmatch(r'[가-힣A-Za-z .]{1,30}', name.strip()) and normal(name) not in {normal(other['name']), normal(other['holder'])}:
            return False
    account_label = r'보낸\s*계좌' if direction == 'incoming' else r'받는\s*계좌'
    known_account = other['account'].replace('-', '').replace(' ', '')
    for account in re.findall(r'(?m)^\s*(?:' + account_label + r'|상대 계좌)\s*[:：]\s*([^\n]+)', raw):
        account = account.strip().replace('-', '').replace(' ', '')
        if (re.fullmatch(r'\d{6,30}', account) and re.fullmatch(r'\d{6,30}', known_account)
                and account != known_account):
            return False
    return True


def settlement_candidates(state, actor, dues):
    candidates = []
    for item in state['imports']:
        if item['owner'] != actor or item['status'] != 'pending':
            continue
        direction = settlement_transfer_direction(item)
        if not direction:
            continue
        stamp = item.get('time') or item.get('receivedAt')
        if not stamp or stamp[:10] > now()[:10]:
            continue
        for due in dues:
            if (due['amount'] <= 0 or item['amount'] != due['amount'] or stamp[:10] < due['month'] + '-01'
                    or (due['memberID'] is not None and due['memberID'] != actor)
                    or actor != due['toID' if direction == 'incoming' else 'fromID']):
                continue
            if settlement_counterparty_matches(state, due, direction, item['raw']):
                candidates.append(dict(importID=item['id'], due=due))
    return candidates


def settle(state, actor, month, member_id=None, expected_revision=None, import_id=None, request_id=None):
    if actor not in [m['id'] for m in state['members']]:
        raise LedgerError('정산할 가계부 구성원을 확인해 주세요.')
    if import_id is not None:
        import_id = text(import_id, '정산 알림', 80)
    request_key = None
    request_payload = dict(month=month, memberID=member_id, revision=expected_revision, importID=import_id)
    if request_id is not None:
        try:
            if not isinstance(request_id, str) or str(uuid.UUID(request_id)) != request_id.lower():
                raise ValueError()
        except (ValueError, AttributeError):
            raise LedgerError('정산 요청 식별자를 확인해 주세요.')
        request_key = actor + ':' + request_id.lower()
        previous = state.get('settlementRequests', {}).get(request_key)
        if previous:
            if previous['payload'] != request_payload:
                raise LedgerError('같은 정산 요청 식별자로 내용을 변경할 수 없어요.')
            return next(r for r in state['settlements'] if r['id'] == previous['recordID'])
    if len(state['members']) != 2:
        raise LedgerError('상대를 초대한 후 정산할 수 있어요.')
    result = settlement_for(state, month)
    if expected_revision is not None and expected_revision != result['revision']:
        raise LedgerError('정산 내역이 바뀌었어요. 새 금액을 확인한 뒤 다시 진행해 주세요.')
    rows = pending(state, month)
    imported = None
    if import_id is not None:
        due = next((d for d in pending_settlements(state) if d['month'] == month and d['memberID'] == member_id
                    and d['revision'] == expected_revision), None)
        if not due or not any(c['importID'] == import_id for c in settlement_candidates(state, actor, [due])):
            raise LedgerError('이 알림은 현재 정산과 일치하지 않아요. 금액·방향·상대를 다시 확인해 주세요.')
        imported = next(i for i in state['imports'] if i['id'] == import_id and i['owner'] == actor)
    if state['mode'] == 'pool':
        if member_id not in [m['id'] for m in state['members']]:
            raise LedgerError('환급받을 사람을 선택해 주세요.')
        rows = [e for e in rows if e['funding'] == 'personal' and e['payer'] == member_id]
        amount = sum(contribution(e) for e in rows)
        result.update(fromID='fund' if amount >= 0 else member_id, toID=member_id if amount >= 0 else 'fund', amount=abs(amount))
    if not rows:
        raise LedgerError('정산할 새 내역이 없어요.')
    record = dict(id=uid(), month=month, fromID=result['fromID'], toID=result['toID'], amount=result['amount'],
                  kind=state['mode'], signedAmount=(sum(contribution(e) for e in rows) if state['mode'] == 'pool' else 0), date=now(), actor=actor, count=len(rows))
    for e in rows:
        e['settlement'] = record['id']
    state['settlements'].append(record)
    if imported is not None:
        imported.update(status='settled', settlementID=record['id'])
    if request_key:
        state.setdefault('settlementRequests', {})[request_key] = dict(payload=request_payload, recordID=record['id'])
    return record


def snapshot(state, actor, month):
    if not re.fullmatch(r'\d{4}-(0[1-9]|1[0-2])', month):
        raise LedgerError('조회할 월을 확인해 주세요.')
    year, mo = map(int, month.split('-'))
    date(year, mo, 1)
    categories = effective_categories(state)
    prev = (date(year, mo, 1) - timedelta(days=1)).strftime('%Y-%m')
    all_rows = [e for e in state['entries'] if visible(e, actor)]
    shared = [e for e in all_rows if e['scope'] == 'shared' and e['kind'] in ('expense', 'refund')]
    rows = [e for e in all_rows if e['day'].startswith(month)]
    current = [e for e in shared if e['day'].startswith(month)]
    total = sum(signed(e) for e in current)
    previous = sum(signed(e) for e in shared if e['day'].startswith(prev))
    today = datetime.fromisoformat(now()).astimezone(KST).date()
    through_day = min(today.day, (date(year, mo, 1) - timedelta(days=1)).day) if (year, mo) == (today.year, today.month) else None
    comparison_total = sum(signed(e) for e in current if through_day is None or int(e['day'][-2:]) <= through_day)
    comparison_previous = sum(signed(e) for e in shared if e['day'].startswith(prev)
                              and (through_day is None or int(e['day'][-2:]) <= through_day))
    by_category = [dict(id=c['id'], name=c['name'], amount=sum(signed(e) for e in current if e['category'] == c['id'])) for c in categories]
    by_member = [dict(id=m['id'], name=m['name'], amount=sum(signed(e) for e in current if e['payer'] == m['id'] and e['funding'] == 'personal')) for m in state['members']]
    end_day = f'{month}-{calendar.monthrange(year, mo)[1]:02}'
    fund_rows = [e for e in all_rows if e['scope'] == 'shared' and e['funding'] == 'fund' and e['day'] <= end_day]
    fund_balance = sum(e['amount'] if e['kind'] in ('deposit', 'income') else -signed(e) for e in fund_rows)
    fund_balance -= sum(r['signedAmount'] for r in state['settlements'] if r['kind'] == 'pool' and r['date'][:10] <= end_day)
    trend = []
    for offset in range(5, -1, -1):
        index = year * 12 + mo - 1 - offset
        key = f'{index // 12:04}-{index % 12 + 1:02}'
        trend.append(dict(month=key, amount=sum(signed(e) for e in shared if e['day'].startswith(key))))
    own_imports = {i['id']: i for i in state['imports'] if i['owner'] == actor}
    reachable_entries = {e['id'] for e in all_rows}
    inbox = []
    for item in own_imports.values():
        if item['status'] != 'pending':
            continue
        details = []
        for candidate_id in dict.fromkeys(item.get('candidates', [])):
            candidate = own_imports.get(candidate_id)
            if not candidate or candidate_id == item['id'] or candidate['status'] not in ('pending', 'recorded'):
                continue
            if candidate['status'] == 'recorded' and candidate.get('entryID') not in reachable_entries:
                continue
            details.append({k: candidate.get(k) for k in ('id', 'merchant', 'kind', 'status', 'amount', 'time', 'sources')})
        inbox.append({**item, 'candidates': [c['id'] for c in details], 'candidateDetails': details})
    recurring_payments = []
    for recurring in state.get('recurringPayments', []):
        if recurring.get('deleted') or (recurring['scope'] != 'shared' and recurring['owner'] != actor):
            continue
        entry = recurring_entry(state, recurring['id'], month)
        recurring_payments.append({**recurring, 'dueDay': recurring_due(recurring, month),
                                  'entryID': entry['id'] if entry and visible(entry, actor) else None})
    # Month existence follows the same privacy boundary as the displayed records and plans.
    months = {e['day'][:7] for e in all_rows} | {today.strftime('%Y-%m')}
    following = (date(year, mo, 1) + timedelta(days=32)).strftime('%Y-%m') if month < '9999-12' else None
    for recurring in recurring_payments:
        if not recurring['active']:
            continue
        if recurring_due(recurring, prev):
            months.add(prev)
        if following is None:
            continue
        first = max(following, recurring['startDay'][:7])
        if not recurring_due(recurring, first):
            if first == '9999-12':
                continue
            first = (date.fromisoformat(first + '-01') + timedelta(days=32)).strftime('%Y-%m')
        months.add(first)
    navigation = dict(previous=max((m for m in months if m < month), default=None),
                      next=min((m for m in months if m > month), default=None))
    personal = [e for e in all_rows if e['scope'] == 'personal' and e['owner'] == actor]
    personal_spending = [e for e in personal if e['kind'] in ('expense', 'refund')]
    personal_current = [e for e in personal_spending if e['day'].startswith(month)]
    personal_total = sum(signed(e) for e in personal_current)
    personal_previous = sum(signed(e) for e in personal_spending if e['day'].startswith(prev))
    personal_income = sum(e['amount'] for e in personal if e['kind'] == 'income' and e['day'].startswith(month))
    personal_stats = dict(
        total=personal_total, previousTotal=personal_previous, delta=personal_total-personal_previous,
        comparisonTotal=sum(signed(e) for e in personal_current if through_day is None or int(e['day'][-2:]) <= through_day),
        comparisonPreviousTotal=sum(signed(e) for e in personal_spending if e['day'].startswith(prev)
                                    and (through_day is None or int(e['day'][-2:]) <= through_day)),
        comparisonThroughDay=through_day, personalTotal=personal_total,
        incomeTotal=personal_income, personalIncomeTotal=personal_income,
        budgetRemaining=0, fundBalance=0, byMember=[],
        byCategory=sorted([dict(id=c['id'], name=c['name'], amount=sum(signed(e) for e in personal_current if e['category'] == c['id']))
                           for c in categories], key=lambda c: c['amount'], reverse=True),
        daily=[dict(day=f'{month}-{d:02}', amount=sum(signed(e) for e in personal_current if e['day'] == f'{month}-{d:02}'))
               for d in range(1, calendar.monthrange(year, mo)[1]+1)],
        trend=[dict(month=t['month'], amount=sum(signed(e) for e in personal_spending if e['day'].startswith(t['month']))) for t in trend])
    dues = pending_settlements(state)
    return dict(pendingSettlements=dues, settlementCandidates=settlement_candidates(state, actor, dues),
                monthNavigation=navigation, recurringPayments=recurring_payments, household={k: state[k] for k in ('id', 'name', 'mode', 'budget')}, me=actor, members=state['members'], categories=categories,
                personalStats=personal_stats,
                entries=sorted(rows, key=lambda e: (e['day'], e['createdAt']), reverse=True),
                inbox=inbox,
                classificationRules=classification_rules(state, actor, categories),
                importStatus={**dict(lastReceivedAt=None, lastShortcutAt=None), **state.get('importStatus', {}).get(actor, {})},
                stats=dict(total=total, previousTotal=previous, delta=total-previous,
                           comparisonTotal=comparison_total, comparisonPreviousTotal=comparison_previous, comparisonThroughDay=through_day,
                           budgetRemaining=state['budget']-total, personalTotal=sum(signed(e) for e in rows if e['scope'] == 'personal'),
                           incomeTotal=sum(e['amount'] for e in rows if e['scope'] == 'shared' and e['kind'] == 'income'),
                           personalIncomeTotal=sum(e['amount'] for e in rows if e['scope'] == 'personal' and e['kind'] == 'income'),
                           fundBalance=fund_balance, byCategory=sorted(by_category, key=lambda c: c['amount'], reverse=True), byMember=by_member,
                           daily=[dict(day=f'{month}-{d:02}', amount=sum(signed(e) for e in current if e['day'] == f'{month}-{d:02}')) for d in range(1, calendar.monthrange(year, mo)[1]+1)], trend=trend),
                settlement=settlement_for(state, month), history=[r for r in reversed(state['settlements']) if r['month'] == month])


def notification_notice_reason(raw):
    completed = re.search(r'승인(?!\s*(?:번호|예정))|(?:결제|출금|입금|송금|이체|환불|취소)\s*완료', raw)
    # A due-date label attached to a completed transaction is only metadata.
    notice_text = re.sub(r'결제\s*예정일', '', raw) if completed else raw
    if re.search(r'(?:출금|결제|청구|입금|지급|송금|이체)\s*(?:할|될)?\s*예정|(?:청구|결제일)\s*안내', notice_text):
        return '예고·청구 안내로 실제 거래가 아니에요.'
    if re.search(r'쿠폰\s*(?:번호|발송|지급|안내)|쿠폰(?:을|이)\s*(?:드립|발송|지급)', raw) and not completed:
        return '쿠폰 안내로 실제 거래가 아니에요.'
    return ''


def review_only_option(payload, *, allow_missing_source=False):
    review_only = payload.get('reviewOnly', False)
    if type(review_only) is not bool:
        raise LedgerError('reviewOnly는 true 또는 false여야 해요.')
    if review_only and payload.get('source') != 'paste':
        if not (allow_missing_source and 'source' not in payload):
            raise LedgerError('직접 확인은 붙여넣기 출처에서만 사용할 수 있어요.')
    return review_only


def parse_message(raw, received_at=None, *, review_only=False):
    raw = text(raw, '알림 내용', 5000)
    if type(review_only) is not bool:
        raise LedgerError('reviewOnly는 true 또는 false여야 해요.')
    if review_only:
        # Ambiguous captures remain manual drafts, including duplicate metadata.
        return dict(amount=None, merchant='', kind='unknown', card='', reference='', time=None,
                    requiresReview=True, reason='금액·종류·사용처·날짜를 직접 확인해 주세요.')
    received = datetime.fromisoformat(received_at or now()).astimezone(KST)
    lines = [s.strip() for s in raw.splitlines() if s.strip()]
    notice_reason = notification_notice_reason(raw)
    transaction_text = re.sub(r'(?:취소|환불)(?:\s*(?:/|및|·)\s*(?:취소|환불))*\s*(?:이|가|은|는)?\s*'
                              r'(?:불가|문의|방법|규정|정책|(?:구매처|가맹점|판매처|고객센터)(?:에|로)?\s*문의)', '', raw)
    kind = 'unknown'
    if not notice_reason and not re.search(r'광고|한도\s*안내|(?:결제|사용|입금|송금|이체|지급)\s*(?:하면|시(?:\s|$)|할\s*경우)', raw):
        if re.search(r'취소|환불', transaction_text):
            kind = 'refund'
        elif re.search(r'송금|이체|출금|내\s*계좌|본인\s*계좌|계좌\s*이동|대체', raw):
            kind = 'transfer'
        elif re.search(r'입금|급여[\s\S]*지급|지급[\s\S]*급여', raw):
            kind = 'income'
        elif re.search(r'승인|결제|사용', raw):
            kind = 'expense'
    amounts = []
    amount_line = -1
    for idx, line in enumerate(lines):
        for match in re.finditer(r'(?<![\d.,])([\d]{1,3}(?:,\d{3})+|\d+)\s*원', line):
            before = line[:match.start()]
            if re.search(r'(누적|잔액|한도|혜택|캐시백|할인)[^\d]*$', before):
                continue
            amounts.append(int(match.group(1).replace(',', '')))
            amount_line = idx
    amount = amounts[0] if len(amounts) == 1 and kind != 'unknown' else None
    if amount is not None and not 0 < amount <= 100_000_000_000:
        amount = None
    card_match = re.search(r'카드\s*[(*\[]?\s*(\d{4})(?:\D|$)', raw)
    reference = re.search(r'(?:승인번호|거래번호)\s*[:：]?\s*([A-Za-z0-9]{4,30})', raw)
    timestamp = None
    when = re.search(r'(?:(\d{4})[-/.])?(\d{1,2})[-/.](\d{1,2})\s+(\d{1,2}):(\d{2})', raw)
    if when:
        try:
            timestamp = received.replace(year=int(when[1] or received.year), month=int(when[2]), day=int(when[3]), hour=int(when[4]), minute=int(when[5]), second=0, microsecond=0)
            if not when[1] and timestamp - received > timedelta(days=180):
                timestamp = timestamp.replace(year=timestamp.year-1)
        except ValueError:
            timestamp = None
    transaction_day = None
    day_match = re.search(r'^거래일\s*[:：]\s*(\d{4}-\d{2}-\d{2})\s*$', raw, re.MULTILINE)
    if day_match:
        try:
            transaction_day = date.fromisoformat(day_match[1]).isoformat()
        except ValueError:
            pass
    merchant = ''
    explicit = re.search(r'(?:가맹점|사용처)\s*[:：]\s*([^\n]+)', raw)
    if explicit:
        merchant = explicit[1].strip()[:120]
    elif amount_line >= 0:
        candidates = lines[amount_line+1:] + lines[:amount_line]
        for line in candidates:
            if not re.search(r'발신|카드|승인|취소|환불|누적|잔액|한도|\d{1,2}:\d{2}|\d+원|출금|입금|이체|송금', line):
                merchant = line[:120]
                break
    review = amount is None or not merchant or kind in ('unknown', 'transfer', 'income')
    reason = notice_reason or ('송금은 지출·수입·내 계좌 이동·정산 중 무엇인지 확인해 주세요.' if kind == 'transfer'
              else '입금은 수입·내 계좌 이동·정산 중 무엇인지 확인해 주세요.' if kind == 'income'
              else '금액 또는 사용처를 직접 확인해 주세요.' if review else '')
    return dict(amount=amount, merchant=merchant, kind=kind, card=card_match[1] if card_match else '',
                reference=reference[1] if reference else '', time=timestamp.isoformat(timespec='seconds') if timestamp else transaction_day,
                requiresReview=review, reason=reason)


def same_reference(a, b):
    return bool(a.get('reference') and a.get('card') and a.get('time') and b.get('time')
                and a.get('merchant') and normal(a['merchant']) == normal(b.get('merchant', ''))
                and all(a.get(k) == b.get(k) for k in ('reference', 'card', 'amount', 'kind', 'time')))


def same_notification(parsed, item, raw, source, received_at):
    if source == 'paste' or 'paste' in item['sources']:
        return False
    if not parsed.get('amount') or parsed['kind'] == 'unknown' or item['status'] == 'duplicate':
        return False
    if any(parsed.get(k) != item.get(k) for k in ('amount', 'kind')):
        return False
    if any(parsed.get(k) and item.get(k) and parsed[k] != item[k] for k in ('card', 'reference')):
        return False
    if parsed['kind'] in ('transfer', 'income'):
        # Equal bank transfers may be separate payments to different people.
        if normal(parsed.get('merchant', '')) != normal(item.get('merchant', '')):
            return False
        direction = settlement_transfer_direction({**parsed, 'raw': raw})
        if not direction or direction != settlement_transfer_direction(item):
            return False
        counterparty = r'(?:받는\s*(?:사람|분|계좌)|보낸\s*(?:사람|분|계좌)|수취인|송금인|입금자|상대방|거래상대|상대\s*계좌)\s*[:：]\s*([^\n]+)'
        if [normal(s) for s in re.findall(counterparty, raw)] != [normal(s) for s in re.findall(counterparty, item['raw'])]:
            return False
    a, b = parsed.get('time'), item.get('time')
    try:
        if a and b and 'T' in a and 'T' in b:
            # shortcut: Without approval IDs, real equal payments in one minute can merge; require issuer IDs to separate them reliably.
            return datetime.fromisoformat(a).astimezone(KST).replace(second=0, microsecond=0) == datetime.fromisoformat(b).astimezone(KST).replace(second=0, microsecond=0)
        # A calendar date or manually pasted text is not evidence of simultaneous delivery.
        if (a and 'T' not in a) or (b and 'T' not in b):
            return False
        received = datetime.fromisoformat(received_at)
        previous = datetime.fromisoformat(item['receivedAt'])
        if abs((received - previous).total_seconds()) > 15:
            return False
        known = a or b
        return not known or abs((datetime.fromisoformat(known) - received).total_seconds()) <= 60
    except (TypeError, ValueError, KeyError):
        return False


def import_message(state, actor, payload):
    review_only = review_only_option(payload)
    source = payload.get('source', 'shortcut')
    if source not in ('sms', 'app', 'shortcut', 'paste'):
        raise LedgerError('알림 출처를 확인해 주세요.')
    event_id = text(payload.get('eventID') or uid(), '알림 식별자', 200)
    event_key = f'{source}:{event_id}'
    received_at = now()
    parsed = parse_message(payload.get('text'), payload.get('receivedAt'), review_only=review_only)
    for item in state['imports']:
        same_event = event_key in item['events']
        if item['owner'] == actor and (same_event or same_reference(parsed, item)
                                      or same_notification(parsed, item, payload['text'], source, received_at)):
            if event_key not in item['events']:
                item['events'].append(event_key)
            if source not in item['sources']:
                item['sources'].append(source)
            if not same_event:
                for field in ('card', 'reference', 'time', 'merchant'):
                    if not item.get(field) and parsed.get(field):
                        item[field] = parsed[field]
            break
    else:
        candidates = []
        if parsed['amount'] and parsed['merchant']:
            for item in state['imports']:
                if item['owner'] != actor or item['status'] in ('ignored', 'duplicate'):
                    continue
                if parsed['amount'] == item['amount'] and parsed['kind'] == item['kind'] and normal(parsed['merchant']) == normal(item['merchant']):
                    if (parsed['time'] and item['time'] and 'T' in parsed['time'] and 'T' in item['time']
                            and abs((datetime.fromisoformat(parsed['time']) - datetime.fromisoformat(item['time'])).total_seconds()) <= 600):
                        candidates.append(item['id'])
        status = 'ignored' if not review_only and notification_notice_reason(payload['text']) else 'pending'
        item = dict(id=uid(), owner=actor, raw=payload['text'], sources=[source], events=[event_key], status=status,
                    candidates=candidates, receivedAt=received_at, entryID=None, **parsed)
        state['imports'].append(item)
    status = state.setdefault('importStatus', {}).setdefault(actor, {})
    status['lastReceivedAt'] = now()
    if payload.get('viaShortcut') is True:
        status['lastShortcutAt'] = status['lastReceivedAt']
    return item


def resolve_import(state, actor, import_id, target_id=None):
    item = next((i for i in state['imports'] if i['id'] == import_id and i['owner'] == actor), None)
    if not item or item['status'] != 'pending':
        raise LedgerError('확인할 알림을 찾을 수 없어요.')
    if target_id:
        target = next((i for i in state['imports'] if i['id'] == target_id and i['owner'] == actor), None)
        if not target or target['id'] == item['id'] or target['status'] not in ('pending', 'recorded'):
            raise LedgerError('연결할 기존 알림을 확인해 주세요.')
        if target['status'] == 'recorded' and not any(e['id'] == target.get('entryID') and visible(e, actor) for e in state['entries']):
            raise LedgerError('기존 기록이 삭제되었어요. 같은 결제인지 다시 확인해 주세요.')
        target['sources'] = list(dict.fromkeys(target['sources'] + item['sources']))
        target['events'] += item['events']
        item['status'] = 'duplicate'
    else:
        item['status'] = 'ignored'
    return item
