"""Execute the actual notification load/reconcile Swift bodies with isolated HTTP replies.

python3 checks/PaymentNotificationOpenCheck.py
No Xcode, device, production requests, or writes to the ledger.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "OurLedger/PaymentNotifications.swift").read_text()
load = source.split("    @MainActor private func load() async {", 1)[1].split("    private func choose", 1)[0]
load = "    @MainActor private func load() async {" + load
advance = "    @MainActor private func advance() async {" + source.split("    @MainActor private func advance() async {", 1)[1].split("    @MainActor private func load()", 1)[0]
remaining = "    private var remaining: [ImportedMessage] {" + source.split("    private var remaining: [ImportedMessage] {", 1)[1].split("    private var reviewCount:", 1)[0]
reconcile = source.split("    @MainActor static func reconcile", 1)[1].split("    @MainActor static func open", 1)[0]
reconcile = "    @MainActor static func reconcile" + reconcile
open_link = source.split("    @MainActor static func open", 1)[1].split("\n}\n\nenum PaymentNotifications", 1)[0]
open_link = "    @MainActor static func open" + open_link
credentials = (ROOT / "OurLedger/ImportIntent.swift").read_text().split("extension Credentials {", 1)[1].split("struct ReceivePaymentNotificationIntent", 1)[0]
# Isolate preferences without replacing the real connection-identity calculation.
credentials = credentials.replace("defaults: .standard", "defaults: testDefaults")

harness = r'''
import Foundation
import CryptoKit
struct PracticeContent { let title: String; let body: String }
enum PaymentNotifications {
    static func practiceContent(id: String, identity: String, now: Date) -> PracticeContent {
        PracticeContent(title: "[테스트] 카드 결제 승인", body: "8,400원 CU 테스트점 " + id)
    }
}

let testDefaultsName = "ourledger-notification-open-" + UUID().uuidString
let testDefaults = UserDefaults(suiteName: testDefaultsName)!
@MainActor var activityFixtures: [AnyObject] = []
struct PaymentActivityAttributes {
    let paymentID, identity: String
    let practice: Bool
    let practiceRawText: String
    init(paymentID: String, identity: String, practice: Bool, practiceRawText: String = "") {
        self.paymentID = paymentID; self.identity = identity
        self.practice = practice; self.practiceRawText = practiceRawText
    }
}
@MainActor final class Activity<Attributes> {
    static var activities: [Activity<Attributes>] { activityFixtures.compactMap { $0 as? Activity<Attributes> } }
    enum Policy { case immediate }
    let attributes: Attributes
    var ended = false
    init(_ attributes: Attributes) { self.attributes = attributes }
    func end(_ content: String?, dismissalPolicy: Policy) async { ended = true }
}
enum PaymentLiveActivities {
RECONCILE_BODY
OPEN_BODY
}
extension Credentials {
CREDENTIALS_BODY
@MainActor final class OpenProbe {
    let store: LedgerStore
    var route: PaymentNotificationRoute
    var item: ImportedMessage?
    var pendingItems: [ImportedMessage] = []
    var startsInForm = false
    var reviewIDs: [String]? = nil
    var error: String?
    var loading = true
    var scope = ""
    var editing = false
    var ignored = false
    var settled = false
    var advancing = false
    var complete = false
    var savedNote = ""
    var savedAmount = 0
REMAINING_BODY
    func next() async { await advance() }
ADVANCE_BODY
    init(_ store: LedgerStore, identity: String? = nil, scope: String? = nil) {
        self.store = store
        route = PaymentNotificationRoute(id: "payment-one", identity: identity ?? store.credentials!.notificationSetup.identity,
            rawText: "This notification summary is not a transaction source", scope: scope, practice: false, ignored: false)
    }
    func start() async { await load() }
LOAD_BODY
    private func choose(_ selected: String) { scope = selected; editing = true }
    private func ignore() async { ignored = true }
}

final class OpenResponseProtocol: URLProtocol {
    @MainActor static var pending: [OpenResponseProtocol] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Task { @MainActor in
            precondition(request.url?.host == "notification-open-check.local", "No external requests allowed")
            precondition(request.httpMethod == "GET" && request.url?.path == "/state", "Read-only state requests only")
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer notification-test-only")
            Self.pending.append(self)
        }
    }
    override func stopLoading() {}
    func respond(_ data: Data, status: Int = 200) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
            httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@main struct Check {
    @MainActor static func main() async throws {
        URLProtocol.registerClass(OpenResponseProtocol.self)
        defer { URLProtocol.unregisterClass(OpenResponseProtocol.self) }
        defer { testDefaults.removePersistentDomain(forName: testDefaultsName) }
        let fixture = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let base = try JSONSerialization.jsonObject(with: fixture) as! [String: Any]
        let owner = base["me"] as! String
        func payload(id: String = "payment-one", actor: String? = nil, status: String = "pending") -> [String: Any] {
            ["id": id, "owner": actor ?? owner, "raw": "카드 승인 8,400원", "status": status,
             "merchant": "검증상점", "kind": "expense", "card": "", "reference": "", "reason": "",
             "amount": 8400, "sources": ["app"], "candidates": [], "requiresReview": false]
        }
        func data(_ inbox: [[String: Any]]) throws -> Data {
            var result = base
            result["inbox"] = inbox
            return try JSONSerialization.data(withJSONObject: result)
        }
        let empty = try data([])
        let pending = try data([payload()])
        let emptySnapshot = try JSONDecoder().decode(LedgerSnapshot.self, from: empty)
        func store() -> LedgerStore {
            let result = LedgerStore()
            result.credentials = Credentials(base: "http://notification-open-check.local", token: "notification-test-only")
            result.month = "2026-10"
            result.snapshot = emptySnapshot
            result.updatedAt = Date()
            return result
        }
        func waitForRequests(_ count: Int) async throws {
            let deadline = Date().addingTimeInterval(5)
            while OpenResponseProtocol.pending.count < count {
                precondition(Date() < deadline, "Expected HTTP request did not arrive")
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        func beginReconcile(_ ledger: LedgerStore) async throws -> (Task<Void, Never>, OpenResponseProtocol?) {
            var finished = false
            let task = Task { await PaymentLiveActivities.reconcile(ledger); finished = true }
            let deadline = Date().addingTimeInterval(5)
            while OpenResponseProtocol.pending.isEmpty && !finished {
                precondition(Date() < deadline, "Reconcile did not finish or request state")
                try await Task.sleep(for: .milliseconds(5))
            }
            return (task, OpenResponseProtocol.pending.isEmpty ? nil : OpenResponseProtocol.pending.removeFirst())
        }
        var failures = 0
        func check(_ condition: Bool, _ message: String) {
            print((condition ? "PASS: " : "FAIL: ") + message)
            if !condition { failures += 1 }
        }
        for response in ["next", "duplicate", "final", "failure", "switch", "cancel"] {
            let ledger = store()
            let probe = OpenProbe(ledger)
            probe.startsInForm = true
            probe.complete = true; probe.scope = "shared"; probe.savedNote = "first-only"; probe.savedAmount = 8400
            let task = Task { await probe.next() }
            try await waitForRequests(1)
            let request = OpenResponseProtocol.pending.removeFirst()
            if response == "switch" { ledger.credentials = Credentials(base: "http://notification-open-check.local", token: "other-test-member") }
            if response == "cancel" { task.cancel() }
            var older = payload(id: "payment-two"); older["receivedAt"] = "2026-10-26T10:00:00+09:00"
            if response == "duplicate" { older["candidates"] = ["other-existing"] }
            var newer = payload(id: "payment-three"); newer["receivedAt"] = "2026-10-26T10:00:01+09:00"
            let contents = response == "final" ? [] : [payload(), newer, older, payload(id: "private-other", actor: "other"), payload(id: "recorded", status: "recorded")]
            request.respond(try data(contents), status: response == "failure" ? 503 : 200)
            await task.value
            if response == "next" || response == "duplicate" {
                check(probe.route.id == "payment-two" && probe.route.scope == nil && probe.scope == "" && probe.savedNote == "" && probe.savedAmount == 0 && probe.loading && !probe.complete,
                      "auto next uses fresh oldest owned pending item and resets scope/note/amount")
                if response == "duplicate" { check(!probe.startsInForm, "auto next duplicate returns to comparison instead of bypassing it") }
            } else {
                check(probe.route.id == "payment-one" && probe.complete && !probe.advancing, "sequence stays on completion for \(response)")
                if response == "failure" { check(probe.error != nil, "next-load failure offers retry without resubmitting saved expense") }
            }
        }
        do {
            let ledger = store(); let probe = OpenProbe(ledger)
            probe.reviewIDs = ["payment-one", "payment-three", "payment-two"]
            probe.startsInForm = true; probe.complete = true
            let task = Task { await probe.next() }
            try await waitForRequests(1)
            var unrelated = payload(id: "unrelated"); unrelated["receivedAt"] = "2026-10-26T09:00:00+09:00"
            var second = payload(id: "payment-two"); second["receivedAt"] = "2026-10-26T10:00:00+09:00"
            var third = payload(id: "payment-three"); third["receivedAt"] = "2026-10-26T11:00:00+09:00"
            OpenResponseProtocol.pending.removeFirst().respond(try data([unrelated, second, third]))
            await task.value
            check(probe.route.id == "payment-three", "capture batch follows supplied order, excluding unrelated older inbox items")
        }
        for mode in ["last", "empty", "recorded", "foreign", "duplicate"] {
            let probe = OpenProbe(store()); probe.startsInForm = true; probe.complete = true
            probe.reviewIDs = mode == "empty" ? [] : mode == "last" ? ["payment-one"] : ["payment-one", "payment-two"]
            var next = payload(id: "payment-two", actor: mode == "foreign" ? "another-member" : nil,
                               status: mode == "recorded" ? "recorded" : "pending")
            if mode == "duplicate" { next["candidates"] = ["earlier"] }
            let task = Task { await probe.next() }
            try await waitForRequests(1)
            OpenResponseProtocol.pending.removeFirst().respond(try data([payload(id: "outside-batch"), next]))
            await task.value
            if mode == "duplicate" {
                check(probe.route.id == "payment-two" && !probe.startsInForm, "batch duplicate requires comparison before recording")
            } else {
                check(probe.route.id == "payment-one" && probe.complete, "batch \(mode) finishes without unrelated inbox navigation")
            }
        }
        do {
            let probe = OpenProbe(store()); probe.reviewIDs = ["payment-two"]
            await probe.start()
            check(probe.item == nil && probe.error != nil && OpenResponseProtocol.pending.isEmpty, "batch route outside supplied IDs cannot fetch or expose an item")
            let duplicate = OpenProbe(store()); duplicate.reviewIDs = ["payment-one"]; duplicate.startsInForm = true
            let task = Task { await duplicate.start() }
            try await waitForRequests(1)
            var item = payload(); item["candidates"] = ["existing"]
            OpenResponseProtocol.pending.removeFirst().respond(try data([item]))
            await task.value
            check(duplicate.item != nil && !duplicate.editing, "first batch duplicate also keeps comparison gate with startsInForm")
            let manual = OpenProbe(store()); manual.startsInForm = true
            let manualTask = Task { await manual.start() }
            try await waitForRequests(1)
            OpenResponseProtocol.pending.removeFirst().respond(try data([item]))
            await manualTask.value
            check(manual.item != nil && manual.editing, "explicit inbox record opens duplicate in form instead of looping back to inbox")
        }
        let noSave = OpenProbe(store())
        await noSave.next()
        check(OpenResponseProtocol.pending.isEmpty && noSave.route.id == "payment-one", "unsaved or failed entry never advances")
        let linkCredentials = store().credentials!
        let identity = linkCredentials.notificationSetup.identity
        let router = PaymentNotificationRouter.shared
        func resetRouter() { router.presentation = nil; router.deferQueued() }
        func paymentRoute() -> PaymentNotificationRoute? {
            if case .payment(let route) = router.presentation { return route }
            return nil
        }
        let link = "ourledger://payment?id=payment-one&identity=" + identity
        activityFixtures = []
        resetRouter()
        _ = PaymentLiveActivities.open(URL(string: link + "&scope=personal")!, credentials: linkCredentials)
        check(paymentRoute()?.id == "payment-one" && paymentRoute()?.scope == "personal" && paymentRoute()?.rawText == "",
              "real payment link routes after its activity has ended; only authenticated load supplies its data")
        resetRouter()
        _ = PaymentLiveActivities.open(URL(string: link.replacingOccurrences(of: identity, with: "wrong-identity"))!, credentials: linkCredentials)
        check(paymentRoute() == nil, "wrong connection link is never routed")
        let practiceLink = URL(string: link + "&practice=true")!
        linkCredentials.notificationSetup.beginPractice("payment-one")
        _ = PaymentLiveActivities.open(practiceLink, credentials: linkCredentials)
        check(paymentRoute() == nil, "practice still requires its current activity as a raw-text source")
        activityFixtures = [Activity(PaymentActivityAttributes(paymentID: "payment-one", identity: identity, practice: true))]
        _ = PaymentLiveActivities.open(practiceLink, credentials: linkCredentials)
        check(paymentRoute() == nil, "practice cannot open without original practice text")
        resetRouter()
        activityFixtures = [Activity(PaymentActivityAttributes(paymentID: "payment-one", identity: identity, practice: true, practiceRawText: "검증 결제 8,400원"))]
        linkCredentials.notificationSetup.beginPractice("payment-one", now: Date().addingTimeInterval(-601))
        _ = PaymentLiveActivities.open(practiceLink, credentials: linkCredentials)
        check(paymentRoute() == nil, "expired practice activity is not a valid notification source")
        resetRouter()
        linkCredentials.notificationSetup.beginPractice("payment-one")
        _ = PaymentLiveActivities.open(practiceLink, credentials: linkCredentials)
        check(paymentRoute()?.practice == true && paymentRoute()?.rawText == "검증 결제 8,400원",
              "valid practice keeps its original local text")
        resetRouter()
        let ledger = store()
        let opening = OpenProbe(ledger, scope: "personal")
        let first = Task { await opening.start() }
        try await waitForRequests(1)
        let overlapping = Task { await ledger.refresh() }
        try await waitForRequests(2)
        OpenResponseProtocol.pending.removeFirst().respond(pending)
        await first.value
        check(opening.item?.id == "payment-one" && opening.editing && opening.scope == "personal" && opening.error == nil,
              "fresh pending payment opens despite a newer App/scene refresh")
        let activity = Activity(PaymentActivityAttributes(paymentID: "payment-one", identity: ledger.credentials!.notificationSetup.identity, practice: false))
        activityFixtures = [activity]
        await PaymentLiveActivities.reconcile(ledger)
        check(!activity.ended, "overlapping refresh cannot end an activity using the stale empty inbox")
        OpenResponseProtocol.pending.removeFirst().respond(pending)
        await overlapping.value
        await PaymentLiveActivities.reconcile(ledger)
        check(!activity.ended, "fresh pending payment retains the activity")

        for status in [401, 503] {
            let ledger = store()
            let probe = OpenProbe(ledger)
            let loading = Task { await probe.start() }
            try await waitForRequests(1)
            let newer = Task { await ledger.refresh() }
            try await waitForRequests(2)
            OpenResponseProtocol.pending.removeFirst().respond(Data("{\"error\":\"검증용 조회 실패\"}".utf8), status: status)
            await loading.value
            check(probe.item == nil && probe.error != nil && !probe.editing, "HTTP \(status) is a load failure even during overlapping refresh")
            OpenResponseProtocol.pending.removeFirst().respond(empty)
            await newer.value
        }

        let changedMonth = store()
        let monthProbe = OpenProbe(changedMonth)
        let monthTask = Task { await monthProbe.start() }
        try await waitForRequests(1)
        changedMonth.month = "2026-09"
        OpenResponseProtocol.pending.removeFirst().respond(pending)
        await monthTask.value
        check(monthProbe.item?.id == "payment-one" && changedMonth.snapshot == nil,
              "month navigation keeps the owned pending payment without overwriting monthly totals")

        let changedConnection = store()
        let connectionProbe = OpenProbe(changedConnection)
        let connectionTask = Task { await connectionProbe.start() }
        try await waitForRequests(1)
        changedConnection.credentials = Credentials(base: "http://notification-open-check.local", token: "other-test-member")
        OpenResponseProtocol.pending.removeFirst().respond(pending)
        await connectionTask.value
        check(connectionProbe.item == nil && connectionProbe.error != nil && !connectionProbe.editing,
              "connection switch rejects old member response explicitly")
        let wrongIdentity = OpenProbe(store(), identity: "different-connection")
        await wrongIdentity.start()
        check(wrongIdentity.item == nil && wrongIdentity.error != nil && OpenResponseProtocol.pending.isEmpty,
              "notification identity mismatch never queries or exposes a payment")

        for (name, response, shouldError) in [
            ("fresh empty inbox", empty, false),
            ("missing merged ID cannot select another same-amount payment", try data([payload(id: "merged-target")]), false),
            ("other owner's payment cannot be opened", try data([payload(actor: "other-owner")]), false),
            ("recorded result cannot be reopened", try data([payload(status: "recorded")]), false),
            ("malformed server response remains a load error", Data("{}".utf8), true)
        ] {
            let probe = OpenProbe(store(), scope: "shared")
            let loading = Task { await probe.start() }
            try await waitForRequests(1)
            OpenResponseProtocol.pending.removeFirst().respond(response)
            await loading.value
            check(probe.item == nil && !probe.editing && (probe.error != nil) == shouldError, name)
        }

        for (name, failed, refreshing) in [
            ("failed refresh preserves activity without a new request", true, false),
            ("pending refresh preserves activity without a new request", false, true)
        ] {
            let ledger = store()
            ledger.error = failed ? "조회 실패" : nil
            ledger.refreshing = refreshing
            let item = Activity(PaymentActivityAttributes(paymentID: "payment-one", identity: ledger.credentials!.notificationSetup.identity, practice: false))
            activityFixtures = [item]
            let (task, request) = try await beginReconcile(ledger)
            request?.respond(pending)
            await task.value
            check(!item.ended && request == nil, name)
        }

        let oldSnapshotStore = store()
        let newlyCreated = Activity(PaymentActivityAttributes(paymentID: "payment-one", identity: identity, practice: false))
        activityFixtures = [newlyCreated]
        // A response read before import can be applied after the activity was created.
        oldSnapshotStore.updatedAt = Date()
        let snapshotTime = oldSnapshotStore.updatedAt
        let (freshTask, freshRequest) = try await beginReconcile(oldSnapshotStore)
        check(freshRequest != nil && !newlyCreated.ended, "old successful response cannot close a newer activity before fresh verification")
        freshRequest?.respond(pending)
        await freshTask.value
        check(freshRequest != nil && !newlyCreated.ended && oldSnapshotStore.snapshot?.inbox.isEmpty == true && oldSnapshotStore.updatedAt == snapshotTime,
              "fresh pending response preserves the new card without replacing shared monthly state")

        let duringFetch = store()
        let captured = Activity(PaymentActivityAttributes(paymentID: "payment-one", identity: identity, practice: false))
        activityFixtures = [captured]
        let (duringTask, duringRequest) = try await beginReconcile(duringFetch)
        let replacement = Activity(PaymentActivityAttributes(paymentID: "payment-one", identity: identity, practice: false))
        let later = Activity(PaymentActivityAttributes(paymentID: "payment-two", identity: identity, practice: false))
        activityFixtures = [replacement, later]
        duringRequest?.respond(empty)
        await duringTask.value
        check(duringRequest != nil && captured.ended && !replacement.ended && !later.ended,
              "fresh absence ends only captured instances, never activities created during the fetch")

        for status in [401, 503, 200] {
            let ledger = store()
            let candidate = Activity(PaymentActivityAttributes(paymentID: "payment-one", identity: identity, practice: false))
            activityFixtures = [candidate]
            let (task, request) = try await beginReconcile(ledger)
            request?.respond(Data("{}".utf8), status: status)
            await task.value
            check(request != nil && !candidate.ended, "reconcile HTTP \(status)/invalid response cannot prove absence")
        }
        for status in [200, 503] {
            let ledger = store()
            let oldActivity = Activity(PaymentActivityAttributes(paymentID: "payment-one", identity: identity, practice: false))
            activityFixtures = [oldActivity]
            let (task, request) = try await beginReconcile(ledger)
            ledger.credentials = Credentials(base: "http://notification-open-check.local", token: "other-test-member")
            let newActivity = Activity(PaymentActivityAttributes(paymentID: "payment-one", identity: ledger.credentials!.notificationSetup.identity, practice: false))
            activityFixtures.append(newActivity)
            request?.respond(empty, status: status)
            await task.value
            check(request != nil && oldActivity.ended && !newActivity.ended && ledger.snapshot == nil,
                  "connection switch during reconcile HTTP \(status) cleans only old connection instances")
        }
        for scenario in ["none", "cached pending", "practice"] {
            let ledger = store()
            if scenario == "cached pending" { ledger.snapshot = try JSONDecoder().decode(LedgerSnapshot.self, from: pending) }
            activityFixtures = scenario == "none" ? [] : [Activity(PaymentActivityAttributes(paymentID: "payment-one", identity: identity, practice: scenario == "practice"))]
            let (task, request) = try await beginReconcile(ledger)
            request?.respond(pending)
            await task.value
            check(request == nil, "no reconcile request for \(scenario)")
        }
        let other = Activity(PaymentActivityAttributes(paymentID: "payment-one", identity: "old-connection", practice: false))
        activityFixtures = [other]
        let switching = store()
        switching.refreshing = true
        await PaymentLiveActivities.reconcile(switching)
        check(other.ended, "connection privacy cleanup still runs while loading")
        let practiceStore = store()
        let practiceSetup = practiceStore.credentials!.notificationSetup
        practiceSetup.reset()
        let firstPractice = practiceSetup.beginTest()
        practiceSetup.beginPractice(firstPractice)
        let secondPractice = practiceSetup.beginTest()
        practiceSetup.beginPractice(secondPractice)
        let practiceProbe = OpenProbe(practiceStore)
        practiceProbe.route = PaymentNotificationRoute(id: firstPractice, identity: practiceSetup.identity,
            rawText: "synthetic practice", scope: "shared", practice: true, ignored: false)
        _ = practiceSetup.completePractice(firstPractice)
        practiceProbe.complete = true
        practiceProbe.scope = "shared"; practiceProbe.savedNote = "previous note"; practiceProbe.savedAmount = 8400
        await practiceProbe.next()
        check(practiceProbe.route.id == secondPractice && practiceProbe.route.practice,
              "two practice notifications advance to the second without a ledger write")
        check(practiceProbe.scope.isEmpty && practiceProbe.savedNote.isEmpty && practiceProbe.savedAmount == 0,
              "next practice clears previous scope and saved input")
        precondition(OpenResponseProtocol.pending.isEmpty)
        exit(failures == 0 ? 0 : 1)
    }
}
'''.replace("REMAINING_BODY", remaining).replace("ADVANCE_BODY", advance).replace("LOAD_BODY", load).replace("RECONCILE_BODY", reconcile).replace("OPEN_BODY", open_link).replace("CREDENTIALS_BODY", credentials)

with tempfile.TemporaryDirectory(prefix="ourledger-notification-open-") as directory:
    work = Path(directory)
    swift = work / "Check.swift"
    swift.write_text(harness)
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
                    str(ROOT / "OurLedger/Models.swift"), str(ROOT / "OurLedger/API.swift"),
                    str(ROOT / "OurLedger/NotificationSetupState.swift"), str(swift), "-o", str(work / "check")], check=True)
    subprocess.run([str(work / "check"), str(ROOT / "checks/fixtures/snapshot-legacy.json")], check=True)
