import Foundation
import CoreGraphics

/// Pure OCR interpretation. No persistence, inferred counterparties/dates, or cross-image deduplication.
enum PaymentCaptureBatch {
    private struct Row {
        var text: String
        var box: CGRect
    }
    private static let moneyPattern = #"(?<![0-9A-Za-z.,])[-+−]?\s*(?:[0-9]{1,3}(?:\s*,\s*[0-9]{3})+|[0-9]+)\s*원"#

    static func texts(from lines: [PaymentImageOCR.Line]) -> [String] {
        let existing = PaymentImageOCR.editableText(from: lines)
        let raw = lines.map(\.text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let rows = rows(from: lines)
        if existing == raw, let list = transactionList(lines) { return list }
        if existing == raw, let list = structuredList(rows) { return list }
        // A second numeric row may be a clipped transaction even when its currency is missing.
        if hasCurrencylessTransaction(rows) { return [reviewText(lines)] }
        // The existing strict bank/card recognizer carries proven merchant/date information.
        if existing != raw { return [existing] }
        guard !lines.isEmpty, lines.allSatisfy({ $0.box.width > 0 && $0.box.height > 0 }) else { return [existing] }
        let fallback: [String]
        if (matches(moneyPattern, raw).count > 1 && !matches(#"(?:출금|입금|결제|청구|지급|송금|이체)\s*(?:할|될)?\s*예정"#, raw).isEmpty) || rows.contains(where: {
            metadata($0.text) && (matches(moneyPattern, $0.text).isEmpty
                || !matches(#"^[+−-]?[0-9,]+원"#, compact($0.text)).isEmpty)
        }) {
            // Detached and trailing balance labels are unsafe for the server's line-based parser.
            // Preserve every original line while explicitly withholding all unverified amounts.
            fallback = [reviewText(lines)]
        } else { fallback = [existing] }
        let headers = rows.indices.filter { header(rows[$0].text) != nil }
        if headers.count > 1 {
            var result: [String] = []
            for index in headers.indices {
                let start = index == 0 ? 0 : headers[index]
                let end = index + 1 < headers.count ? headers[index + 1] : rows.count
                // All blocks must succeed. Never discard an unreadable/truncated sibling.
                guard let text = normalized(Array(rows[start..<end])) else { return fallback }
                result.append(text)
            }
            return result
        }
        return normalized(rows).map { [$0] } ?? fallback
    }

    private static func matches(_ pattern: String, _ text: String) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }
    private static func listDay(_ text: String) -> Bool {
        !matches(#"^(?:[0-9]{4}년\s*)?(?:[0-9]{1,2}월\s*)?[0-9]{1,2}일(?:\s*[일월화수목금토]요일)?$"#,
                 text.trimmingCharacters(in: .whitespaces)).isEmpty
    }
    private static func listAmount(_ text: String) -> Bool {
        !matches(#"^[+−-]?[0-9Oo,]+원?$"#, compact(text)).isEmpty
    }
    private static func listMetadata(_ text: String) -> Bool {
        metadata(text) || !matches(#"^(?:(?:이번\s*(?:달|주)|월간|주간|일간|전체)\s*)?(?:합계|총액|총\s*(?:지출|수입)|월간\s*(?:지출|수입)|주간\s*(?:지출|수입))\s*[:：]?\s*[+−-]?[0-9,\s]+원?$"#, text).isEmpty
            || !matches(#"^(?:월간|주간|일간|이번\s*달)\s*(?:지출|수입)\s*[+−-]?[0-9,\s]+원?$"#, text).isEmpty
    }
    /// Repeated named rows with explicit actions establish a list even without date headers.
    /// Horizontal OCR fragments are joined by vertical overlap before this pass.
    private static func structuredList(_ rows: [Row]) -> [String]? {
        guard !rows.contains(where: { header($0.text) != nil }) else { return nil }
        func dated(_ row: Row) -> Bool { listDay(row.text) || date(row.text) != nil }
        var excluded = Set<Int>()
        for i in rows.indices where listMetadata(rows[i].text) {
            excluded.insert(i)
            if matches(moneyPattern, rows[i].text).isEmpty, i + 1 < rows.count,
               listAmount(rows[i + 1].text), rows[i].box.minY - rows[i + 1].box.maxY < rows[i].box.height * 2 {
                excluded.insert(i + 1)
            }
        }
        let starts = rows.indices.filter { !excluded.contains($0) && !dated(rows[$0])
            && !matches(#"[+−-]?\s*[0-9Oo][0-9Oo,\s]*원|[+−-]?[0-9Oo,]+$|(?:^|\s)원$"#, rows[$0].text).isEmpty }
        guard starts.count >= 2 else { return nil }
        let height = starts.map { rows[$0].box.height }.sorted()[starts.count / 2]
        let column = starts.map { rows[$0].box.minX }.sorted()[starts.count / 2]
        let trailing = starts.map { rows[$0].box.maxX }.sorted()[starts.count / 2]
        guard starts.allSatisfy({ abs(rows[$0].box.minX - column) < height * 3 })
                || starts.allSatisfy({ abs(rows[$0].box.maxX - trailing) < height * 3 }) else { return nil }
        var result: [String] = [], confirmed = 0
        for n in starts.indices {
            let start = starts[n], end = n + 1 < starts.count ? starts[n + 1] : rows.count
            if n + 1 < starts.count, rows[start].box.minY - rows[end].box.maxY < height { return nil }
            let boundary = (start + 1..<end).first(where: { dated(rows[$0]) }) ?? end
            let group = Array(rows[start..<boundary])
            // Unattached caption fragments cannot be swallowed into the preceding transaction.
            var closeEnd = 1
            while closeEnd < group.count {
                let above = group[closeEnd - 1], below = group[closeEnd]
                guard above.box.minY - below.box.maxY < max(above.box.height, below.box.height) * 2 else { break }
                closeEnd += 1
            }
            let item = Array(group.prefix(closeEnd))
            let useful = item.enumerated().filter { !excluded.contains(start + $0.offset) }.map(\.element)
            var hint = "발신 알림: 날짜 확인 필요"
            let nearestDate = rows[..<start].last(where: dated)
            if let day = nearestDate { hint = "발신 알림: 원본 날짜 " + day.text + " · 연도 확인 필요" }
            if let text = rowTransaction(useful) {
                if text.contains("\n가맹점: ") { confirmed += 1 }
                if let day = nearestDate, let full = date(day.text) {
                    hint = "거래일: " + String(full.prefix(10))
                    if full.count > 10 { hint += "\n" + full }
                    if !text.contains("\n가맹점: ") { hint = "발신 알림: 원본 날짜 " + full + " · 날짜 확인 필요" }
                }
                result.append(text + "\n" + hint)
            } else { result.append(reviewText(item.map { .init(text: $0.text, box: $0.box) }) + "\n" + hint) }
            let remaining = Array(group.dropFirst(closeEnd)) + Array(rows[boundary..<end].filter { !dated($0) })
            if !remaining.isEmpty {
                result.append(reviewText(remaining.map { .init(text: $0.text, box: $0.box) }))
            }
        }
        // Two fully interpreted named rows, not two monetary tokens, are the minimum evidence.
        guard confirmed >= 2 else { return nil }
        let prefix = rows[..<starts[0]].filter { !dated($0) && !listMetadata($0.text) }
        if prefix.contains(where: { !matches(moneyPattern, $0.text).isEmpty || $0.text.contains("|") }) {
            result.insert(reviewText(prefix.map { .init(text: $0.text, box: $0.box) }), at: 0)
        }
        return result
    }
    private static func rowTransaction(_ rows: [Row]) -> String? {
        guard let first = rows.first, rows.allSatisfy({ $0.box.minY >= 0 }),
              matches(#"광고|예정|실패|거절|쿠폰|문의"#, rows.map(\.text).joined(separator: " ")).isEmpty else { return nil }
        let amounts = matches(moneyPattern, first.text)
        guard amounts.count == 1 else { return nil }
        let printed = (first.text as NSString).substring(with: amounts[0].range)
        var name = (first.text as NSString).replacingCharacters(in: amounts[0].range, with: "").trimmingCharacters(in: .whitespaces)
        let actionPattern = #"(?:일시불\s*)?카드\s*결제|승인\s*취소(?:\s*완료)?|결제\s*취소(?:\s*완료)?|환불(?:\s*완료)?|취소(?:\s*완료)?|출금(?:\s*완료)?|입금(?:\s*완료)?|결제(?:\s*완료)?"#
        func action(_ value: String) -> String? {
            let v = compact(value)
            if v.contains("취소") || v.contains("환불") { return "refund" }
            if v.contains("출금") { return "transfer" }
            if v.contains("입금") { return "income" }
            return v.contains("결제") ? "expense" : nil
        }
        var kinds = Set<String>()
        if let token = matches("^(?:" + actionPattern + #")(?:\s+|$)|(?:^|\s+)(?:"# + actionPattern + ")$", name).first {
            if let type = action((name as NSString).substring(with: token.range)) { kinds.insert(type) }
            name = (name as NSString).replacingCharacters(in: token.range, with: "").trimmingCharacters(in: .whitespaces)
        }
        let captions = rows.dropFirst()
        if let directional = captions.first(where: { !matches(#"[|｜]|->|<-|→|←|>|<"#, $0.text).isEmpty }) {
            guard captions.count == 1, let text = listTransaction([Row(text: printed, box: first.box), directional]) else { return nil }
            let expected = ["income": "입금", "transfer": "출금", "expense": "카드 결제", "refund": "환불 완료"]
            guard kinds.count <= 1, kinds.first.map({ text.hasPrefix(expected[$0]! + "\n") }) ?? true else { return nil }
            if !name.isEmpty, !text.contains("\n가맹점: " + name + "\n") && !text.hasSuffix("\n가맹점: " + name) { return nil }
            return text
        }
        var names = Set<String>()
        if !name.isEmpty { names.insert(name) }
        for row in captions {
            if !matches("^(?:" + actionPattern + ")$", row.text).isEmpty, let type = action(row.text) { kinds.insert(type) }
            else { names.insert(row.text) }
        }
        guard kinds.count == 1, let type = kinds.first, names.count == 1, let merchant = names.first,
              validMerchant(merchant), !metadata(merchant),
              let amount = Int(printed.filter(\.isNumber)), (1...100_000_000_000).contains(amount),
              !(type == "income" && printed.contains(where: { "-−".contains($0) })),
              !(type == "transfer" || type == "expense") || !printed.contains("+") else { return nil }
        return listText(action: ["income":"입금", "transfer":"출금", "expense":"카드 결제", "refund":"환불 완료"][type]!, amount: amount, merchant: merchant)
    }
    /// A list needs date sections plus repeated aligned amount/caption pairs, not amounts alone.
    private static func transactionList(_ lines: [PaymentImageOCR.Line]) -> [String]? {
        let days = lines.filter { listDay($0.text) }.sorted { $0.box.midY > $1.box.midY }
        guard let firstDay = days.first else { return nil }
        let amounts = lines.filter {
            $0.box.maxY < firstDay.box.minY && listAmount($0.text)
                && !matches(moneyPattern, $0.text).isEmpty
        }.sorted { $0.box.midY > $1.box.midY }
        guard amounts.count >= 2 else { return nil }
        let height = amounts.map(\.box.height).sorted()[amounts.count / 2]
        let column = amounts.map(\.box.minX).sorted()[amounts.count / 2]
        guard amounts.allSatisfy({ abs($0.box.minX - column) < height * 3 }) else { return nil }
        for (upper, lower) in zip(amounts, amounts.dropFirst()) {
            guard upper.box.minY > lower.box.maxY else { return nil }
        }
        // Derive the gutter from the leftmost admitted amount, not the median column:
        // accepted indented transactions must not be filtered out of the body afterward.
        let textColumn = amounts.map(\.box.minX).min()!
        let body = rows(from: lines.filter {
            $0.box.maxY <= firstDay.box.maxY && (listDay($0.text) || $0.box.minX >= textColumn - height)
        })
        let starts = body.indices.filter { listAmount(body[$0].text) }
        let paired = starts.filter { index in
            guard index + 1 < body.count, !listDay(body[index + 1].text), !listAmount(body[index + 1].text) else { return false }
            let next = body[index + 1]
            let gap = body[index].box.minY - next.box.maxY
            return gap >= -height * 0.5 && gap < height * 2
                && !matches(#"[|｜]|->|<-|→|←|>|<"#, next.text).isEmpty
        }
        guard paired.count >= 2 else { return nil }
        let prefix = lines.filter { $0.box.minY >= firstDay.box.maxY }
        let calendar = prefix.filter { !matches(#"^[일월화수목금토]$"#, $0.text).isEmpty }.count >= 3
            && prefix.filter { !matches(#"^[0-9]{1,2}$"#, $0.text).isEmpty }.count >= 3
        let months = prefix.filter { !matches(#"^[0-9]{1,2}월$"#, $0.text).isEmpty }
        let month = months.count == 1 ? months[0].text : ""
        var result: [String] = []
        if !calendar, prefix.contains(where: { !listMetadata($0.text) && (!matches(moneyPattern, $0.text).isEmpty || $0.text.contains("|") || $0.text.contains("→")) }) {
            result.append(reviewText(prefix))
        }
        var dayHint = "", knownDay: String?, index = 0
        func review(_ rows: [Row]) -> String {
            reviewText(rows.map { .init(text: $0.text, box: $0.box) })
                + "\n발신 알림: 목록 일부를 확인해 주세요.\n" + dayHint
        }
        while index < body.count {
            if listDay(body[index].text) {
                let rawDay = body[index].text
                let fullDay = rawDay.replacingOccurrences(of: #"\s*[일월화수목금토]요일$"#, with: "", options: .regularExpression)
                if let known = date(fullDay) {
                    knownDay = known
                    dayHint = "발신 알림: 원본 날짜 " + known + " · 날짜 확인 필요"
                } else {
                    knownDay = nil
                    dayHint = "발신 알림: 원본 날짜 " + (rawDay.contains("월") && !matches(#"[0-9]월"#, rawDay).isEmpty ? "" : month + " ")
                        + rawDay + " · 연도 확인 필요"
                }
                index += 1; continue
            }
            let start = index
            index += 1
            while index < body.count, !listDay(body[index].text), !listAmount(body[index].text) { index += 1 }
            let group = Array(body[start..<index])
            guard listAmount(group[0].text), group.count > 1 else { result.append(review(group)); continue }
            var captionEnd = 1
            while captionEnd < group.count {
                let above = group[captionEnd - 1], current = group[captionEnd]
                let gap = above.box.minY - current.box.maxY
                guard gap >= -height * 0.5, gap < max(above.box.height, current.box.height) * 1.5 else { break }
                captionEnd += 1
            }
            let item = Array(group.prefix(captionEnd))
            if let text = listTransaction(item) {
                // A bare 거래일 label becomes the server's guessed merchant when no name exists.
                let dateText = knownDay != nil && text.contains("\n가맹점: ") ? "거래일: " + knownDay! : dayHint
                result.append(text + "\n" + dateText)
            } else { result.append(review(item)) }
            if captionEnd < group.count { result.append(review(Array(group.dropFirst(captionEnd)))) }
        }
        return result.isEmpty ? nil : result
    }
    private static func listTransaction(_ rows: [Row]) -> String? {
        guard rows.count >= 2, rows.allSatisfy({ $0.box.minY >= 0 }) else { return nil }
        let printed = compact(rows[0].text)
        let money = matches(moneyPattern, printed)
        guard money.count == 1, money[0].range.length == (printed as NSString).length,
              let amount = Int(printed.filter(\.isNumber)), (1...100_000_000_000).contains(amount) else { return nil }
        let caption = rows.dropFirst().map(\.text).joined(separator: " ")
        guard matches(#"광고|예정|실패|거절|쿠폰|문의"#, caption).isEmpty,
              matches(moneyPattern, caption).isEmpty else { return nil }
        let parts = caption.components(separatedBy: CharacterSet(charactersIn: "|｜")).map { $0.trimmingCharacters(in: .whitespaces) }
        guard !parts.contains(where: metadata) else { return nil }
        let action: String
        var merchant: String?
        if parts.contains(where: { !matches(#"(?:^|\s)(?:승인\s*취소|결제\s*취소|취소(?:완료)?|환불(?:완료)?)(?:\s|$)"#, $0).isEmpty }) {
            action = "환불 완료"
            let names = parts.filter { validMerchant($0) && matches(#"카드|취소|환불|승인|입금"#, $0).isEmpty }
            if names.count == 1 { merchant = names[0] }
        } else if parts.count >= 2, printed.hasPrefix("-") || printed.hasPrefix("−"),
                  caption.contains("카드"), validMerchant(parts[0]) {
            action = "카드 결제"; merchant = parts[0]
        } else {
            let arrows = matches(#"->|<-|→|←|>{1,2}|<{1,2}"#, caption)
            guard arrows.count == 1 else { return nil }
            let ns = caption as NSString, arrow = arrows[0].range
            var from = ns.substring(to: arrow.location).trimmingCharacters(in: .whitespaces)
            var to = ns.substring(from: NSMaxRange(arrow)).trimmingCharacters(in: .whitespaces)
            if ["<-", "←", "<", "<<"].contains(ns.substring(with: arrow)) { swap(&from, &to) }
            func own(_ text: String) -> Bool { !matches(#"^(?:내|본인|나의).*(?:통장|계좌)$"#, compact(text)).isEmpty }
            if own(to), !own(from), validMerchant(from), !printed.hasPrefix("-"), !printed.hasPrefix("−") {
                action = "입금"; merchant = from
            } else if own(from), !own(to), validMerchant(to), !printed.hasPrefix("+") {
                action = "출금"; merchant = to
            } else { return nil }
        }
        return listText(action: action, amount: amount, merchant: merchant)
    }
    private static func listText(action: String, amount: Int, merchant: String?) -> String? {
        // The consumer scans the entire body, including names. Do not emit a verified amount
        // when a counterparty word would override this structurally established action.
        let conflicts = action == "환불 완료" ? "" : action == "출금" ? #"취소|환불"#
            : #"취소|환불|송금|이체|출금|내\s*계좌|본인\s*계좌|계좌\s*이동|대체"#
                + (action == "카드 결제" ? #"|입금|급여[\s\S]*지급|지급[\s\S]*급여"# : "")
        guard conflicts.isEmpty || matches(conflicts, merchant ?? "").isEmpty else { return nil }
        var output = [action, "\(amount)원"]
        if let merchant { output.append("가맹점: " + merchant) }
        return output.joined(separator: "\n")
    }
    private static func compact(_ text: String) -> String { text.filter { !$0.isWhitespace } }
    private static func reviewText(_ lines: [PaymentImageOCR.Line]) -> String {
        let review = lines.map { line in
            matches(moneyPattern, line.text).isEmpty ? line.text : "잔액·누적 여부 확인 필요: " + line.text
        }.joined(separator: "\n")
        return "발신 알림: 금액 확인 필요\n" + review
    }
    private static func hasCurrencylessTransaction(_ rows: [Row]) -> Bool {
        for i in rows.indices where !rows[i].text.contains("원") {
            let value = compact(rows[i].text)
            let numbers = matches(#"[+−-]?[0-9Oo][0-9Oo,]*"#, value)
            guard numbers.count == 1 else { continue }
            let remainder = (value as NSString).replacingCharacters(in: numbers[0].range, with: "")
            if kind(remainder) != nil { return true }
            if remainder.isEmpty,
               (i > 0 && kind(rows[i - 1].text) != nil)
                || (i + 1 < rows.count && kind(rows[i + 1].text) != nil) { return true }
        }
        return false
    }
    private static func rows(from lines: [PaymentImageOCR.Line]) -> [Row] {
        let sorted = lines.sorted { $0.box.midY == $1.box.midY ? $0.box.minX < $1.box.minX : $0.box.midY > $1.box.midY }
        var groups: [[PaymentImageOCR.Line]] = []
        for line in sorted {
            if let last = groups.last, let anchor = last.first,
               min(anchor.box.maxY, line.box.maxY) - max(anchor.box.minY, line.box.minY)
                > min(anchor.box.height, line.box.height) * 0.5 {
                groups[groups.count - 1].append(line)
            } else { groups.append([line]) }
        }
        return groups.map { group in
            let ordered = group.sorted { $0.box.minX < $1.box.minX }
            return Row(text: ordered.map(\.text).joined(separator: " "),
                       box: ordered.dropFirst().reduce(ordered[0].box) { $0.union($1.box) })
        }
    }
    private static func header(_ text: String) -> String? {
        let value = compact(text)
        for title in ["요금납부", "입출금알림", "거래알림", "결제알림"] where value.hasPrefix(title) {
            let suffix = String(value.dropFirst(title.count))
            if suffix.isEmpty || !matches(#"^[0-9년월일./:오전후시간분초방금어제오늘-]+$"#, suffix).isEmpty { return title }
        }
        return nil
    }
    private static func metadata(_ text: String) -> Bool {
        // Currency/metadata labels are commonly wrapped: “잔액(원)”, “98,760원 [잔액]”.
        let value = compact(text).filter { !"()[]{}（）［］【】".contains($0) }
        let label = #"(?:(?:거래후|출금후|입금후|현재|남은|출금가능|가용)?잔액|누적(?:이용금액)?|할인(?:금액)?|한도|혜택|캐시백|수수료|합계|총액)"#
        return !matches("^" + label + #"(?:[:：]?[+−-]?[0-9,]*원?)?$"#, value).isEmpty
            || !matches(#"^[+−-]?[0-9,]+원[:：]?"# + label + "$", value).isEmpty
    }
    private static func kind(_ text: String) -> String? {
        var value = compact(text)
        for label in ["거래유형", "거래구분"] where value.hasPrefix(label) {
            value = String(value.dropFirst(label.count)).trimmingCharacters(in: CharacterSet(charactersIn: ":："))
        }
        switch value {
        case "출금", "CMS출금", "출금완료", "자동출금", "자동이체", "이체", "이체완료", "송금", "송금완료": return "transfer"
        case "입금", "CMS입금", "입금완료": return "income"
        case "결제", "결제완료", "카드결제", "승인", "카드승인", "승인완료": return "expense"
        case "환불", "환불완료", "결제취소", "승인취소", "취소완료": return "refund"
        default: return nil
        }
    }
    private static func normalized(_ rows: [Row]) -> String? {
        let raw = rows.map(\.text).joined(separator: "\n")
        guard matches(#"광고|예정|실패|거절|쿠폰|취소\s*문의|환불\s*문의"#, raw).isEmpty else { return nil }
        var excluded = Set<Int>()
        for i in rows.indices where metadata(rows[i].text) {
            excluded.insert(i)
            if matches(moneyPattern, rows[i].text).isEmpty {
                guard i + 1 < rows.count else { return nil }
                let next = rows[i + 1]
                let amounts = matches(moneyPattern, next.text)
                let gap = rows[i].box.minY - next.box.maxY
                guard amounts.count == 1, amounts[0].range.length == (next.text as NSString).length,
                   gap >= -next.box.height * 0.5, gap <= max(next.box.height, rows[i].box.height) * 2.5,
                   min(rows[i].box.maxX, next.box.maxX) > max(rows[i].box.minX, next.box.minX) else { return nil }
                excluded.insert(i + 1)
            }
        }
        var amounts: [(Int, NSTextCheckingResult)] = []
        var kinds = Set<String>()
        for i in rows.indices where !excluded.contains(i) {
            let row = rows[i].text
            let found = matches(moneyPattern, row)
            // A malformed amount must not disappear beside a correctly recognized transaction.
            if found.isEmpty, !matches(#"[0-9Oo][0-9Oo,\s]*원"#, row).isEmpty { return nil }
            if found.isEmpty, !matches(#"[0-9Oo,]+\s*(?:출금|입금|결제|송금|이체)"#, row).isEmpty { return nil }
            for amount in found { amounts.append((i, amount)) }
            let remainder = found.reversed().reduce(row) { ($0 as NSString).replacingCharacters(in: $1.range, with: "") }
            if !found.isEmpty, !matches(#"[0-9Oo]"#, remainder).isEmpty { return nil }
            if let value = kind(remainder) { kinds.insert(value) }
        }
        guard amounts.count == 1, kinds.count == 1, let type = kinds.first else { return nil }
        let (amountIndex, match) = amounts[0]
        let printedAmount = (rows[amountIndex].text as NSString).substring(with: match.range)
        guard let amount = Int(printedAmount.filter(\.isNumber)), (1...100_000_000_000).contains(amount),
              !(type == "income" && printedAmount.contains(where: { "-−".contains($0) })),
              !(type != "income" && printedAmount.contains("+")) else { return nil }
        var merchants = Set<String>()
        var dates = Set<String>()
        for row in rows where !metadata(row.text) {
            let arrows = matches(#"->|<-|→|←|>|<"#, row.text)
            if !arrows.isEmpty {
                guard arrows.count == 1 else { return nil }
                let ns = row.text as NSString, range = arrows[0].range
                let left = ns.substring(to: range.location).trimmingCharacters(in: .whitespaces)
                let right = ns.substring(from: NSMaxRange(range)).trimmingCharacters(in: .whitespaces)
                guard !left.isEmpty, !right.isEmpty else { return nil }
                let reversed = ["←", "<-", "<"].contains(ns.substring(with: range))
                let counterparty = (type == "income") != reversed ? left : right
                guard validMerchant(counterparty) else { return nil }
                merchants.insert(counterparty)
            } else if let prefix = matches(#"^(?:가맹점|사용처|적요|거래처)(?:\s*[:：]\s*|\s+)(.+)$"#, row.text).first {
                let value = (row.text as NSString).substring(with: prefix.range(at: 1)).trimmingCharacters(in: .whitespaces)
                if validMerchant(value) { merchants.insert(value) }
            }
            var datedText = row.text
            if header(row.text) != nil, let title = matches(#"^(?:요금\s*납부|입출금\s*알림|거래\s*알림|결제\s*알림)\s*"#, row.text).first {
                datedText = (row.text as NSString).substring(from: NSMaxRange(title.range))
            }
            if let value = date(datedText) { dates.insert(value) }
        }
        guard merchants.count <= 1 else { return nil }
        let action = ["transfer": "출금", "income": "입금", "expense": "카드 결제", "refund": "환불 완료"][type]!
        var result = [action, "\(amount)원"]
        if let merchant = merchants.first { result.append("가맹점: " + merchant) }
        if dates.count == 1, let value = dates.first {
            // Without an explicit merchant the server otherwise guesses the date label as a name.
            let prefix = merchants.isEmpty ? "발신 알림: " : ""
            result.append(prefix + "거래일: " + String(value.prefix(10)))
            if value.count > 10 { result.append(prefix + value) }
        }
        // UI labels/account balances are not sent as guessed merchants or extra transaction amounts.
        return result.joined(separator: "\n")
    }
    private static func validMerchant(_ text: String) -> Bool {
        let value = compact(text)
        return text.count <= 120 && !matches(#"[가-힣A-Za-z]"#, text).isEmpty
            && !["결제", "입금", "출금", "증명서발급", "증명서발급하기", "이용안내", "거래내역", "알림"].contains(value)
            && kind(value) == nil && matches(moneyPattern, text).isEmpty
    }
    private static func date(_ text: String) -> String? {
        let pattern = #"^(?:(?:거래일시|거래일자|거래일|일시)\s*[:：]?\s*)?([0-9]{4})(?:년|[./-])\s*([0-9]{1,2})(?:월|[./-])\s*([0-9]{1,2})(?:일)?(?:\s+([0-9]{1,2}):([0-9]{2})(?::([0-9]{2}))?)?$"#
        guard let match = matches(pattern, text.trimmingCharacters(in: .whitespaces)).first else { return nil }
        let ns = text.trimmingCharacters(in: .whitespaces) as NSString
        func part(_ index: Int) -> Int? { match.range(at: index).location == NSNotFound ? nil : Int(ns.substring(with: match.range(at: index))) }
        let fields = DateComponents(year: part(1), month: part(2), day: part(3), hour: part(4) ?? 0, minute: part(5) ?? 0, second: part(6) ?? 0)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let value = calendar.date(from: fields), calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: value) == fields else { return nil }
        let day = String(format: "%04d-%02d-%02d", part(1)!, part(2)!, part(3)!)
        return part(4).map { day + String(format: " %02d:%02d", $0, part(5)!) } ?? day
    }
}
