import Foundation

final class MonthResponseProtocol: URLProtocol {
    @MainActor static var pending: [MonthResponseProtocol] = []
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "month-check.local" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Task { @MainActor in Self.pending.append(self) } }
    override func stopLoading() {}
    func respond(_ data: Data, statusCode: Int = 200) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: statusCode,
            httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@main
struct StoreMonthCheck {
    @MainActor static func main() async throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let snapshot = try JSONDecoder().decode(LedgerSnapshot.self, from: data)
        let store = LedgerStore()
        store.snapshot = snapshot
        store.month = store.month == "2026-09" ? "2026-10" : "2026-09"
        guard store.snapshot == nil else {
            fputs("FAIL: changing month must hide the previous month's amounts before networking\n", stderr)
            exit(1)
        }
        print("PASS: month change cannot display or settle the previous month's snapshot")
        store.credentials = Credentials(base: "http://example.invalid", token: "test-only")
        store.activeInvite = URL(string: "ourledger://join?invite=test-only")
        store.inviteExpiresAt = Date().addingTimeInterval(3600)
        do { _ = try await store.makeInvite(); preconditionFailure("Invalid base must fail") } catch { }
        precondition(store.activeInvite == nil && store.inviteExpiresAt == nil,
                     "A lost regeneration response must not leave the possibly invalid old link shareable")
        print("PASS: failed invite regeneration cannot leave an old link shareable")
        store.month = "2026-09"
        store.snapshot = snapshot
        store.tab = 3
        store.receiveURL(URL(string: "ourledger://home")!)
        precondition(store.month == String(dayString(Date()).prefix(7)) && store.tab == 0)
        precondition(store.snapshot == nil, "Widget navigation must not relabel an older month's totals")
        print("PASS: widget link opens the current month and hides an old snapshot")

        URLProtocol.registerClass(MonthResponseProtocol.self)
        defer { URLProtocol.unregisterClass(MonthResponseProtocol.self) }
        store.credentials = Credentials(base: "http://month-check.local", token: "member-a-test-only")
        store.snapshot = nil
        let changingConnection = Task { await store.refresh() }
        while MonthResponseProtocol.pending.isEmpty { await Task.yield() }
        store.credentials = Credentials(base: "http://month-check.local", token: "member-b-test-only")
        MonthResponseProtocol.pending.removeFirst().respond(data)
        await changingConnection.value
        precondition(store.snapshot == nil, "A response for the old member must not expose their ledger to a new connection")
        print("PASS: connection change rejects the previous member's in-flight response")

        let credentials = store.credentials
        let today = String(dayString(Date()).prefix(7))
        var payload = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        payload["monthNavigation"] = ["previous": NSNull(), "next": NSNull()]
        let empty = try JSONDecoder().decode(LedgerSnapshot.self, from: JSONSerialization.data(withJSONObject: payload))
        store.month = today
        store.snapshot = empty
        precondition(store.monthDestination(-1) == nil && store.monthDestination(1) == nil)
        store.changeMonth(-1); store.changeMonth(1)
        precondition(store.month == today && store.snapshot != nil, "Empty current month stays usable")
        store.month = "2000-01"; store.snapshot = snapshot
        precondition(store.monthDestination(1) == today && store.monthDestination(-1) == nil,
                     "Legacy responses allow returning to today without inventing other months")
        store.month = "2099-01"; store.snapshot = snapshot
        precondition(store.monthDestination(-1) == today && store.monthDestination(1) == nil)
        payload["monthNavigation"] = ["previous": "2026-02", "next": "2027-04"]
        let navigation = try JSONDecoder().decode(LedgerSnapshot.self, from: JSONSerialization.data(withJSONObject: payload))
        store.month = "2026-10"; store.snapshot = navigation; store.tab = 2
        precondition(store.monthDestination(-1) == "2026-02" && store.monthDestination(1) == "2027-04")
        precondition(store.monthDestination(0) == nil)
        store.changeMonth(1)
        precondition(store.month == "2027-04" && store.snapshot == nil && store.credentials == credentials && store.tab == 2,
                     "Month navigation clears old amounts while preserving the connection and selected tab")
        precondition(store.monthDestination(-1) == nil, "Do not navigate from an unloaded month's data")
        print("PASS: empty current month, gaps, recurring destination and legacy month boundaries")

        let olderMonth = Task { await store.refresh() }
        while MonthResponseProtocol.pending.count < 1 { await Task.yield() }
        store.month = "2026-10"
        let newerMonth = Task { await store.refresh() }
        while MonthResponseProtocol.pending.count < 2 { await Task.yield() }
        MonthResponseProtocol.pending.removeFirst().respond(data)
        await olderMonth.value
        precondition(store.snapshot == nil && store.refreshing,
                     "An old month's response cannot relabel totals or end a newer loading state")
        MonthResponseProtocol.pending.removeFirst().respond(data)
        await newerMonth.value
        precondition(store.snapshot != nil && !store.refreshing && store.credentials == credentials)

        let olderRefresh = Task { await store.refresh() }
        while MonthResponseProtocol.pending.count < 1 { await Task.yield() }
        let newerRefresh = Task { await store.refresh() }
        while MonthResponseProtocol.pending.count < 2 { await Task.yield() }
        MonthResponseProtocol.pending.removeLast().respond(data)
        await newerRefresh.value
        let updatedAt = store.updatedAt
        MonthResponseProtocol.pending.removeFirst().respond(data)
        await olderRefresh.value
        precondition(store.updatedAt == updatedAt, "A superseded same-month response must be ignored")
        print("PASS: out-of-order month and same-month responses cannot replace the newest state")

        store.month = "2026-09"
        let failedMonth = Task { await store.refresh() }
        while MonthResponseProtocol.pending.isEmpty { await Task.yield() }
        MonthResponseProtocol.pending.removeFirst().respond(Data("{\"error\":\"검증용 조회 실패\"}".utf8), statusCode: 503)
        await failedMonth.value
        precondition(store.snapshot == nil && store.error != nil && !store.refreshing && store.credentials == credentials,
                     "A failed month load must keep the connection without showing old totals")
        let retry = Task { await store.refresh() }
        while MonthResponseProtocol.pending.isEmpty { await Task.yield() }
        MonthResponseProtocol.pending.removeFirst().respond(data)
        await retry.value
        precondition(store.snapshot != nil && store.error == nil && !store.refreshing && store.credentials == credentials)
        print("PASS: failed month load and retry preserve the connection and clear the error on success")
    }
}
