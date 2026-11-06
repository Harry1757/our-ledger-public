"""Actual intent bodies: diagnostic stages, concurrent task context and unchanged throws.

python3 -B checks/NotificationDeliveryCheck.py
Reuses ingestion-check facades, without running/importing that check or editing it.
HTTP is replaced here; PaymentIngestionCheck.py separately covers actual local HTTP.
"""
import ast
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = ROOT / "checks/PaymentIngestionCheck.py"
tree = ast.parse(source.read_text())
namespace = {"ROOT": ROOT}
for node in tree.body:
    if isinstance(node, ast.FunctionDef) and node.name == "perform_body":
        exec(compile(ast.Module(body=[node], type_ignores=[]), str(source), "exec"), namespace)
    elif isinstance(node, ast.Assign) and any(
        isinstance(target, ast.Name) and target.id in {"intent_source", "api", "credentials", "harness"}
        for target in node.targets
    ):
        exec(compile(ast.Module(body=[node], type_ignores=[]), str(source), "exec"), namespace)

mock_api = r'''
actor RequestProbe {
    static let shared = RequestProbe()
    var count = 0
    var allowTests = false
    var importWrites = 0
    var previewCount = 0
    var completeAtState: String?
    var completeAtPreview: String?
    func enableTests() { allowTests = true }
    func completeOnResponse(_ token: String, preview: Bool) {
        if preview { completeAtPreview = token } else { completeAtState = token }
    }
    func testRequest(_ path: String) -> Bool {
        if path == "/imports" { importWrites += 1 }
        if path == "/imports/preview" { previewCount += 1 }
        if path.hasPrefix("/state?"), let token = completeAtState {
            precondition(Credentials.load()!.notificationSetup.completePractice(token))
            completeAtState = nil
        }
        if path == "/imports/preview", let token = completeAtPreview {
            precondition(Credentials.load()!.notificationSetup.completePractice(token))
            completeAtPreview = nil
        }
        return allowTests && path.hasPrefix("/state?")
    }
    var pairWaiter: CheckedContinuation<Void, Never>?
    func submit(_ text: String) async throws {
        count += 1
        let setup = Credentials.load()!.notificationSetup
        precondition(setup.deliveries.first?.stage == .submitting || text == "test")
        if text.hasPrefix("pair") {
            let context = NotificationDeliveryContext.current!
            precondition(setup.deliveries.first(where: { $0.id == context.id })?.stage == .submitting)
            if let waiter = pairWaiter {
                precondition(setup.deliveries.count == 2 && setup.deliveries.allSatisfy { $0.stage == .submitting })
                pairWaiter = nil
                waiter.resume()
            } else {
                await withCheckedContinuation { pairWaiter = $0 }
            }
        }
        if text.hasPrefix("failure") || text == "test" {
            throw APIError(message: "PRIVATE_FINANCIAL_SENTINEL", statusCode: 401)
        }
        if text.hasPrefix("cancel") { throw CancellationError() }
    }
}
struct ServerAPI {
    let credentials: Credentials
    func request<T: Decodable>(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> T {
        if await RequestProbe.shared.testRequest(path) {
            let snapshot = #"{"household":{"id":"test","name":"test","mode":"separate","budget":0},"me":"synthetic","members":[],"categories":[],"entries":[],"inbox":[],"stats":{"total":0,"previousTotal":0,"delta":0,"budgetRemaining":0,"personalTotal":0,"fundBalance":0,"byCategory":[],"byMember":[],"daily":[],"trend":[]},"settlement":{"fromID":"","toID":"","kind":"","revision":"test","amount":0,"count":0,"memberAmounts":[]},"history":[]}"#
            return try JSONDecoder().decode(T.self, from: Data(snapshot.utf8))
        }
        let text = body?["text"] as? String ?? "test"
        if path != "/imports/preview" { try await RequestProbe.shared.submit(text) }
        let value: [String: Any] = ["id": UUID().uuidString, "owner": "synthetic", "raw": text,
            "status": text.hasPrefix("handled") ? "ignored" : "pending", "merchant": "synthetic",
            "kind": "expense", "card": "", "reference": "", "reason": "", "amount": 1000,
            "sources": [], "candidates": [], "requiresReview": false]
        return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: value))
    }
}
'''
harness = namespace["harness"].replace(namespace["api"], mock_api)
harness = harness[:harness.index("@main struct Check")]
harness += r'''
@main struct Check {
    static func main() async throws {
        defer { testDefaults.removePersistentDomain(forName: defaultsName) }
        let setup = Credentials.load()!.notificationSetup
        func receive(_ text: String) async throws {
            let action = ReceivePaymentNotificationIntent(); action.text = text
            _ = try await action.perform()
        }
        try await receive("안내문")
        precondition(setup.deliveries.count == 1 && setup.deliveries[0].stage == .filterExcluded)
        let filteredRequests = await RequestProbe.shared.count
        precondition(filteredRequests == 0)
        print("PASS: actual receiver records filtered invocation without requesting server")
        setup.reset()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await receive("pairA 출금 1,000원") }
            group.addTask { try await receive("pairB 출금 2,000원") }
            try await group.waitForAll()
        }
        precondition(setup.deliveries.count == 2 && Set(setup.deliveries.map(\.id)).count == 2)
        precondition(setup.deliveries.allSatisfy { $0.stage == .serverAcknowledged })
        precondition(NotificationDeliveryContext.current == nil)
        print("PASS: overlapping actual receiver/import calls share one record each, with isolated task context")
        for mode in ["failure", "cancel"] {
            do { try await receive(mode + " 출금 1,000원"); preconditionFailure("Must rethrow original failure") }
            catch {
                if mode == "cancel" { precondition(error is CancellationError) }
                else { precondition((error as? APIError)?.message == "PRIVATE_FINANCIAL_SENTINEL") }
            }
            precondition(setup.deliveries[0].stage == (mode == "cancel" ? .cancelled : .failed))
            precondition(setup.deliveries[0].failedStage == .submitting)
        }
        print("PASS: original error and cancellation propagate; only closed failure stage is recorded")
        let test = setup.beginTest()
        do { try await receive(test); preconditionFailure("Test endpoint must throw") }
        catch { precondition(error is APIError) }
        precondition(setup.deliveries[0].stage == .failed && setup.deliveries[0].failedStage == .testing)
        print("PASS: connection test error is distinct from transaction submission")
        let other = NotificationSetupState(defaults: testDefaults, identity: "other-connection")
        let otherID = other.beginDelivery()
        let countBefore = setup.deliveries.count
        try await NotificationDeliveryContext.$current.withValue(.init(id: otherID, identity: other.identity)) {
            let action = ImportTransactionIntent(); action.text = "handled 出금 1,000원"
            action.eventID = "PRIVATE_FINANCIAL_SENTINEL"
            _ = try await action.perform()
        }
        precondition(setup.deliveries.count == countBefore + 1 && setup.deliveries[0].stage == .serverAcknowledged)
        precondition(other.deliveries[0].stage == .started)
        precondition(setup.deliveries[0].stage.title == "서버 응답 확인", "Ack cannot promise a newly saved transaction")
        let serialized = String(decoding: try JSONEncoder().encode(setup.deliveries), as: UTF8.self)
        for privateValue in ["PRIVATE_FINANCIAL_SENTINEL", "출금", "1,000", "synthetic-token"] {
            precondition(!serialized.contains(privateValue))
        }
        print("PASS: direct import, foreign context isolation, generic ack, no raw text/event ID/error/token in records")
        setup.reset()
        await RequestProbe.shared.enableTests()
        let writesBefore = await RequestProbe.shared.importWrites
        let displayedBefore = await DisplayCapture.shared.ids.count
        let first = setup.beginTest(); setup.beginPractice(first)
        let second = setup.beginTest(); setup.beginPractice(second)
        try await receive("카드 승인 8,400원\n" + first)
        try await receive("카드 승인 8,400원\n" + second)
        let displayed = await DisplayCapture.shared.ids
        precondition(Array(displayed.dropFirst(displayedBefore)) == [first, second], "Both receipts must open the matching practice, not the latest token")
        precondition(setup.completePractice(first) && setup.matchesPractice(second))
        precondition(setup.completePractice(second))
        try await receive("카드 승인 8,400원\n" + first)
        let unknown = NotificationSetupState.testMarker + " 000000000000"
        try await receive("카드 승인 8,400원\n" + unknown)
        let expired = setup.beginTest(now: Date().addingTimeInterval(-301))
        try await receive("카드 승인 8,400원\n" + expired)
        for token in [first, unknown, expired] {
            let direct = ImportTransactionIntent(); direct.text = "카드 승인 8,400원\n" + token
            _ = try await direct.perform()
        }
        let writesAfter = await RequestProbe.shared.importWrites
        let displayCountAfter = await DisplayCapture.shared.ids.count
        precondition(writesBefore == writesAfter, "Test messages must never reach /imports, including direct, stale and replayed input")
        precondition(displayCountAfter == displayedBefore + 2)
        print("PASS: two matching practice activities, independent completion, stale/replayed/unknown/direct test inputs never imported")
        for preview in [false, true] {
            let token = setup.beginTest(); setup.beginPractice(token)
            await RequestProbe.shared.completeOnResponse(token, preview: preview)
            try await receive("카드 승인 8,400원\n" + token)
            let count = await DisplayCapture.shared.ids.count
            precondition(count == displayCountAfter, "A completion during state/preview response must not recreate the practice activity")
            precondition(setup.practiceToken(in: token) == nil)
        }
        let duplicate = setup.beginTest(); setup.beginPractice(duplicate)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<10 { group.addTask { try await receive("카드 승인 8,400원\n" + duplicate) } }
            try await group.waitForAll()
        }
        let duplicatesDisplayed = await DisplayCapture.shared.ids.filter { $0 == duplicate }.count
        precondition(duplicatesDisplayed == 1, "Overlapping duplicate receipts must not display the same test twice")
        let finalWrites = await RequestProbe.shared.importWrites
        precondition(finalWrites == writesBefore)
        print("PASS: completion during both async response boundaries and ten concurrent duplicate receipts; zero test imports")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="ourledger-delivery-check-") as directory:
    work = Path(directory)
    (work / "Check.swift").write_text(harness)
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
                    str(ROOT / "OurLedger/Models.swift"), str(ROOT / "OurLedger/NotificationSetupState.swift"),
                    str(work / "Check.swift"), "-o", str(work / "check")], check=True)
    subprocess.run([str(work / "check"), "http://127.0.0.1:1", "synthetic-token"], check=True, timeout=30)
