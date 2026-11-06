import SwiftUI

@main
struct OurLedgerApp: App {
    @State private var store = LedgerStore()
    @Environment(\.scenePhase) private var phase
    init() { PaymentNotifications.register() }
    var body: some Scene {
        WindowGroup {
            Group {
                if store.credentials == nil { OnboardingView() }
                else { LedgerTabs() }
            }
            .background(LedgerKeyboardDismissal())
            .environment(store)
            .tint(LedgerTheme.accent)
            .fontDesign(.default)
            .preferredColorScheme(.light)
            .environment(\.locale, Locale(identifier: "ko_KR"))
            .task(id: store.month) {
                await store.refresh()
                await PaymentLiveActivities.reconcile(store)
            }
            .onChange(of: phase) { _, value in
                if value == .active { Task { await store.refresh(); await PaymentLiveActivities.reconcile(store) } }
            }
            .onOpenURL { if !PaymentLiveActivities.open($0, credentials: store.credentials) { store.receiveURL($0) } }
            .onChange(of: store.snapshot?.inbox.map(\.id)) { _, _ in Task { await PaymentLiveActivities.reconcile(store) } }
            .onChange(of: store.credentials) { _, _ in
                PaymentNotificationRouter.shared.connectionChanged(identity: store.credentials?.notificationSetup.identity)
                Task { await PaymentLiveActivities.reconcile(store) }
            }
        }
    }
}

struct LedgerTabs: View {
    @Environment(LedgerStore.self) private var store
    @State private var notificationRouter = PaymentNotificationRouter.shared
    @State private var tourStep: Int?
    @State private var tourSession = UUID()
    @AppStorage("ledgerDisplayScope") private var ledgerScope = "shared"
    private var tourSteps: [LedgerTourStep] {
        LedgerTourStep.stepsAvailable(memberCount: store.snapshot?.members.count ?? 1, scope: ledgerScope)
    }
    private var automaticGuide: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["OURLEDGER_TEST_SERVER"] == nil
            || forceGuide || ProcessInfo.processInfo.environment["OURLEDGER_SHOW_GUIDE"] == "automatic"
        #else
        true
        #endif
    }
    private var forceGuide: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["OURLEDGER_SHOW_GUIDE"] == "1"
        #else
        false
        #endif
    }
    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            if let notice = store.notice {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityHidden(true)
                    Text(notice).font(.footnote).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { store.notice = nil } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }.accessibilityLabel("저장 안내 닫기")
                }.padding(.leading, 16).background(LedgerTheme.surface).accessibilityIdentifier("saveNotice")
            }
            if let error = store.error {
                HStack(alignment: .top, spacing: 12) {
                    Text(error).font(.footnote).fixedSize(horizontal: false, vertical: true)
                    Button("다시 시도") { Task { await store.refresh() } }.font(.footnote).frame(minHeight: 44)
                }.padding(16).background(LedgerTheme.surface)
            }
            TabView(selection: $store.tab) {
                Tab("가계부", systemImage: "book.closed", value: 0) { DashboardView() }
                Tab("확인함", systemImage: "tray", value: 1) { InboxView() }
                    .badge(store.snapshot?.inbox.count ?? 0)
                Tab("통계", systemImage: "chart.bar", value: 2) { InsightsView() }
                Tab("설정", systemImage: "slider.horizontal.3", value: 3) { SettingsView() }
            }
            .id(tourSession)
            .environment(\.ledgerGuideTarget, LedgerTourStep.step(at: tourStep, in: tourSteps)?.target)
            .overlay {
                if store.snapshot == nil && store.tab != 0 { MonthLoadingView() }
            }
        }
        .allowsHitTesting(tourStep == nil)
        .accessibilityHidden(tourStep != nil)
        .overlayPreferenceValue(LedgerTourTargetPreferenceKey.self) { anchors in
            GeometryReader { safe in
                GeometryReader { full in
                    LedgerFeatureTour(currentStep: $tourStep,
                        targets: anchors.mapValues { full[$0] }, safeAreaInsets: safe.safeAreaInsets,
                        steps: tourSteps)
                }.ignoresSafeArea(.container)
            }
        }
        .sheet(item: $notificationRouter.presentation, onDismiss: {
            guard notificationRouter.presentation == nil else { return }
            if notificationRouter.showNextQueued() { return }
            if notificationRouter.showTourRequested {
                notificationRouter.showTourRequested = false; notificationRouter.resumeGuide = false; startTour()
            } else if notificationRouter.resumeGuide || (automaticGuide && store.snapshot != nil && store.credentials?.notificationSetup.introSeen == false) {
                notificationRouter.resumeGuide = false; notificationRouter.showGuide()
            } else if automaticGuide && tourStep == nil && store.credentials?.notificationSetup.featureTourSeen == false {
                startTour()
            }
        }) { presentation in
            switch presentation {
            case .guide(let introductory):
                NotificationGuide(introductory: introductory) { notificationRouter.showTourRequested = true }
            case .payment(let route):
                PaymentNotificationView(route: route)
            }
        }
        .task(id: store.snapshot?.me) {
            #if DEBUG
            await PaymentLiveActivities.prepareLocalNotificationTest(store)
            #endif
            guard automaticGuide, tourStep == nil, store.snapshot != nil, notificationRouter.presentation == nil else { return }
            if forceGuide || store.credentials?.notificationSetup.introSeen == false {
                notificationRouter.showGuide(introductory: forceGuide
                    || store.credentials?.notificationSetup.configured != true)
            } else if store.credentials?.notificationSetup.featureTourSeen == false {
                startTour()
            }
        }
        .onChange(of: tourStep) { previous, current in
            if previous != nil && current == nil { store.credentials?.notificationSetup.featureTourSeen = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ledgerShowFeatureTour)) { _ in startTour() }
    }
    private func startTour() {
        guard store.snapshot != nil else { return }
        tourSession = UUID(); store.tab = 0; tourStep = 0
    }
}

extension Notification.Name {
    static let ledgerShowFeatureTour = Notification.Name("ledgerShowFeatureTour")
}

struct MonthControl: View {
    @Environment(LedgerStore.self) private var store
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 0))
        layout {
            Text(store.month.replacingOccurrences(of: "-", with: "년 ") + "월")
                .font(.title3.bold()).monospacedDigit()
                .foregroundStyle(LedgerTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("selectedMonth")
            if !typeSize.isAccessibilitySize { Spacer(minLength: 4) }
            HStack(spacing: 0) {
              ForEach([-1, 1], id: \.self) { offset in
                if store.monthDestination(offset) != nil {
                    Button { store.changeMonth(offset) } label: {
                        Image(systemName: offset < 0 ? "chevron.left" : "chevron.right")
                            .font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44)
                    }.accessibilityLabel(offset < 0 ? "이전 달" : "다음 달")
                        .buttonStyle(.plain)
                }
              }
            }
        }.frame(minHeight: 44)
    }
}

struct MonthLoadingView: View {
    @Environment(LedgerStore.self) private var store
    var body: some View {
        VStack(spacing: 16) {
            MonthControl().padding(.horizontal, 20)
            Spacer()
            if store.error == nil {
                ProgressView("선택한 달의 기록을 불러오고 있어요")
            } else {
                Image(systemName: "wifi.exclamationmark").font(.largeTitle).foregroundStyle(LedgerTheme.muted)
                Text("기록을 불러오지 못했어요").font(.title3.weight(.semibold))
                Text("가계부 연결은 유지돼요. 잠시 후 다시 시도해 주세요.")
                    .font(.subheadline).foregroundStyle(LedgerTheme.muted)
                    .multilineTextAlignment(.center).padding(.horizontal, 24)
                Button("다시 시도") { Task { await store.refresh() } }
                    .buttonStyle(.borderedProminent).disabled(store.refreshing)
            }
            if store.month != String(dayString(Date()).prefix(7)) {
                Button("이번 달로 돌아가기") { store.receiveURL(URL(string: "ourledger://home")!) }
                    .frame(minHeight: 44)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LedgerTheme.background)
        .accessibilityIdentifier("monthLoadingState")
    }
}

struct ErrorNotice: View {
    let message: String?
    var body: some View {
        if let message { Text(message).font(.footnote).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
    }
}
