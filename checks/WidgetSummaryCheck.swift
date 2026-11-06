import Foundation

@main
struct WidgetSummaryCheck {
    static func main() throws {
        let now = ISO8601DateFormatter().date(from: "2026-10-31T14:59:59Z")!
        let nextMonth = now.addingTimeInterval(1)
        func entry(_ id: String, payer: String = "me", owner: String = "me", scope: String = "shared",
                   kind: String = "expense", funding: String = "personal", month: String = "2026-10", amount: Int) -> [String: Any] {
            ["id": id, "owner": owner, "payer": payer, "scope": scope, "kind": kind,
             "funding": funding, "note": "검증용", "category": "other", "day": month + "-01", "amount": amount]
        }
        func snapshot(partner: Bool = true) throws -> LedgerSnapshot {
            let member: (String) -> [String: String] = { ["id": $0, "name": $0, "bank": "", "account": "", "holder": ""] }
            let body: [String: Any] = [
                "household": ["id": "test", "name": "검증용", "mode": "pool", "budget": 0],
                "me": "me", "members": partner ? [member("me"), member("other")] : [member("me")],
                "categories": [], "inbox": [], "history": [],
                "entries": [entry("mine", amount: 100), entry("pool", funding: "fund", amount: 200),
                    entry("refund", kind: "refund", funding: "fund", amount: 30),
                    entry("other", payer: "other", owner: "other", funding: "fund", amount: 80),
                    entry("other-refund", payer: "other", owner: "other", kind: "refund", amount: 10),
                    entry("deposit", kind: "deposit", funding: "fund", amount: 9_000),
                    entry("shared-income", kind: "income", amount: 500_000),
                    entry("partner-income", payer: "other", owner: "other", kind: "income", amount: 700_000),
                    entry("personal", scope: "personal", amount: 70),
                    entry("personal-income", scope: "personal", kind: "income", amount: 3_000_000),
                    entry("personal-refund", scope: "personal", kind: "refund", amount: 20),
                    entry("private-other", payer: "other", owner: "other", scope: "personal", amount: 8_000),
                    entry("previous", month: "2026-09", amount: 7_000)],
                "stats": ["total": 999, "previousTotal": 0, "delta": 0, "budgetRemaining": 0,
                    "personalTotal": 999, "fundBalance": 0, "byCategory": [], "byMember": [], "daily": [], "trend": []],
                "settlement": ["fromID": "", "toID": "", "kind": "", "revision": "", "amount": 0, "count": 0, "memberAmounts": []],
                "recurringPayments": [["id": "planned", "owner": "me", "note": "예정", "scope": "shared",
                    "category": "other", "payer": "me", "funding": "personal", "startDay": "2026-10-01",
                    "amount": 999_999, "dayOfMonth": 31, "active": true]]
            ]
            return try JSONDecoder().decode(LedgerSnapshot.self, from: JSONSerialization.data(withJSONObject: body))
        }
        let pairedSnapshot = try snapshot()
        let data = LedgerWidgetPublisher.summary(pairedSnapshot, month: "2026-10", now: now)!
        assert(data.sharedTotal == 340 && data.mySharedTotal == 270 && data.partnerSharedTotal == 70,
               "Pool spending and refunds must count by payer, excluding income, deposits and other months")
        assert(data.personalTotal == 50, "Only my actual personal expenses and refunds may be cached")
        assert(data.mySharedTotal + data.partnerSharedTotal! == data.sharedTotal)
        assert(data.updatedAt == now && data.month == "2026-10")
        assert(LedgerWidgetPublisher.summary(pairedSnapshot, month: "2026-09", now: now) == nil)
        assert(LedgerWidgetPublisher.summary(pairedSnapshot, month: "2026-10", now: nextMonth) == nil,
               "KST midnight must reject the previous month even when UTC is still October")
        let solo = LedgerWidgetPublisher.summary(try snapshot(partner: false), month: "2026-10", now: now)!
        assert(solo.partnerSharedTotal == nil, "No partner must remain distinct from zero spending")

        let suite = "OurLedger.WidgetSummaryCheck." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        assert(LedgerWidgetData.read(at: now, defaults: defaults) == nil)
        try data.write(to: defaults)
        let restored = LedgerWidgetData.read(at: now, defaults: defaults)!
        assert(restored.sharedTotal == 340 && restored.personalTotal == 50 && restored.partnerSharedTotal == 70)
        assert(LedgerWidgetData.read(at: nextMonth, defaults: defaults) == nil,
               "Old cached amounts must become empty at the KST month boundary")
        try solo.write(to: defaults)
        assert(LedgerWidgetData.read(at: now, defaults: defaults)?.partnerSharedTotal == nil)
        print("PASS: widget income exclusion/pool/refund/privacy/planned/solo/KST rollover and isolated cache checks")
    }
}
