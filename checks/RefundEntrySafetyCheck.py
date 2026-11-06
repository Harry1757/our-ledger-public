"""Run EntryForm's actual decisions on macOS, then check in-memory financial invariants.

No simulator, user database, or cloud access. Run: python3 checks/RefundEntrySafetyCheck.py
"""
from pathlib import Path
import copy
import re
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'server'))
import ledger as L


def swift_block(source, marker):
    start = source.index(marker)
    opening = source.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end].replace('private ', '', 1)


class RefundEntrySafetyCheck(unittest.TestCase):
    def test_actual_form_decisions_and_exclusion_callback(self):
        source = (ROOT / 'OurLedger/EntryForm.swift').read_text()
        initial_kind = re.search(r'kind = (.+imported.kind.+)', source).group(1)
        code = r'''
import Foundation
struct Item { var kind: String; var requiresReview = false }
struct Household { var mode = "separate" }
struct Snapshot { var household = Household() }
enum Failure: Error { case offline }
final class Store {
    var snapshot: Snapshot? = Snapshot()
    var calls: [(String, String)] = []
    var fail = false
    func mutate(_ path: String, method: String) async throws {
        calls.append((path, method))
        if fail { throw Failure.offline }
    }
}
struct Import { var kind: String; var requiresReview = false; var id = "synthetic-refund" }
final class Form {
    enum ImportOutcome { case excluded, settled }
    var existing: Item?
    var imported: Import?
    var kind = "expense", scope = "shared"
    var store = Store()
    var busy = false, demonstration = false, dismissed = false
    var error: String?
    var onHandled: ((ImportOutcome) -> Void)?
    func dismiss() { dismissed = true }
    VALID_KIND
    AMBIGUOUS_IMPORT
    IGNORE_IMPORT
    func initializeImport() {
        if let imported { kind = INITIAL_KIND }
    }
}
func require(_ condition: Bool, _ message: String) {
    if !condition { print("FAIL: " + message); exit(1) }
}
@main struct Check {
    static func main() async {
        let form = Form()
        form.kind = "refund"
        require(!form.validKind, "New entry must not create a refund")
        for mode in ["separate", "pool"] {
            form.store.snapshot?.household.mode = mode
            for scope in ["shared", "personal"] {
                form.scope = scope
                for kind in ["expense", "income", "refund", "deposit", ""] {
                    form.kind = kind
                    form.existing = Item(kind: "refund")
                    require(form.validKind == (kind == "refund"), "Legacy refund must not convert: \(kind)")
                    form.existing = nil
                    require(form.validKind == (["expense", "income"].contains(kind) || (kind == "deposit" && mode == "pool" && scope == "shared")), "New kind/pool validation")
                }
            }
        }
        for importedKind in ["refund", "transfer", "income", "expense"] {
            for review in [false, true] {
                form.imported = Import(kind: importedKind, requiresReview: review)
                form.initializeImport()
                let expected: String
                switch (importedKind, review) {
                case ("refund", _): expected = ""
                case ("income", _): expected = "income"
                default: expected = "expense"
                }
                require(form.kind == expected, "Imported \(importedKind) must not silently become income/refund")
            }
        }
        form.imported = Import(kind: "refund")
        form.scope = "shared"
        for kind in ["", "refund", "deposit", "expense", "income"] {
            form.kind = kind
            require(form.validKind == ["expense", "income"].contains(kind), "Refund notice needs explicit expense/income")
        }
        var outcomes = 0
        form.onHandled = { outcome in
            require(outcome == .excluded, "Excluded import must use common excluded outcome")
            require(form.store.calls.last?.0 == "/imports/synthetic-refund" && form.store.calls.last?.1 == "DELETE", "Only the import may be excluded")
            outcomes += 1
        }
        form.store.fail = true
        await form.ignoreTransfer()
        require(outcomes == 0 && form.error != nil && !form.busy && !form.dismissed, "Failure must keep form available without advancing")
        form.store.fail = false
        await form.ignoreTransfer()
        require(outcomes == 1 && form.error == nil && !form.busy && !form.dismissed, "Successful refund exclusion must advance exactly once")
        let count = form.store.calls.count
        form.busy = true
        await form.ignoreTransfer()
        require(form.store.calls.count == count && outcomes == 1, "Busy exclusion must not submit twice")
        form.busy = false
        form.onHandled = nil
        await form.ignoreTransfer()
        require(form.dismissed, "Standalone exclusion must dismiss")
        print("PASS: actual new/imported/legacy kind guards, pool deposit, exclusion success/error/busy/callback")
    }
}
'''
        for token, value in {
            'VALID_KIND': swift_block(source, 'private var validKind:'),
            'AMBIGUOUS_IMPORT': swift_block(source, 'private var ambiguousImport:'),
            'IGNORE_IMPORT': swift_block(source, 'private func ignoreTransfer()'),
            'INITIAL_KIND': initial_kind,
        }.items():
            code = code.replace(token, value)
        with tempfile.TemporaryDirectory(prefix='ourledger-refund-check-') as directory:
            work = Path(directory)
            (work / 'Check.swift').write_text(code)
            subprocess.run(['swiftc', '-parse-as-library', str(work / 'Check.swift'), '-o', str(work / 'check')], check=True)
            subprocess.run([str(work / 'check')], check=True)

    def test_excluding_refund_changes_no_financial_state(self):
        for mode in ['separate', 'pool']:
            with self.subTest(mode=mode):
                state = L.new_household('합성검사', '검사A', mode)
                actor = state['members'][0]['id']
                L.add_member(state, '검사B')
                payload = dict(amount=10000, note='검사 거래', day='2026-10-20', scope='shared', kind='expense', funding='personal')
                original = L.add_entry(state, actor, payload)
                linked = L.add_entry(state, actor, {**payload, 'kind': 'refund', 'amount': 1000, 'refundOf': original['id']})
                unlinked = L.add_entry(state, actor, {**payload, 'kind': 'refund', 'amount': 500})
                if mode == 'pool':
                    L.add_entry(state, actor, {**payload, 'kind': 'deposit', 'funding': 'fund', 'amount': 50000})
                before = copy.deepcopy(state['entries'])
                financial = L.snapshot(state, actor, '2026-10')
                imported = L.import_message(state, actor, dict(text='카드 승인취소 2,000원\n가맹점: 검사상점', eventID='synthetic-cancel'))
                self.assertEqual((imported['kind'], imported['status']), ('refund', 'pending'))
                L.resolve_import(state, actor, imported['id'])
                after = L.snapshot(state, actor, '2026-10')
                self.assertEqual(imported['status'], 'ignored')
                self.assertEqual(state['entries'], before)
                for key in ['stats', 'personalStats', 'settlement']:
                    self.assertEqual(after[key], financial[key], key)
                for refund in [linked, unlinked]:
                    edited = L.update_entry(state, actor, refund['id'], {'note': '환불 설명 수정', 'kind': 'refund'})
                    self.assertEqual(edited['kind'], 'refund')
                    self.assertEqual(edited.get('refundOf'), refund.get('refundOf'))
                self.assertEqual(L.snapshot(state, actor, '2026-10')['stats']['total'], 8500)


if __name__ == '__main__':
    unittest.main(verbosity=2)
