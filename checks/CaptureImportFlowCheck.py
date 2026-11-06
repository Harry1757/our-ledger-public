"""Exercise Inbox's real submission body with isolated HTTP responses (no app/device).

python3 checks/CaptureImportFlowCheck.py
The pre-change inline handler is also executable to demonstrate the regression.
"""
from pathlib import Path
import json
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "OurLedger/Inbox.swift").read_text()
paste = source.split("struct PasteNotificationView: View {", 1)[1]

def block(text, marker):
    start = text.index(marker)
    opening = text.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end]

marker = "@MainActor private func submit("
if marker in paste:
    submit = block(paste, marker)
else:
    # Execute the existing handler, not a reimplementation of the missing behavior.
    original = block(paste, "Task {")[len("Task {"):-1]
    submit = '''@MainActor private func submit(automatically: Bool = false) async {
        let eventID = submissionIDs.id(source: source, text: raw)
        busy = true; error = nil
    ''' + original + "\n}"
helper = block(source, "enum CaptureImportFlow {") if "enum CaptureImportFlow {" in source else ""
read_image = block(paste, "private func readImages(")
batch_submit = block(paste, "@MainActor private func submitCaptureBatch(")
batch_preview = block(paste, "@MainActor private func refreshCapturePreviews(")
batch_draft = block(source, "struct CaptureImportDraft:")
submitted_capture = block(paste, "private var hasSubmittedCapture:")
cancel_image = block(paste, "private func cancelImageReading(")
credentials = (ROOT / "OurLedger/ImportIntent.swift").read_text().split("extension Credentials {", 1)[1].split("struct ReceivePaymentNotificationIntent", 1)[0]
credentials = credentials.replace("defaults: .standard", "defaults: testDefaults")

harness = r'''
import Foundation
import CryptoKit
let testDefaultsName = "capture-flow-" + UUID().uuidString
let testDefaults = UserDefaults(suiteName: testDefaultsName)!
extension Credentials {
CREDENTIALS
HELPER
BATCH_DRAFT
// Replace only photo loading/Vision; execute Inbox's actual readImage lifecycle.
struct PhotosPickerItem {
    let text: String
    @MainActor static var onLoad: (() -> Void)?
    @MainActor func loadTransferable<T>(type: T.Type) async throws -> T? {
        Self.onLoad?()
        if text == "unreadable-image" { throw PaymentImageOCR.Failure.unreadableImage }
        return Data(text.utf8) as? T
    }
}
enum PaymentImageOCR {
    enum Failure: LocalizedError { case unreadableImage, noText }
    static func recognizeTransactions(_ data: Data) async throws -> [String] {
        String(decoding: data, as: UTF8.self).components(separatedBy: "\n---batch---\n")
    }
}
@MainActor final class Probe {
    let store: LedgerStore
    var raw = "카드 결제\n18,400원\n가맹점: 검증마트\n거래일: 2026-10-27"
    var source = "paste"
    var submissionIDs = ImportSubmissionIDs()
    var busy = false
    var error: String?
    var recordingRoute: PaymentNotificationRoute?
    var recordingIDs: [String]?
    var captureDrafts: [CaptureImportDraft] = []
    var captureIdentity: String?
SUBMITTED_CAPTURE
    var readingID: UUID? = UUID()
    var hasImageDraft = false
    var selectedImages: [PhotosPickerItem] = []
    var imageTask: Task<Void, Never>?
    var dismissed = false
    init(_ store: LedgerStore) { self.store = store }
    func dismiss() { dismissed = true }
    func run(_ automatic: Bool = false) async { await submit(automatically: automatic) }
    func scan(_ texts: [String] = ["카드 승인 18,400원 검증마트"]) async {
        readImages(texts.map { PhotosPickerItem(text: $0) })
        await imageTask?.value
    }
    func seedBatch(_ texts: [String]) {
        captureIdentity = store.credentials!.notificationSetup.identity
        captureDrafts = texts.enumerated().map { CaptureImportDraft(imageNumber: $0.offset + 1, raw: $0.element) }
    }
    func runBatch() async { await submitCaptureBatch() }
    func previews() async { await refreshCapturePreviews() }
    func cancel() { cancelImageReading() }
BATCH_SUBMIT
BATCH_PREVIEW
SUBMIT
READ_IMAGE
CANCEL_IMAGE
}
final class Replies: URLProtocol {
    @MainActor static var response: [String: Any] = [:]
    @MainActor static var preview: [String: Any] = [:]
    @MainActor static var snapshot: [String: Any] = [:]
    @MainActor static var requests: [(String, [String: Any])] = []
    @MainActor static var failurePath: String?
    @MainActor static var failureText: String?
    @MainActor static var failureStatus = 503
    @MainActor static var responseByText: [String: [String: Any]] = [:]
    @MainActor static var beforeReply: ((String) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Task { @MainActor in
            precondition(request.url?.host == "capture-flow-check.local", "No external requests")
            let path = request.url!.path
            precondition(["/imports", "/imports/preview", "/state"].contains(path), "Must never save entries")
            precondition(request.httpMethod == (path == "/state" ? "GET" : "POST"))
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
            }
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            Self.requests.append((path, body))
            Self.beforeReply?(path)
            let text = body["text"] as? String ?? ""
            let failed = path == Self.failurePath && (Self.failureText == nil || Self.failureText == text)
            let result = failed ? ["error": "synthetic failure"] : path == "/state" ? Self.snapshot : path == "/imports/preview" ? Self.preview : Self.responseByText[text] ?? Self.response
            let payload = try! JSONSerialization.data(withJSONObject: result)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: failed ? Self.failureStatus : 200,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: payload)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
@main struct Check {
    @MainActor static func main() async throws {
        URLProtocol.registerClass(Replies.self)
        defer { URLProtocol.unregisterClass(Replies.self); testDefaults.removePersistentDomain(forName: testDefaultsName) }
        let fixture = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let base = try JSONSerialization.jsonObject(with: fixture) as! [String: Any]
        let owner = base["me"] as! String
        let normal: [String: Any] = ["id": "import-returned-by-server", "owner": owner,
            "raw": "synthetic", "status": "pending", "merchant": "검증마트", "kind": "expense",
            "card": "", "reference": "", "reason": "", "amount": 18400,
            "sources": ["paste"], "candidates": [], "requiresReview": false]
        var count = 0, failures = 0
        func check(_ ok: Bool, _ title: String) {
            count += 1
            if !ok { failures += 1 }
            print("\(ok ? "PASS" : "FAIL") \(title)")
        }
        func probe() throws -> Probe {
            Replies.response = normal; Replies.preview = normal; Replies.snapshot = base; Replies.snapshot["inbox"] = [normal]
            Replies.requests = []; Replies.failurePath = nil; Replies.beforeReply = nil
            Replies.failureText = nil; Replies.failureStatus = 503; Replies.responseByText = [:]
            PhotosPickerItem.onLoad = nil
            let store = LedgerStore()
            store.credentials = Credentials(base: "http://capture-flow-check.local", token: "synthetic-only")
            store.snapshot = try JSONDecoder().decode(LedgerSnapshot.self, from: fixture)
            return Probe(store)
        }
        do {
            let p = try probe(); Replies.preview["merchant"] = ""; Replies.response["merchant"] = ""
            Replies.preview["requiresReview"] = true; Replies.response["requiresReview"] = true
            await p.run(true)
            check(p.recordingRoute != nil && !p.dismissed, "amount-first: missing merchant must open common form for manual completion")
        }
        for source in ["paste", "sms", "app"] {
            let p = try probe(); p.source = source
            p.raw = "발신 알림: 금액 확인 필요\n출금 예정과 실제 거래가 섞인 합성 문구"
            await p.run()
            let request = Replies.requests.first { $0.0 == "/imports" }!
            check((request.1["reviewOnly"] as? Bool ?? false) == (source == "paste"),
                  "\(source): explicit OCR review flag is capture-only")
        }
        do {
            let p = try probe()
            p.seedBatch(["발신 알림: 금액 확인 필요\n합성 출금 예정", "일반 캡처"])
            var reviewResponse = normal
            reviewResponse["kind"] = "unknown"; reviewResponse["amount"] = NSNull(); reviewResponse["requiresReview"] = true
            Replies.responseByText["발신 알림: 금액 확인 필요\n합성 출금 예정"] = reviewResponse
            await p.previews()
            let previews = Replies.requests.filter { $0.0 == "/imports/preview" }
            check(previews.count == 2 && previews[0].1["reviewOnly"] as? Bool == true
                  && previews[1].1["reviewOnly"] == nil, "batch previews preserve explicit review contract")
            await p.runBatch()
            let imports = Replies.requests.filter { $0.0 == "/imports" }
            check(imports.count == 2 && imports[0].1["reviewOnly"] as? Bool == true
                  && imports[1].1["reviewOnly"] == nil, "batch import uses the same review contract")
        }
        for status in ["ignored", "recorded", "pending"] {
            let p = try probe()
            p.raw = "발신 알림: 금액 확인 필요\n합성 검토 문구"
            Replies.response["status"] = status
            await p.run()
            check(p.error != nil && !p.dismissed && p.recordingRoute == nil && !p.raw.isEmpty,
                  "legacy/mismatched review response \(status) keeps draft instead of losing it")
        }
        do {
            let p = try probe(); let text = "발신 알림: 금액 확인 필요\n합성 검토 문구"
            p.seedBatch([text]); Replies.response["status"] = "ignored"
            await p.runBatch()
            check(p.error != nil && p.captureDrafts[0].imported == nil && !p.captureDrafts[0].retryLocked,
                  "legacy ignored batch response stays editable and unconsumed")
        }
        for source in ["sms", "app", "paste"] {
            let p = try probe(); p.source = source
            await p.run()
            check(p.recordingRoute?.id == "import-returned-by-server" && !p.dismissed,
                  "\(source): clear submit opens returned import in same sheet without dismiss")
            check(p.recordingRoute?.scope == nil && p.recordingRoute?.practice == false && p.recordingRoute?.ignored == false,
                  "\(source): scope stays user-selected, no practice or ignore action")
            check(Replies.requests.first?.1["source"] as? String == source,
                  "\(source): submitted source preserved")
        }
        for (field, value) in [("amount", NSNull()), ("amount", 0), ("amount", -1),
            ("amount", 100_000_000_001), ("merchant", " "), ("requiresReview", true),
            ("kind", "unknown"), ("kind", "")] as [(String, Any)] {
            let p = try probe(); Replies.response[field] = value
            await p.run()
            check(p.recordingRoute != nil && !p.dismissed, "manual unknown \(field): open form without guessing or saving an entry")
        }
        for (field, value) in [("candidates", ["previous"]),
            ("status", "recorded"), ("status", "ignored"), ("status", "duplicate"),
            ("owner", "another-member")] as [(String, Any)] {
            let p = try probe(); Replies.response[field] = value
            await p.run()
            check(p.recordingRoute == nil && p.dismissed, "manual \(field)=\(value): preserve inbox review")
        }
        for (field, value) in [("amount", NSNull()), ("amount", 0), ("amount", -1), ("amount", 100_000_000_001),
            ("kind", ""), ("kind", "unknown")] as [(String, Any)] {
            let p = try probe(); Replies.preview[field] = value
            await p.run(true)
            check(p.recordingRoute == nil && !p.dismissed && Replies.requests.map(\.0) == ["/imports/preview"],
                  "OCR uncertain \(field): keep editable draft without importing")
        }
        do {
            let p = try probe(); await p.run(true)
            check(p.recordingRoute != nil && !p.dismissed && Replies.requests.map(\.0) == ["/imports/preview", "/imports", "/state"],
                  "OCR clear preview imports once then opens form")
        }
        let bankData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
        let bankFixtures = try JSONSerialization.jsonObject(with: bankData) as! [[String: Any]]
        for fixture in bankFixtures {
            let preview = fixture["preview"] as! [String: Any]
            let imported = fixture["imported"] as! [String: Any]
            let kind = preview["kind"] as! String
            check(preview["requiresReview"] as? Bool == true && imported["status"] as? String == "pending",
                  "real parser/import \(kind): review means user must choose kind, import remains pending")
            for automatic in [false, true] {
                let p = try probe(); p.raw = fixture["text"] as! String
                Replies.preview = preview; Replies.response = imported
                await p.run(automatic)
                check(p.recordingRoute?.id == imported["id"] as? String && p.recordingRoute != nil
                      && p.recordingRoute?.scope == nil && !p.dismissed,
                      "\(kind), automatic=\(automatic): open common form without choosing scope or saving")
                let paths = automatic ? ["/imports/preview", "/imports", "/state"] : ["/imports", "/state"]
                check(Replies.requests.map(\.0) == paths
                      && Replies.requests.filter { $0.0 == "/imports" }.allSatisfy {
                          $0.1["text"] as? String == p.raw && $0.1["source"] as? String == "paste"
                          && $0.1["scope"] == nil && $0.1["kind"] == nil
                      }, "\(kind): preview/import contract preserves text/source and leaves classification to EntryForm")
            }
            for (field, value) in [("amount", NSNull()), ("amount", 0), ("kind", "unknown")] as [(String, Any)] {
                let p = try probe(); Replies.preview = preview; Replies.preview[field] = value
                await p.run(true)
                check(p.recordingRoute == nil && !p.dismissed && Replies.requests.map(\.0) == ["/imports/preview"],
                      "\(kind) with unsafe \(field): no automatic import")
            }
            for (field, value) in [("candidates", ["previous"]), ("status", "recorded"),
                                  ("status", "ignored"), ("status", "duplicate")] as [(String, Any)] {
                let p = try probe(); Replies.preview = preview; Replies.response = imported; Replies.response[field] = value
                await p.run(true)
                check(p.recordingRoute == nil && p.dismissed
                      && Replies.requests.map(\.0) == ["/imports/preview", "/imports", "/state"],
                      "\(kind) response \(field)=\(value): actual import response still blocks direct form")
            }
        }
        for status in ["recorded", "ignored", "duplicate"] {
            let p = try probe(); Replies.response["status"] = status
            await p.run(true)
            check(p.recordingRoute == nil && p.dismissed, "OCR actual response \(status) overrides clear preview")
        }
        do {
            let p = try probe(); Replies.response["candidates"] = ["previous"]
            await p.run(true)
            check(p.recordingRoute == nil && p.dismissed, "OCR duplicate candidate remains in comparison flow")
        }
        for path in ["/imports/preview", "/imports", "/state"] {
            for change in ["credentials", "source", "raw"] {
                let p = try probe()
                Replies.beforeReply = { replyPath in
                    guard replyPath == path else { return }
                    if change == "credentials" { p.store.credentials = Credentials(base: "http://capture-flow-check.local", token: "other") }
                    else if change == "source" { p.source = "app" }
                    else { p.raw = "another draft" }
                }
                await p.run(true)
                check(p.recordingRoute == nil && !p.dismissed, "\(change) changes at \(path): stale response cannot navigate")
                if path == "/imports/preview" {
                    check(!Replies.requests.contains { $0.0 == "/imports" }, "\(change): no import after stale preview")
                }
            }
        }
        for path in ["/imports/preview", "/imports"] {
            let p = try probe(); Replies.failurePath = path
            await p.run(true)
            check(p.error != nil && !p.busy && !p.dismissed && p.recordingRoute == nil,
                  "\(path) failure preserves draft and enables retry")
        }
        do {
            let p = try probe(); Replies.failurePath = "/imports"; await p.run()
            let first = Replies.requests.first?.1["eventID"] as? String
            Replies.failurePath = nil; await p.run()
            let ids = Replies.requests.filter { $0.0 == "/imports" }.compactMap { $0.1["eventID"] as? String }
            check(first != nil && ids.count == 2 && ids[0] == ids[1], "retry preserves submission id")
        }
        for scenario in ["busy", "empty", "no credentials", "wrong automatic source"] {
            let p = try probe()
            if scenario == "busy" { p.busy = true }
            if scenario == "empty" { p.raw = " \n" }
            if scenario == "no credentials" { p.store.credentials = nil }
            if scenario == "wrong automatic source" { p.source = "sms" }
            await p.run(true)
            check(Replies.requests.isEmpty && p.recordingRoute == nil, "\(scenario): no request")
        }
        do {
            let p = try probe(); p.raw = ""
            await p.scan()
            check(p.recordingRoute != nil && !p.dismissed && p.readingID == nil && p.hasImageDraft,
                  "first OCR with no draft opens form and clears reading state")
        }
        for existing in ["edited text", "cleared image draft"] {
            let p = try probe()
            p.raw = existing == "edited text" ? "user draft" : ""
            p.hasImageDraft = existing == "cleared image draft"
            await p.scan()
            check(Replies.requests.isEmpty && p.recordingRoute == nil && !p.dismissed && p.hasImageDraft,
                  "OCR replacing \(existing) requires explicit submit")
        }
        for change in ["credentials", "source", "cancel"] {
            let p = try probe(); p.raw = ""
            PhotosPickerItem.onLoad = {
                if change == "credentials" { p.store.credentials = nil }
                else if change == "source" { p.source = "sms" }
                else { p.cancel() }
            }
            await p.scan()
            check(Replies.requests.isEmpty && p.raw.isEmpty && !p.hasImageDraft && p.recordingRoute == nil,
                  "\(change) while loading image cannot overwrite draft or submit")
        }
        for path in ["/imports/preview", "/imports", "/state"] {
            let p = try probe(); p.raw = ""
            Replies.beforeReply = { if $0 == path { p.cancel() } }
            await p.scan()
            check(p.recordingRoute == nil && !p.dismissed && !p.busy,
                  "cancel at \(path) cannot open a recording screen")
        }
        do {
            let p = try probe(); p.raw = ""
            await p.scan(["first\n---batch---\nsecond", "third"])
            check(p.captureDrafts.map(\.raw) == ["first", "second", "third"] && p.captureDrafts.map(\.imageNumber) == [1, 1, 2],
                  "ordered image scan preserves all transactions in each selected image")
            check(p.captureDrafts.allSatisfy { $0.preview?.amount == 18400 } && p.recordingRoute == nil
                  && Replies.requests.allSatisfy { $0.0 == "/imports/preview" }, "multi capture previews only; explicit confirmation required before any import")
        }
        do {
            let p = try probe(); await p.scan(["first", "unreadable-image", "third"])
            check(p.captureDrafts.count == 3 && p.captureDrafts[1].raw.isEmpty && p.captureDrafts[1].issue != nil
                  && p.captureDrafts[2].raw == "third", "unreadable image keeps its ordered editable slot; later images still recognized")
            let requestCount = Replies.requests.count
            await p.runBatch()
            check(Replies.requests.count == requestCount && p.recordingRoute == nil, "unreadable slot cannot silently disappear on submission")
        }
        do {
            let p = try probe(); await p.scan((1...12).map { "image-\($0)" })
            check(p.captureDrafts.count == 10 && p.captureDrafts.last?.imageNumber == 10, "image processing respects the ten-photo picker bound")
        }
        do {
            let p = try probe(); var loads = 0
            PhotosPickerItem.onLoad = { loads += 1; if loads == 2 { p.cancel() } }
            await p.scan(["first", "second", "third"])
            check(p.captureDrafts.count == 3 && p.captureDrafts[0].raw == "first"
                  && p.captureDrafts[1...].allSatisfy { $0.raw.isEmpty && !$0.waitingForImage && $0.issue != nil },
                  "cancelling OCR preserves read content and explicitly accounts for all unread images")
            check(!Replies.requests.contains { $0.0 == "/imports" }, "cancelled image processing never imports")
        }
        let safetyData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))
        let safetyFixtures = try JSONSerialization.jsonObject(with: safetyData) as! [[String: Any]]
        for fixture in safetyFixtures {
            let text = fixture["text"] as! String, preview = fixture["preview"] as! [String: Any]
            let imported = fixture["imported"] as! [String: Any]
            let amount = preview["amount"] as? Int
            let p = try probe(); p.raw = text; Replies.preview = preview; Replies.response = imported
            await p.run(true)
            if amount == nil {
                check(p.recordingRoute == nil && Replies.requests.map(\.0) == ["/imports/preview"],
                      "real balance/notice/unknown preview stays unfilled with no automatic import")
                await p.run()
                check((p.recordingRoute != nil) == (imported["status"] as? String == "pending"),
                      "explicit unknown text goes to manual form; server-ignored notices never become entries")
            } else {
                check(p.recordingRoute != nil && preview["merchant"] as? String == "",
                      "real amount-first parser without merchant/date opens common form")
            }
        }
        func configureBatch(_ p: Probe) {
            p.seedBatch(["first", "second", "third"])
            for (index, text) in ["first", "second", "third"].enumerated() {
                var result = normal; result["id"] = "batch-\(index + 1)"; result["raw"] = text
                Replies.responseByText[text] = result
            }
            Replies.snapshot["inbox"] = [Replies.responseByText["third"]!, Replies.responseByText["first"]!, Replies.responseByText["second"]!]
        }
        do {
            let p = try probe(); configureBatch(p)
            Replies.failurePath = "/imports"; Replies.failureText = "second"
            await p.runBatch()
            check(p.captureDrafts[0].imported?.id == "batch-1" && p.captureDrafts[1].imported == nil
                  && p.captureDrafts[1].retryLocked && p.recordingRoute == nil && p.error != nil, "partial failure retains successful ID and freezes uncertain request text")
            let failedID = Replies.requests.last?.1["eventID"] as? String
            Replies.failurePath = nil
            await p.runBatch()
            let imports = Replies.requests.filter { $0.0 == "/imports" }
            check(imports.compactMap { $0.1["text"] as? String } == ["first", "second", "second", "third"]
                  && imports[2].1["eventID"] as? String == failedID, "retry skips successful imports and reuses uncertain event ID")
            check(p.recordingIDs == ["batch-1", "batch-2", "batch-3"] && p.recordingRoute?.id == "batch-1"
                  && p.recordingRoute?.scope == nil && !p.dismissed, "successful retry opens ordered batch without choosing scope or saving ledger")
            let calls = imports.count
            await p.runBatch()
            check(Replies.requests.filter { $0.0 == "/imports" }.count == calls, "resuming a submitted batch never resubmits successful IDs")
        }
        do {
            let p = try probe(); p.seedBatch(["same text", "same text"])
            await p.runBatch()
            let eventIDs = Replies.requests.filter { $0.0 == "/imports" }.compactMap { $0.1["eventID"] as? String }
            check(eventIDs.count == 2 && Set(eventIDs).count == 2, "identical OCR text in separate rows has independent stable event IDs")
            check(p.recordingIDs == ["import-returned-by-server"], "server-deduplicated ID appears once in batch review order")
        }
        do {
            let p = try probe(); configureBatch(p)
            Replies.failurePath = "/imports"; Replies.failureText = "first"; Replies.failureStatus = 422
            await p.runBatch()
            let oldID = Replies.requests.last?.1["eventID"] as? String
            check(!p.captureDrafts[0].retryLocked && p.captureDrafts[0].imported == nil, "definitive server rejection permits raw correction")
            p.captureDrafts[0].raw = "corrected"; Replies.failurePath = nil
            await p.runBatch()
            check(Replies.requests[1].1["text"] as? String == "corrected" && Replies.requests[1].1["eventID"] as? String != oldID,
                  "corrected rejected text gets its own retry ID")
        }
        do {
            let p = try probe(); configureBatch(p)
            var task: Task<Void, Never>?
            Replies.beforeReply = { path in
                if path == "/imports", Replies.requests.filter({ $0.0 == "/imports" }).count == 2 { task?.cancel() }
            }
            task = Task { await p.runBatch() }; await task?.value
            check(p.captureDrafts[0].imported?.id == "batch-1" && p.recordingRoute == nil && !p.busy,
                  "cancellation during a later import retains prior success without navigating")
            let secondIDs = Replies.requests.filter { $0.1["text"] as? String == "second" }.compactMap { $0.1["eventID"] as? String }
            Replies.beforeReply = nil; await p.runBatch()
            let retriedIDs = Replies.requests.filter { $0.1["text"] as? String == "second" }.compactMap { $0.1["eventID"] as? String }
            check(p.recordingIDs == ["batch-1", "batch-2", "batch-3"] && Set(secondIDs + retriedIDs).count == 1,
                  "cancelled import resumes using the same event ID and preserved ordered successes")
        }
        for change in ["credentials", "source"] {
            let p = try probe(); configureBatch(p)
            Replies.beforeReply = { path in
                if path == "/imports" {
                    if change == "credentials" { p.store.credentials = nil } else { p.source = "app" }
                }
            }
            await p.runBatch()
            check(p.recordingRoute == nil && Replies.requests.filter { $0.0 == "/imports" }.count == 1,
                  "batch \(change) switch cannot send remaining items or navigate with stale identity")
        }
        do {
            let p = try probe(); configureBatch(p)
            for text in ["first", "second", "third"] { Replies.responseByText[text]?["status"] = "ignored" }
            await p.runBatch()
            check(p.recordingRoute == nil && !p.dismissed && p.error != nil && p.captureDrafts.allSatisfy { $0.imported?.status == "ignored" },
                  "notice-only batch shows every non-recordable outcome without guessing a transaction")
        }
        do {
            let p = try probe(); configureBatch(p)
            Replies.failurePath = "/imports"; Replies.failureText = "second"
            await p.runBatch()
            check(p.captureDrafts[0].imported?.id == "batch-1", "review regression starts with first import already successful")
            Replies.failurePath = nil
            var foreign = normal; foreign["id"] = "unrelated"; foreign["owner"] = "another-member"
            Replies.snapshot["inbox"] = [foreign, Replies.responseByText["third"]!, Replies.responseByText["second"]!]
            await p.runBatch()
            check(p.recordingRoute?.id == "batch-2" && p.recordingIDs == ["batch-2", "batch-3"],
                  "retry after first item handled elsewhere intersects latest own pending IDs in original batch order")
            check(Replies.requests.filter { $0.0 == "/imports" && $0.1["text"] as? String == "first" }.count == 1,
                  "externally handled success is never reimported")
        }
        do {
            let p = try probe(); configureBatch(p); Replies.failurePath = "/state"
            await p.runBatch()
            check(p.recordingRoute == nil && p.error != nil && p.captureDrafts.allSatisfy { $0.imported != nil },
                  "failed final refresh cannot navigate using cached pending imports; success IDs are retained")
            let beforeRetry = Replies.requests.filter { $0.0 == "/imports" }.count
            Replies.failurePath = nil; await p.runBatch()
            check(p.recordingRoute?.id == "batch-1" && Replies.requests.filter { $0.0 == "/imports" }.count == beforeRetry,
                  "refresh retry performs no duplicate imports and proceeds only after latest state succeeds")
        }
        do {
            let p = try probe(); configureBatch(p); Replies.snapshot["inbox"] = []
            await p.runBatch()
            check(p.recordingRoute == nil && p.recordingIDs == nil && p.error != nil,
                  "batch whose items are all handled in latest state never opens stale first ID")
        }
        print("\(count - failures)/\(count) checks passed")
        exit(failures == 0 ? 0 : 1)
    }
}
'''.replace("CREDENTIALS", credentials).replace("HELPER", helper).replace("BATCH_DRAFT", batch_draft).replace("SUBMITTED_CAPTURE", submitted_capture).replace("BATCH_SUBMIT", batch_submit).replace("BATCH_PREVIEW", batch_preview).replace("SUBMIT", submit).replace("READ_IMAGE", read_image).replace("CANCEL_IMAGE", cancel_image)
with tempfile.TemporaryDirectory(prefix="capture-flow-") as directory:
    work = Path(directory)
    # Use real server parser/import outputs, without HTTP, persistence or production data.
    sys.dont_write_bytecode = True
    sys.path.insert(0, str(ROOT / "server"))
    from ledger import import_message, new_household, parse_message
    owner = json.loads((ROOT / "checks/fixtures/snapshot-legacy.json").read_text())["me"]
    bank_fixtures = []
    for label, kind in [("출금", "transfer"), ("입금", "income")]:
        state = new_household("검증", "검증자", "separate")
        state["members"][0]["id"] = owner
        text = label + "\n65,720원\n가맹점: 테스트보험\n거래일: 2026-10-26\n2026-10-26 19:16"
        preview = parse_message(text)
        imported = import_message(state, owner, {"text": text, "source": "paste", "eventID": "bank-flow-check"})
        assert preview["kind"] == kind and preview["amount"] == 65720 and preview["requiresReview"]
        assert imported["status"] == "pending" and imported["candidates"] == [] and not state["entries"]
        bank_fixtures.append({"text": text, "preview": preview, "imported": imported})
    bank_path = work / "bank.json"
    bank_path.write_text(json.dumps(bank_fixtures))
    safety_fixtures = []
    for text in ["출금\n65,720원", "입금\n65,720원", "승인\n18,400원", "잔액 18,400원", "출금 예정 18,400원", "읽기 불명확 18,400원"]:
        state = new_household("검증", "검증자", "separate")
        state["members"][0]["id"] = owner
        preview = parse_message(text)
        imported = import_message(state, owner, {"text": text, "source": "paste", "eventID": "safety-test"})
        assert not state["entries"]
        safety_fixtures.append({"text": text, "preview": preview, "imported": imported})
    safety_path = work / "safety.json"
    safety_path.write_text(json.dumps(safety_fixtures))
    swift = work / "Check.swift"
    swift.write_text(harness)
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
                    str(ROOT / "OurLedger/Models.swift"), str(ROOT / "OurLedger/API.swift"),
                    str(ROOT / "OurLedger/NotificationSetupState.swift"), str(swift),
                    "-o", str(work / "check")], check=True)
    subprocess.run([str(work / "check"), str(ROOT / "checks/fixtures/snapshot-legacy.json"), str(bank_path), str(safety_path)], check=True, timeout=60)
