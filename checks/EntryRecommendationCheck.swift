import Foundation

@main
struct EntryRecommendationCheck {
    static func main() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let fixture = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        if let cases = fixture["classificationChecks"] as? [[String: String]] {
            let current = try JSONDecoder().decode(LedgerSnapshot.self, from: data)
            for item in cases {
                let note = item["note"]!
                let actual = current.recommendedCategory(for: note)
                precondition(actual?.id == item["categoryID"] && actual?.name == item["categoryName"],
                             "Server/client recommendation mismatch: " + note)
            }
            for entry in current.entries {
                precondition(current.categories.contains { $0.id == entry.category }, "Saved category must be selectable")
            }
            precondition(current.categories.filter { $0.name == "의료" }.count == 1)
            let privateStats = LedgerInsights(snapshot: current, scope: "personal", month: "2026-10")
            precondition(privateStats.byCategory.contains { $0.name == "의료" && $0.amount == 3000 },
                         "The new category must survive decoding and personal statistics")
            print("PASS: live server fixture, \(cases.count) exact/ambiguous/personal recommendations and medical category decoding")
            return
        }
        let legacy = try JSONDecoder().decode(LedgerSnapshot.self, from: data)
        precondition(legacy.classificationRules == nil, "Old server response must remain decodable")
        precondition(legacy.recommendedCategory(for: "커피") == nil, "Do not pretend to know missing personal rules")
        var payload = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        payload["classificationRules"] = ["특별커피": "travel"]
        let view = try JSONDecoder().decode(LedgerSnapshot.self, from: JSONSerialization.data(withJSONObject: payload))
        precondition(view.recommendedCategory(for: " 특별 커피 ")?.id == "travel", "Own exact rule overrides keywords")
        precondition(view.recommendedCategory(for: "커피")?.id == "cafe")
        precondition(view.recommendedCategory(for: "커피 여행")?.id == "other", "Conflicting categories stay unclassified")
        precondition(view.recommendedCategory(for: "전혀 모름")?.id == "other")
        precondition(view.recommendedCategory(for: "  ") == nil)
        precondition(parsedWon("100,000,000,000") == 100_000_000_000)
        for invalid in ["0", "-1", "1.5", "1a2", "100000000001", "99999999999999999999999999"] {
            precondition(parsedWon(invalid) == nil, "Reject invalid or oversized amount: " + invalid)
        }
        precondition(formattedWonInput("18000") == "18,000")
        precondition(formattedWonInput("1.5") == "1.5", "Do not turn invalid pasted text into a valid amount")
        let saved = Entry(id: "saved", owner: "test-a", payer: "test-a", scope: "shared", kind: "expense", funding: "personal", note: "커피", category: "cafe", day: "2026-10-21", amount: 1000, settlement: nil, importID: nil, refundOf: nil, recurringID: nil, recurringMonth: nil)
        try saved.validateSubmission(["scope": "shared", "amount": 1000, "note": " 커피 "])
        for changed in [["scope": "personal", "amount": 1000] as [String: Any], ["scope": "shared", "amount": 2000]] {
            var rejected = false
            do { try saved.validateSubmission(changed) } catch { rejected = true }
            precondition(rejected, "A retry must not claim changed values were saved when server returned the previous entry")
        }
        print("PASS: legacy decoding, personal category rules, ambiguous keywords and integer-won input")
    }
}
