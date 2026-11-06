import Foundation

@main
struct RecurringCandidateCheck {
    static func main() throws {
        let decoder = JSONDecoder()
        let payment = try decoder.decode(RecurringPayment.self, from: Data(#"{"id":"r","owner":"me","note":"월세","scope":"shared","category":"other","payer":"me","funding":"personal","startDay":"2026-10-01","amount":1000,"dayOfMonth":21,"active":true}"#.utf8))
        let base: [String: Any] = ["id": "e", "owner": "me", "payer": "me", "scope": "shared", "kind": "expense",
            "funding": "personal", "note": "실제 월세", "category": "other", "day": "2026-10-21", "amount": 1000]
        func matches(_ changes: [String: Any] = [:], month: String = "2026-10", me: String = "me") throws -> Bool {
            let data = try JSONSerialization.data(withJSONObject: base.merging(changes) { _, new in new })
            return recurringLinkCandidate(try decoder.decode(Entry.self, from: data), payment: payment, month: month, me: me)
        }
        let ownExpense = try matches()
        assert(ownExpense)
        let ineligible: [[String: Any]] = [["owner": "partner"], ["scope": "personal"], ["payer": "partner"],
                                        ["funding": "fund"], ["amount": 999], ["kind": "refund"],
                                        ["day": "2026-09-21"], ["recurringID": "another"]]
        for changes in ineligible {
            let invalid = try matches(changes)
            assert(!invalid)
        }
        let partner = try matches(me: "partner")
        assert(!partner)
        let submitted: [String: Any] = ["id": "r", "note": "월세", "scope": "shared", "category": "other",
            "payer": "me", "funding": "personal", "startDay": "2026-10-01", "amount": 1000,
            "dayOfMonth": 21, "active": true]
        assert(recurringCreationMatches(payment, body: submitted, owner: "me"))
        assert(recurringCreationMatches(payment, body: submitted.merging(["category": ""]) { _, new in new }, owner: "me"),
               "Automatic classification may resolve an empty category on the server")
        let changedDrafts: [[String: Any]] = [["id": "different"], ["note": "changed"], ["scope": "personal"],
            ["category": "changed"], ["payer": "partner"], ["funding": "fund"], ["startDay": "2026-11-01"],
            ["amount": 2000], ["dayOfMonth": 22], ["active": false]]
        for change in changedDrafts {
            assert(!recurringCreationMatches(payment, body: submitted.merging(change) { _, new in new }, owner: "me"),
                   "An idempotent retry returning the original schedule must not claim a changed draft was saved")
        }
        assert(!recurringCreationMatches(payment, body: submitted, owner: "partner"))
        var incomplete = submitted
        incomplete.removeValue(forKey: "amount")
        assert(!recurringCreationMatches(payment, body: incomplete, owner: "me"))
        assert(validRecurringNote(String(repeating: "a", count: 120)))
        assert(!validRecurringNote(String(repeating: "a", count: 121)))
        assert(validRecurringNote(String(repeating: "가", count: 120)))
        assert(!validRecurringNote(String(repeating: "가", count: 121)))
        assert(!validRecurringNote("월세\n관리비"))
        assert(!validRecurringNote("   "))
        assert(validRecurringNote(" 월세 "))
        print("PASS: 10 candidate, 14 creation snapshot and 7 note validation assertions")
    }
}
