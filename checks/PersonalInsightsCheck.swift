import Foundation

@main struct PersonalInsightsCheck {
    static func main() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        var body = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        func snapshot() throws -> LedgerSnapshot {
            try JSONDecoder().decode(LedgerSnapshot.self, from: JSONSerialization.data(withJSONObject: body))
        }
        let legacy = try snapshot()
        precondition(legacy.personalStats == nil)
        let empty = LedgerInsights(snapshot: legacy, scope: "personal", month: "2026-10")
        precondition(empty.total == 0 && empty.incomeTotal == 0 && empty.byCategory.isEmpty)
        precondition(empty.historyStats == nil, "Missing history is unknown, not a zero previous month")
        body["entries"] = [
            entry("coffee", "expense", 8_000), entry("refund", "refund", 10_000),
            entry("trip", "expense", 5_000, category: "travel", day: "2026-10-02"),
            entry("salary", "income", 70_000), entry("deposit", "deposit", 90_000),
            entry("partner", "expense", 100_000, owner: "test-b"),
            entry("partner-income", "income", 120_000, owner: "test-b"),
            entry("shared", "expense", 200_000, scope: "shared"),
            entry("shared-income", "income", 30_000, scope: "shared"),
            entry("old", "expense", 300_000, day: "2026-09-30"),
            entry("future", "expense", 400_000, day: "2026-11-01")
        ]
        let fallback = LedgerInsights(snapshot: try snapshot(), scope: "personal", month: "2026-10")
        precondition(fallback.total == 3_000 && fallback.incomeTotal == 70_000)
        precondition(Set(fallback.spending.map(\.id)) == ["coffee", "refund", "trip"])
        precondition(fallback.byCategory.map(\.id) == ["travel", "cafe"])
        precondition(fallback.byCategory.map(\.amount) == [5_000, -2_000], "Refund excess remains negative")
        precondition(fallback.daily.count == 31 && fallback.daily[0].amount == -2_000 && fallback.daily[1].amount == 5_000)
        precondition(fallback.daily.reduce(0) { $0 + $1.amount } == fallback.total)
        precondition(fallback.historyStats == nil)

        var sharedStats = body["stats"] as! [String: Any]
        sharedStats["total"] = 200_000
        sharedStats["previousTotal"] = 150_000
        sharedStats["budgetRemaining"] = 10_000
        body["stats"] = sharedStats
        let shared = LedgerInsights(snapshot: try snapshot(), scope: "shared", month: "2026-10")
        precondition(shared.total == 200_000 && shared.incomeTotal == 30_000)
        precondition(shared.spending.map(\.id) == ["shared"])
        precondition(shared.historyStats?.previousTotal == 150_000)

        var personalStats = sharedStats
        personalStats["total"] = 3_000
        personalStats["previousTotal"] = 9_000
        personalStats["incomeTotal"] = 70_000
        personalStats["comparisonTotal"] = 1_000
        personalStats["comparisonPreviousTotal"] = 2_000
        personalStats["comparisonThroughDay"] = 10
        personalStats["byCategory"] = [["id": "cafe", "name": "카페", "amount": -2_000], ["id": "travel", "name": "여행", "amount": 5_000]]
        personalStats["daily"] = [["day": "2026-10-01", "amount": -2_000], ["day": "2026-10-02", "amount": 5_000]]
        personalStats["trend"] = (5...10).map { ["month": String(format: "2026-%02d", $0), "amount": $0 * 100] as [String: Any] }
        body["personalStats"] = personalStats
        let reported = LedgerInsights(snapshot: try snapshot(), scope: "personal", month: "2026-10")
        precondition(reported.total == 3_000 && reported.incomeTotal == 70_000)
        precondition(reported.byCategory.map(\.amount) == [-2_000, 5_000] && reported.daily.count == 2)
        precondition(reported.historyStats?.previousTotal == 9_000 && reported.historyStats?.trend.count == 6)
        precondition(reported.historyStats?.comparisonTotal == 1_000 && reported.historyStats?.comparisonPreviousTotal == 2_000)
        precondition(reported.historyStats?.comparisonThroughDay == 10)
        let sharedAfterPersonal = LedgerInsights(snapshot: try snapshot(), scope: "shared", month: "2026-10")
        precondition(sharedAfterPersonal.total == 200_000)
        body["personalStats"] = NSNull()
        let nullStats = try snapshot()
        precondition(nullStats.personalStats == nil)
        precondition(LedgerInsights(snapshot: nullStats, scope: "personal", month: "2026-10").historyStats == nil)

        body["entries"] = [entry("full-expense", "expense", 10), entry("full-refund", "refund", 10)]
        let zero = LedgerInsights(snapshot: try snapshot(), scope: "personal", month: "2026-10")
        precondition(zero.total == 0 && zero.spending.count == 2 && zero.byCategory.first?.amount == 0)
        body["entries"] = [entry("income-only", "income", 100)]
        let incomeOnly = LedgerInsights(snapshot: try snapshot(), scope: "personal", month: "2026-10")
        precondition(incomeOnly.spending.isEmpty && incomeOnly.total == 0 && incomeOnly.incomeTotal == 100)
        print("PASS: legacy/null compatibility, own-personal/month isolation, signed refunds, deposits excluded, income separate, zero/empty states, server stats and historical comparison routing")
    }

    static func entry(_ id: String, _ kind: String, _ amount: Int, owner: String = "test-a",
                      scope: String = "personal", category: String = "cafe", day: String = "2026-10-01") -> [String: Any] {
        ["id": id, "owner": owner, "payer": owner, "scope": scope, "kind": kind,
         "funding": "personal", "note": "검증", "category": category, "day": day, "amount": amount]
    }
}
