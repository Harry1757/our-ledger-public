import SwiftUI
import UserNotifications
import AppIntents
import OSLog
import SafariServices

struct NotificationGuide: View {
    @Environment(LedgerStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    var introductory = false
    var onFinished: (() -> Void)?
    @State private var step = 0
    @State private var error: String?
    @State private var sending = false
    @State private var shortcutOpening = ShortcutOpening()
    @State private var shortcutHelpExpanded = false
    @State private var showingInstallPage = false
    @State private var clock = Date()
    @State private var authorization = UNAuthorizationStatus.notDetermined
    private var setup: NotificationSetupState? { store.credentials?.notificationSetup }
    private var allowed: Bool { authorization == .authorized || authorization == .provisional || authorization == .ephemeral }
    private var passed: Bool {
        guard let verified = setup?.verifiedAt else { return false }
        return setup?.testStartedAt.map { verified >= $0 } ?? true
    }
    private var practiced: Bool {
        guard let completed = setup?.practiceCompletedAt, let started = setup?.testStartedAt else { return false }
        return completed >= started && setup?.pendingPracticeTokens(now: clock).isEmpty == true
    }
    private var awaitingAlert: Bool {
        guard let started = setup?.testStartedAt, !practiced else { return false }
        return (0..<3).contains(clock.timeIntervalSince(started))
    }
    private var titles: [String] { ["시작하기", "문자·앱 연결", "자동 실행 켜기", "알림 허용", "결제 기록 테스트"] }
    var body: some View {
        let _ = clock
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(spacing: 6) {
                        ForEach(titles.indices, id: \.self) { index in Capsule().fill(index <= step ? LedgerTheme.accent : LedgerTheme.border).frame(height: 4) }
                    }.accessibilityLabel("설정 \(step + 1)단계, 총 \(titles.count)단계")
                    switch step {
                    case 0: welcome
                    case 1: automationSetup
                    case 2: automationActivation
                    case 3: permission
                    default: paymentTest
                    }
                    if let error { ErrorNotice(message: error).accessibilityIdentifier("automationSetupError") }
                }.padding(24)
            }.ledgerScreen()
                .navigationTitle(titles[step]).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        if step > 0 { Button("이전") { step -= 1; error = nil } }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(introductory ? "나중에" : "닫기") { finish(tour: introductory) }.accessibilityIdentifier("guideClose")
                    }
                }
                .safeAreaInset(edge: .bottom) { bottomAction.padding(20).background(LedgerTheme.background) }
                .task {
                    await refreshAuthorization()
                    if !introductory, setup?.configured == true { step = allowed ? 4 : 3 }
                }
                .onChange(of: phase) { _, value in
                    clock = Date()
                    if value == .active { Task { await refreshAuthorization() } }
                }
                .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { clock = $0 }
                .sheet(isPresented: $showingInstallPage) { ShortcutInstallPage(isPresented: $showingInstallPage).ignoresSafeArea() }
        }
    }
    private var welcome: some View {
        VStack(alignment: .leading, spacing: 24) {
            Image(systemName: "bell.badge.fill").font(.system(size: 42)).foregroundStyle(LedgerTheme.accent).accessibilityHidden(true)
            Text("결제하면,\n확인만 하세요").font(.largeTitle.bold()).foregroundStyle(LedgerTheme.ink)
            Text("공용·개인을 고르고, 한 줄만 적으면 끝이에요.").foregroundStyle(LedgerTheme.muted)
            instruction("message", "문자부터 연결", "결제 문자와 추가 앱 알림을 연결해요.")
            instruction("bell", "실제 알림으로 연습", "알림을 눌러 기록까지 직접 해봐요.")
            instruction("hand.point.up", "사용법 한눈에", "자주 쓰는 곳만 짧게 알려드려요.")
        }
    }
    private var automationSetup: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("문자와 결제 앱 연결").font(.title2.bold())
            Label("문자 ‘원’ · 우리 가계부 기본 포함", systemImage: "checkmark.circle.fill")
                .font(.subheadline).foregroundStyle(LedgerTheme.muted).accessibilityIdentifier("automationDefaults")
            Button { openShortcut(.install) } label: {
                Label(shortcutOpening.requestedInstaller ? "추가 화면 다시 열기" : "1. 단축어 추가하기", systemImage: "plus")
            }.buttonStyle(LedgerPrimaryButtonStyle()).disabled(shortcutOpening.destination != nil)
                .accessibilityIdentifier("addAutomationShortcut")
            Button { openShortcut(.edit) } label: {
                Label("2. 결제 앱 추가하기", systemImage: "app.badge.checkmark")
            }.buttonStyle(.bordered).controlSize(.large).frame(maxWidth: .infinity, alignment: .leading)
                .disabled(shortcutOpening.destination != nil)
                .accessibilityIdentifier("openAppAutomation")
            if shortcutOpening.destination != nil {
                HStack(spacing: 8) {
                    ProgressView().accessibilityLabel("단축어 여는 중")
                    Text("단축어 여는 중…").font(.subheadline).foregroundStyle(LedgerTheme.muted)
                }.accessibilityIdentifier("shortcutOpening")
            }
            if let error = shortcutOpening.error {
                ErrorNotice(message: error).accessibilityIdentifier("shortcutOpeningError")
            }
            instruction("plus.circle", "편집 → 앱 추가", "오른쪽 위 ‘편집’을 누르고, 알림 조건의 ＋로 토스·카드사 앱을 하나씩 더해요. ‘우리 가계부’는 유지해 주세요.")
            Text("‘단축어 추가’로 보관함에 저장한 뒤 2번을 눌러주세요. 앱 알림은 iOS27 이상에서 사용해요.")
                .font(.footnote).foregroundStyle(LedgerTheme.muted)
            DisclosureGroup("등록 화면이 안 나오나요?", isExpanded: $shortcutHelpExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("기존 목록만 보이면 추가 화면이 열리지 않은 거예요. 설치 페이지에서 ‘결제 알림 자동 수신’을 다시 가져와 주세요.")
                        .font(.footnote).foregroundStyle(LedgerTheme.muted)
                        .accessibilityIdentifier("shortcutInstallRecovery")
                    Button { showingInstallPage = true } label: {
                        Label("설치 페이지 열기", systemImage: "safari")
                    }.buttonStyle(.bordered).controlSize(.large).disabled(shortcutOpening.destination != nil)
                        .accessibilityIdentifier("openShortcutInstallPage")
                    Text("이미 추가했다면 보관함 → 모든 단축어에서 ‘결제 알림 자동 수신’을 찾아 편집해 주세요.")
                        .font(.footnote).foregroundStyle(LedgerTheme.muted)
                        .accessibilityIdentifier("shortcutRecoveryInstructions")
                    Button { openShortcut(.app) } label: {
                        Label("단축어 앱 직접 열기", systemImage: "arrow.up.forward.app")
                    }.frame(minHeight: 44).disabled(shortcutOpening.destination != nil)
                        .accessibilityIdentifier("openShortcutsApp")
                }.padding(.top, 8)
            }
        }
    }
    private var automationActivation: some View {
        VStack(alignment: .leading, spacing: 24) {
            Image(systemName: "power.circle.fill")
                .font(.system(size: 44)).foregroundStyle(LedgerTheme.accent).accessibilityHidden(true)
            Text("자동 실행도 켜주세요").font(.title2.bold())
            Text("단축어를 추가해도 자동화는 꺼져 있어요. 이 기기에서 한 번 켜야 알림을 받을 수 있어요.")
                .foregroundStyle(LedgerTheme.muted)
                .accessibilityIdentifier("automationActivationReason")
            Button { openShortcut(.edit) } label: {
                Label("단축어 열어 자동 실행 켜기", systemImage: "power")
            }.buttonStyle(LedgerPrimaryButtonStyle()).disabled(shortcutOpening.destination != nil)
                .accessibilityIdentifier("openAutomationActivation")
            instruction("1.circle", "오른쪽 위 ‘편집’", "‘결제 알림 자동 수신’의 편집 화면을 열어요.")
            VStack(alignment: .leading, spacing: 20) {
                Text("두 조건에서 각각 켜주세요").font(.headline)
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right.circle").font(.title3).foregroundStyle(.blue)
                        .accessibilityHidden(true)
                    Text("‘수신할 때’ 옆 파란 화살표예요.")
                        .font(.subheadline).foregroundStyle(LedgerTheme.muted)
                }.accessibilityElement(children: .combine)
                    .accessibilityLabel("수신할 때 옆, 파란 동그라미 안의 오른쪽 화살표 버튼을 눌러요")
                instruction("message", "메시지 수신 조건", "파란 화살표 → ‘자동화’ 켬 · ‘실행 전에 확인’ 끔.")
                instruction("bell", "앱 알림 조건", "파란 화살표 → ‘자동화’ 켬.")
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                .background(LedgerTheme.surface, in: RoundedRectangle(cornerRadius: 16))

            if shortcutOpening.destination != nil {
                ProgressView("단축어 여는 중…").accessibilityIdentifier("shortcutOpening")
            }
            if let error = shortcutOpening.error {
                ErrorNotice(message: error).accessibilityIdentifier("shortcutOpeningError")
                Button("단축어 앱 직접 열기") { openShortcut(.app) }
                    .frame(minHeight: 44).accessibilityIdentifier("openShortcutsApp")
            }
        }
    }
    private var permission: some View {
        VStack(alignment: .leading, spacing: 24) {
            Image(systemName: allowed ? "checkmark.circle.fill" : "bell.badge.fill").font(.system(size: 44)).foregroundStyle(LedgerTheme.accent).accessibilityHidden(true)
            Text(allowed ? "알림이 허용됐어요" : "결제 알림을 받아볼까요?").font(.title2.bold())
            Text("다음에는 결제처럼 알림이 와요. 알림을 누르고 공용·개인을 선택해 직접 기록해 보세요.").foregroundStyle(LedgerTheme.muted)
            if authorization == .denied {
                Button("iPhone 설정에서 알림 켜기") { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
                    .frame(minHeight: 44)
            }
        }.accessibilityIdentifier("notificationPermissionStep")
    }
    private var paymentTest: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: practiced ? "checkmark.circle.fill" : "creditcard.fill").font(.system(size: 44)).foregroundStyle(LedgerTheme.accent).accessibilityHidden(true)
            Text(practiced ? "기록까지 직접 마쳤어요" : "결제 알림을 눌러보세요").font(.title2.bold())
                .accessibilityIdentifier(practiced ? "paymentPracticePassed" : "paymentPracticeWaiting")
            Text(practiced ? "다시 해보거나, 다음으로 넘어가 사용법을 볼 수 있어요." : "누를 때마다 금액이 다른 결제 알림을 보내드려요. 알림 누르기 → 공용·개인 → 한 줄 입력 → 기록 완료까지 해보세요.")
                .foregroundStyle(LedgerTheme.muted)
            Button(sending || awaitingAlert ? "알림 보내는 중…" : setup?.testStartedAt == nil ? "결제 알림 받아보기" : "다시 테스트하기") { Task { await sendTest() } }
                .buttonStyle(LedgerPrimaryButtonStyle()).disabled(sending || awaitingAlert).accessibilityIdentifier("sendAutomationTest")
            if awaitingAlert {
                HStack(spacing: 10) {
                    ProgressView().accessibilityLabel("알림 발송 중").accessibilityIdentifier("testNotificationSending")
                    Text("곧 결제 알림이 도착해요").font(.subheadline).foregroundStyle(LedgerTheme.muted)
                }
            } else if setup?.testStartedAt != nil && !practiced {
                Text("알림을 눌러 기록을 마치면 이곳에 완료가 표시돼요.").font(.subheadline).foregroundStyle(LedgerTheme.muted)
            }
            if let setup, let token = setup.pendingPracticeTokens(now: clock).first,
               let date = setup.practiceDate(token), !awaitingAlert {
                Button("남은 테스트 \(setup.pendingPracticeTokens(now: clock).count)건 이어서") {
                    let content = PaymentNotifications.practiceContent(id: token, identity: setup.identity, now: date)
                    PaymentNotificationRouter.shared.receive(PaymentNotificationRoute(id: token, identity: setup.identity,
                        rawText: content.title + "\n" + content.body, scope: nil, practice: true, ignored: false))
                }.frame(minHeight: 44).accessibilityIdentifier("resumePaymentPractice")
            }
            Label("테스트 금액은 실제 지출에 포함되지 않아요", systemImage: "info.circle").font(.footnote).foregroundStyle(LedgerTheme.muted)
            DisclosureGroup("연결 상태") {
                VStack(alignment: .leading, spacing: 12) {
                    Text(passed ? "앱 알림 자동 전달과 서버 연결을 확인했어요." : "앱 알림 자동 전달은 아직 확인 전이에요.")
                        .accessibilityIdentifier(passed ? "automationTestPassed" : "automationTestWaiting")
                    Text("문자는 실제 결제 문자가 왔을 때 별도로 확인해 주세요.")
                    Text("아일랜드의 금액을 길게 누르면 공용·개인·제외가 펼쳐져요.")
                    Button("자동화 설정 다시 확인") { step = 1 }
                }.font(.footnote).foregroundStyle(LedgerTheme.muted).padding(.top, 8)
            }
        }
    }
    @ViewBuilder private var bottomAction: some View {
        switch step {
        case 0: primary("자동화 설정하기") { step = 1 }
        case 1: primary("앱을 추가했어요 · 다음") { step = 2 }
        case 2: primary("두 자동화를 켰어요 · 다음") { setup?.configured = true; step = 3 }
        case 3:
            if allowed { primary("다음 · 결제 알림 테스트") { step = 4 } }
            else { primary("알림 허용하기") { Task { await requestAuthorization() } } }
        default: primary(practiced ? "다음 · 사용법 보기" : "테스트는 나중에 · 사용법 보기") { finish(tour: true) }
        }
    }
    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).font(.headline).frame(maxWidth: .infinity, minHeight: 24) }
            .buttonStyle(LedgerPrimaryButtonStyle()).disabled(sending || shortcutOpening.destination != nil).accessibilityIdentifier("automationGuideNext")
    }
    private func instruction(_ image: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: image).font(.title3).foregroundStyle(LedgerTheme.accent).frame(width: 24).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) { Text(title).font(.headline); Text(detail).font(.subheadline).foregroundStyle(LedgerTheme.muted) }
        }
    }
    private func openShortcut(_ destination: ShortcutOpening.Destination) {
        Task { @MainActor in
            await shortcutOpening.open(destination) { url in
                let accepted = await UIApplication.shared.open(url)
                Logger(subsystem: "com.hwangsoonhwan.OurLedger", category: "ShortcutSetup")
                    .notice("URL handoff: \(destination.rawValue, privacy: .public), accepted: \(accepted, privacy: .public)")
                return accepted
            }
            if shortcutOpening.error != nil { shortcutHelpExpanded = true }
        }
    }
    @MainActor private func refreshAuthorization() async { authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus }
    @MainActor private func requestAuthorization() async {
        sending = true; error = nil
        defer { sending = false }
        do {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            await refreshAuthorization()
            if allowed { step = 4 }
        } catch { self.error = error.localizedDescription }
    }
    @MainActor private func sendTest() async {
        guard !sending, let setup else { return }
        sending = true; error = nil
        defer { sending = false }
        await refreshAuthorization()
        guard allowed else { step = 3; return }
        clock = Date()
        let token = setup.beginTest(now: clock)
        setup.beginPractice(token, now: clock)
        do {
            let content = PaymentNotifications.practiceContent(id: token, identity: setup.identity, now: clock)
            try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "ourledger-automation-test-" + token, content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)))
        } catch {
            setup.discardPractice(token)
            self.error = error.localizedDescription
        }
    }
    private func finish(tour: Bool) { setup?.introSeen = true; if tour { onFinished?() }; dismiss() }
}

private struct ShortcutInstallPage: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    func makeCoordinator() -> Coordinator { Coordinator(isPresented: $isPresented) }
    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: ShortcutOpening.Destination.install.url)
        controller.dismissButtonStyle = .close
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        let isPresented: Binding<Bool>
        init(isPresented: Binding<Bool>) { self.isPresented = isPresented }
        func safariViewControllerDidFinish(_ controller: SFSafariViewController) { isPresented.wrappedValue = false }
    }
}

struct NotificationConnectionCard: View {
    @Environment(LedgerStore.self) private var store
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var clock = Date()
    let onOpen: () -> Void
    private var setup: NotificationSetupState? { store.credentials?.notificationSetup }
    var body: some View {
        let _ = clock
        Button(action: onOpen) {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                : AnyLayout(HStackLayout(spacing: 12))
            layout {
                Image(systemName: setup?.verifiedAt == nil ? "bell.badge" : "checkmark.circle.fill")
                    .font(.system(size: 22)).foregroundStyle(LedgerTheme.brand).frame(width: 22).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(setup?.configured == true ? "결제 알림 연결" : "거래 알림 연결하기")
                        .font(.body.weight(.medium)).foregroundStyle(LedgerTheme.ink)
                    Text(status).font(.footnote).foregroundStyle(LedgerTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !dynamicTypeSize.isAccessibilitySize {
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(LedgerTheme.muted).accessibilityHidden(true)
                }
            }.padding(.vertical, 8).frame(minHeight: 60, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain).ledgerRowDivider().accessibilityIdentifier("notificationGuide")
            .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { clock = $0 }
    }
    private var status: String {
        if let received = setup?.receivedAt { return "최근 전달 " + received.formatted(date: .abbreviated, time: .shortened) }
        if setup?.verifiedAt != nil { return "테스트 확인 · 연결 관리" }
        return setup?.configured == true ? "테스트가 필요해요" : "처음 한 번 연결해 주세요"
    }
}
