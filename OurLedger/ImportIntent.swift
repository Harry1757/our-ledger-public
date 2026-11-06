import AppIntents
import UserNotifications
import UIKit
import CryptoKit

struct ImportClipboardIntent: AppIntent {
    static var title: LocalizedStringResource = "복사한 결제 가져오기"
    static var description = IntentDescription("직접 실행했을 때만 복사한 결제 문구를 확인함에 넣어요. 공용·개인은 앱에서 선택해요.")
    static var supportedModes: IntentModes = .foreground

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let content = UIPasteboard.general.string, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APIError(message: "결제 문자나 알림 내용을 먼저 복사해 주세요.")
        }
        let action = ImportTransactionIntent()
        action.text = content
        action.source = "paste"
        return try await action.perform()
    }
}

struct LedgerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ReceivePaymentNotificationIntent(), phrases: ["\(.applicationName)에 결제 알림 전달"], shortTitle: "결제 알림 자동 수신", systemImageName: "bell.badge")
        AppShortcut(intent: ImportClipboardIntent(), phrases: ["\(.applicationName)에 복사한 결제 넣기"], shortTitle: "복사한 결제 가져오기", systemImageName: "doc.on.clipboard")
    }
}

struct ImportTransactionIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "거래 알림 가져오기"
    static var description = IntentDescription("전달한 결제·송금 문구를 가계부 확인함에 보관해요. 확인 전에는 지출로 등록하지 않아요.")
    static var supportedModes: IntentModes = .background

    @Parameter(title: "알림 내용") var text: String
    @Parameter(title: "알림 출처", default: "sms") var source: String
    @Parameter(title: "이벤트 식별자 (선택)") var eventID: String?

    static var parameterSummary: some ParameterSummary { Summary("\(\.$text)을 확인함으로 가져오기") }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let credentials = Credentials.load() else { throw APIError(message: "우리 가계부 앱에서 가계부를 먼저 연결해 주세요.") }
        let setup = credentials.notificationSetup
        let context = NotificationDeliveryContext.current
        let deliveryID = context?.identity == setup.identity ? context!.id : setup.beginDelivery()
        guard !text.contains(NotificationSetupState.testMarker) else {
            setup.recordDelivery(deliveryID, stage: .filterExcluded)
            return .result(dialog: "연결 테스트 알림은 실제 거래로 가져오지 않아요.")
        }
        let api = ServerAPI(credentials: credentials)
        // A failed response may follow a successful save, so retries must reuse the same event ID.
        let suppliedID = eventID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let body: [String: Any] = ["text": text, "source": source, "eventID": suppliedID.isEmpty ? UUID().uuidString : suppliedID, "viaShortcut": true]
        let result: ImportedMessage
        setup.recordDelivery(deliveryID, stage: .submitting)
        do {
            do { result = try await api.request("/imports", method: "POST", body: body) }
            catch let failure as APIError where failure.statusCode == nil || [500, 502, 503, 504].contains(failure.statusCode ?? 0) {
                try await Task.sleep(for: .milliseconds(300))
                result = try await api.request("/imports", method: "POST", body: body)
            }
        } catch {
            setup.recordDelivery(deliveryID, stage: error is CancellationError || Task.isCancelled ? .cancelled : .failed)
            throw error
        }
        setup.recordDelivery(deliveryID, stage: .serverAcknowledged)
        if result.status == "pending" {
            let live = await PaymentLiveActivities.show(id: result.id, identity: credentials.notificationSetup.identity,
                merchant: result.merchant, amount: result.amount)
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            if !live && (settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional) {
                let notification = PaymentNotifications.content(id: result.id, identity: credentials.notificationSetup.identity,
                    merchant: result.merchant.isEmpty ? "새 거래" : result.merchant, amount: result.amount)
                // A failed local notification must not turn a successfully imported transaction into a failed import.
                try? await center.add(UNNotificationRequest(identifier: result.id, content: notification, trigger: nil))
            }
        }
        return .result(dialog: result.status == "pending" ? "확인함에 보관했어요. 앱에서 공용 여부를 확인해 주세요." : "이미 처리한 거래 알림이에요. 새 지출로 등록하지 않았어요.")
    }
}


extension Credentials {
    var notificationSetup: NotificationSetupState {
        let digest = SHA256.hash(data: Data((base + "\n" + token).utf8)).map { String(format: "%02x", $0) }.joined()
        return NotificationSetupState(defaults: .standard, identity: digest)
    }
}

struct ReceivePaymentNotificationIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "결제 알림 자동 수신"
    static var description = IntentDescription("알림·메시지 자동화의 받은 본문을 연결해 주세요. 클립보드는 읽지 않아요.")
    static var supportedModes: IntentModes = .background
    @Parameter(title: "알림 내용") var text: String
    @Parameter(title: "알림 출처", default: "app") var source: String
    static var parameterSummary: some ParameterSummary { Summary("\(\.$text)을 자동으로 받기") }

    func perform() async throws -> some IntentResult {
        guard let credentials = Credentials.load() else {
            throw APIError(message: "우리 가계부에서 가계부를 먼저 연결해 주세요.")
        }
        let setup = credentials.notificationSetup
        let deliveryID = setup.beginDelivery()
        do {
            if setup.matchesTest(text) {
                setup.recordDelivery(deliveryID, stage: .testing)
                // Verify authenticated server access without creating a test expense or inbox item.
                let _: LedgerSnapshot = try await ServerAPI(credentials: credentials).request("/state?month=" + String(dayString(Date()).prefix(7)))
                let confirmed = setup.confirmTest(text)
                if confirmed, let token = setup.practiceToken(in: text) {
                    let parsed: PaymentRecognition = try await ServerAPI(credentials: credentials).request("/imports/preview", method: "POST", body: ["text": text])
                    // A user can complete/discard while the preview request is suspended.
                    if setup.practiceToken(in: text) == token {
                        _ = await PaymentLiveActivities.show(id: token, identity: setup.identity, merchant: parsed.merchant,
                            amount: parsed.amount, practice: true, rawText: text)
                    }
                }
                setup.recordDelivery(deliveryID, stage: .testAcknowledged)
                return .result()
            }
            guard NotificationSetupState.isPayment(text) else {
                setup.recordDelivery(deliveryID, stage: .filterExcluded)
                return .result()
            }
            let action = ImportTransactionIntent()
            action.text = text
            action.source = source == "sms" ? "sms" : "app"
            try await NotificationDeliveryContext.$current.withValue(.init(id: deliveryID, identity: setup.identity)) {
                _ = try await action.perform()
            }
            setup.received()
            return .result()
        } catch {
            setup.recordDelivery(deliveryID, stage: error is CancellationError || Task.isCancelled ? .cancelled : .failed)
            throw error
        }
    }
}
