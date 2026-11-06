import SwiftUI
import UserNotifications
import AppIntents

struct SettingsView: View {
    @Environment(LedgerStore.self) private var store
    @State private var bank = ""
    @State private var account = ""
    @State private var holder = ""
    @State private var budget = ""
    @State private var loadedBudget = ""
    @State private var loadedAccount: [String] = []
    @State private var addingCategory = false
    @State private var showingPCConnection = false
    @State private var confirmingRegeneration = false
    @State private var copiedInvite = false
    @State private var loadedSettings = false
    @State private var error: String?
    @State private var savedValues: [String]?
    @State private var busy = false
    private var settingsEdited: Bool {
        loadedSettings && ([bank, account, holder] != loadedAccount || budget != loadedBudget)
    }
    var body: some View {
        NavigationStack {
            if let view = store.snapshot {
                let member = view.members.first { $0.id == view.me }
                let accountValues = [member?.bank ?? "", member?.account ?? "", member?.holder ?? ""]
                Form {
                    Section {
                        HStack(spacing: 12) {
                            Image(systemName: "book.closed.fill").foregroundStyle(LedgerTheme.muted)
                                .font(.system(size: 20)).frame(width: 22)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(view.household.name).font(.body.weight(.medium)).foregroundStyle(LedgerTheme.ink)
                                Text(view.members.map(\.name).joined(separator: " · "))
                                    .font(.subheadline).foregroundStyle(LedgerTheme.muted)
                            }.fixedSize(horizontal: false, vertical: true)
                        }.listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                    }.listRowBackground(LedgerTheme.surface).listRowSeparator(.hidden)
                    Section {
                        NotificationConnectionCard { PaymentNotificationRouter.shared.showGuide() }.ledgerTourTarget(.settings)
                            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        DisclosureGroup("전달 기록") {
                            ImportReceiptStatus(status: view.importStatus, setup: store.credentials?.notificationSetup)
                        }
                    }.listRowBackground(LedgerTheme.surface).listRowSeparator(.hidden)
                    Section("기록 관리") {
                        NavigationLink { RecurringPaymentsView() } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "repeat").font(.system(size: 20)).foregroundStyle(LedgerTheme.muted).frame(width: 22)
                                Text("정기결제").foregroundStyle(LedgerTheme.ink)
                            }
                        }.ledgerRowDivider().accessibilityIdentifier("recurringPayments").ledgerTourTarget(.recurring)
                        Button { NotificationCenter.default.post(name: .ledgerShowFeatureTour, object: nil) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "questionmark.circle").font(.system(size: 20)).foregroundStyle(LedgerTheme.muted).frame(width: 22)
                                Text("사용법 다시 보기").foregroundStyle(LedgerTheme.ink)
                            }
                        }.ledgerRowDivider().accessibilityIdentifier("replayFeatureTour")
                    }.listRowBackground(LedgerTheme.surface).listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                    sharingSection(view)
                    Section("내 정산 계좌") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("은행").font(.subheadline).foregroundStyle(LedgerTheme.muted)
                            TextField("은행 이름 입력", text: $bank).accessibilityIdentifier("bankName")
                        }.padding(.vertical, 4)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("계좌번호").font(.subheadline).foregroundStyle(LedgerTheme.muted)
                            TextField("계좌번호 입력", text: $account).keyboardType(.numbersAndPunctuation)
                        }.padding(.vertical, 4)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("예금주").font(.subheadline).foregroundStyle(LedgerTheme.muted)
                            TextField("예금주 이름 입력", text: $holder)
                        }.padding(.vertical, 4)
                        Text("상대에게 공개되는 계좌예요.").font(.footnote).foregroundStyle(LedgerTheme.muted)
                    }.listRowBackground(LedgerTheme.surface).listRowSeparator(.hidden)
                        .listSectionSeparator(.hidden).disabled(busy)
                    Section("월 생활비 예산") {
                        HStack(alignment: .firstTextBaseline) {
                            TextField("예산 금액", text: $budget).onChange(of: budget) { _, value in budget = formattedWonInput(value) }.keyboardType(.numberPad)
                                .font(.title2.weight(.semibold)).monospacedDigit()
                                .accessibilityIdentifier("budgetAmount")
                            Text("원").foregroundStyle(LedgerTheme.muted)
                        }.padding(.vertical, 6)
                        Text("0원 = 예산 없음").font(.footnote).foregroundStyle(LedgerTheme.muted)
                    }.listRowBackground(LedgerTheme.surface).listRowSeparator(.hidden).disabled(busy)
                    Section("카테고리") {
                        DisclosureGroup("카테고리 관리 · \(view.categories.count)개") {
                            ForEach(view.categories) { category in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(category.name).foregroundStyle(LedgerTheme.ink)
                                    if !category.keywords.isEmpty { Text(category.keywords.joined(separator: ", ")).font(.footnote).foregroundStyle(LedgerTheme.muted) }
                                }.padding(.vertical, 4)
                            }
                            Button("카테고리 추가") { addingCategory = true }.frame(minHeight: 44)
                        }
                    }.listRowBackground(LedgerTheme.surface).listRowSeparator(.hidden)
                    if let error, !settingsEdited, savedValues != [bank, account, holder, budget] {
                        Section { ErrorNotice(message: error) }
                    }
                    Section("연결 정보") {
                        Button { showingPCConnection = true } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "desktopcomputer").font(.system(size: 20))
                                    .foregroundStyle(LedgerTheme.accent).frame(width: 22).accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("PC에서 기록하기").foregroundStyle(LedgerTheme.ink)
                                    Text("내 계정으로 PC 웹 가계부에 연결해요.")
                                        .font(.footnote).foregroundStyle(LedgerTheme.muted)
                                }.fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.footnote)
                                    .foregroundStyle(LedgerTheme.muted).accessibilityHidden(true)
                            }
                        }.accessibilityIdentifier("pcConnection")
                        Text("개인 내역·미확인 알림은 나만 봐요.").font(.footnote).foregroundStyle(LedgerTheme.muted)
                        DisclosureGroup("자세히") {
                            Text(store.credentials?.base ?? "").font(.footnote).textSelection(.enabled)
                        }
                    }.listRowBackground(LedgerTheme.surface).listRowSeparator(.hidden)
                }.font(.body.weight(.medium)).environment(\.defaultMinListRowHeight, 52)
                    .ledgerScreen().listSectionSpacing(24).ledgerRootScreen()
                    .scrollDismissesKeyboard(.interactively)
                    .safeAreaInset(edge: .bottom) {
                        if settingsEdited || savedValues == [bank, account, holder, budget] {
                            VStack(spacing: 10) {
                                ErrorNotice(message: error)
                                Button(savedValues == [bank, account, holder, budget] ? "저장했어요" : "계좌 · 예산 저장") { Task { await save() } }
                                    .buttonStyle(LedgerPrimaryButtonStyle())
                                    .disabled(!settingsEdited || busy || store.refreshing)
                                    .accessibilityIdentifier("saveSettings")
                            }.padding(.horizontal, 20).padding(.vertical, 12).background(LedgerTheme.background)
                        }
                    }
                    .onAppear {
                        guard !loadedSettings else { return }
                        let member = view.members.first { $0.id == view.me }
                        bank = member?.bank ?? ""; account = member?.account ?? ""; holder = member?.holder ?? ""
                        loadedAccount = [bank, account, holder]
                        budget = formattedWonInput(String(view.household.budget))
                        loadedBudget = budget
                        loadedSettings = true
                    }
                    .onChange(of: accountValues) { _, values in
                        guard loadedAccount.count == 3 else { return }
                        if bank == loadedAccount[0] { bank = values[0] }
                        if account == loadedAccount[1] { account = values[1] }
                        if holder == loadedAccount[2] { holder = values[2] }
                        loadedAccount = values
                    }
                    .onChange(of: view.household.budget) { _, value in
                        if budget == loadedBudget { budget = formattedWonInput(String(value)) }
                        loadedBudget = formattedWonInput(String(value))
                    }
                    .sheet(isPresented: $addingCategory) { CategoryForm() }
                    .sheet(isPresented: $showingPCConnection) { PCConnectionSheet() }
                    .alert("초대 링크를 다시 만들까요?", isPresented: $confirmingRegeneration) {
                        Button("취소", role: .cancel) {}
                        Button("다시 만들기") { createInvite() }.accessibilityIdentifier("confirmRegenerateInvite")
                    } message: {
                        Text("새 링크를 만들면 이전 링크는 즉시 무효가 돼요. 상대에게 새 링크를 보내 주세요.")
                    }
            }
        }
    }
    private func sharingSection(_ view: LedgerSnapshot) -> some View {
        Section("함께 쓰는 가계부") {
            ForEach(view.members) { member in
                LabeledContent {
                    Text(member.id == view.me ? "나" : "함께 사용 중")
                        .font(.subheadline).foregroundStyle(LedgerTheme.muted)
                } label: {
                    Text(member.name)
                }
            }
            LabeledContent {
                Text(view.household.mode == "pool" ? "공동자금" : "각자 결제 후 정산")
                    .font(.subheadline).foregroundStyle(LedgerTheme.muted)
            } label: {
                Text("생활비 관리")
            }
            if view.members.count >= 2 {
                VStack(alignment: .leading, spacing: 4) {
                    Label("두 사람 연결됨", systemImage: "person.2")
                        .font(.body.weight(.medium)).foregroundStyle(LedgerTheme.accent)
                        .accessibilityIdentifier("membershipConnected")
                    Text("공용은 함께 · 개인·미확인 알림은 나만")
                        .font(.footnote).foregroundStyle(LedgerTheme.muted)
                }.fixedSize(horizontal: false, vertical: true)
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(alignment: .leading, spacing: 8) {
                        if let invite = store.activeInvite, let expiresAt = store.inviteExpiresAt, expiresAt > context.date {
                            Text("초대 참여 대기 중").font(.body.weight(.medium)).foregroundStyle(LedgerTheme.ink).accessibilityIdentifier("membershipPending")
                            Text("유효 기한: \(expiresAt.formatted(date: .abbreviated, time: .standard))")
                                .font(.footnote).foregroundStyle(LedgerTheme.muted).accessibilityIdentifier("inviteExpiration")
                            ShareLink("초대 링크 공유", item: invite)
                                .frame(minHeight: 44, alignment: .leading)
                                .disabled(busy || store.refreshing || expiresAt <= Date()).accessibilityIdentifier("shareInvite")
                            Button("초대 링크 복사") {
                                guard !busy, expiresAt > Date(), store.activeInvite == invite,
                                      (store.snapshot?.members.count ?? 2) < 2 else { return }
                                UIPasteboard.general.setItems([["public.utf8-plain-text": invite.absoluteString]],
                                    options: [.localOnly: true, .expirationDate: expiresAt])
                                copiedInvite = true
                            }.frame(minHeight: 44, alignment: .leading)
                                .disabled(busy || store.refreshing).accessibilityIdentifier("copyInvite")
                            if copiedInvite { Text("복사했어요.").font(.footnote) }
                        } else if store.activeInvite != nil {
                            Text("초대 링크가 만료됐어요").accessibilityIdentifier("inviteExpired")
                            Text("새 링크를 만들어 주세요.")
                                .font(.footnote).foregroundStyle(LedgerTheme.muted)
                        } else {
                            Text("혼자 사용 중").font(.body.weight(.medium)).foregroundStyle(LedgerTheme.ink).accessibilityIdentifier("membershipSolo")
                            Text("한 사람을 초대할 수 있어요.")
                                .font(.footnote).foregroundStyle(LedgerTheme.muted)
                        }
                        Button(store.activeInvite == nil ? "초대 링크 만들기" : "초대 링크 다시 만들기") {
                            if store.activeInvite == nil { createInvite() }
                            else { confirmingRegeneration = true }
                        }.frame(minHeight: 44, alignment: .leading)
                            .disabled(busy || store.refreshing).accessibilityIdentifier("makeInvite")
                        DisclosureGroup("도움말") { Text("초대 링크는 24시간 동안 한 번만 사용할 수 있어요. 다시 만들면 이전 링크는 즉시 무효가 돼요.").font(.footnote).foregroundStyle(LedgerTheme.muted) }
                            .font(.footnote).foregroundStyle(LedgerTheme.muted)
                    }.frame(maxWidth: .infinity, alignment: .leading).buttonStyle(.borderless)
                }
            }
            Button("참여 상태 새로고침") {
                guard !busy, !store.refreshing else { return }
                busy = true; error = nil
                Task {
                    defer { busy = false }
                    await store.refresh()
                    error = store.error
                }
            }.disabled(busy || store.refreshing).accessibilityIdentifier("refreshMembership")
        }.listRowBackground(LedgerTheme.surface).listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
    }
    private func createInvite() {
        guard !busy, !store.refreshing, (store.snapshot?.members.count ?? 2) < 2 else { return }
        busy = true; error = nil
        Task {
            defer { busy = false }
            do { _ = try await store.makeInvite(); copiedInvite = false }
            catch { self.error = error.localizedDescription }
        }
    }
    private func save() async {
        guard !busy, !store.refreshing else { return }
        guard let value = Int(budget.replacingOccurrences(of: ",", with: "")), value >= 0 else { error = "예산을 0원 이상으로 입력해 주세요."; return }
        busy = true; error = nil; savedValues = nil
        defer { busy = false }
        var body: [String: Any] = [:]
        for (index, field) in ["bank", "account", "holder"].enumerated() {
            let value = [bank, account, holder][index]
            if loadedAccount.indices.contains(index), value != loadedAccount[index] { body[field] = value }
        }
        if budget != loadedBudget { body["budget"] = value }
        do {
            try await store.mutate("/settings", method: "PATCH", body: body)
            if store.error == nil, let current = store.snapshot?.household.budget {
                budget = formattedWonInput(String(current)); loadedBudget = budget
            } else if body["budget"] != nil { loadedBudget = budget }
            loadedAccount = [bank, account, holder]
            savedValues = [bank, account, holder, budget]
        }
        catch { self.error = error.localizedDescription }
    }
}

private struct PCConnectionSheet: View {
    private struct CodeResponse: Decodable {
        let code: String
        let expiresIn: Int
    }
    @Environment(LedgerStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var code: String?
    @State private var expiresAt: Date?
    @State private var copied = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("PC에서 기록하기", systemImage: "desktopcomputer")
                        .font(.headline).foregroundStyle(LedgerTheme.ink)
                    Link("PC 웹 가계부 열기", destination: URL(string: "https://our-ledger-web.vercel.app")!)
                    Text("our-ledger-web.vercel.app에 코드를 입력하세요.")
                    Text("새 구성원을 추가하지 않고 내 계정으로 연결해요. 코드는 본인의 PC에서만 입력해 주세요.")
                        .font(.footnote).foregroundStyle(LedgerTheme.muted)
                }.listRowBackground(LedgerTheme.surface).listRowSeparator(.hidden)
                Section("연결 코드") {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        VStack(alignment: .leading, spacing: 12) {
                            if let code, let expiresAt {
                                let remaining = Self.remainingSeconds(until: expiresAt, now: context.date)
                                if remaining > 0 {
                                    Text(code).font(.system(.largeTitle, design: .monospaced).weight(.semibold))
                                        .foregroundStyle(LedgerTheme.accent).lineLimit(1).minimumScaleFactor(0.5)
                                        .privacySensitive().accessibilityIdentifier("pcConnectionCode")
                                    Text("남은 시간 \(remaining / 60)분 \(remaining % 60)초")
                                        .font(.footnote).monospacedDigit().foregroundStyle(LedgerTheme.muted)
                                        .accessibilityIdentifier("pcConnectionExpiration")
                                    Button(copied ? "복사했어요" : "코드 복사") {
                                        guard !busy, expiresAt > Date() else { return }
                                        UIPasteboard.general.setItems([["public.utf8-plain-text": code]],
                                            options: [.localOnly: true, .expirationDate: expiresAt])
                                        copied = true
                                    }.frame(minHeight: 44).disabled(busy).accessibilityIdentifier("copyPCConnectionCode")
                                } else {
                                    Text("연결 코드가 만료됐어요.").accessibilityIdentifier("pcConnectionExpired")
                                    Text("새 코드를 만들어 다시 입력해 주세요.")
                                        .font(.footnote).foregroundStyle(LedgerTheme.muted)
                                }
                            } else {
                                Text("코드를 만들어 PC에 입력하면 연결돼요.")
                                    .font(.subheadline).foregroundStyle(LedgerTheme.muted)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.listRowBackground(LedgerTheme.surface).listRowSeparator(.hidden)
                Section {
                    if busy { ProgressView("연결 코드 만드는 중…").accessibilityIdentifier("pcConnectionBusy") }
                    ErrorNotice(message: error)
                    Button(code == nil ? "연결 코드 만들기" : "새 코드 만들기") {
                        Task { await generateCode() }
                    }.buttonStyle(LedgerPrimaryButtonStyle()).disabled(busy)
                        .accessibilityIdentifier("generatePCConnectionCode")
                }.listRowBackground(LedgerTheme.surface).listRowSeparator(.hidden)
            }.ledgerScreen().navigationTitle("PC 연결").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() }.disabled(busy) }
                }
        }.interactiveDismissDisabled(busy)
    }

    private static func remainingSeconds(until expiresAt: Date, now: Date) -> Int {
        max(0, Int(ceil(expiresAt.timeIntervalSince(now))))
    }

    @MainActor private func generateCode() async {
        guard !busy else { return }
        error = nil
        guard let api = store.api else {
            error = "가계부 연결을 확인한 뒤 다시 시도해 주세요."
            return
        }
        busy = true; copied = false; code = nil; expiresAt = nil
        defer { busy = false }
        let requestedAt = Date()
        do {
            let response: CodeResponse = try await api.request("/device-links", method: "POST", body: [:])
            guard !response.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, response.expiresIn > 0 else {
                throw APIError(message: "유효한 연결 코드를 받지 못했어요. 다시 만들어 주세요.")
            }
            code = response.code
            expiresAt = requestedAt.addingTimeInterval(TimeInterval(response.expiresIn))
        } catch let failure as APIError where failure.statusCode == 401 || failure.statusCode == 403 {
            error = "가계부 인증을 확인할 수 없어요. 연결 상태를 확인한 뒤 다시 시도해 주세요."
        } catch let failure as APIError where failure.statusCode == 404 || failure.statusCode == 405 {
            error = "서버에서 아직 PC 연결을 지원하지 않아요. 잠시 후 다시 시도해 주세요."
        } catch is DecodingError {
            error = "연결 코드 응답을 읽지 못했어요. 잠시 후 다시 시도해 주세요."
        } catch {
            self.error = "연결 코드를 만들지 못했어요. " + error.localizedDescription
        }
    }
}

struct CategoryForm: View {
    @Environment(LedgerStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var keywords = ""
    @State private var error: String?
    @State private var busy = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("카테고리 이름", text: $name).accessibilityIdentifier("categoryName")
                    TextField("자동 분류 단어 (선택)", text: $keywords)
                    Text("예: 사료, 동물병원. 여러 단어는 쉼표로 나눠 주세요.").font(.footnote).foregroundStyle(LedgerTheme.muted)
                }
                Section { ErrorNotice(message: error) }
            }.ledgerScreen().disabled(busy).navigationTitle("카테고리 추가").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() }.disabled(busy) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("추가") {
                            guard !busy else { return }
                            busy = true; error = nil
                            Task {
                                defer { busy = false }
                                do { try await store.mutate("/categories", body: ["name": name, "keywords": keywords]); dismiss() }
                                catch { self.error = error.localizedDescription }
                            }
                        }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy).accessibilityIdentifier("addCategory")
                    }
                }
        }.interactiveDismissDisabled(busy)
    }
}

private struct ImportReceiptStatus: View {
    let status: ImportStatus?
    let setup: NotificationSetupState?
    @Environment(\.scenePhase) private var scenePhase
    @State private var deliveries: [NotificationDeliveryRecord] = []
    var body: some View {
        Group {
            if let status {
                VStack(alignment: .leading, spacing: 4) {
                    Text("최근 확인함 도착").font(.subheadline)
                    Text(receivedTime(status.lastReceivedAt)).font(.footnote).foregroundStyle(LedgerTheme.muted)
                        .accessibilityIdentifier("lastReceivedAt")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("최근 단축어 전달").font(.subheadline)
                    Text(receivedTime(status.lastShortcutAt)).font(.footnote).foregroundStyle(LedgerTheme.muted)
                        .accessibilityIdentifier("lastShortcutAt")
                }
                Text("본인의 서버 수신 시각이에요. 수동 붙여넣기도 포함되며, 단축어 시각은 마지막 성공 요청이에요.")
                    .font(.footnote).foregroundStyle(LedgerTheme.muted)
            } else {
                Text("서버에서 수신 시각을 제공하지 않아 전달 상태를 확인할 수 없어요.")
                    .font(.footnote).foregroundStyle(LedgerTheme.muted).accessibilityIdentifier("importStatusUnavailable")
            }
            Text("이 기기의 최근 동작").font(.subheadline.weight(.medium))
            if deliveries.isEmpty {
                Text("아직 전달 기록이 없어요. 연결 후 실행한 동작부터 표시돼요.")
                    .font(.footnote).foregroundStyle(LedgerTheme.muted)
            }
            ForEach(deliveries) { record in
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.stage.title).font(.subheadline)
                    Text("시작 " + record.startedAt.formatted(date: .abbreviated, time: .standard))
                    Text("확인 " + record.updatedAt.formatted(date: .abbreviated, time: .standard))
                    if let stage = record.failedStage { Text("단계: " + stage.title) }
                }.font(.footnote).foregroundStyle(LedgerTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("최근 20건만 이 기기에 보관해요. 완료 미확인은 실패를 뜻하지 않으며, 서버 응답 확인도 새 거래 등록을 뜻하지는 않아요. 알림 원문과 금액은 저장하지 않아요.")
                .font(.footnote).foregroundStyle(LedgerTheme.muted)
        }
        .onAppear { deliveries = setup?.deliveries ?? [] }
        .onChange(of: setup?.identity) { _, _ in deliveries = setup?.deliveries ?? [] }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { deliveries = setup?.deliveries ?? [] }
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: RunLoop.main)) { _ in
            deliveries = setup?.deliveries ?? []
        }
    }
    private func receivedTime(_ value: String?) -> String {
        guard let value else { return "아직 수신 기록이 없어요" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        return date?.formatted(date: .abbreviated, time: .standard) ?? "수신 시각을 확인할 수 없어요"
    }
}
