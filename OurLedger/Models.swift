import Foundation

struct LedgerSnapshot: Decodable {
    let household: Household
    let me: String
    let members: [Member]
    let categories: [Category]
    let entries: [Entry]
    let inbox: [ImportedMessage]
    let stats: LedgerStats
    let personalStats: LedgerStats?
    let settlement: SettlementPreview
    let history: [SettlementRecord]
    let pendingSettlements: [SettlementDue]?
    let settlementCandidates: [SettlementCandidate]?
    let classificationRules: [String: String]?
    let importStatus: ImportStatus?
    let recurringPayments: [RecurringPayment]?
    let monthNavigation: MonthNavigation?
    func memberName(_ id: String) -> String { id == "fund" ? "공동자금" : members.first { $0.id == id }?.name ?? "상대" }
    func categoryName(_ id: String) -> String { categories.first { $0.id == id }?.name ?? "미분류" }
    func recommendedCategory(for note: String) -> Category? {
        guard let classificationRules, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        func normal(_ text: String) -> String {
            text.components(separatedBy: .whitespacesAndNewlines).joined()
                .folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
        }
        let key = normal(note)
        if let id = classificationRules[key], let category = categories.first(where: { $0.id == id }) { return category }
        let matches = categories.filter { category in category.keywords.contains { key.contains(normal($0)) } }
        return matches.count == 1 ? matches.first : categories.first { $0.name == "미분류" }
    }
}

struct MonthNavigation: Decodable {
    let previous, next: String?
}

struct Household: Decodable { let id, name, mode: String; let budget: Int }
struct Member: Decodable, Identifiable { let id, name, bank, account, holder: String }
struct Category: Decodable, Identifiable { let id, name: String; let keywords: [String] }
struct Entry: Decodable, Identifiable {
    let id, owner, payer, scope, kind, funding, note, category, day: String
    let amount: Int
    let settlement: String?
    let importID: String?
    let refundOf: String?
    let recurringID, recurringMonth: String?
    var signedAmount: Int { kind == "income" ? 0 : kind == "refund" ? -amount : amount }
    func validateSubmission(_ body: [String: Any]) throws {
        guard scope == body["scope"] as? String else {
            throw APIError(message: "이전 요청에서 이미 " + (scope == "personal" ? "개인" : "공용") + "으로 기록됐어요. 요청한 공개 범위로 바뀌지 않았어요. 가계부에서 기존 내역을 확인해 주세요.")
        }
        let fields = ["note": note, "kind": kind, "funding": funding, "payer": payer, "day": day, "category": category, "recurringID": recurringID ?? "", "recurringMonth": recurringMonth ?? ""]
        let changed = fields.contains { key, value in
            guard let expected = body[key] as? String else { return false }
            return value != (key == "note" ? expected.trimmingCharacters(in: .whitespacesAndNewlines) : expected)
        }
        guard amount == body["amount"] as? Int, !changed else {
            throw APIError(message: "이전 요청에서 이미 다른 내용으로 기록됐어요. 가계부에서 기존 내역을 확인한 뒤 수정해 주세요.")
        }
    }
}
struct PaymentRecognition: Decodable {
    let merchant, kind, card, reference, reason: String
    let amount: Int?
    let time: String?
    let requiresReview: Bool
}

struct ImportedMessage: Decodable, Identifiable {
    let id, owner, raw, status, merchant, kind, card, reference, reason: String
    let amount: Int?
    let time: String?
    let sources, candidates: [String]
    let requiresReview: Bool
    let candidateDetails: [ImportCandidate]?
    let receivedAt: String?
    var needsDuplicateComparison: Bool { !candidates.isEmpty }
}
struct ImportCandidate: Decodable, Identifiable {
    let id, merchant, kind, status: String
    let amount: Int?
    let time: String?
    let sources: [String]
}
struct ImportStatus: Decodable { let lastReceivedAt, lastShortcutAt: String? }
struct RecurringPayment: Decodable, Identifiable {
    let id, owner, note, scope, category, payer, funding, startDay: String
    let amount, dayOfMonth: Int
    let active: Bool
    let dueDay, entryID: String?
}
struct AmountGroup: Decodable, Identifiable { let id, name: String; let amount: Int }
struct DailyAmount: Decodable, Identifiable { let day: String; let amount: Int; var id: String { day } }
struct MonthlyAmount: Decodable, Identifiable { let month: String; let amount: Int; var id: String { month } }
struct LedgerStats: Decodable {
    let total, previousTotal, delta, budgetRemaining, personalTotal, fundBalance: Int
    let byCategory, byMember: [AmountGroup]
    let daily: [DailyAmount]
    let trend: [MonthlyAmount]
    let comparisonTotal, comparisonPreviousTotal, comparisonThroughDay: Int?
    let incomeTotal, personalIncomeTotal: Int?
}

struct LedgerInsights {
    let entries, spending: [Entry]
    let total, incomeTotal: Int
    let byCategory: [AmountGroup]
    let daily: [DailyAmount]
    // A legacy response has no personal history; never synthesize a zero comparison.
    let historyStats: LedgerStats?

    init(snapshot: LedgerSnapshot, scope: String, month: String) {
        let rows = snapshot.entries.filter {
            $0.scope == scope && (scope == "shared" || $0.owner == snapshot.me)
                && String($0.day.prefix(7)) == month
        }
        let expenses = rows.filter { ["expense", "refund"].contains($0.kind) }
        let reported = scope == "shared" ? snapshot.stats : snapshot.personalStats
        entries = rows
        spending = expenses
        historyStats = reported
        total = reported?.total ?? expenses.reduce(0) { $0 + $1.signedAmount }
        incomeTotal = reported?.incomeTotal ?? rows.filter { $0.kind == "income" }.reduce(0) { $0 + $1.amount }
        if let reported {
            byCategory = reported.byCategory
            daily = reported.daily
        } else {
            byCategory = Dictionary(grouping: expenses, by: \.category).map { id, entries in
                AmountGroup(id: id, name: snapshot.categoryName(id), amount: entries.reduce(0) { $0 + $1.signedAmount })
            }.sorted { $0.amount == $1.amount ? $0.id < $1.id : $0.amount > $1.amount }
            let amounts = Dictionary(grouping: expenses, by: \.day).mapValues { entries in
                entries.reduce(0) { $0 + $1.signedAmount }
            }
            daily = ledgerMonthDays(month).compactMap { $0 }.map { DailyAmount(day: $0, amount: amounts[$0] ?? 0) }
        }
    }
}
struct SettlementPreview: Decodable {
    let fromID, toID, kind, revision: String
    let amount, count: Int
    let memberAmounts: [AmountGroup]
}
struct SettlementRecord: Decodable, Identifiable {
    let id, month, fromID, toID, kind, date: String
    let amount, count: Int
}
struct SettlementDue: Decodable, Identifiable {
    let month, fromID, toID, revision: String
    let amount, count: Int
    let memberID: String?
    var id: String { month + ":" + (memberID ?? "") }
}
struct SettlementCandidate: Decodable, Identifiable {
    let importID: String
    let due: SettlementDue
    var id: String { importID + ":" + due.id }
}
struct AuthResponse: Decodable { let token, memberID, householdID: String }
struct InviteResponse: Decodable { let invite: String; let expiresIn: Int }
struct EmptyResponse: Decodable {}
struct APIError: LocalizedError {
    let message: String
    let statusCode: Int?
    init(message: String, statusCode: Int? = nil) { self.message = message; self.statusCode = statusCode }
    var errorDescription: String? { message }
}

func won(_ value: Int) -> String { value.formatted(.number.locale(Locale(identifier: "ko_KR"))) + "원" }
func parsedWon(_ text: String) -> Int? {
    guard text.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ",") }),
          let value = Int(text.replacingOccurrences(of: ",", with: "")), value > 0, value <= 100_000_000_000 else { return nil }
    return value
}
func formattedWonInput(_ text: String) -> String {
    guard text.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ",") }),
          let value = Int(text.replacingOccurrences(of: ",", with: "")) else { return text }
    return value.formatted(.number.locale(Locale(identifier: "ko_KR")))
}
func dayString(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "Asia/Seoul")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
}
func parseDay(_ day: String) -> Date {
    ISO8601DateFormatter().date(from: day + "T12:00:00+09:00") ?? Date()
}

func ledgerMonthDays(_ month: String) -> [String?] {
    let pieces = month.split(separator: "-")
    guard pieces.count == 2, month.count == 7, let year = Int(pieces[0]), let number = Int(pieces[1]),
          (1...9999).contains(year), (1...12).contains(number) else { return [] }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
    guard let date = calendar.date(from: DateComponents(year: year, month: number, day: 1, hour: 12)),
          let range = calendar.range(of: .day, in: .month, for: date) else { return [] }
    let leading = calendar.component(.weekday, from: date) - 1
    var days: [String?] = Array(repeating: nil, count: leading)
    days += range.map { String(format: "%04d-%02d-%02d", year, number, $0) }
    days += Array(repeating: nil, count: (7 - days.count % 7) % 7)
    return days
}

func compactCalendarWon(_ amount: Int) -> String {
    let magnitude = abs(amount)
    let scale = magnitude >= 100_000_000 ? 100_000_000 : magnitude >= 10_000 ? 10_000 : 1
    let suffix = scale == 100_000_000 ? "억" : scale == 10_000 ? "만" : ""
    let value = (Double(magnitude) / Double(scale)).formatted(.number.locale(Locale(identifier: "ko_KR")).precision(.fractionLength(0...(scale == 1 ? 0 : 1))))
    return (amount < 0 ? "−" : "") + value + suffix
}

func recurringLinkCandidate(_ entry: Entry, payment: RecurringPayment, month: String, me: String) -> Bool {
    payment.owner == me && entry.owner == me && entry.kind == "expense" && entry.recurringID == nil
        && String(entry.day.prefix(7)) == month && entry.scope == payment.scope
        && entry.payer == payment.payer && entry.funding == payment.funding && entry.amount == payment.amount
}

func recurringCreationMatches(_ payment: RecurringPayment, body: [String: Any], owner: String) -> Bool {
    let fields = ["id": payment.id, "note": payment.note, "scope": payment.scope,
                  "payer": payment.payer, "funding": payment.funding, "startDay": payment.startDay]
    return payment.owner == owner && fields.allSatisfy { body[$0.key] as? String == $0.value }
        && body["amount"] as? Int == payment.amount && body["dayOfMonth"] as? Int == payment.dayOfMonth
        && body["active"] as? Bool == payment.active
        && (body["category"] as? String == "" || body["category"] as? String == payment.category)
}

func validRecurringNote(_ note: String) -> Bool {
    let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmed.isEmpty && trimmed.unicodeScalars.count <= 120 && !note.contains(where: { $0.isNewline })
}

// Reuse a request only for the exact same draft, including after switching input methods.
struct ImportSubmissionIDs {
    private var ids: [String: String] = [:]
    mutating func id(source: String, text: String) -> String {
        let key = source + "\0" + text
        if let id = ids[key] { return id }
        let id = UUID().uuidString
        ids[key] = id
        return id
    }
}
