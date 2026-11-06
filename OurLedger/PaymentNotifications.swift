import SwiftUI
import UserNotifications
import Observation
import ActivityKit

enum PaymentLiveActivities {
    #if DEBUG
    @MainActor static func prepareLocalNotificationTest(_ store: LedgerStore) async {
        let environment = ProcessInfo.processInfo.environment
        guard environment["OURLEDGER_TEST_ACTIVITY"] == "1" || environment["OURLEDGER_TEST_QUEUE_PREFIX"] != nil else { return }
        guard let server = environment["OURLEDGER_TEST_SERVER"],
              let credentials = store.credentials, credentials.base == server,
              let url = URL(string: server), url.scheme == "http", url.host == "127.0.0.1", url.port == 18817,
              store.snapshot != nil else { return }
        let setup = credentials.notificationSetup
        if let prefix = environment["OURLEDGER_TEST_QUEUE_PREFIX"], !prefix.isEmpty {
            let items = (store.snapshot?.inbox ?? []).filter { $0.merchant.hasPrefix(prefix) }
                .sorted { ($0.receivedAt ?? $0.id) < ($1.receivedAt ?? $1.id) }
            for item in items.prefix(2) {
                PaymentNotificationRouter.shared.receive(PaymentNotificationRoute(id: item.id, identity: setup.identity,
                    rawText: "", scope: nil, practice: false, ignored: false))
            }
            return
        }
        let token = setup.beginTest()
        setup.beginPractice(token)
        let content = PaymentNotifications.practiceContent(id: token, identity: setup.identity)
        _ = await show(id: token, identity: setup.identity, merchant: "CU 테스트점", amount: NotificationSetupState.practiceAmount(token), practice: true,
                       rawText: content.title + "\n" + content.body)
    }
    #endif
    @MainActor static func show(id: String, identity: String, merchant: String, amount: Int?, practice: Bool = false, rawText: String = "") async -> Bool {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return false }
        let state = PaymentActivityAttributes.ContentState(merchant: merchant, amount: amount)
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(600))
        let current = Activity<PaymentActivityAttributes>.activities
        if let existing = current.first(where: { $0.attributes.paymentID == id && $0.attributes.identity == identity }) {
            await existing.update(content)
            return true
        }
        do {
            _ = try Activity.request(attributes: PaymentActivityAttributes(paymentID: id, identity: identity, practice: practice, practiceRawText: rawText), content: content, pushType: nil)
            // Only the latest pending payment occupies the island; all others remain in the inbox.
            for activity in current { await activity.end(nil, dismissalPolicy: .immediate) }
            return true
        } catch { return false }
    }
    static func end(id: String, identity: String) async {
        for activity in Activity<PaymentActivityAttributes>.activities where activity.attributes.paymentID == id && activity.attributes.identity == identity {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
    @MainActor static func reconcile(_ store: LedgerStore) async {
        for activity in Activity<PaymentActivityAttributes>.activities {
            let attributes = activity.attributes
            let otherConnection = attributes.identity != store.credentials?.notificationSetup.identity
            let expiredPractice = attributes.practice && store.credentials?.notificationSetup.matchesPractice(attributes.paymentID) != true
            if otherConnection || expiredPractice { await activity.end(nil, dismissalPolicy: .immediate) }
        }
        guard !Task.isCancelled, !store.refreshing, store.error == nil, store.updatedAt != nil,
              let credentials = store.credentials, let cached = store.snapshot else { return }
        let identity = credentials.notificationSetup.identity
        let candidates = Activity<PaymentActivityAttributes>.activities.filter { activity in
            !activity.attributes.practice && activity.attributes.identity == identity
                && !cached.inbox.contains { $0.id == activity.attributes.paymentID && $0.owner == cached.me && $0.status == "pending" }
        }
        guard !candidates.isEmpty else { return }
        // Capture instances before fetching: later activities may not exist in this response yet.
        let fresh: LedgerSnapshot?
        do { fresh = try await ServerAPI(credentials: credentials).request("/state?month=" + store.month) }
        catch { fresh = nil }
        for activity in candidates {
            let otherConnection = activity.attributes.identity != store.credentials?.notificationSetup.identity
            let confirmedMissing = !Task.isCancelled && store.credentials == credentials && fresh.map { snapshot in
                !snapshot.inbox.contains { $0.id == activity.attributes.paymentID && $0.owner == snapshot.me && $0.status == "pending" }
            } == true
            if otherConnection || confirmedMissing { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }
    @MainActor static func open(_ url: URL, credentials: Credentials?) -> Bool {
        guard url.host == "payment" else { return false }
        guard let credentials, let link = PaymentActivityLink(url, identity: credentials.notificationSetup.identity) else { return true }
        var rawText = ""
        if link.practice {
            guard credentials.notificationSetup.matchesPractice(link.id),
                  let activity = Activity<PaymentActivityAttributes>.activities.first(where: {
                      $0.attributes.paymentID == link.id && $0.attributes.identity == link.identity && $0.attributes.practice
                  }), !activity.attributes.practiceRawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
            rawText = activity.attributes.practiceRawText
        }
        PaymentNotificationRouter.shared.receive(PaymentNotificationRoute(id: link.id, identity: link.identity,
            rawText: rawText, scope: ["shared", "personal"].contains(link.scope ?? "") ? link.scope : nil,
            practice: link.practice, ignored: link.scope == "ignore"))
        return true
    }
}

enum PaymentNotifications {
    static let category = "OURLEDGER_PAYMENT"
    static func register() {
        let actions = [
            UNNotificationAction(identifier: "shared", title: "공용", options: .foreground),
            UNNotificationAction(identifier: "personal", title: "개인", options: .foreground),
            UNNotificationAction(identifier: "ignore", title: "잘못 온 알림", options: .foreground)
        ]
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: category, actions: actions, intentIdentifiers: [], options: [])
        ])
        UNUserNotificationCenter.current().delegate = PaymentNotificationDelegate.shared
    }
    static func content(id: String, identity: String, merchant: String, amount: Int?, practice: Bool = false) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = (practice ? "[테스트] " : "") + (amount.map(won) ?? "새 결제") + " · 공용인가요?"
        content.body = merchant + " · 눌러서 기록해 주세요."
        content.categoryIdentifier = category
        content.sound = .default
        content.userInfo = ["paymentID": id, "identity": identity, "practice": practice]
        return content
    }
    static func practiceContent(id: String, identity: String, now: Date = Date()) -> UNMutableNotificationContent {
        let amount = NotificationSetupState.practiceAmount(id)
        let content = content(id: id, identity: identity, merchant: "CU 테스트점", amount: amount, practice: true)
        content.title = "[테스트] 카드 결제 승인"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "Asia/Seoul")
        formatter.dateFormat = "MM/dd HH:mm"
        content.body = "테스트카드 1234 승인\n" + won(amount) + "\n가맹점: CU 테스트점\n" + formatter.string(from: now) + "\n" + id
        return content
    }
}

private final class PaymentNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = PaymentNotificationDelegate()
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        DispatchQueue.main.async { completionHandler([.banner, .sound, .list]) }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let category = response.notification.request.content.categoryIdentifier
        let action = response.actionIdentifier
        let rawText = response.notification.request.content.title + "\n" + response.notification.request.content.body
        // iOS27's state-restoration completion touches UIKit and must run on the main thread.
        Task { @MainActor in
            defer { completionHandler() }
            guard category == PaymentNotifications.category,
                  let id = info["paymentID"] as? String, let identity = info["identity"] as? String,
                  [UNNotificationDefaultActionIdentifier, "shared", "personal", "ignore"].contains(action),
                  Credentials.load()?.notificationSetup.identity == identity else { return }
            PaymentNotificationRouter.shared.receive(PaymentNotificationRoute(id: id, identity: identity, rawText: rawText,
                scope: ["shared", "personal"].contains(action) ? action : nil,
                practice: info["practice"] as? Bool == true, ignored: action == "ignore"))
        }
    }
}

struct PaymentNotificationView: View {
    @Environment(LedgerStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var route: PaymentNotificationRoute
    @State var startsInForm = false
    var reviewIDs: [String]? = nil
    @State private var pendingItems: [ImportedMessage] = []
    @State private var advancing = false
    @State private var item: ImportedMessage?
    @State private var loading = true
    @State private var editing = false
    @State private var scope = ""
    @State private var complete = false
    @State private var ignored = false
    @State private var settled = false
    @State private var error: String?
    @State private var saving = false
    @State private var savedNote = ""
    @State private var savedAmount = 0
    private var remaining: [ImportedMessage] {
        guard !route.practice else { return [] }
        let pending = pendingItems.filter { $0.status == "pending" && $0.id != route.id }
        if let reviewIDs {
            guard let current = reviewIDs.firstIndex(of: route.id) else { return [] }
            var seen = Set<String>()
            return reviewIDs.dropFirst(current + 1).compactMap { id in
                guard seen.insert(id).inserted else { return nil }
                return pending.first { $0.id == id }
            }
        }
        return pending.sorted { ($0.receivedAt ?? "", $0.id) < ($1.receivedAt ?? "", $1.id) }
    }
    private var reviewCount: Int {
        route.practice ? (store.credentials?.notificationSetup.pendingPracticeTokens().count ?? 0) : remaining.count + 1
    }
    var body: some View {
        Group {
            if editing, let item {
                EntryForm(imported: item, initialScope: scope, demonstration: route.practice,
                    onRecorded: { selected, note, amount in
                        guard store.credentials?.notificationSetup.identity == route.identity else { return }
                        if route.practice {
                            guard store.credentials?.notificationSetup.completePractice(route.id) == true else {
                                error = "테스트가 만료됐어요. 다시 보내 주세요."; editing = false; return
                            }
                        }
                        scope = selected; savedNote = note; savedAmount = amount; complete = true; editing = false
                    }, onHandled: { outcome in
                        ignored = outcome == .excluded; settled = outcome == .settled
                        complete = true; editing = false
                    }, reviewRemaining: reviewCount)
                    .id(route.id)
            } else {
        NavigationStack {
            ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if loading || advancing { ProgressView(complete ? "다음 거래를 확인하고 있어요" : "결제를 확인하고 있어요") }
                else if complete {
                    Image(systemName: ignored ? "minus.circle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 44)).foregroundStyle(LedgerTheme.accent).accessibilityHidden(true)
                    Text(settled ? "정산을 마쳤어요" : ignored ? "이 알림은 제외했어요" : "기록을 마쳤어요").font(.title.bold()).accessibilityIdentifier("paymentFlowComplete")
                    if !ignored && !settled { Text(won(savedAmount) + " · " + savedNote).font(.title3.weight(.semibold)) }
                    Text(route.practice ? "테스트를 직접 마쳤어요. 실제 지출·통계에는 포함되지 않아요." : settled ? "정산 내역에 반영했어요." : ignored ? "지출로 기록하지 않았어요." : scope == "personal" ? "개인 기록으로 저장했어요. 나만 볼 수 있어요." : "공용 기록으로 저장했어요.")
                        .foregroundStyle(LedgerTheme.muted)
                    if error != nil && !route.practice {
                        Button("다음 거래 다시 확인") { Task { await advance() } }
                            .buttonStyle(LedgerPrimaryButtonStyle()).accessibilityIdentifier("retryNextPayment")
                    }
                    Button("완료") { PaymentNotificationRouter.shared.deferQueued(); dismiss() }
                        .buttonStyle(LedgerPrimaryButtonStyle()).accessibilityIdentifier("finishPaymentFlow")
                } else if let item, item.needsDuplicateComparison {
                    Image(systemName: "doc.on.doc").font(.largeTitle).foregroundStyle(LedgerTheme.accent).accessibilityHidden(true)
                    Text("비슷한 결제가 있어요").font(.title2.bold())
                    Text("문자와 앱에서 같은 결제가 왔을 수 있어요. 확인함에서 비교해 주세요.").foregroundStyle(LedgerTheme.muted)
                    Button("확인함에서 비교하기") { PaymentNotificationRouter.shared.deferQueued(); store.tab = 1; dismiss() }
                        .buttonStyle(LedgerPrimaryButtonStyle()).accessibilityIdentifier("notificationCompareDuplicate")
                } else if let item {
                    if route.practice { Label("테스트 · 알림에서 읽은 내용", systemImage: "text.viewfinder").font(.subheadline).foregroundStyle(LedgerTheme.muted) }
                    Text(item.amount.map(won) ?? "금액 확인 필요").font(.largeTitle.bold()).monospacedDigit()
                    Text(item.merchant.isEmpty ? "새 거래" : item.merchant).font(.title3)
                    if reviewCount > 0 {
                        Text("확인할 거래 \(reviewCount)건 · 한 건씩 기록해요")
                            .font(.subheadline).foregroundStyle(LedgerTheme.muted).accessibilityIdentifier("paymentReviewRemaining")
                    }
                    Text("어떤 거래인가요?").font(.title2.bold())
                    Button("공용으로 기록") { choose("shared") }.buttonStyle(LedgerPrimaryButtonStyle()).accessibilityIdentifier("notificationChooseShared")
                    Button("개인으로 기록") { choose("personal") }.buttonStyle(LedgerPrimaryButtonStyle()).accessibilityIdentifier("notificationChoosePersonal")
                    Button("잘못 온 알림") { Task { await ignore() } }.frame(maxWidth: .infinity, minHeight: 44).accessibilityIdentifier("notificationIgnore")
                    if route.practice { Text("실제 지출에는 포함되지 않는 기록 연습이에요.").font(.footnote).foregroundStyle(LedgerTheme.muted) }
                } else if error != nil {
                    Text("결제를 불러오지 못했어요.").font(.title3.bold())
                    Button("다시 시도") { loading = true; Task { await load() } }.buttonStyle(LedgerPrimaryButtonStyle())
                        .accessibilityIdentifier("retryPaymentNotification")
                } else {
                    Text("확인함에서 이 알림을 찾지 못했어요.").font(.title3.bold())
                    Text("기록·제외했거나 다른 알림과 합쳐졌을 수 있어요.").foregroundStyle(LedgerTheme.muted)
                    Button("확인함 보기") { PaymentNotificationRouter.shared.deferQueued(); store.tab = 1; dismiss() }.buttonStyle(LedgerPrimaryButtonStyle())
                    Button("다시 시도") { loading = true; Task { await load() } }.frame(maxWidth: .infinity, minHeight: 44)
                        .accessibilityIdentifier("retryPaymentNotification")
                }
                if let error { ErrorNotice(message: error) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
            }.ledgerScreen().navigationTitle(route.practice ? "결제 알림 체험" : "결제 확인")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { PaymentNotificationRouter.shared.deferQueued(); dismiss() }.disabled(saving)
                } }

        }.interactiveDismissDisabled(saving)
            }
        }
        .task(id: route.id) { await load() }
        .task(id: complete) {
            guard complete else { return }
            let finished = route
            await advance()
            if finished.practice {
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["ourledger-automation-test-" + finished.id])
            }
            await PaymentLiveActivities.end(id: finished.id, identity: finished.identity)
        }
        .onDisappear { PaymentNotificationRouter.shared.deferQueued() }
    }
    @MainActor private func advance() async {
        guard !advancing, complete,
              let credentials = store.credentials, credentials.notificationSetup.identity == route.identity else { return }
        advancing = true; error = nil
        defer { advancing = false }
        do {
            if route.practice {
                let setup = credentials.notificationSetup
                guard let next = setup.pendingPracticeTokens().first(where: { $0 != route.id }),
                      let date = setup.practiceDate(next) else { return }
                let content = PaymentNotifications.practiceContent(id: next, identity: route.identity, now: date)
                route = PaymentNotificationRoute(id: next, identity: route.identity,
                    rawText: content.title + "\n" + content.body, scope: nil, practice: true, ignored: false)
            } else {
            // Read directly: a concurrent refresh may leave the cached inbox behind the saved record.
            let snapshot: LedgerSnapshot = try await ServerAPI(credentials: credentials).request("/state?month=" + store.month)
            try Task.checkCancellation()
            guard store.credentials == credentials else { return }
            pendingItems = snapshot.inbox.filter { $0.owner == snapshot.me && $0.status == "pending" }
            guard let next = remaining.first else { return }
            if reviewIDs != nil { startsInForm = !next.needsDuplicateComparison }
            else if next.needsDuplicateComparison { startsInForm = false }
            route = PaymentNotificationRoute(id: next.id, identity: route.identity, rawText: "", scope: nil, practice: false, ignored: false)
            }
            scope = ""; item = nil; editing = false; complete = false; ignored = false; settled = false
            savedNote = ""; savedAmount = 0; loading = true
        } catch is CancellationError { }
        catch { self.error = "기록 처리는 끝났지만 다음 거래를 불러오지 못했어요. 다시 확인해 주세요." }
    }
    @MainActor private func load() async {
        guard loading else { return }
        error = nil; item = nil
        defer { loading = false }
        guard let credentials = store.credentials, credentials.notificationSetup.identity == route.identity else {
            error = "이 알림을 받은 가계부 연결을 확인해 주세요."; return
        }
        if !route.practice, let reviewIDs, !reviewIDs.contains(route.id) {
            error = "이번에 가져온 캡처에 없는 거래예요."; return
        }
        if route.practice {
            guard credentials.notificationSetup.matchesPractice(route.id) else {
                error = "테스트가 만료됐어요. 다시 보내 주세요."; return
            }
            do {
                let parsed: PaymentRecognition = try await ServerAPI(credentials: credentials).request("/imports/preview", method: "POST", body: ["text": route.rawText])
                try Task.checkCancellation()
                guard store.credentials == credentials else {
                    error = "가계부 연결이 바뀌었어요. 이 알림을 받은 연결에서 다시 확인해 주세요."; return
                }
                guard credentials.notificationSetup.matchesPractice(route.id) else {
                    error = "테스트가 만료됐어요. 다시 보내 주세요."; return
                }
                item = ImportedMessage(id: route.id, owner: store.snapshot?.me ?? "", raw: route.rawText, status: "pending", merchant: parsed.merchant, kind: parsed.kind, card: parsed.card, reference: parsed.reference, reason: parsed.reason, amount: parsed.amount, time: parsed.time, sources: ["app"], candidates: [], requiresReview: parsed.requiresReview, candidateDetails: [], receivedAt: nil)
            } catch { self.error = error.localizedDescription; return }
        } else {
            do {
                // A concurrent App/scene refresh can discard store.refresh()'s response and leave an older inbox.
                let snapshot: LedgerSnapshot = try await ServerAPI(credentials: credentials).request("/state?month=" + store.month)
                try Task.checkCancellation()
                guard store.credentials == credentials else {
                    error = "가계부 연결이 바뀌었어요. 이 알림을 받은 연결에서 다시 확인해 주세요."; return
                }
                pendingItems = snapshot.inbox.filter { $0.owner == snapshot.me && $0.status == "pending" }
                item = pendingItems.first { $0.id == route.id }
            } catch { self.error = error.localizedDescription; return }
        }
        guard item != nil else { return }
        if route.ignored { await ignore() }
        else if let selected = route.scope, item?.needsDuplicateComparison == false { choose(selected) }
        // An explicit inbox "record" action may edit a duplicate; an automatic batch may not.
        else if startsInForm, reviewIDs == nil || item?.needsDuplicateComparison == false { editing = true }
    }
    private func choose(_ selected: String) { scope = selected; editing = true }
    @MainActor private func ignore() async {
        guard !saving, let credentials = store.credentials, credentials.notificationSetup.identity == route.identity else { return }
        saving = true; defer { saving = false }
        do {
            if route.practice {
                guard credentials.notificationSetup.matchesPractice(route.id) else { throw APIError(message: "테스트가 만료됐어요.") }
                credentials.notificationSetup.discardPractice(route.id)
            }
            else { try await store.mutate("/imports/" + route.id, method: "DELETE") }
            ignored = true; complete = true
            await PaymentLiveActivities.end(id: route.id, identity: route.identity)
        } catch { self.error = error.localizedDescription }
    }
}
