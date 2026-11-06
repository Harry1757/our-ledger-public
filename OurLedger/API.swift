import Foundation
import Observation
import Security

struct Credentials: Codable, Equatable {
    let base, token: String
    private static let service = "com.hwangsoonhwan.OurLedger.session"
    static func load() -> Credentials? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "member",
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Credentials.self, from: data)
    }
    func save() throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service, kSecAttrAccount as String: "member"]
        let values: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(self),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            let inserted = SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil)
            guard inserted == errSecSuccess else { throw APIError(message: "연결 정보를 안전하게 저장하지 못했어요.") }
        } else if status != errSecSuccess {
            throw APIError(message: "연결 정보를 안전하게 저장하지 못했어요.")
        }
    }
}

struct ServerAPI {
    let credentials: Credentials
    static func validateBase(_ base: String) throws -> String {
        guard let url = URLComponents(string: base.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else { throw APIError(message: "서버 주소를 확인해 주세요.") }
        let local = host == "localhost" || host == "127.0.0.1" || host.hasSuffix(".local") || host.hasPrefix("192.168.") || host.hasPrefix("10.")
        guard url.scheme == "https" || (url.scheme == "http" && local) else {
            throw APIError(message: "외부 서버에는 HTTPS 주소가 필요해요.")
        }
        return base.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    func request<T: Decodable>(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> T {
        let base = try Self.validateBase(credentials.base)
        guard let url = URL(string: base + path) else { throw APIError(message: "요청 주소를 확인해 주세요.") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !credentials.token.isEmpty { request.setValue("Bearer " + credentials.token, forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) }
        catch { throw APIError(message: "서버에 연결하지 못했어요. 서버 실행과 네트워크를 확인해 주세요.") }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: String])?["error"]
            throw APIError(message: message ?? "요청을 처리하지 못했어요.", statusCode: (response as? HTTPURLResponse)?.statusCode)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

@MainActor @Observable
final class LedgerStore {
    var credentials = Credentials.load() {
        didSet {
            if credentials != oldValue {
                snapshot = nil; error = nil; updatedAt = nil
                refreshID = UUID(); refreshing = false
            }
        }
    }
    var snapshot: LedgerSnapshot?
    var month = String(dayString(Date()).prefix(7)) {
        didSet {
            if month != oldValue {
                snapshot = nil; error = nil; updatedAt = nil
                refreshID = UUID(); refreshing = false
            }
        }
    }
    var error: String?
    var refreshing = false
    var updatedAt: Date?
    var tab = 0
    var inviteURL: URL?
    var activeInvite: URL?
    var inviteExpiresAt: Date?
    var notice: String?
    private var refreshID = UUID()
    var api: ServerAPI? { credentials.map { ServerAPI(credentials: $0) } }

    func monthDestination(_ direction: Int) -> String? {
        guard (direction == -1 || direction == 1), let snapshot else { return nil }
        let candidate = direction < 0 ? snapshot.monthNavigation?.previous : snapshot.monthNavigation?.next
        let today = String(dayString(Date()).prefix(7))
        // shortcut: older servers only allow returning to today; deploy month metadata to enable history.
        let destination = candidate ?? today
        guard !ledgerMonthDays(destination).isEmpty,
              direction < 0 ? destination < month : destination > month else { return nil }
        return destination
    }

    func changeMonth(_ direction: Int) {
        if let destination = monthDestination(direction) { month = destination }
    }

    func refresh() async {
        guard let api, let credentials else { return }
        let requestID = UUID()
        refreshID = requestID
        let requestedMonth = month
        refreshing = true
        defer { if refreshID == requestID { refreshing = false } }
        do {
            let result: LedgerSnapshot = try await api.request("/state?month=" + requestedMonth)
            if month == requestedMonth, self.credentials == credentials, refreshID == requestID {
                snapshot = result; updatedAt = Date(); error = nil
                #if os(iOS)
                LedgerWidgetPublisher.publish(result, month: requestedMonth)
                #endif
                if result.members.count == 2 { activeInvite = nil; inviteExpiresAt = nil }
            }
        } catch {
            if requestedMonth == month, self.credentials == credentials, refreshID == requestID {
                self.error = error.localizedDescription + (snapshot == nil ? "" : " 표시 중인 기록은 마지막 조회 상태예요.")
            }
        }
    }
    func connect(base: String, name: String, household: String, mode: String, invite: String?, setupCode: String = "") async throws {
        let base = try ServerAPI.validateBase(base)
        let api = ServerAPI(credentials: Credentials(base: base, token: ""))
        let payload: [String: Any] = invite.map { ["invite": $0, "memberName": name] }
            ?? ["name": household, "memberName": name, "mode": mode, "setupCode": setupCode.trimmingCharacters(in: .whitespacesAndNewlines)]
        let result: AuthResponse = try await api.request(invite == nil ? "/households" : "/join", method: "POST", body: payload)
        let saved = Credentials(base: base, token: result.token)
        try saved.save()
        credentials = saved
        await refresh()
    }
    func mutate(_ path: String, method: String = "POST", body: [String: Any] = [:]) async throws {
        guard let api else { throw APIError(message: "먼저 가계부를 연결해 주세요.") }
        let _: EmptyResponse = try await api.request(path, method: method, body: body)
        await refresh()
    }
    func makeInvite() async throws -> URL {
        guard let api, let credentials else { throw APIError(message: "가계부 연결이 필요해요.") }
        guard (snapshot?.members.count ?? 0) < 2 else { throw APIError(message: "두 사람이 이미 함께 쓰고 있어요.") }
        activeInvite = nil; inviteExpiresAt = nil
        let requestedAt = Date()
        let result: InviteResponse = try await api.request("/invite", method: "POST", body: [:])
        var components = URLComponents()
        components.scheme = "ourledger"
        components.host = "join"
        components.queryItems = [URLQueryItem(name: "server", value: credentials.base), URLQueryItem(name: "invite", value: result.invite)]
        guard let url = components.url else { throw APIError(message: "초대 링크를 만들지 못했어요.") }
        activeInvite = url
        inviteExpiresAt = requestedAt.addingTimeInterval(TimeInterval(result.expiresIn))
        return url
    }
    func receiveURL(_ url: URL) {
        if url.scheme == "ourledger", url.host == "home" {
            month = String(dayString(Date()).prefix(7)); tab = 0
            return
        }
        guard url.scheme == "ourledger", url.host == "join" else { return }
        if credentials != nil { error = "이미 가계부에 참여 중이에요. 초대 링크는 상대방의 앱에서 열어 주세요."; return }
        inviteURL = url
    }
}
