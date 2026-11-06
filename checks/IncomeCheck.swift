import Foundation

@main
struct IncomeCheck {
    static func main() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let old = try JSONDecoder().decode(LedgerSnapshot.self, from: data)
        precondition(old.stats.incomeTotal == nil && old.stats.personalIncomeTotal == nil,
                     "Old server snapshots must decode without income fields")
        var body = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var stats = body["stats"] as! [String: Any]
        stats["incomeTotal"] = 150_000
        stats["personalIncomeTotal"] = 3_000_000
        body["stats"] = stats
        body["entries"] = [
            entry("salary", kind: "income", amount: 3_000_000),
            entry("expense", kind: "expense", amount: 8_400),
            entry("refund", kind: "refund", amount: 1_400),
            entry("deposit", kind: "deposit", amount: 9_000)
        ]
        let current = try JSONDecoder().decode(LedgerSnapshot.self, from: JSONSerialization.data(withJSONObject: body))
        precondition(current.stats.incomeTotal == 150_000 && current.stats.personalIncomeTotal == 3_000_000)
        precondition(current.entries[0].signedAmount == 0, "Income must not become calendar or dashboard spending")
        precondition(current.entries[1].signedAmount == 8_400 && current.entries[2].signedAmount == -1_400)
        precondition(current.entries[3].signedAmount == 9_000, "Existing deposit semantics are unchanged")
        precondition(current.entries.filter { $0.kind != "deposit" }.reduce(0) { $0 + $1.signedAmount } == 7_000)
        let recognition: [String: Any] = ["kind": "income", "amount": 3_000_000, "merchant": "테스트회사",
            "card": "", "reference": "", "reason": "입금 확인", "requiresReview": true]
        let parsed = try JSONDecoder().decode(PaymentRecognition.self, from: JSONSerialization.data(withJSONObject: recognition))
        precondition(parsed.kind == "income" && parsed.requiresReview)
        var imported: [String: Any] = ["id": "sample", "owner": "test-a", "raw": "승인 8,400원", "status": "pending",
            "merchant": "테스트점", "kind": "expense", "card": "", "reference": "", "reason": "",
            "amount": 8_400, "sources": ["sms"], "candidates": [], "requiresReview": false]
        func decodeImport() throws -> ImportedMessage {
            try JSONDecoder().decode(ImportedMessage.self, from: JSONSerialization.data(withJSONObject: imported))
        }
        let uniqueImport = try decodeImport()
        precondition(!uniqueImport.needsDuplicateComparison)
        imported["candidates"] = ["same-app-payment"]
        let duplicateImport = try decodeImport()
        precondition(duplicateImport.needsDuplicateComparison, "Notification routes must compare potential SMS/app duplicates before recording")
        print("PASS: income snapshot compatibility, separate income totals, zero spend and recognition decoding")
    }

    static func entry(_ id: String, kind: String, amount: Int) -> [String: Any] {
        ["id": id, "owner": "test-a", "payer": "test-a", "scope": "shared", "kind": kind,
         "funding": kind == "deposit" ? "fund" : "personal", "note": "검증", "category": "other",
         "day": "2026-10-21", "amount": amount]
    }
}
