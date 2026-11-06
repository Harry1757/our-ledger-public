import SwiftUI

struct OnboardingView: View {
    private enum InputField: Hashable { case name, invite }
    @FocusState private var focusedField: InputField?
    @Environment(LedgerStore.self) private var store
    @State private var name = ""
    @State private var household = "우리 가계부"
    #if DEBUG
    @State private var base = ProcessInfo.processInfo.environment["OURLEDGER_TEST_SERVER"] ?? "http://127.0.0.1:8817"
    #else
    @State private var base = "http://127.0.0.1:8817"
    #endif
    @State private var mode = "separate"
    @State private var link = ""
    @State private var setupCode = ""
    @State private var joining = false
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(joining ? "초대받은 가계부에\n함께 기록해요" : "함께 쓰는 생활비,\n내 지출까지 한눈에")
                            .font(.title.weight(.bold)).lineSpacing(4)
                            .foregroundStyle(LedgerTheme.ink).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("onboardingWelcome")
                        Text(joining ? "공용은 함께 보고, 개인 기록은 나만 봐요." : "혼자 시작해도 좋아요. 나중에 상대를 초대하세요.")
                            .font(.subheadline).foregroundStyle(LedgerTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }.padding(.vertical, 8).listRowSeparator(.hidden).listRowBackground(LedgerTheme.background)
                }
                Section("시작하기") {
                    Picker("참여 방식", selection: $joining) { Text("새로 만들기").tag(false); Text("초대받았어요").tag(true) }
                        .pickerStyle(.segmented).frame(minHeight: 44).accessibilityIdentifier("participationMode")
                    TextField("내 이름", text: $name).accessibilityLabel("내 이름").accessibilityIdentifier("memberName")
                        .focused($focusedField, equals: .name).submitLabel(joining ? .next : .done)
                        .onSubmit { focusedField = joining ? .invite : nil }
                    if joining {
                        TextField("초대 링크 붙여넣기", text: $link, axis: .vertical)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("inviteLink")
                            .keyboardType(.URL).focused($focusedField, equals: .invite).submitLabel(.done)
                            .onSubmit { focusedField = nil }.frame(minHeight: 44)
                        DisclosureGroup("도움말") { Text("링크는 발급 후 24시간 동안 한 번만 사용할 수 있어요. 만료됐거나 새 링크가 발급됐다면 상대에게 최신 링크를 요청해 주세요.").font(.footnote).foregroundStyle(LedgerTheme.muted) }
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        TextField("가계부 이름", text: $household).accessibilityLabel("가계부 이름").accessibilityIdentifier("householdName")
                        Picker("생활비 관리", selection: $mode) {
                            Text("각자 결제 후 정산").tag("separate")
                            Text("공동자금으로 사용").tag("pool")
                        }
                        Text(mode == "separate" ? "함께 쓴 돈을 반반 나누고 차액만 정산해요." : "모은 돈의 잔액과 대신 낸 생활비를 확인해요.")
                            .font(.footnote).foregroundStyle(LedgerTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Section("연결 정보") {
                    DisclosureGroup("서버 설정") {
                        TextField("서버 주소", text: $base).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("serverAddress")
                        Text(joining ? "초대 링크의 서버로 연결해요." : "함께 쓰는 상대도 같은 서버에 연결해요.")
                            .font(.footnote).foregroundStyle(LedgerTheme.muted)
                    }
                    if !joining {
                        SecureField("가입 코드", text: $setupCode).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityLabel("가계부 가입 코드")
                        Text("새 가계부를 만들려면 전달받은 가입 코드를 입력해 주세요.")
                            .font(.footnote).foregroundStyle(LedgerTheme.muted)
                    }
                }
            }.ledgerScreen().listSectionSpacing(16).disabled(busy).scrollDismissesKeyboard(.interactively)
            .toolbar(.hidden, for: .navigationBar)
            .contentMargins(.top, 12, for: .scrollContent)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    ErrorNotice(message: error)
                    Button(busy ? "연결 중…" : joining ? "함께 시작하기" : "가계부 만들기") {
                        Task { await connect() }
                    }.buttonStyle(LedgerPrimaryButtonStyle())
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy
                        || (joining ? link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : household.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                    .accessibilityIdentifier("createHousehold")
                }.padding(.horizontal, 20).padding(.vertical, 12).background(LedgerTheme.background)
            }
            .onChange(of: store.inviteURL) { _, url in
                if let url { applyInvite(url) }
            }
            .onChange(of: joining) { _, _ in error = nil }
            .onAppear { if let url = store.inviteURL { applyInvite(url) } }
        }
    }
    private func applyInvite(_ url: URL) {
        joining = true; link = url.absoluteString
        if let address = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "server" })?.value { base = address }
    }
    private func connect() async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            var invitation: String?
            var address = base
            if joining {
                guard let url = URLComponents(string: link), url.scheme == "ourledger", url.host == "join",
                      let server = url.queryItems?.first(where: { $0.name == "server" })?.value,
                      let code = url.queryItems?.first(where: { $0.name == "invite" })?.value else {
                    throw APIError(message: "받은 초대 링크를 확인해 주세요.")
                }
                address = server; invitation = code
            }
            try await store.connect(base: address, name: name, household: household, mode: mode, invite: invitation, setupCode: setupCode)
        } catch { self.error = error.localizedDescription }
    }
}
