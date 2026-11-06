import Foundation

struct LedgerWidgetData: Codable {
    static let appGroup = "group.com.hwangsoonhwan.OurLedger"
    private static let cacheKey = "LedgerSummaryWidget.data"

    let month: String
    let sharedTotal: Int
    let personalTotal: Int
    let mySharedTotal: Int
    let partnerSharedTotal: Int?
    let updatedAt: Date

    static func currentMonth(at date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Seoul")
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: date)
    }

    static func read(at now: Date = Date(), defaults: UserDefaults? = UserDefaults(suiteName: appGroup)) -> LedgerWidgetData? {
        guard let bytes = defaults?.data(forKey: cacheKey),
              let data = try? JSONDecoder().decode(Self.self, from: bytes),
              data.month == currentMonth(at: now) else { return nil }
        return data
    }

    func write(to defaults: UserDefaults? = UserDefaults(suiteName: Self.appGroup)) throws {
        guard let defaults else { throw CocoaError(.fileWriteNoPermission) }
        // One encoded value keeps the month and all four amounts in the same cache snapshot.
        defaults.set(try JSONEncoder().encode(self), forKey: Self.cacheKey)
    }
}
