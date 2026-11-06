"""Run only the Inbox OCR helper on synthetic images; no app build or server calls.

    python3 checks/PaymentImageOCRCheck.py
    python3 checks/PaymentImageOCRCheck.py /tmp/ourledger-ui-fixture.png
    python3 checks/PaymentImageOCRCheck.py /tmp/ourledger-draft-fixture.png ambiguous
    python3 checks/PaymentImageOCRCheck.py /tmp/ourledger-bank-auto.png bank
"""
import json
from pathlib import Path
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "OurLedger/Inbox.swift").read_text()
marker = "// MARK: - On-device payment image OCR"
assert marker in source, "Inbox OCR helper is missing"
helper = source.split(marker, 1)[1]

with tempfile.TemporaryDirectory(prefix="ourledger-ocr-") as directory:
    work = Path(directory)
    (work / "OCR.swift").write_text("import Foundation\nimport Vision\nimport ImageIO\n" + helper)
    (work / "Check.swift").write_text(r'''
import AppKit
import Vision

@main struct OCRCheck {
    static func image(_ lines: [String]) -> Data {
        let image = NSImage(size: NSSize(width: 1200, height: 800))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 1200, height: 800).fill()
        for (index, line) in lines.enumerated() {
            (line as NSString).draw(at: NSPoint(x: 60, y: 680 - index * 100),
                withAttributes: [.font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.black])
        }
        image.unlockFocus()
        return NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    }

    static func main() async throws {
        if CommandLine.arguments.count == 2 {
            try image(["테스트카드 승인", "18,400원", "가맹점: 검증마트", "10/26 14:00"])
                .write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        }
        let ambiguousData = image(["18,400원"])
        if CommandLine.arguments.count == 3 && CommandLine.arguments[2] == "ambiguous" {
            try ambiguousData.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        }
        let ambiguousText = try await PaymentImageOCR.recognize(ambiguousData)
        precondition(ambiguousText == "18,400원", "Draft fixture must contain only an amount: \(ambiguousText)")
        typealias Line = PaymentImageOCR.Line
        func line(_ text: String, _ x: Double, _ y: Double, _ width: Double = 0.25) -> Line {
            Line(text: text, box: CGRect(x: x, y: y, width: width, height: 0.025))
        }
        let detail = [
            line("테스트상점", 0.06, 0.87), line("18,400원", 0.06, 0.77),
            line("거래 일자", 0.06, 0.69), line("결제 구분", 0.06, 0.64),
            line("이용 금액", 0.06, 0.59), line("결제 카드", 0.06, 0.54),
            line("26. 10.25", 0.70, 0.69), line("일시불", 0.70, 0.64),
            line("18,400원", 0.70, 0.59), line("테스트카드", 0.70, 0.54)
        ]
        let canonical = "카드 결제\n18,400원\n가맹점: 테스트상점\n거래일: 2026-10-25"
        precondition(PaymentImageOCR.editableText(from: detail) == canonical, "Single detail was not normalized")
        func preserves(_ lines: [Line]) {
            precondition(PaymentImageOCR.editableText(from: lines) == lines.map(\.text).joined(separator: "\n"), "Ambiguous detail was changed: \(lines.map(\.text))")
        }
        let bank = [
            line("상세 내역", 0.40, 0.89), line("테스트보험", 0.14, 0.79),
            line("-65,720원", 0.06, 0.74),
            line("적요", 0.06, 0.66), line("테스트보험", 0.70, 0.66),
            line("거래 유형", 0.06, 0.60), line("CMS출금", 0.70, 0.60),
            line("입금처", 0.06, 0.54), line("출금처", 0.06, 0.48),
            line("내 테스트은행 0000-0000-0000", 0.39, 0.48, 0.54),
            line("일시", 0.06, 0.36), line("2026년 10월 26일 19:16", 0.49, 0.36, 0.45),
            line("거래 후 잔액", 0.06, 0.30), line("60,857원", 0.70, 0.30),
            line("증명서 발급하기", 0.12, 0.22)
        ]
        let bankCanonical = "출금\n65,720원\n가맹점: 테스트보험\n거래일: 2026-10-26\n2026-10-26 19:16"
        precondition(PaymentImageOCR.editableText(from: bank) == bankCanonical, "Bank detail amount/balance/type/date mapping failed")
        precondition(PaymentImageOCR.editableText(from: bank.reversed()) == bankCanonical, "OCR reading order must not change bank fields")
        var bankIncome = bank
        bankIncome[2] = line("+65,720원", 0.06, 0.74)
        bankIncome[6] = line("입금", 0.70, 0.60)
        precondition(PaymentImageOCR.editableText(from: bankIncome).hasPrefix("입금\n65,720원\n"), "Deposit classified as withdrawal by field labels")
        for (labelIndex, replacement) in [(3, "거래처"), (5, "거래 구분"), (10, "거래 일시")] {
            var variant = bank
            variant[labelIndex] = line(replacement, 0.06, bank[labelIndex].box.minY)
            precondition(PaymentImageOCR.editableText(from: variant) == bankCanonical, "Equivalent bank field label failed")
        }
        var bankNumericDate = bank
        bankNumericDate[11] = line("2026.10.26 19:16", 0.49, 0.36, 0.45)
        precondition(PaymentImageOCR.editableText(from: bankNumericDate) == bankCanonical)
        func keepBankRaw(_ rows: [Line]) {
            precondition(PaymentImageOCR.editableText(from: rows) == rows.map(\.text).joined(separator: "\n"), "Ambiguous bank detail was auto-normalized")
        }
        // Vision may split one physical date row into multiple horizontal observations.
        // Use varied dates/segmentation, not just the rendered bank screenshot's output.
        let dateFragments: [([String], String, String?)] = [
            (["2026년 10월", "26일 19:16"], "2026-10-26", "19:16"),
            (["2027년 3월", "5일 08:07"], "2027-03-05", "08:07"),
            (["2024.", "02.", "29", "06:45"], "2024-02-29", "06:45"),
            (["2025-12-31", "23:59"], "2025-12-31", "23:59"),
            (["2028년", "2월 29일"], "2028-02-29", nil)
        ]
        func splitDate(_ fragments: [String], gap: CGFloat = 0.008) -> [Line] {
            var rows = bank
            rows.remove(at: 11)
            var x: CGFloat = 0.49
            for text in fragments {
                let width = CGFloat(text.filter { !$0.isWhitespace }.count) * 0.014
                rows.append(line(text, x, 0.36, width))
                x += width + gap
            }
            return rows
        }
        for (fragments, day, time) in dateFragments {
            let expected = "출금\n65,720원\n가맹점: 테스트보험\n거래일: " + day
                + (time.map { "\n" + day + " " + $0 } ?? "")
            for gap: CGFloat in [-0.006, 0.008, 0.018] {
                let rows = splitDate(fragments, gap: gap)
                for variant in [rows, Array(rows.reversed()), rows.map {
                    Line(text: $0.text, box: $0.box.offsetBy(dx: 0.025, dy: -0.015))
                }] {
                    precondition(PaymentImageOCR.editableText(from: variant) == expected,
                        "Same-row date fragments not normalized: \(fragments), gap=\(gap)")
                }
            }
        }
        keepBankRaw(splitDate(["2026년 2월", "30일 19:16"]))
        keepBankRaw(splitDate(["2026년 10월", "26일 25:16"]))
        keepBankRaw(splitDate(["2026년 10월"]))
        keepBankRaw(splitDate(["2026년 10월", "다른 거래"]))
        keepBankRaw(splitDate(["2026년 10월 26일", "19:16", "20:00"]))
        keepBankRaw(splitDate(["2026년 10월", "26일 19:16"], gap: 0.16))
        let split = splitDate(["2026년 10월", "26일 19:16"])
        var otherRow = split
        otherRow[otherRow.count - 1] = Line(text: "26일 19:16", box: split.last!.box.offsetBy(dx: 0, dy: -0.045))
        keepBankRaw(otherRow)
        var stacked = split
        stacked[stacked.count - 2] = Line(text: "2026년 10월", box: CGRect(x: 0.49, y: 0.374, width: 0.126, height: 0.010))
        stacked[stacked.count - 1] = Line(text: "26일 19:16", box: CGRect(x: 0.624, y: 0.360, width: 0.112, height: 0.010))
        keepBankRaw(stacked) // Both overlap the label, but not each other: two physical rows.
        keepBankRaw(split + [split.last!])
        keepBankRaw(bank + [line("-12,000원", 0.06, 0.70)])
        keepBankRaw(bank + [line("출금 예정", 0.06, 0.18)])
        var conflictingSign = bank
        conflictingSign[2] = line("+65,720원", 0.06, 0.74)
        keepBankRaw(conflictingSign)
        var badBankDate = bank
        badBankDate[11] = line("2026년 2월 30일 19:16", 0.49, 0.36, 0.45)
        keepBankRaw(badBankDate)
        keepBankRaw(bank + [line("12,000원", 0.06, 0.18)])
        var differingAmount = detail
        differingAmount[8] = line("24,000원", 0.70, 0.59)
        preserves(differingAmount)
        preserves(detail + [line("18,400원", 0.70, 0.25)])
        preserves(detail + detail)
        preserves(detail + [line("26.10.25", 0.70, 0.25)])
        preserves(Array(detail.dropLast()))
        preserves(detail + [line("다른상점", 0.06, 0.83)])
        preserves(detail + [line("일시불", 0.40, 0.64)])
        for date in ["26.02.30", "26.13.01", "26.10.25 12:30"] {
            var invalidDate = detail
            invalidDate[6] = line(date, 0.70, 0.69)
            preserves(invalidDate)
        }
        var displacedValue = detail
        displacedValue[7] = line("일시불", 0.70, 0.42)
        preserves(displacedValue)
        for notice in ["거래 목록", "출금 예정", "승인 취소", "환불 완료"] {
            preserves(detail + [line(notice, 0.06, 0.30)])
        }

        let detailImage = NSImage(size: NSSize(width: 1200, height: 1800))
        detailImage.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 1200, height: 1800).fill()
        for item in detail {
            (item.text as NSString).draw(at: NSPoint(x: item.box.minX * 1200, y: item.box.minY * 1800),
                withAttributes: [.font: NSFont.systemFont(ofSize: 40), .foregroundColor: NSColor.black])
        }
        detailImage.unlockFocus()
        let detailData = NSBitmapImageRep(data: detailImage.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        let recognizedDetail = try await PaymentImageOCR.recognize(detailData)
        precondition(recognizedDetail == canonical, "Synthetic detail OCR: \(recognizedDetail)")

        let fixtures = [
            ["카드 승인", "8,400원", "가맹점: 테스트상점", "10/26 12:30"],
            ["카드 결제", "25,000원", "가맹점: TEST MART", "10/26 12:31"],
            ["이체 완료", "50,000원", "테스트받는분", "10/26 12:32"],
            ["카드 승인", "8,400원", "9,500원", "가맹점: 테스트상점"],
            ["자동이체", "오늘 테스트보험 외 1곳에서 119,970원", "출금할 예정이에요.", "통장에서 출금돼요."]
        ]
        var texts: [String] = []
        for fixture in fixtures {
            texts.append(try await PaymentImageOCR.recognize(image(fixture)))
        }
        texts.append(recognizedDetail)
        func renderDetail(_ rows: [Line], dark: Bool, width: CGFloat) -> Data {
            let height = width * 1.5
            let image = NSImage(size: NSSize(width: width, height: height))
            image.lockFocus()
            (dark ? NSColor.black : NSColor.white).setFill()
            NSRect(x: 0, y: 0, width: width, height: height).fill()
            for row in rows {
                (row.text as NSString).draw(at: NSPoint(x: row.box.minX * width, y: row.box.minY * height),
                    withAttributes: [.font: NSFont.systemFont(ofSize: width / 36),
                                     .foregroundColor: dark ? NSColor.white : NSColor.black])
            }
            image.unlockFocus()
            return NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        }
        if CommandLine.arguments.count == 3 && CommandLine.arguments[2] == "bank" {
            try renderDetail(bank, dark: true, width: 1200).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        }
        for dark in [false, true] {
            for width: CGFloat in [600, 1200] {
                let recognizedBank = try await PaymentImageOCR.recognize(renderDetail(bank, dark: dark, width: width))
                precondition(recognizedBank == bankCanonical, "Bank image layout normalization failed (dark=\(dark), width=\(width)): \(recognizedBank)")
            }
        }
        let imageDates = [
            ("2027년 3월 5일 08:07", "2027-03-05", "08:07"),
            ("2024.02.29 06:45", "2024-02-29", "06:45"),
            ("2028년 2월 29일", "2028-02-29", "")
        ]
        for (text, day, time) in imageDates {
            for (dark, width, offset) in [(true, CGFloat(600), CGFloat(0.02)), (false, CGFloat(900), CGFloat(-0.015))] {
                var rows = bank
                rows[11] = line(text, 0.49, 0.36, 0.45)
                rows = rows.map { Line(text: $0.text, box: $0.box.offsetBy(dx: offset, dy: -0.01)) }
                let recognized = try await PaymentImageOCR.recognize(renderDetail(rows, dark: dark, width: width))
                let expected = "출금\n65,720원\n가맹점: 테스트보험\n거래일: " + day
                    + (time.isEmpty ? "" : "\n" + day + " " + time)
                precondition(recognized == expected,
                    "Varied bank date image failed (date=\(text), dark=\(dark), width=\(width)): \(recognized)")
            }
        }
        texts.append(PaymentImageOCR.editableText(from: bank))
        texts.append(PaymentImageOCR.editableText(from: bankIncome))
        do {
            _ = try await PaymentImageOCR.recognize(image([]))
            fatalError("Blank image must fail")
        } catch PaymentImageOCR.Failure.noText {}
        do {
            _ = try await PaymentImageOCR.recognize(Data("invalid image".utf8))
            fatalError("Invalid image must fail")
        } catch PaymentImageOCR.Failure.unreadableImage {}
        let cancelled = Task {
            try? await Task.sleep(for: .seconds(1))
            return try await PaymentImageOCR.recognize(image(fixtures[0]))
        }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            fatalError("Cancelled task must fail")
        } catch is CancellationError {}
        let data = try JSONSerialization.data(withJSONObject: texts)
        print(String(decoding: data, as: UTF8.self))
    }
}
''')
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
                    str(work / "OCR.swift"), str(ROOT / "OurLedger/PaymentCaptureBatch.swift"), str(work / "Check.swift"),
                    "-o", str(work / "check")], check=True)
    result = subprocess.run([str(work / "check"), *sys.argv[1:3]], text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(result.stderr.split("\n\n", 1)[0])
    texts = json.loads(result.stdout)

sys.path.insert(0, str(ROOT / "server"))
from ledger import parse_message

expected = [(8400, "테스트상점", "expense"), (25000, "TEST MART", "expense"),
            (50000, "테스트받는분", "transfer"), (None, "테스트상점", "expense")]
*transactions, scheduled_notice, detail_text, bank_text, bank_income_text = texts
for raw, (amount, merchant, kind) in zip(transactions, expected, strict=True):
    parsed = parse_message(raw, "2026-10-26T12:40:00+09:00")
    assert (parsed["amount"], parsed["merchant"], parsed["kind"]) == (amount, merchant, kind), (raw, parsed)
    if kind == "transfer" or amount is None:
        assert parsed["requiresReview"]
    print(f"PASS: {kind}, amount={amount}, merchant={merchant}")
normalized_notice = "".join(scheduled_notice.split())
assert "119,970원" in normalized_notice and "출금할예정" in normalized_notice, scheduled_notice
parsed_notice = parse_message(scheduled_notice, "2026-10-26T12:40:00+09:00")
assert parsed_notice["kind"] == "unknown" and parsed_notice["amount"] is None, (scheduled_notice, parsed_notice)
assert parsed_notice["requiresReview"]
print("PASS: scheduled withdrawal OCR -> unknown, amount=None")
parsed_detail = parse_message(detail_text, "2026-10-26T12:40:00+09:00")
assert (parsed_detail["amount"], parsed_detail["merchant"], parsed_detail["kind"]) == (18400, "테스트상점", "expense"), parsed_detail
assert parsed_detail["time"] in (None, "2026-10-25"), "Date-only OCR must not invent a time"
assert detail_text.endswith("거래일: 2026-10-25")
print("PASS: detail image -> canonical text -> amount/merchant; date-only, no invented time")
print("PASS: multiple transactions, differing amounts and ambiguous details keep original text")
print("PASS: 45 same-row date variants (5 dates, 3 gaps, reordered/shifted boxes); 9 ambiguous dates keep original text")
print("PASS: 6 additional bank images with varied dates/formats, light/dark, 600/900px and shifted layout")
print("PASS: blank image, invalid image, cancellation; no network or persistence")

for raw, kind in [(bank_text, "transfer"), (bank_income_text, "income")]:
    parsed = parse_message(raw, "2026-10-26T20:00:00+09:00")
    assert (parsed["amount"], parsed["merchant"], parsed["kind"], parsed["time"]) == (65720, "테스트보험", kind, "2026-10-26T19:16:00+09:00"), parsed
    assert parsed["requiresReview"]
print("PASS: bank withdrawal/deposit, balance exclusion, layout labels, reordered columns, light/dark 600/1200px OCR, server parser")
ambiguous = parse_message("18,400원", "2026-10-27T12:00:00+09:00")
# The parser deliberately withholds the amount when the transaction kind is unknown.
# The editable OCR draft above still retains the visible "18,400원".
assert ambiguous["amount"] is None and not ambiguous["merchant"] and ambiguous["requiresReview"], ambiguous
assert ambiguous["kind"] == "unknown", ambiguous
print("PASS: ambiguous image keeps 18,400원 with unknown kind/missing merchant; no automatic import")
