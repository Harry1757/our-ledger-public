"""Synthetic checks of actual EntryForm payload and Recurring journal, without an app build.

    python3 checks/EntryRecurringRecoveryCheck.py
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
entry = (ROOT / "OurLedger/EntryForm.swift").read_text()
recurring = (ROOT / "OurLedger/Recurring.swift").read_text()
# Execute the actual payload expression; don't duplicate its normalization in the test.
payload = entry.split('var body: [String: Any] = ', 1)[1].split('\n        if !category', 1)[0]
with tempfile.TemporaryDirectory(prefix="ourledger-recovery-") as directory:
    work = Path(directory)
    check = r'''
import Foundation
@main struct Check {
    static func main() throws {
        let entryID = "synthetic", value = 3000000, note = "공동자금", scope = "shared", payer = "me", date = Date()
        for kind in ["deposit", "expense", "income", "refund"] {
            for funding in ["personal", "fund"] {
                let body: [String: Any] = PAYLOAD
                var response = body
                response["owner"] = "me"; response["category"] = "other"
                if kind == "deposit" { response["funding"] = "fund" }
                let saved = try JSONDecoder().decode(Entry.self, from: JSONSerialization.data(withJSONObject: response))
                do { try saved.validateSubmission(body) }
                catch { fatalError("Actual EntryForm payload mismatches saved \(kind), funding \(funding): \(error)") }
                if kind != "deposit" { precondition(body["funding"] as? String == funding) }
                var altered = body; altered["amount"] = value + 1
                do { try saved.validateSubmission(altered); fatalError("Real amount mismatch accepted") } catch {}
            }
        }
        print("PASS: actual EntryForm payload / deposit correction / genuine mismatch rejection")
    }
}
'''.replace("PAYLOAD", payload)
    (work / "EntryCheck.swift").write_text(check)
    subprocess.run(["swiftc", str(ROOT / "OurLedger/Models.swift"), str(work / "EntryCheck.swift"), "-o", str(work / "entry")], check=True)
    subprocess.run([str(work / "entry")], check=True)
    marker = "// MARK: - Durable recurring creation"
    assert marker in recurring, "Missing durable recovery: closing the form discards pending creation ID"
    (work / "Journal.swift").write_text("import Foundation\nimport CryptoKit\n" + recurring.split(marker, 1)[1])
    (work / "JournalCheck.swift").write_text(r'''
import Foundation
@main struct Check {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("drafts")
        let journal = RecurringCreationJournal(directory: root, account: "synthetic-server\nme")
        let other = RecurringCreationJournal(directory: root, account: "synthetic-server\npartner")
        let body: [String: Any] = ["id": "same-request", "note": "월세", "amount": 300000,
            "scope": "shared", "payer": "me", "funding": "personal", "category": "",
            "startDay": "2026-10-26", "dayOfMonth": 26, "active": true]
        precondition(tryLoad(journal) == nil)
        try journal.stage(body)
        // Reconstruct the store, as when closing the sheet or restarting the process.
        let reopened = RecurringCreationJournal(directory: root, account: "synthetic-server\nme")
        precondition(NSDictionary(dictionary: tryLoad(reopened)!).isEqual(to: body))
        precondition(tryLoad(other) == nil, "Private draft crossed accounts")
        try reopened.stage(body) // exact retry stays same ID
        for change in [["id": "new-request"], ["scope": "personal"], ["note": "changed"]] {
            do { try reopened.stage(body.merging(change) { _, new in new }); fatalError("Pending payload overwritten") } catch {}
        }
        do { try reopened.clear(id: "different"); fatalError("Unrelated request cleared") } catch {}
        precondition(NSDictionary(dictionary: tryLoad(reopened)!).isEqual(to: body))
        // Response lost, form closed, then the existing schedule edited/paused elsewhere.
        // Explicit acknowledgement may resolve that ID, but never another member's ID.
        func saved(_ changes: [String: Any]) throws -> RecurringPayment {
            let response = body.merging(["owner": "me", "category": "other"]) { _, new in new }
                .merging(changes) { _, new in new }
            return try JSONDecoder().decode(RecurringPayment.self, from: JSONSerialization.data(withJSONObject: response))
        }
        for change: [String: Any] in [["active": false], ["note": "변경한 월세", "amount": 350000]] {
            let latest = try saved(change)
            precondition(!recurringCreationMatches(latest, body: body, owner: "me"))
            precondition(tryLoad(reopened) != nil, "Reading changed state must not auto-resolve")
            try reopened.confirmExisting(latest, id: "same-request", owner: "me")
            precondition(tryLoad(reopened) == nil, "Confirmed existing schedule must release pending creation")
            try reopened.stage(body)
        }
        for invalid in [["owner": "partner"], ["id": "another-request"]] {
            do { try reopened.confirmExisting(saved(invalid), id: "same-request", owner: "me"); fatalError("Unrelated existing schedule accepted") } catch {}
            precondition(tryLoad(reopened) != nil)
        }
        try reopened.clear(id: "same-request")
        precondition(tryLoad(reopened) == nil)
        try reopened.clear(id: "same-request") // cleanup can be retried
        var next = body; next["id"] = "next-request"
        try reopened.stage(next)
        precondition(tryLoad(reopened)?["id"] as? String == "next-request")
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        precondition(files.count == 1)
        try Data("broken".utf8).write(to: files[0])
        do { _ = try reopened.load(); fatalError("Corrupt recovery silently treated as empty") } catch {}
        do { try reopened.stage(body); fatalError("Corrupt pending request overwritten") } catch {}
        try Data("{}".utf8).write(to: files[0])
        do { _ = try reopened.load(); fatalError("Missing fields accepted for forced-cast restoration") } catch {}
        let blocked = root.appendingPathComponent("not-a-directory")
        try Data().write(to: blocked)
        do { try RecurringCreationJournal(directory: blocked, account: "me").stage(body); fatalError("Failed persistence accepted") } catch {}
        print("PASS: durable replay, exact payload, account isolation, overwrite protection, clear-by-ID, corrupt/storage errors")
    }
    static func tryLoad(_ journal: RecurringCreationJournal) -> [String: Any]? { try! journal.load() }
}
''')
    subprocess.run(["swiftc", str(ROOT / "OurLedger/Models.swift"), str(work / "Journal.swift"), str(work / "JournalCheck.swift"), "-o", str(work / "journal")], check=True)
    subprocess.run([str(work / "journal"), str(work)], check=True)
