import Foundation
import Observation

/// Closed diagnostic fields only: never retain notification text, event IDs or error bodies.
struct NotificationDeliveryRecord: Codable, Identifiable {
    enum Stage: String, Codable {
        case started, filterExcluded, submitting, serverAcknowledged, testing, testAcknowledged, failed, cancelled
        var unfinished: Bool { self == .started || self == .submitting || self == .testing }
        var title: String {
            switch self {
            case .started: return "동작 시작 · 완료 미확인"
            case .filterExcluded: return "거래 알림 필터에서 제외"
            case .submitting: return "서버 전송 시작 · 완료 미확인"
            case .serverAcknowledged: return "서버 응답 확인"
            case .testing: return "연결 테스트 중 · 완료 미확인"
            case .testAcknowledged: return "연결 테스트 응답 확인"
            case .failed: return "전달 오류 · 완료 미확인"
            case .cancelled: return "동작 취소 · 완료 미확인"
            }
        }
    }
    let id: UUID
    let startedAt: Date
    var updatedAt: Date
    var stage: Stage
    var failedStage: Stage?
}

enum NotificationDeliveryContext {
    struct Invocation: Sendable { let id: UUID; let identity: String }
    @TaskLocal static var current: Invocation?
}

@Observable @MainActor final class ShortcutOpening {
    enum Destination: String {
        case install, edit, app
        var url: URL {
            switch self {
            case .install: return URL(string: "https://www.icloud.com/shortcuts/7c1640958955451a804c96164b0e5697")!
            case .app: return URL(string: "shortcuts://")!
            case .edit:
                var parts = URLComponents(string: "shortcuts://open-shortcut")!
                parts.queryItems = [URLQueryItem(name: "name", value: "결제 알림 자동 수신")]
                return parts.url!
            }
        }
    }
    private(set) var destination: Destination?
    private(set) var error: String?
    private(set) var requestedInstaller = false

    func open(_ target: Destination, using openURL: (URL) async -> Bool) async {
        guard destination == nil else { return }
        destination = target
        error = nil
        defer { destination = nil }
        guard await openURL(target.url) else {
            error = "단축어 화면을 열지 못했어요. 다시 누르거나 아래 도움말에서 직접 열어주세요."
            return
        }
        // shortcut: iOS reports URL handoff, not the screen; retain recovery until a navigation callback exists.
        if target == .install { requestedInstaller = true }
    }
}

/// Only a fresh notification round trip can verify the connection; opening Shortcuts cannot.
struct NotificationSetupState {
    let defaults: UserDefaults
    let identity: String
    private var prefix: String { "notificationSetup.v1." + identity + "." }
    // LiveActivityIntent invocations run in the app process. Protect the entire read/write,
    // including reset, so overlapping calls cannot replace one another's records.
    private static let deliveryLock = NSLock()
    private var storedDeliveries: [NotificationDeliveryRecord] {
        guard let data = defaults.data(forKey: prefix + "deliveries"),
              let records = try? JSONDecoder().decode([NotificationDeliveryRecord].self, from: data) else { return [] }
        return records
    }
    var deliveries: [NotificationDeliveryRecord] {
        Self.deliveryLock.lock(); defer { Self.deliveryLock.unlock() }
        return storedDeliveries
    }
    private func saveDeliveries(_ records: [NotificationDeliveryRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: prefix + "deliveries")
    }
    func beginDelivery(now: Date = Date()) -> UUID {
        Self.deliveryLock.lock(); defer { Self.deliveryLock.unlock() }
        let record = NotificationDeliveryRecord(id: UUID(), startedAt: now, updatedAt: now, stage: .started)
        saveDeliveries(Array(([record] + storedDeliveries).prefix(20)))
        return record.id
    }
    func recordDelivery(_ id: UUID, stage: NotificationDeliveryRecord.Stage, now: Date = Date()) {
        Self.deliveryLock.lock(); defer { Self.deliveryLock.unlock() }
        var records = storedDeliveries
        // Reset/evicted records stay removed; terminal server acknowledgements stay terminal.
        guard let index = records.firstIndex(where: { $0.id == id }), records[index].stage.unfinished else { return }
        if stage == .failed || stage == .cancelled { records[index].failedStage = records[index].stage }
        records[index].stage = stage
        records[index].updatedAt = now
        saveDeliveries(records)
    }
    var configured: Bool {
        get { defaults.bool(forKey: prefix + "configured") }
        nonmutating set { defaults.set(newValue, forKey: prefix + "configured") }
    }
    var introSeen: Bool {
        get { defaults.bool(forKey: prefix + "introSeen.v2") }
        nonmutating set { defaults.set(newValue, forKey: prefix + "introSeen.v2") }
    }
    var featureTourSeen: Bool {
        get { defaults.bool(forKey: prefix + "featureTourSeen") }
        nonmutating set { defaults.set(newValue, forKey: prefix + "featureTourSeen") }
    }
    var verifiedAt: Date? { defaults.object(forKey: prefix + "verifiedAt") as? Date }
    var receivedAt: Date? { defaults.object(forKey: prefix + "receivedAt") as? Date }
    var testStartedAt: Date? { defaults.object(forKey: prefix + "testStartedAt") as? Date }
    static let testMarker = "[우리 가계부 연결 테스트]"

    // Only generated practice/test IDs and timestamps are retained, never notification bodies.
    private struct PendingToken: Codable {
        let token: String
        let startedAt: Date
        func valid(at now: Date, lifetime: TimeInterval) -> Bool {
            (0...lifetime).contains(now.timeIntervalSince(startedAt))
        }
    }
    // Call only while holding deliveryLock. Public methods never call one another under it.
    private func tokens(_ kind: String) -> [PendingToken] {
        let key = prefix + kind + "Queue.v2"
        if let data = defaults.data(forKey: key) {
            return (try? JSONDecoder().decode([PendingToken].self, from: data)) ?? []
        }
        var records: [PendingToken] = []
        if let token = defaults.string(forKey: prefix + kind + "Token"), !token.isEmpty,
           let date = defaults.object(forKey: prefix + kind + "StartedAt") as? Date {
            records.append(PendingToken(token: token, startedAt: date))
        }
        // Persist even an empty queue before removing legacy keys: consumed tokens cannot return.
        saveTokens(records, kind: kind)
        defaults.removeObject(forKey: prefix + kind + "Token")
        if kind == "practice" { defaults.removeObject(forKey: prefix + "practiceStartedAt") }
        return records
    }
    private func saveTokens(_ records: [PendingToken], kind: String) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: prefix + kind + "Queue.v2")
    }
    private func ordered(_ records: [PendingToken]) -> [PendingToken] {
        // Preserve insertion order for equal timestamps.
        records.enumerated().sorted {
            $0.element.startedAt == $1.element.startedAt ? $0.offset < $1.offset : $0.element.startedAt < $1.element.startedAt
        }.map(\.element)
    }
    private func contains(_ token: String, in text: String) -> Bool {
        // Do not accept a valid token as the prefix of a different, longer ID.
        let pattern = "(?<![A-Za-z0-9])" + NSRegularExpression.escapedPattern(for: token) + "(?![A-Za-z0-9])"
        return text.range(of: pattern, options: .regularExpression) != nil
    }
    func beginTest(now: Date = Date()) -> String {
        Self.deliveryLock.lock(); defer { Self.deliveryLock.unlock() }
        var records = tokens("test").filter { $0.valid(at: now, lifetime: 300) }
        let sample = defaults.integer(forKey: prefix + "practiceSample") % 20 + 1
        defaults.set(sample, forKey: prefix + "practiceSample")
        var token: String
        repeat {
            token = Self.testMarker + " " + String(UInt64.random(in: 100_000_000_000...999_999_999_999)) + "-sample-\(sample)"
        } while records.contains(where: { $0.token == token })
        records.append(PendingToken(token: token, startedAt: now))
        saveTokens(Array(ordered(records).suffix(20)), kind: "test")
        defaults.set(now, forKey: prefix + "testStartedAt")
        return token
    }
    static func practiceAmount(_ token: String) -> Int {
        guard let suffix = token.components(separatedBy: "-sample-").last,
              token.contains("-sample-"), let sample = Int(suffix), (1...20).contains(sample) else { return 8400 }
        return sample * 100
    }
    func matchesTest(_ text: String, now: Date = Date()) -> Bool {
        Self.deliveryLock.lock(); defer { Self.deliveryLock.unlock() }
        return tokens("test").contains { $0.valid(at: now, lifetime: 300) && contains($0.token, in: text) }
    }
    @discardableResult func confirmTest(_ text: String, now: Date = Date()) -> Bool {
        Self.deliveryLock.lock(); defer { Self.deliveryLock.unlock() }
        var records = tokens("test")
        guard let index = records.firstIndex(where: { $0.valid(at: now, lifetime: 300) && contains($0.token, in: text) }) else { return false }
        records.remove(at: index)
        saveTokens(records, kind: "test")
        defaults.set(now, forKey: prefix + "verifiedAt")
        configured = true
        return true
    }
    func received(now: Date = Date()) { defaults.set(now, forKey: prefix + "receivedAt"); configured = true }
    var practiceCompletedAt: Date? { defaults.object(forKey: prefix + "practiceCompletedAt") as? Date }
    var practiceToken: String? {
        Self.deliveryLock.lock(); defer { Self.deliveryLock.unlock() }
        return ordered(tokens("practice")).last?.token
    }
    func beginPractice(_ token: String, now: Date = Date()) {
        Self.deliveryLock.lock(); defer { Self.deliveryLock.unlock() }
        guard !token.isEmpty else { return }
        var records = tokens("practice").filter { $0.token != token && $0.valid(at: now, lifetime: 600) }
        records.append(PendingToken(token: token, startedAt: now))
        saveTokens(Array(ordered(records).suffix(20)), kind: "practice")
    }
    func pendingPracticeTokens(now: Date = Date()) -> [String] {
        Self.deliveryLock.lock(); defer { Self.deliveryLock.unlock() }
        return ordered(tokens("practice").filter { $0.valid(at: now, lifetime: 600) }).map(\.token)
    }
    func practiceDate(_ token: String) -> Date? {
        Self.deliveryLock.lock(); defer { Self.deliveryLock.unlock() }
        return tokens("practice").first { $0.token == token }?.startedAt
    }
    func practiceToken(in text: String, now: Date = Date()) -> String? {
        Self.deliveryLock.lock(); defer { Self.deliveryLock.unlock() }
        return ordered(tokens("practice")).first { $0.valid(at: now, lifetime: 600) && contains($0.token, in: text) }?.token
    }
    func matchesPractice(_ token: String, now: Date = Date()) -> Bool {
        Self.deliveryLock.lock(); defer { Self.deliveryLock.unlock() }
        return tokens("practice").contains { $0.token == token && $0.valid(at: now, lifetime: 600) }
    }
    @discardableResult func completePractice(_ token: String, now: Date = Date()) -> Bool {
        Self.deliveryLock.lock(); defer { Self.deliveryLock.unlock() }
        var records = tokens("practice")
        guard let index = records.firstIndex(where: { $0.token == token && $0.valid(at: now, lifetime: 600) }) else { return false }
        records.remove(at: index)
        saveTokens(records, kind: "practice")
        defaults.set(now, forKey: prefix + "practiceCompletedAt")
        return true
    }
    func discardPractice(_ token: String) {
        Self.deliveryLock.lock(); defer { Self.deliveryLock.unlock() }
        saveTokens(tokens("practice").filter { $0.token != token }, kind: "practice")
        saveTokens(tokens("test").filter { $0.token != token }, kind: "test")
    }
    func reset() {
        Self.deliveryLock.lock(); defer { Self.deliveryLock.unlock() }
        for key in ["configured", "verifiedAt", "receivedAt", "testToken", "testStartedAt", "practiceToken", "practiceStartedAt", "practiceCompletedAt", "testQueue.v2", "practiceQueue.v2", "practiceSample", "deliveries"] {
            defaults.removeObject(forKey: prefix + key)
        }
    }
    static func isPayment(_ text: String) -> Bool {
        guard !text.contains(testMarker), !text.contains("공용으로 쓴 돈인가요?"), !text.contains("눌러서 기록해 주세요.") else { return false }
        // Keep notice filtering aligned with server/ledger.py's notification_notice_reason.
        let completed = text.range(of: #"승인(?!\s*(?:번호|예정))|(?:결제|출금|입금|송금|이체|환불|취소)\s*완료"#, options: .regularExpression) != nil
        let noticeText = completed ? text.replacingOccurrences(of: #"결제\s*예정일"#, with: "", options: .regularExpression) : text
        guard noticeText.range(of: #"(?:출금|결제|청구|입금|지급|송금|이체)\s*(?:할|될)?\s*예정|(?:청구|결제일)\s*안내"#, options: .regularExpression) == nil else { return false }
        if !completed, text.range(of: #"쿠폰\s*(?:번호|발송|지급|안내)|쿠폰(?:을|이)\s*(?:드립|발송|지급)"#, options: .regularExpression) != nil { return false }
        let transactionText = text.replacingOccurrences(of: #"(?:취소|환불)(?:\s*(?:/|및|·)\s*(?:취소|환불))*\s*(?:이|가|은|는)?\s*불가"#, with: "", options: .regularExpression)
        let promotion = #"\[\s*광고\s*\]|\(\s*광고\s*\)|결제\s*(?:시(?:\s|[,，])|하면)|한도\s*안내"#
        guard text.range(of: promotion, options: .regularExpression) == nil else { return false }
        if text.range(of: "할인|쿠폰|캐시백|혜택", options: .regularExpression) != nil,
           transactionText.range(of: "승인|취소|환불|결제\\s*완료|입금|출금|송금\\s*완료|이체\\s*완료", options: .regularExpression) == nil { return false }
        let money = #"(?:\d[\d,]*(?:\.\d+)?\s*(?:원|KRW|USD|JPY|EUR|달러|엔)|(?:₩|\$|KRW|USD|JPY|EUR)\s*[\d,]+(?:\.\d+)?)"#
        return text.range(of: money, options: [.regularExpression, .caseInsensitive]) != nil
            && transactionText.range(of: "승인|결제|출금|이체|송금|취소|환불|입금|지급", options: .regularExpression) != nil
    }
}

struct PaymentActivityLink {
    let id, identity: String
    let scope: String?
    let practice: Bool
    init?(_ url: URL, identity: String) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "ourledger", parts.host == "payment", parts.path.isEmpty,
              parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil else { return nil }
        let items = parts.queryItems ?? []
        guard Set(items.map(\.name)).count == items.count,
              items.allSatisfy({ ["id", "identity", "scope", "practice"].contains($0.name) }) else { return nil }
        func value(_ key: String) -> String? { items.first { $0.name == key }?.value }
        guard value("identity") == identity, let id = value("id"), !id.isEmpty, id.count <= 200,
              value("scope") == nil || ["shared", "personal", "ignore"].contains(value("scope")!),
              value("practice") == nil || value("practice") == "true" else { return nil }
        self.id = id; self.identity = identity; self.scope = value("scope"); self.practice = value("practice") == "true"
    }
}

struct PaymentNotificationRoute: Identifiable {
    let id, identity, rawText: String
    let scope: String?
    let practice: Bool
    let ignored: Bool
}

enum LedgerFlowPresentation: Identifiable {
    case guide(introductory: Bool)
    case payment(PaymentNotificationRoute)
    var id: String {
        switch self { case .guide: return "guide"; case .payment(let route): return "payment-" + route.id }
    }
}

@MainActor @Observable final class PaymentNotificationRouter {
    static let shared = PaymentNotificationRouter()
    var presentation: LedgerFlowPresentation?
    var resumeGuide = false
    var showTourRequested = false
    private(set) var queued: [PaymentNotificationRoute] = []
    func showGuide(introductory: Bool = false) { presentation = .guide(introductory: introductory) }
    func receive(_ route: PaymentNotificationRoute) {
        if case .guide = presentation { resumeGuide = true }
        if route.practice { resumeGuide = true }
        if case .payment(let current) = presentation {
            guard current.id != route.id || current.identity != route.identity || current.practice != route.practice else { return }
            guard !queued.contains(where: { $0.id == route.id && $0.identity == route.identity && $0.practice == route.practice }) else { return }
            queued.append(route)
            return
        }
        presentation = .payment(route)
    }
    @discardableResult func showNextQueued() -> Bool {
        guard presentation == nil, !queued.isEmpty else { return false }
        presentation = .payment(queued.removeFirst())
        return true
    }
    func deferQueued() { queued.removeAll() }
    func connectionChanged(identity: String?) {
        queued.removeAll { $0.identity != identity }
        if case .payment(let route) = presentation, route.identity != identity {
            presentation = nil; resumeGuide = false; showTourRequested = false
        }
    }
}
