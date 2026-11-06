"""Execute EntryForm's actual initialization/lifecycle decisions with synthetic data only.

Run: python3 checks/EntryDefaultsCheck.py (Foundation/Swift, no network or user database).
"""
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def block(source, marker):
    start = source.index(marker)
    opening = source.index('{', start)
    end, depth = opening + 1, 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end].replace('private ', '', 1)


def closure(source, marker):
    if marker not in source:
        return ''
    body = block(source, marker).split('{', 1)[1][:-1]
    return re.sub(r'^\s*_,\s*\w+\s+in\s*', '', body)


class EntryDefaultsCheck(unittest.TestCase):
    def test_actual_form_defaults_refresh_and_preservation(self):
        source = (ROOT / 'OurLedger/EntryForm.swift').read_text()
        decisions = [block(source, marker) for marker in [
            'private func fill()', 'private var ambiguousImport:',
            'private var validKind:', 'private var readyToSave:',
        ]]
        for marker in ['private func fillMissingPayer()', 'private var validPayer:',
                       'private var payerOptions:']:
            if marker in source:
                decisions.append(block(source, marker))
        if 'private var payerOptions:' not in source:
            # Before the fix, execute the actual inline picker filter as well.
            expression = re.search(r'ForEach\((store.snapshot\?\.members.filter.+)\) \{ Text', source).group(1)
            decisions.append('var payerOptions: [(id: String, name: String)] { (' + expression + ').map { ($0.id, $0.name) } }')
        state = '\n'.join(re.findall(r'@State private (var .+)', source))
        code = r'''
import Foundation
struct TextSize { var isAccessibilitySize = true }
final class Store { var snapshot: LedgerSnapshot?; var month = "2026-11" }
final class Form {
    enum InputField: Hashable { case amount, note }
    var existing: Entry?, imported: ImportedMessage?, recurring: RecurringPayment?
    var initialScope: String?
    var focusedField: InputField?
    var dynamicTypeSize = TextSize(), store = Store()
    var settlementMatches: [String] { [] }
    var saveAllowed = false
    STATE
    DECISIONS
    func attemptSave() {
        SAVE_GUARDS
        _ = value; _ = trimmedNote
        saveAllowed = true
    }
    func chooseScope(_ value: String) {
        let previousScope = scope
        SCOPE_ACTION
        if previousScope != scope { SCOPE_CHANGE }
    }
    func appear() {
        let previousScope = scope
        APPEAR
        if previousScope != scope { SCOPE_CHANGE }
    }
    func receive(_ snapshot: LedgerSnapshot?) {
        let previous = store.snapshot?.me
        store.snapshot = snapshot
        if previous != snapshot?.me { SNAPSHOT_CHANGE }
    }
}
var failures: [String] = []
func require(_ value: Bool, _ message: String) { if !value { failures.append(message) } }
func decode<T: Decodable>(_ body: [String: Any], as type: T.Type) throws -> T {
    try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: body))
}
@main struct Check {
    static func main() throws {
        var fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
        fixture["household"] = ["id": "synthetic", "name": "검사", "mode": "pool", "budget": 0]
        fixture["members"] = [
            ["id": "test-a", "name": "본인이름", "bank": "", "account": "", "holder": ""],
            ["id": "test-b", "name": "상대이름", "bank": "", "account": "", "holder": ""]]
        let snapshot = try decode(fixture, as: LedgerSnapshot.self)
        let new = Form()
        new.appear()
        require(new.kind == "expense" && new.scope.isEmpty, "New draft defaults expense without choosing privacy")
        new.amount = "12,345"; new.note = "직접 입력"; new.category = "cafe"
        new.date = parseDay("2026-11-02"); new.kind = "income"; new.scope = "shared"
        require(!new.readyToSave, "Missing payer/snapshot must block save")
        new.attemptSave()
        require(!new.saveAllowed && new.error != nil, "Actual save must reject missing payer before preparing a request")
        let id = new.entryID
        new.receive(snapshot)
        require(new.payer == "test-a", "Late snapshot fills self payer")
        require(new.amount == "12,345" && new.note == "직접 입력" && new.category == "cafe" && dayString(new.date) == "2026-11-02" && new.kind == "income" && new.scope == "shared" && new.entryID == id, "Late snapshot must preserve all typed fields and ID")
        require(new.readyToSave, "Complete draft with self payer can save")
        new.attemptSave(); require(new.saveAllowed, "Actual save accepts a valid self payer")
        require(new.payerOptions.contains { $0.id == "test-a" && $0.name == "나" }, "Self is shown as 나 by member ID")
        new.payer = "test-b"; new.receive(nil); new.receive(snapshot); new.appear()
        require(new.payer == "test-b" && new.note == "직접 입력" && new.kind == "income", "Refresh/reappearance must preserve selected payer and inputs")
        new.payer = "missing-member"
        require(!new.readyToSave, "Unknown payer must block save")
        new.saveAllowed = false; new.error = nil; new.attemptSave()
        require(!new.saveAllowed && new.error != nil, "Actual save rejects unknown member ID")
        new.payer = ""; require(!new.readyToSave, "Empty payer with loaded snapshot must block save")
        new.payer = "test-a"; new.scope = ""; require(!new.readyToSave, "Default payer must not bypass privacy choice")
        for scope in ["shared", "personal"] {
            let manual = Form(); manual.store.snapshot = snapshot; manual.initialScope = scope; manual.appear()
            require(manual.payer == "test-a" && manual.kind == "expense" && manual.scope == scope, "Manual \(scope) defaults to self expense")
        }
        let switching = Form(); switching.store.snapshot = snapshot; switching.appear()
        switching.scope = "shared"; switching.kind = "deposit"; switching.payer = "test-b"; switching.funding = "fund"
        switching.amount = "8,400"; switching.note = "입력 유지"
        switching.chooseScope("personal")
        require(switching.scope == "personal" && switching.kind == "expense" && switching.payer == "test-a" && switching.funding == "personal" && switching.note == "입력 유지" && switching.amount == "8,400", "Explicit personal selection still normalizes payer/funding/deposit without losing typed fields")
        switching.kind = "income"; switching.chooseScope("shared")
        require(switching.kind == "income" && switching.payer == "test-a", "Explicit shared selection retains income and payer")
        for (kind, review, expected) in [("unknown", true, "expense"), ("transfer", false, "expense"), ("income", true, "income"), ("expense", true, "expense"), ("expense", false, "expense"), ("income", false, "income"), ("refund", true, ""), ("refund", false, "")] {
            let imported = Form(); imported.store.snapshot = snapshot
            imported.imported = try decode(["id": "notice", "owner": "test-a", "raw": "합성", "status": "pending", "merchant": "합성상점", "kind": kind, "card": "", "reference": "", "reason": "확인", "amount": 1000, "time": "2026-11-01", "sources": [], "candidates": [], "requiresReview": review], as: ImportedMessage.self)
            imported.appear()
            require(imported.kind == expected && imported.payer == "test-a" && imported.scope.isEmpty, "Import \(kind)/review=\(review) default and privacy")
        }
        for kind in ["expense", "income", "refund", "deposit"] {
            for payer in ["test-a", "test-b", "fund"] {
                let edited = Form()
                edited.existing = try decode(["id": "saved", "owner": "test-a", "payer": payer, "scope": "shared", "kind": kind, "funding": "fund", "note": "기존 기록", "category": "other", "day": "2026-11-01", "amount": 1200], as: Entry.self)
                edited.appear(); edited.receive(snapshot); edited.appear()
                require(edited.payer == payer && edited.kind == kind && edited.funding == "fund" && edited.entryID == "saved", "Edited \(kind)/\(payer) preserves payer, kind, fund, ID")
                require(edited.payerOptions.contains { $0.id == payer }, "Edited selected payer must have a picker option: \(payer)")
            }
        }
        let personal = Form()
        personal.existing = try decode(["id": "private", "owner": "test-a", "payer": "test-a", "scope": "personal", "kind": "expense", "funding": "personal", "note": "개인", "category": "other", "day": "2026-11-01", "amount": 1200], as: Entry.self)
        personal.appear(); personal.receive(snapshot)
        require(personal.payer == "test-a" && personal.readyToSave, "Personal edit opened before snapshot retains payer")
        personal.payer = "test-b"
        require(personal.payerOptions.contains { $0.id == "test-b" }, "Personal picker must retain current selection")
        require(!personal.readyToSave, "Personal transaction cannot save with another member's payer")
        personal.attemptSave(); require(!personal.saveAllowed && personal.error != nil, "Actual save rejects personal payer mismatch")
        for scope in ["shared", "personal"] {
            let recurring = Form()
            recurring.recurring = try decode(["id": "schedule", "owner": "test-a", "note": "정기", "scope": scope, "category": "other", "payer": scope == "shared" ? "test-b" : "test-a", "funding": scope == "shared" ? "fund" : "personal", "startDay": "2026-11-01", "amount": 1200, "dayOfMonth": 1, "active": true, "dueDay": "2026-11-01"], as: RecurringPayment.self)
            recurring.appear(); recurring.receive(snapshot); recurring.appear()
            require(recurring.payer == recurring.recurring!.payer && recurring.funding == recurring.recurring!.funding && recurring.kind == "expense" && recurring.recurringMonth == "2026-11", "Recurring \(scope) retains configured payer/funding/month")
        }
        if !failures.isEmpty { failures.forEach { print("FAIL: " + $0) }; exit(1) }
        print("PASS: actual form initialization, late snapshot, typed fields, privacy, import kinds, edited/recurring payer and picker, save readiness")
    }
}
'''
        for token, value in {
            'STATE': state, 'DECISIONS': '\n'.join(decisions),
            'APPEAR': closure(source, '.onAppear'),
            'SAVE_GUARDS': source.split('private func save() async {', 1)[1].split('var body: [String: Any]', 1)[0],
            'SCOPE_ACTION': block(block(source, 'private func scopeButton('), 'Button {').split('{', 1)[1][:-1],
            'SCOPE_CHANGE': ('let value = scope; ' + closure(source, '.onChange(of: scope)')) if '.onChange(of: scope)' in source else '',
            'SNAPSHOT_CHANGE': closure(source, '.onChange(of: store.snapshot?.me)'),
        }.items():
            code = code.replace(token, value)
        with tempfile.TemporaryDirectory(prefix='ourledger-defaults-') as directory:
            work = Path(directory)
            (work / 'Check.swift').write_text(code)
            subprocess.run(['swiftc', str(ROOT / 'OurLedger/Models.swift'), str(work / 'Check.swift'), '-o', str(work / 'check')], check=True)
            result = subprocess.run([str(work / 'check'), str(ROOT / 'checks/fixtures/snapshot-legacy.json')], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            print(result.stdout.strip())


if __name__ == '__main__':
    unittest.main(verbosity=2)
