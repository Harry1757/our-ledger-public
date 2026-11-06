"""Actual Swift intent bodies -> actual local HTTP/SQLite server, with concurrent inputs.

python3 checks/PaymentIngestionCheck.py
ActivityKit/notifications and credential loading are isolated test doubles. No production access.
"""
from pathlib import Path
import json
import subprocess
import sys
import tempfile
import threading

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "server"))
import app
import ledger

intent_source = (ROOT / "OurLedger/ImportIntent.swift").read_text()


def perform_body(name):
    start = intent_source.index("struct " + name)
    start = intent_source.index("func perform()", start)
    start = intent_source.index("{", start)
    depth = 0
    for index in range(start, len(intent_source)):
        if intent_source[index] == "{":
            depth += 1
        elif intent_source[index] == "}":
            depth -= 1
            if depth == 0:
                return intent_source[start:index + 1]
    raise AssertionError("Missing intent body")


api = "struct ServerAPI {" + (ROOT / "OurLedger/API.swift").read_text().split("struct ServerAPI {", 1)[1].split("\n@MainActor @Observable", 1)[0]
credentials = "extension Credentials {" + intent_source.split("extension Credentials {", 1)[1].split("struct ReceivePaymentNotificationIntent", 1)[0]
credentials = credentials.replace("defaults: .standard", "defaults: testDefaults")
harness = r'''
import Foundation
import CryptoKit

let defaultsName = "ourledger-ingestion-" + UUID().uuidString
let testDefaults = UserDefaults(suiteName: defaultsName)!
struct Credentials: Equatable {
    let base, token: String
    static func load() -> Credentials? {
        let base = CommandLine.arguments[1]
        precondition(URL(string: base)?.host == "127.0.0.1", "Local synthetic ledger only")
        return Credentials(base: base, token: CommandLine.arguments[2])
    }
}
CREDENTIALS
API
struct TestResult { static func result(dialog: String = "") -> Self { Self() } }
actor DisplayCapture {
    static let shared = DisplayCapture()
    var ids: [String] = []
    func append(_ id: String) { ids.append(id) }
}
enum PaymentLiveActivities {
    static func show(id: String, identity: String, merchant: String, amount: Int?, practice: Bool = false, rawText: String = "") async -> Bool {
        await DisplayCapture.shared.append(id)
        return true
    }
}
enum Permission { case authorized, provisional, denied }
struct Settings { let authorizationStatus = Permission.denied }
struct UNNotificationRequest { let identifier: String; let content: String; let trigger: String? }
struct UNUserNotificationCenter {
    static func current() -> Self { Self() }
    func notificationSettings() async -> Settings { Settings() }
    func add(_ request: UNNotificationRequest) async throws {}
}
enum PaymentNotifications {
    static func content(id: String, identity: String, merchant: String, amount: Int?) -> String { "" }
}
final class ImportTransactionIntent {
    var text = ""
    var source = "app"
    var eventID: String?
    func perform() async throws -> TestResult IMPORT_BODY
}
final class ReceivePaymentNotificationIntent {
    var text = ""
    var source = "app"
    func perform() async throws -> TestResult RECEIVE_BODY
}
struct Input: Decodable {
    let text: String
    let eventID: String?
    let receiver: Bool
}
@main struct Check {
    static func main() async throws {
        defer { testDefaults.removePersistentDomain(forName: defaultsName) }
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))
        let inputs = try JSONDecoder().decode([Input].self, from: data)
        let outcomes = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for input in inputs {
                group.addTask {
                    do {
                        if input.receiver {
                            let action = ReceivePaymentNotificationIntent()
                            action.text = input.text
                            _ = try await action.perform()
                        } else {
                            let action = ImportTransactionIntent()
                            action.text = input.text; action.eventID = input.eventID
                            _ = try await action.perform()
                        }
                        return true
                    } catch { return false }
                }
            }
            var result: [Bool] = []
            for await value in group { result.append(value) }
            return result
        }
        let ids = await DisplayCapture.shared.ids
        let result: [String: Any] = ["success": outcomes.filter { $0 }.count,
                                   "failed": outcomes.filter { !$0 }.count, "displayRequests": ids.count,
                                   "uniqueDisplayIDs": Set(ids).count]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self))
    }
}
'''.replace("CREDENTIALS", credentials).replace("API", api).replace("IMPORT_BODY", perform_body("ImportTransactionIntent")).replace("RECEIVE_BODY", perform_body("ReceivePaymentNotificationIntent"))


def notice(amount, reference="", minute="30"):
    return f"테스트은행 출금\n{amount:,}원\n사용처: 검증상점\n10/26 18:{minute}" + (f"\n카드 1234\n거래번호 {reference}" if reference else "")


def item(amount=10000, event=None, reference="", receiver=True):
    return dict(text=notice(amount, reference), eventID=event, receiver=receiver)


cases = [
    ("different amounts, automatic event IDs", [item(), item(20000)], "normal", 2, 2, 2),
    ("same amount and time, distinct automatic event IDs share one notification", [item(), item()], "normal", 1, 2, 2),
    ("same amount and time, distinct supplied event IDs share one notification", [item(event="first", receiver=False), item(event="second", receiver=False)], "normal", 1, 2, 2),
    ("same amount, different minutes stay separate", [item(), dict(text=notice(10000,minute="31"),eventID=None,receiver=True)], "normal", 2, 2, 2),
    ("same amount, different transaction references", [item(reference="REF1001"), item(reference="REF1002")], "normal", 2, 2, 2),
    ("bank bill pair: first then second", [
        dict(text="요금납부\n65,720원 출금\n내 테스트은행 통장 → 합성보험10179", eventID=None, receiver=True),
        dict(text="요금납부\n54,250원 출금\n내 테스트은행 통장 → 검증보험10209", eventID=None, receiver=True)], "normal", 2, 2, 2),
    ("bank bill pair: reversed", [
        dict(text="요금납부\n54,250원 출금\n내 테스트은행 통장 → 검증보험10209", eventID=None, receiver=True),
        dict(text="요금납부\n65,720원 출금\n내 테스트은행 통장 → 합성보험10179", eventID=None, receiver=True)], "normal", 2, 2, 2),
    ("DIAGNOSTIC: two withdrawals in one delivery stay one ambiguous import", [dict(text=notice(10000) + "\n\n" + notice(20000), eventID=None, receiver=True)], "combined", 1, 1, 1),
    ("same event retry is deduplicated", [item(event="retry", receiver=False), item(event="retry", receiver=False)], "normal", 1, 2, 2),
    ("DIAGNOSTIC: reused event ID collapses different amounts", [item(event="reused", receiver=False), item(20000, event="reused", receiver=False)], "normal", 1, 2, 2),
    ("DIAGNOSTIC: identical card/reference/time/amount merges different events", [item(reference="REF1001"), item(reference="REF1001")], "normal", 1, 2, 2),
    ("one transient pre-save 503 retries without losing a payment", [item(), item(20000)], "fail-first", 2, 2, 3),
    ("lost response after commit retries without creating a duplicate", [item(), item(20000)], "lose-response", 2, 2, 3),
    ("blank optional event ID is assigned once before retry", [item(event="", receiver=False), item(20000, event="", receiver=False)], "lose-response", 2, 2, 3),
    ("authentication failure is not retried", [item(), item(20000)], "unauthorized-first", 1, 1, 2),
    ("persistent outage stops after one retry per event", [item(), item(20000)], "fail-all", 0, 0, 4),
]

with tempfile.TemporaryDirectory(prefix="ourledger-ingestion-") as directory:
    work = Path(directory)
    (work / "Check.swift").write_text(harness)
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
                    str(ROOT / "OurLedger/Models.swift"), str(ROOT / "OurLedger/NotificationSetupState.swift"),
                    str(work / "Check.swift"), "-o", str(work / "check")], check=True)
    for index, (name, inputs, mode, expected_pending, expected_success, expected_requests) in enumerate(cases):
        store = app.Store(work / f"case-{index}.sqlite")
        auth = store.create(dict(name="동시 수신 검사", memberName="검증 사용자", mode="separate"))
        server = app.make_server("127.0.0.1", 0, store)
        original_handler = server.RequestHandlerClass
        barrier = threading.Barrier(len(inputs))
        lock = threading.Lock()
        counter = [0]

        class ControlledHandler(original_handler):
            def do_POST(self):
                if self.path == "/imports":
                    with lock:
                        self.import_index = counter[0]
                        counter[0] += 1
                    if self.import_index < len(inputs):
                        barrier.wait(timeout=10)
                    if mode == "fail-all" or (mode == "fail-first" and self.import_index == 0):
                        self.respond(503, dict(error="검증용 일시 오류"))
                        return
                    if mode == "unauthorized-first" and self.import_index == 0:
                        self.respond(401, dict(error="검증용 인증 오류"))
                        return
                super().do_POST()

            def respond(self, status, value):
                if mode == "lose-response" and self.path == "/imports" and getattr(self, "import_index", None) == 0 and status == 200:
                    self.close_connection = True
                    return
                super().respond(status, value)

        server.RequestHandlerClass = ControlledHandler
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            inputs_path = work / "inputs.json"
            inputs_path.write_text(json.dumps(inputs, ensure_ascii=False))
            result = subprocess.run([str(work / "check"), f"http://127.0.0.1:{server.server_port}", auth["token"], str(inputs_path)],
                                    text=True, capture_output=True, timeout=45)
            assert result.returncode == 0, result.stderr
            outcome = json.loads(result.stdout)
            snapshot = store.run(auth["token"], lambda state, actor: ledger.snapshot(state, actor, "2026-10"))
            pending = len(snapshot["inbox"])
            assert (pending, outcome["success"], counter[0]) == (expected_pending, expected_success, expected_requests), (name, pending, outcome, counter[0])
            assert len(snapshot["entries"]) == 0, "Imports must not auto-record transactions"
            assert outcome['uniqueDisplayIDs'] == expected_pending, "Repeated deliveries must update the same notification, not create another card"
            if name.startswith("bank bill pair:"):
                assert sorted(row["amount"] for row in snapshot["inbox"]) == [54250, 65720]
                assert all(row["kind"] == "transfer" and row["status"] == "pending" for row in snapshot["inbox"])
                assert all(not row["candidates"] for row in snapshot["inbox"])
            if mode == "combined":
                assert snapshot["inbox"][0]["amount"] is None and snapshot["inbox"][0]["requiresReview"], "Combined text must remain for explicit review, not silently select one amount"
            print(f"PASS: {name}; requests={counter[0]}, pending={pending}, success={outcome['success']}, failed={outcome['failed']}", flush=True)
        finally:
            server.shutdown()
            server.server_close()
            thread.join()
print("PASS: synthetic local state only; no production requests, devices, or automatic entries")
