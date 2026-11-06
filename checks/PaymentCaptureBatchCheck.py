"""Synthetic amount-first/batch OCR checks. Optional image stays local; no network/ledger writes.

python3 checks/PaymentCaptureBatchCheck.py
python3 checks/PaymentCaptureBatchCheck.py --image /absolute/local/image --output /ignored/result.json
"""
import argparse
import json
from pathlib import Path
import random
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "server"))
from ledger import parse_message


def line(text, y, x=0.16, width=0.55, height=0.025):
    return dict(text=text, x=x, y=y, width=width, height=height)


def block(y, amount="12,340", who="검증상점A", kind="출금", date=None):
    rows = [line("요금납부", y), line(amount + "원 " + kind, y - 0.055)]
    if who is not None:
        rows.append(line("내 검증통장 > " + who, y - 0.11))
    if date:
        rows.append(line(date, y - 0.16))
    return rows


def want(amount, merchant="", kind="transfer", time=None):
    return dict(amount=amount, merchant=merchant, kind=kind, time=time)


cases = []

def add(name, rows, expected=None):
    cases.append(dict(name=name, lines=rows, expected=expected))


pair = block(0.90) + block(0.55, "56,780", "검증상점B")
pair_want = [want(12340, "검증상점A"), want(56780, "검증상점B")]
add("two complete notification blocks", pair, pair_want)
add("same amount means two independent transactions", block(.90) + block(.55, who="검증상점B"), [want(12340, "검증상점A"), want(12340, "검증상점B")])
add("two blocks without merchant/date", block(.90, who=None) + block(.55, "56,780", None), [want(12340), want(56780)])
add("incoming counterparty on arrow left", [line("요금납부", .90), line("12,340원 입금", .845), line("검증회사 → 내 통장", .79)] + block(.55), [want(12340, "검증회사", "income"), want(12340, "검증상점A")])
for n in range(8):
    rows = [dict(row, x=row["x"] + n * .002, y=row["y"] + (n % 3 - 1) * .003) for row in pair]
    random.Random(n).shuffle(rows)
    add(f"stable top-bottom order shuffled/shifted {n}", rows, pair_want)
for arrow in ["→", "->", ">"]:
    add(f"arrow notation {arrow}", [dict(r, text=r["text"].replace(">", arrow)) for r in pair], pair_want)
for sign in ["-", "−", ""]:
    add(f"withdrawal sign {sign!r}", block(.90, sign + "12,340") + block(.55, "56,780", "검증상점B"), pair_want)
add("deposit plus sign", [line("+ 12,340 원 입금", .8)], [want(12340, kind="income")])
add("whitespace around comma/currency", [line("12, 340 원 출금", .8)], [want(12340)])
add("digits separated without comma are uncertain", [line("1 234원 출금", .8)])
add("no O-to-zero repair", [line("12,34O원 출금", .8)])
add("withdrawal with conflicting plus sign", [line("+12,340원 출금", .8)])
add("deposit with conflicting minus sign", [line("-12,340원 입금", .8)])
add("single withdrawal unknown merchant/date", [line("12,340원 출금", .8)], [want(12340)])
add("single income unknown merchant/date", [line("입금", .86), line("12,340원", .8)], [want(12340, kind="income")])
add("amount only remains unknown/review", [line("12,340원", .8)])
# Banks wrap metadata labels in punctuation or append them after the amount.
for label in ["잔액", "현재 잔액", "남은 잔액", "누적", "누적 이용금액", "할인 금액"]:
    for wrapped in ["(" + label + ")", "[" + label + "]", "（" + label + "）"]:
        add("metadata punctuation trailing " + wrapped, [line("출금", .9), line("98,760원 " + wrapped, .8)], "review")
        add("transaction plus wrapped metadata " + wrapped, [line("12,340원 출금", .9), line("98,760원 " + wrapped, .8)], [want(12340)])
    add("metadata unit in label " + label, [line("출금", .9), line(label + "(원)", .8), line("98,760원", .765)], "review")

add("no amount", [line("출금 완료", .8)])
for title in ["결제", "증명서 발급", "이용 안내"]:
    add(f"UI text is never merchant: {title}", [line("카드 결제", .86), line("12,340원", .8), line(title, .65)], [want(12340, kind="expense")])
for label in ["잔액", "거래 후 잔액", "누적", "누적 이용금액", "할인", "한도", "캐시백"]:
    add(f"metadata inline {label}", [line("12,340원 출금", .9), line(label + " 98,760원", .8)], [want(12340)])
    add(f"metadata next row {label}", [line("12,340원 출금", .9), line(label, .8), line("98,760원", .765)], [want(12340)])
    add(f"metadata only {label}", [line("출금", .9), line(label, .8), line("98,760원", .765)], "review")
add("balance/cumulative/discount together", [line("12,340원 출금", .95), line("잔액", .86), line("98,760원", .825), line("누적 50,000원", .75), line("할인", .66), line("1,000원", .625)], [want(12340)])
add("each block has its own balance", block(.95) + [line("잔액", .77), line("98,760원", .735)] + block(.55, "56,780", "검증상점B") + [line("누적", .37), line("80,000원", .335)], pair_want)
for x in [.16, .65]:
    add(f"amount label left/right {x}", [line("출금", .9), line("거래금액", .8, x=x, width=.15), line("12,340원", .8, x=.65 if x == .16 else .16, width=.20)], [want(12340)])
add("amount label next row", [line("출금", .9), line("거래금액", .8), line("12,340원", .76)], [want(12340)])
add("kind on next row", [line("12,340원", .8), line("출금", .76)], [want(12340)])
add("amount/kind split horizontally", [line("12,340원", .8, width=.2), line("출금", .802, x=.40, width=.1)], [want(12340)])
add("bank detail with balance but no merchant/date", [line("-12,340원", .9), line("거래 유형", .8, width=.15), line("CMS출금", .8, x=.65, width=.2), line("거래 후 잔액", .7), line("98,760원", .66)], [want(12340)])
for notice in ["출금 예정", "출금할 예정", "결제 실패", "입금 실패", "승인 거절", "환불 예정", "취소 예정", "광고", "결제 취소 문의"]:
    add(f"notice/failure never actual transaction: {notice}", [line("12,340원", .9), line(notice, .8)])
for kind in ["결제 취소", "환불 완료", "승인 취소"]:
    add(f"completed refund {kind}", [line("12,340원 " + kind, .8)], [want(12340, kind="refund")])
add("mixed transaction and advertising preserves entire capture", pair + [line("광고 1,000원 쿠폰", .15)])
add("truncated final block without amount", block(.9) + [line("요금납부", .55), line("출금", .49)])
add("truncated arrow never silently discarded", block(.9) + [line("요금납부", .55), line("56,780원 출금", .49), line("내 통장 >", .43)])
add("clear plus unreadable amount", block(.9) + block(.55, "56,78O", "검증상점B"))
add("clear plus unknown transaction kind", block(.9) + [line("요금납부", .55), line("56,780원", .49)])
add("two amounts within one block", block(.9) + [line("1,000원 출금", .73)] + block(.55))
add("unlabelled extra amount is not a balance guess", [line("12,340원 출금", .9), line("98,760원", .8)])
add("no repeated headers: amounts alone cannot split", [line("12,340원 출금", .9), line("56,780원 출금", .6)])
add("same row cards are not vertical blocks", block(.9) + [dict(r, x=r["x"]+.45) for r in block(.9, "56,780", "검증상점B")])
add("single card repeated amount is not two transactions", [line("검증카드", .9), line("12,340원 카드 결제", .8), line("이용금액 12,340원", .7), line("잔액 98,760원", .6)])
for text, time in [("2027-03-05 08:07", "2027-03-05T08:07:00+09:00"), ("2024년 2월 29일", "2024-02-29"), ("2026년 2월 30일", None), ("어제 19:16", None), ("1시간 전", None)]:
    add(f"date not guessed: {text}", block(.9, date=text) + block(.55, "56,780", "검증상점B"), [want(12340, "검증상점A", time=time), want(56780, "검증상점B")])
add("split date pieces on same row", block(.9) + [line("2027년 3월", .73, width=.15), line("5일 08:07", .73, x=.33, width=.2)], [want(12340, "검증상점A", time="2027-03-05T08:07:00+09:00")])
add("ambiguous dates omitted", block(.9) + [line("2027-03-05", .73), line("2027-03-06", .68)], [want(12340, "검증상점A")])
add("amount zero", [line("0원 출금", .8)])
add("too large", [line("100,000,000,001원 출금", .8)])
add("empty input", [])
add("known mixed headers retain both blocks", block(.90) + [dict(r, text="입출금알림") if r["text"] == "요금납부" else r for r in block(.55, "56,780", "검증상점B")], pair_want)
for y, x in [(.50, .16), (.765, .80), (.86, .16)]:
    add(f"unresolved balance label cannot create expense {y}/{x}", [line("출금", .95), line("잔액", .80, width=.2), line("54원", y, x=x, width=.15)], "review")
add("colon merchant without whitespace", [line("12,340원 출금", .9), line("가맹점:검증상점", .8)], [want(12340, "검증상점")])
add("header absolute date", [line("요금납부 2027-03-05 08:07", .9), line("12,340원 출금", .84)], [want(12340, time="2027-03-05T08:07:00+09:00")])
add("cut amount without currency must not be lost", block(.9) + block(.55, "56,780", "검증상점B") + [line("999 출금", .34)], "review")
card = [line("검증상점", .87, .06), line("18,400원", .77, .06),
        line("거래 일자", .69, .06, .25), line("결제 구분", .64, .06, .25),
        line("이용 금액", .59, .06, .25), line("결제 카드", .54, .06, .25),
        line("26. 10.25", .69, .70, .25), line("일시불", .64, .70, .25),
        line("18,400원", .59, .70, .25), line("검증카드", .54, .70, .25)]
add("legacy canonical card preserves two-digit year and merchant", card, [want(18400, "검증상점", "expense", "2026-10-25")])
bank = [line("상세 내역", .89, .40), line("-65,720원", .74, .06),
        line("적요", .66, .06, .25), line("검증보험", .66, .70, .25),
        line("거래 유형", .60, .06, .25), line("CMS출금", .60, .70, .25),
        line("일시", .36, .06, .25), line("2026년 10월 26일 19:16", .36, .49, .45),
        line("거래 후 잔액", .30, .06, .25), line("60,857원", .30, .70, .25)]
add("legacy canonical bank preserves merchant/date/balance exclusion", bank, [want(65720, "검증보험", "transfer", "2026-10-26T19:16:00+09:00")])
add("date-only without merchant stays visible but never becomes a merchant", [line("12,340원 출금", .9), line("2027-03-05", .8)], [want(12340)])
cases[-1]["retained"] = "2027-03-05"
add("P1 trailing balance must not become withdrawal", [line("출금", .9), line("98,760원 잔액", .8)], "review")
add("P2 currencyless second amount must not disappear", [line("12,340원 출금", .9), line("56,780", .8), line("출금", .7)], "review")
for label in ["누적", "거래 후 잔액", "할인", "누적 이용금액"]:
    add(f"trailing metadata-only {label}", [line("출금", .9), line("98,760원 " + label, .8)], "review")
for label in ["잔액", "누적", "할인"]:
    add(f"real transaction with trailing metadata {label}", [line("12,340원 출금", .9), line("98,760원 " + label, .8)], [want(12340)])
for rows in [
    [line("12,340원 출금", .9), line("입금", .8), line("56,780", .7)],
    [line("12,340원 출금", .9), line("56780", .8), line("출금", .7)],
    [line("12,340원 출금", .9), line("56,780 출금", .8)],
    block(.9) + [line("요금납부", .55), line("56,780", .49), line("출금", .43)],
]:
    add(f"currencyless transaction variant {len(cases)}", rows, "review")

# Date-grouped transaction lists: all names/amounts are synthetic, no screenshot fixture.
def list_row(y, amount, caption, x=.18):
    return [line(amount, y, x, .24, .024), line(caption, y-.026, x, .65, .014)]

calendar = [line("10월", .96, .45, .1),
            *[line(t, .89, .08+i*.15, .04) for i,t in enumerate(["일", "월", "화", "수"])],
            *[line(str(20+i), .85, .08+i*.15, .04) for i in range(4)],
            line("-120,000원", .81, .08, .12), line("+250,000", .81, .28, .12)]
dated_list = [line("26일 월요일", .65, .055, .18, .016),
    *list_row(.59, "-8,400원", "검증교통 | 검증카드"),
    *list_row(.51, "25,000원", "검증보험 -> 내 검증은행 통장"),
    *list_row(.43, "-5,100원", "검증생활 | 검증카드"),
    *list_row(.35, "1,400원", "검증 캐시백 >> 내 검증은행 계좌"),
    *list_row(.27, "8,600원", "검증카드 취소 | 검증 환급금 입금"),
    *list_row(.19, "9,200원", "취소 | 검증의류 | 검증카드"),
    line("25일 일요일", .125, .055, .18, .016),
    *list_row(.085, "-3,200원", "검증백화점 | 검증카드"), line("....", .001, .23, .12, .006)]
list_expected = [want(8400, "검증교통", "expense"), want(25000, "검증보험", "income"),
    want(5100, "검증생활", "expense"), want(1400, "검증 캐시백", "income"),
    want(8600, kind="refund"), want(9200, "검증의류", "refund"),
    want(3200, "검증백화점", "expense"), "review"]
add("calendar totals excluded, seven complete list rows and clipped tail retained", calendar+dated_list, list_expected)
cases[-1]["retained"] = "연도 확인 필요"
for seed in range(6):
    rows = [dict(r, x=r['x']+.002*seed, y=r['y']+(.001 if seed%2 else 0)) for r in calendar+dated_list]
    random.Random(seed).shuffle(rows)
    add(f"list preserves vertical order with OCR shuffle/position jitter {seed}", rows, list_expected)
for arrow in ["→", ">", "->", ">>"]:
    rows = [dict(r, text=r['text'].replace('->', arrow).replace('>>', arrow)) for r in calendar+dated_list]
    add("list incoming direction without color " + arrow, rows, list_expected)
for text in ["1,400원", "+1,400원", "1,4O0원"]:
    rows = calendar + dated_list[:]
    rows = [dict(r,text=text) if r['text']=='1,400원' else r for r in rows]
    expected = list_expected[:] if 'O' not in text else list_expected[:3]+['review']+list_expected[4:]
    add("list currency/sign/O handling " + text, rows, expected)
for caption in ["검증상점 | 검증카드", "검증상점", "검증상점 -> 상대 은행", "검증상점 ->", "광고 쿠폰 안내", "취소 실패 | 검증카드"]:
    rows = [dict(r,text=caption) if r['text']=='검증보험 -> 내 검증은행 통장' else r for r in calendar+dated_list]
    add("list ambiguous positive/cropped/advertised caption " + caption, rows, list_expected[:1]+['review']+list_expected[2:])
for marker in ["취소 | 검증의류 | 검증카드", "승인취소 | 검증의류 | 검증카드", "환불 완료 | 검증의류 | 검증카드"]:
    rows = [dict(r,text=marker) if r['text']=='취소 | 검증의류 | 검증카드' else r for r in calendar+dated_list]
    add("list explicit cancellation preserves amount " + marker, rows, list_expected)
rows = [dict(r,text='-8,400원') if r['text']=='-5,100원' else r for r in calendar+dated_list]
add("same amount different list merchants both kept", rows, list_expected[:2]+[want(8400,'검증생활','expense')]+list_expected[3:])
add("list without calendar still separates at date headers", dated_list, list_expected)
add("list no clipped tail does not invent an extra item", calendar+dated_list[:-1], list_expected[:-1])
for fragment in ["3,000원", "3,000", "원", "검증 가게 일부"]:
    add("partially clipped list tail " + fragment, calendar+dated_list[:-1]+[line(fragment,.001,.18,.24,.006)], list_expected)
rows = [r for r in calendar+dated_list if r['text']!='검증생활 | 검증카드']
add("list row with missing caption stays review instead of losing amount", rows, list_expected[:2]+['review']+list_expected[3:])
add("no date: repeated complete amount-caption pairs", list_row(.8,'-8,400원','검증교통 | 검증카드')+list_row(.6,'-5,100원','검증생활 | 검증카드'), [want(8400,"검증교통","expense"), want(5100,"검증생활","expense")])
add("list dates aligned with amount/caption column", [dict(r,x=.18) if r['text'] in ['26일 월요일','25일 일요일'] else r for r in dated_list], list_expected)
for sx, sy, dx, dy in [(.75,.75,.08,.1), (1,.55,0,.3), (.6,1,.2,0), (.9,.9,.01,.02)]:
    transformed = [dict(r,x=r['x']*sx+dx,y=r['y']*sy+dy,width=r['width']*sx,height=r['height']*sy) for r in calendar+dated_list]
    add(f"list geometry scales independently {sx}/{sy}", transformed, list_expected)
known_dates = [dict(r,text='2027년 3월 5일 금요일') if r['text']=='26일 월요일' else
               dict(r,text='2027년 3월 4일 목요일') if r['text']=='25일 일요일' else r for r in dated_list]
known_expected = [dict(v,time='2027-03-04' if i==6 else '2027-03-05') if isinstance(v,dict) and v['merchant'] else v
                  for i,v in enumerate(list_expected)]
add("known full dates reach server when merchant is explicit", known_dates, known_expected)
for label in ["잔액", "누적", "합계", "할인 금액"]:
    rows = [dict(r,text=label+' | 검증카드') if r['text']=='검증생활 | 검증카드' else r for r in calendar+dated_list]
    add("list metadata is not a negative card payment " + label, rows, list_expected[:2]+['review']+list_expected[3:])

# Counterparty words must not turn a structurally incoming/expense row into another kind.
for caption in ["합성출금서비스 -> 내 검증은행 통장", "합성환불보장몰 -> 내 검증은행 통장",
                "합성이체서비스 -> 내 검증은행 통장", "합성취소지원몰 -> 내 검증은행 통장"]:
    rows = [dict(r,text=caption) if r['text']=='검증보험 -> 내 검증은행 통장' else r for r in dated_list]
    add("list parser keyword collision stays review " + caption, rows, list_expected[:1]+['review']+list_expected[2:])
    cases[-1]["retained"] = caption
for caption in ["합성입금서비스 | 검증카드", "합성환불보장몰 | 검증카드"]:
    rows = [dict(r,text=caption) if r['text']=='검증생활 | 검증카드' else r for r in dated_list]
    add("expense counterparty keyword collision stays review " + caption, rows, list_expected[:2]+['review']+list_expected[3:])
rows = [dict(r,text='합성카드서비스 -> 내 검증은행 통장') if r['text']=='검증보험 -> 내 검증은행 통장' else r for r in dated_list]
add("card in incoming counterparty is not itself a kind conflict", rows,
    list_expected[:1]+[want(25000,'합성카드서비스','income')]+list_expected[2:])

# Independent synthetic QA cases promoted to development regressions (not held-out results).
layout_fixtures = {'right_column_variable_spacing': [{'text': '가계부 거래 내역', 'x': 0.1, 'y': 0.94, 'width': 0.78, 'height': 0.034},
                                   {'text': '이번 달 합계 91,357원',
                                    'x': 0.1,
                                    'y': 0.875,
                                    'width': 0.78,
                                    'height': 0.027},
                                   {'text': '14일 금요일', 'x': 0.1, 'y': 0.79, 'width': 0.78, 'height': 0.022},
                                   {'text': '모래서점', 'x': 0.1, 'y': 0.7, 'width': 0.34, 'height': 0.027},
                                   {'text': '-3,761원', 'x': 0.68, 'y': 0.7, 'width': 0.26, 'height': 0.027},
                                   {'text': '일시불 카드 결제', 'x': 0.1, 'y': 0.66, 'width': 0.78, 'height': 0.019},
                                   {'text': '해솔공방 입금', 'x': 0.1, 'y': 0.55, 'width': 0.45, 'height': 0.027},
                                   {'text': '9,482원', 'x': 0.68, 'y': 0.55, 'width': 0.26, 'height': 0.027},
                                   {'text': '해솔공방 → 내 바다은행 통장',
                                    'x': 0.1,
                                    'y': 0.51,
                                    'width': 0.78,
                                    'height': 0.022},
                                   {'text': '솔빛문구 취소', 'x': 0.1, 'y': 0.33, 'width': 0.43, 'height': 0.027},
                                   {'text': '1,579원', 'x': 0.68, 'y': 0.33, 'width': 0.26, 'height': 0.027},
                                   {'text': '승인 취소 완료', 'x': 0.1, 'y': 0.29, 'width': 0.78, 'height': 0.019}],
 'no_date_header_balance_pairs': [{'text': '계좌 입출금 내역', 'x': 0.1, 'y': 0.94, 'width': 0.78, 'height': 0.036},
                                  {'text': '2025.03.14 09:11',
                                   'x': 0.1,
                                   'y': 0.84,
                                   'width': 0.78,
                                   'height': 0.021},
                                  {'text': '출금 6,832원', 'x': 0.55, 'y': 0.79, 'width': 0.39, 'height': 0.027},
                                  {'text': '달빛시장', 'x': 0.1, 'y': 0.79, 'width': 0.32, 'height': 0.027},
                                  {'text': '잔액 74,561원',
                                   'x': 0.55,
                                   'y': 0.745,
                                   'width': 0.39,
                                   'height': 0.02},
                                  {'text': '2025.03.13 17:23',
                                   'x': 0.1,
                                   'y': 0.63,
                                   'width': 0.78,
                                   'height': 0.021},
                                  {'text': '입금 4,391원', 'x': 0.55, 'y': 0.58, 'width': 0.39, 'height': 0.027},
                                  {'text': '나무협동조합', 'x': 0.1, 'y': 0.58, 'width': 0.4, 'height': 0.027},
                                  {'text': '잔액 78,952원',
                                   'x': 0.55,
                                   'y': 0.535,
                                   'width': 0.39,
                                   'height': 0.02},
                                  {'text': '2025.03.12 13:05',
                                   'x': 0.1,
                                   'y': 0.42,
                                   'width': 0.78,
                                   'height': 0.021},
                                  {'text': '출금 예정 2,876원',
                                   'x': 0.48,
                                   'y': 0.36,
                                   'width': 0.46,
                                   'height': 0.027},
                                  {'text': '다음 달 회비', 'x': 0.1, 'y': 0.31, 'width': 0.78, 'height': 0.027}],
 'stacked_calendar_cancel_notice_crop': [{'text': '3월 소비 달력',
                                          'x': 0.1,
                                          'y': 0.95,
                                          'width': 0.78,
                                          'height': 0.033},
                                         {'text': '월간 지출 113,579원',
                                          'x': 0.1,
                                          'y': 0.9,
                                          'width': 0.78,
                                          'height': 0.023},
                                         {'text': '월간 수입 224,681원',
                                          'x': 0.1,
                                          'y': 0.86,
                                          'width': 0.78,
                                          'height': 0.023},
                                         {'text': '14일 금요일',
                                          'x': 0.06,
                                          'y': 0.8,
                                          'width': 0.78,
                                          'height': 0.019},
                                         {'text': '-5,273원',
                                          'x': 0.26,
                                          'y': 0.737,
                                          'width': 0.78,
                                          'height': 0.032},
                                         {'text': '소금서점 | 별빛카드',
                                          'x': 0.26,
                                          'y': 0.7,
                                          'width': 0.7,
                                          'height': 0.018},
                                         {'text': '1,864원',
                                          'x': 0.26,
                                          'y': 0.606,
                                          'width': 0.78,
                                          'height': 0.03},
                                         {'text': '달빛 캐시백 → 내 파도은행 계좌',
                                          'x': 0.26,
                                          'y': 0.568,
                                          'width': 0.71,
                                          'height': 0.018},
                                         {'text': '7,291원',
                                          'x': 0.26,
                                          'y': 0.473,
                                          'width': 0.78,
                                          'height': 0.03},
                                         {'text': '취소 | 바람가게 | 별빛카드',
                                          'x': 0.26,
                                          'y': 0.435,
                                          'width': 0.7,
                                          'height': 0.018},
                                         {'text': '3,648원',
                                          'x': 0.26,
                                          'y': 0.332,
                                          'width': 0.78,
                                          'height': 0.03},
                                         {'text': '입금 예정 | 조약돌회사',
                                          'x': 0.26,
                                          'y': 0.294,
                                          'width': 0.7,
                                          'height': 0.018},
                                         {'text': '13일 목요일',
                                          'x': 0.06,
                                          'y': 0.195,
                                          'width': 0.78,
                                          'height': 0.019},
                                         {'text': '-9,157원',
                                          'x': 0.26,
                                          'y': 0.04,
                                          'width': 0.78,
                                          'height': 0.03},
                                         {'text': '아래 잘린 가게',
                                          'x': 0.26,
                                          'y': -0.007,
                                          'width': 0.6,
                                          'height': 0.018}]}
layout_expected = {
    "right_column_variable_spacing": [want(3761,"모래서점","expense"), want(9482,"해솔공방","income"), want(1579,"솔빛문구","refund")],
    "no_date_header_balance_pairs": [want(6832,"달빛시장","transfer","2025-03-14T09:11:00+09:00"), want(4391,"나무협동조합","income","2025-03-13T17:23:00+09:00"), "review"],
    "stacked_calendar_cancel_notice_crop": [want(5273,"소금서점","expense"),want(1864,"달빛 캐시백","income"),want(7291,"바람가게","refund"),"review","review"],
}
for name, rows in layout_fixtures.items():
    add("promoted layout " + name, rows, layout_expected[name])
    for n,(sx,sy,dx,dy) in enumerate([(.78,.8,.07,.08),(.62,.6,.15,.1),(1,.85,0,.05)]):
        variant=[dict(r,x=r['x']*sx+dx,y=r['y']*sy+dy,width=r['width']*sx,height=r['height']*sy) for r in rows]
        random.Random(n).shuffle(variant)
        add(f"promoted layout scaled shuffled {name}/{n}",variant,layout_expected[name])
right_rows=layout_fixtures["right_column_variable_spacing"]
right_expected=layout_expected["right_column_variable_spacing"]
add("right amounts without a date header",[r for r in right_rows if r['text']!='14일 금요일'],right_expected)
add("right layout same amount independent merchants",[dict(r,text='3,761원') if r['text']=='9,482원' else r for r in right_rows],
    [right_expected[0],want(3761,'해솔공방','income'),right_expected[2]])
for broken in ["9,48O원","9,482","원"]:
    add("right layout retains clipped amount " + broken,[dict(r,text=broken) if r['text']=='9,482원' else r for r in right_rows],
        [right_expected[0],"review",right_expected[2]])
for marker in ['입금 예정','입금 실패','광고 쿠폰 안내']:
    add("right uncertain row stays review " + marker,
        [dict(r,text=marker) if r['text']=='해솔공방 → 내 바다은행 통장' else r for r in right_rows],
        [right_expected[0],"review",right_expected[2]])
for rows in [
    [line('출금 6,832원',.8),line('출금 예정 2,876원',.6)],
    [line('결제 6,832원',.8),line('결제 예정 2,876원',.6)],
]:
    add("unsplit transaction plus notice explicitly requires review " + rows[0]['text'],rows,"review")

for separator in ["|", "｜", "| ", " |"]:
    rows=[dict(r,text=separator.join(['취소','검증의류','검증카드'])) if r['text']=='취소 | 검증의류 | 검증카드' else r for r in dated_list]
    add("cancellation separators survive OCR spacing " + repr(separator),rows,list_expected)
bank_rows=layout_fixtures["no_date_header_balance_pairs"]
for label in ["잔액", "누적", "할인 금액"]:
    detached=[]
    for r in bank_rows:
        if r['text'].startswith('잔액 '):
            detached += [dict(r,text=label),dict(r,text=r['text'].split(' ',1)[1],y=r['y']-.027)]
        else: detached.append(r)
    add("structured rows detached metadata " + label,detached,layout_expected["no_date_header_balance_pairs"])

# Promoted from independent QA: admitted amount rows must never be lost to gutter filtering.
indented_rows = [{'height': 0.025625, 'text': '지난 거래', 'width': 0.88, 'x': 0.045, 'y': 0.946},
 {'height': 0.01875, 'text': '2024년 12월 3일', 'width': 0.88, 'x': 0.18, 'y': 0.87},
 {'height': 0.025, 'text': '-5,834원', 'width': 0.76, 'x': 0.18, 'y': 0.795},
 {'height': 0.01625, 'text': '자갈서점 | 산들카드', 'width': 0.76, 'x': 0.18, 'y': 0.756},
 {'height': 0.0225, 'text': '5,834원', 'width': 0.82, 'x': 0.115, 'y': 0.653},
 {'height': 0.014999999999999998, 'text': '승인 취소 | 자갈서점 | 산들카드', 'width': 0.82, 'x': 0.115, 'y': 0.619},
 {'height': 0.02625, 'text': '2,749원', 'width': 0.75, 'x': 0.215, 'y': 0.515},
 {'height': 0.014999999999999998, 'text': '이슬 캐시백 → 내 고래은행 계좌', 'width': 0.75, 'x': 0.215, 'y': 0.476},
 {'height': 0.0225, 'text': '8,163원', 'width': 0.8, 'x': 0.135, 'y': 0.366},
 {'height': 0.01625, 'text': '결제 예정 | 구름요금', 'width': 0.8, 'x': 0.135, 'y': 0.332},
 {'height': 0.01875, 'text': '2024년 12월 2일', 'width': 0.88, 'x': 0.18, 'y': 0.218},
 {'height': 0.025, 'text': '1,92', 'width': 0.7, 'x': 0.19, 'y': 0.021},
 {'height': 0.014999999999999998, 'text': '잘린 행의 설명 일부', 'width': 0.7, 'x': 0.19, 'y': -0.006}]
indented_expected = [want(5834,"자갈서점","expense","2024-12-03"),
    want(5834,"자갈서점","refund","2024-12-03"),
    want(2749,"이슬 캐시백","income","2024-12-03"),"review","review"]
for variant in ["original", "shuffled", "shifted_scaled"]:
    rows = [dict(r) for r in indented_rows]
    if variant == "shuffled": random.Random(37).shuffle(rows)
    if variant == "shifted_scaled":
        rows = [dict(r,x=r['x']*.82+.04,y=r['y']*.82+.08,width=r['width']*.82,height=r['height']*.82) for r in rows]
    add("indented cancel/scheduled rows retained " + variant, rows, indented_expected)
    cases[-1]["retained"] = "결제 예정 | 구름요금"
for x in [.106,.12,.15,.20]:
    rows=[dict(r,x=x) if r['text'] in ['5,834원','승인 취소 | 자갈서점 | 산들카드'] else r for r in indented_rows]
    add("accepted amount-column edge retains cancellation " + str(x),rows,indented_expected)
for x in [.02,.60]:
    rows=[dict(r,x=x) if r['text'] in ['5,834원','승인 취소 | 자갈서점 | 산들카드'] else r for r in indented_rows]
    add("outside column tolerance preserves all raw rows " + str(x),rows,"review")

HARNESS = r'''
import Foundation
import Vision
import ImageIO
struct InputLine: Decodable {
    let text: String
    let x, y, width, height: Double
    var line: PaymentImageOCR.Line { .init(text: text, box: CGRect(x: x, y: y, width: width, height: height)) }
}
struct Fixture: Decodable { let lines: [InputLine] }
@main struct Check {
    static func main() throws {
        if CommandLine.arguments[1] == "image" {
            let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
            let source = CGImageSourceCreateWithData(data as CFData, nil)!
            let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 4096] as CFDictionary)!
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate; request.recognitionLanguages = ["ko-KR", "en-US"]; request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: image).perform([request])
            let lines = (request.results ?? []).compactMap { result -> PaymentImageOCR.Line? in
                result.topCandidates(1).first.map { .init(text: $0.string, box: result.boundingBox) }
            }
            let output = ["texts": PaymentCaptureBatch.texts(from: lines), "fallback": [PaymentImageOCR.editableText(from: lines)]]
            print(String(decoding: try JSONSerialization.data(withJSONObject: output), as: UTF8.self))
            return
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let fixtures = try JSONDecoder().decode([Fixture].self, from: data)
        let output = fixtures.map { fixture -> [String: [String]] in
            let lines = fixture.lines.map(\.line)
            return ["texts": PaymentCaptureBatch.texts(from: lines), "fallback": [PaymentImageOCR.editableText(from: lines)]]
        }
        print(String(decoding: try JSONSerialization.data(withJSONObject: output), as: UTF8.self))
    }
}
'''

args = argparse.ArgumentParser()
args.add_argument("--image", type=Path)
args.add_argument("--output", type=Path)
options = args.parse_args()
source = (ROOT / "OurLedger/Inbox.swift").read_text().split("// MARK: - On-device payment image OCR", 1)[1]
with tempfile.TemporaryDirectory(prefix="capture-batch-check-") as directory:
    work = Path(directory)
    (work / "OCR.swift").write_text("import Foundation\nimport Vision\nimport ImageIO\n" + source)
    (work / "Check.swift").write_text(HARNESS)
    (work / "fixtures.json").write_text(json.dumps(cases))
    batch = ROOT / "OurLedger/PaymentCaptureBatch.swift"
    if not batch.exists():
        batch = work / "Baseline.swift"
        batch.write_text("import Foundation\nenum PaymentCaptureBatch { static func texts(from lines: [PaymentImageOCR.Line]) -> [String] { [PaymentImageOCR.editableText(from: lines)] } }")
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library", str(work / "OCR.swift"), str(batch), str(work / "Check.swift"), "-o", str(work / "check")], check=True)
    outputs = json.loads(subprocess.check_output([str(work / "check"), str(work / "fixtures.json")]))
    failures = 0
    for case, result in zip(cases, outputs, strict=True):
        try:
            if case["expected"] == "review":
                assert len(result["texts"]) == 1 and "금액 확인 필요" in result["texts"][0]
                assert parse_message(result["texts"][0])["amount"] is None, "balance must never become a transaction on server"
                assert all(r["text"] in result["texts"][0] for r in case["lines"]), "review must retain original text"
            elif case["expected"] is None:
                assert result["texts"] == result["fallback"], "must preserve full fallback, not drop or split uncertain text"
            else:
                parsed = [parse_message(text, "2026-10-27T12:00:00+09:00") for text in result["texts"]]
                assert len(parsed) == len(case["expected"]), (len(parsed), len(case["expected"]))
                for text, item, expected in zip(result["texts"], parsed, case["expected"], strict=True):
                    if expected == "review":
                        assert text.startswith("발신 알림: 금액 확인 필요") and item["amount"] is None, (text,item)
                    else:
                        actual = {key: item[key] for key in ("amount", "merchant", "kind", "time")}
                        assert actual == expected, (actual,expected)
                if "retained" in case:
                    assert case["retained"] in "\n".join(result["texts"]), "known date must remain visible for review"
            print("PASS", case["name"])
        except Exception as error:
            failures += 1
            print("FAIL", case["name"], error)
    print(f"{len(cases)-failures}/{len(cases)} synthetic cases passed")
    if options.image:
        result = json.loads(subprocess.check_output([str(work / "check"), "image", str(options.image)]))
        # Never print private image text, names or account identifiers.
        if options.output:
            options.output.write_text(json.dumps(result, ensure_ascii=False, indent=2))
        print("LOCAL IMAGE:", len(result["texts"]), "result(s); fallback=", result["texts"] == result["fallback"])
    sys.exit(1 if failures else 0)
