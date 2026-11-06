import SwiftUI
import CryptoKit

struct RecurringPaymentsView: View {
    var scope: String? = nil
    @Environment(LedgerStore.self) private var store
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var adding = false
    @State private var editing: RecurringPayment?
    @State private var recording: RecurringPayment?
    @State private var linking: RecurringPayment?
    @State private var archiving: RecurringPayment?
    @State private var busy = false
    @State private var error: String?

    private var blocked: Bool { busy || store.refreshing || store.error != nil }

    var body: some View {
        List {
            if let view = store.snapshot, let allPayments = view.recurringPayments {
                let payments = allPayments.filter { scope == nil || $0.scope == scope }
                Section {
                    MonthControl().disabled(busy).listRowSeparator(.hidden)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(scope == "personal" ? "개인 · 남은 예정액" : scope == "shared" ? "공용 · 남은 예정액" : "남은 예정액").font(.subheadline).foregroundStyle(LedgerTheme.muted)
                        Text(won(payments.filter { $0.active && $0.dueDay != nil && $0.entryID == nil }.reduce(0) { $0 + $1.amount }))
                            .font(.largeTitle.weight(.bold)).monospacedDigit()
                            .foregroundStyle(LedgerTheme.ink)
                        Text("예정액은 지출에 포함되지 않아요")
                            .font(.footnote).foregroundStyle(LedgerTheme.muted)
                    }.padding(.vertical, 8).listRowSeparator(.hidden)
                }.listRowBackground(LedgerTheme.background)
                Section("매월 반복 일정") {
                    if payments.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("매달 나가는 돈을 모아보세요").font(.headline).foregroundStyle(LedgerTheme.ink)
                            Text("일정을 추가하고, 결제한 뒤 확인해서 기록해요.")
                                .font(.subheadline).foregroundStyle(LedgerTheme.muted)
                        }.padding(.vertical, 12)
                    }
                    ForEach(payments) { payment in
                        paymentRow(payment, view: view)
                    }
                }
                Section {
                    DisclosureGroup("도움말") {
                        Text("결제 후 직접 기록하거나 기존 지출을 연결해 주세요.")
                        Text("공용 일정은 상대도 볼 수 있어요. 수정·기록·연결은 만든 사람만 할 수 있어요. 개인 일정은 나만 볼 수 있어요.")
                    }
                }
            } else if store.snapshot != nil {
                Section {
                    Text("현재 서버에서는 정기결제를 사용할 수 없어요.")
                    Text("정기결제를 지원하는 서버로 업데이트한 뒤 다시 확인해 주세요.")
                        .font(.footnote).foregroundStyle(LedgerTheme.muted)
                }
            } else {
                Section {
                    if store.refreshing { ProgressView("일정을 불러오는 중…") }
                    else { Text("일정을 불러오지 못했어요.").foregroundStyle(LedgerTheme.muted) }
                }
            }
            if let message = error ?? store.error {
                Section {
                    Text(message).foregroundStyle(LedgerTheme.ink)
                    Button("다시 불러오기") {
                        guard !busy, !store.refreshing else { return }
                        Task { await store.refresh(); error = store.error }
                    }.frame(minHeight: 44).disabled(busy || store.refreshing)
                }
            }
        }
        .accessibilityIdentifier("recurringList")
        .ledgerScreen().listSectionSpacing(16)
        .contentMargins(.top, 8, for: .scrollContent)
        .safeAreaInset(edge: .bottom) {
            if store.snapshot?.recurringPayments != nil {
                Button { adding = true } label: { Label("일정 추가", systemImage: "plus") }
                    .buttonStyle(LedgerPrimaryButtonStyle())
                    .accessibilityIdentifier("addRecurring").disabled(blocked)
                    .padding(.horizontal, 20).padding(.vertical, 12).background(LedgerTheme.background)
            }
        }
        .navigationTitle("정기결제").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
        .navigationBarBackButtonHidden(busy)
        .refreshable { if !busy && !store.refreshing { await store.refresh(); error = store.error } }
        .sheet(isPresented: $adding) { RecurringPaymentForm() }
        .sheet(item: $editing) { RecurringPaymentForm(existing: $0) }
        .sheet(item: $recording) { EntryForm(recurring: $0) }
        .sheet(item: $linking) { RecurringLinkForm(payment: $0, month: store.month) }
        .alert("정기결제 일정을 삭제할까요?", isPresented: Binding(
            get: { archiving != nil }, set: { if !$0 { archiving = nil } }
        ), presenting: archiving) { payment in
            Button("취소", role: .cancel) { archiving = nil }
            Button("일정 삭제", role: .destructive) { Task { await change(payment, archive: true) } }
        } message: { payment in
            Text("‘\(payment.note)’ 일정을 삭제해요. 이미 기록한 실제 지출은 삭제되지 않아요.")
        }
    }

    private func paymentRow(_ payment: RecurringPayment, view: LedgerSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(payment.note).font(.headline)
                    Text(won(payment.amount)).font(.title2.weight(.semibold)).monospacedDigit()
                }.foregroundStyle(LedgerTheme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if payment.owner == view.me {
                    Menu {
                        Button("일정 수정") { editing = payment }
                        Button(payment.active ? "일시중지" : "다시 시작") { Task { await change(payment) } }
                        Button("일정 삭제", role: .destructive) { archiving = payment }
                    } label: {
                        Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44)
                    }.accessibilityLabel(payment.note + " 일정 관리")
                }
            }
            Label(payment.entryID != nil ? "기록 완료" : !payment.active ? "일시중지" : payment.dueDay == nil ? "이번 달 예정 없음" : "예정 · 확인 후 기록",
                  systemImage: payment.entryID != nil ? "checkmark.circle" : payment.active ? "calendar" : "pause.circle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(payment.entryID != nil ? LedgerTheme.accent : LedgerTheme.muted)
            if !payment.active && payment.entryID != nil {
                Text("일시중지").font(.footnote).foregroundStyle(LedgerTheme.muted)
            }
            Text(payment.dueDay.map { "예정일 " + String($0.suffix(5)).replacingOccurrences(of: "-", with: "/") + " · 매월 \(payment.dayOfMonth)일" }
                 ?? "매월 \(payment.dayOfMonth)일")
                .font(.subheadline).foregroundStyle(LedgerTheme.muted)
            Text((payment.scope == "shared" ? "공용" : "개인") + " · " + view.categoryName(payment.category)
                 + " · " + view.memberName(payment.payer) + " · " + (payment.funding == "fund" ? "공동자금" : "개인 돈"))
                .font(.footnote).foregroundStyle(LedgerTheme.muted)
            if payment.owner == view.me {
                if payment.active && payment.dueDay != nil && payment.entryID == nil {
                    let actions = dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                        : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
                    actions {
                        Button { recording = payment } label: {
                            Text("확인 후 기록").fontWeight(.semibold)
                                .padding(.horizontal, 14).frame(minHeight: 44)
                                .background(LedgerTheme.accentSoft, in: RoundedRectangle(cornerRadius: 12))
                                .contentShape(RoundedRectangle(cornerRadius: 12))
                        }.buttonStyle(.plain).foregroundStyle(LedgerTheme.accent)
                            .accessibilityIdentifier("recordRecurring-" + payment.id)
                        Button { linking = payment } label: {
                            Text("기존 지출 연결").frame(minHeight: 44).contentShape(Rectangle())
                        }.buttonStyle(.borderless)
                            .accessibilityIdentifier("linkRecurring-" + payment.id)
                    }.font(.subheadline)
                }
            } else {
                Text(view.memberName(payment.owner) + " · 조회 전용")
                    .font(.footnote).foregroundStyle(LedgerTheme.muted)
            }
        }
        .fixedSize(horizontal: false, vertical: true).padding(.vertical, 8)
        .buttonStyle(.borderless).disabled(blocked).listRowSeparator(.hidden)
        .listRowBackground(LedgerTheme.surface)
    }

    @MainActor private func change(_ payment: RecurringPayment, archive: Bool = false) async {
        guard !blocked, let current = store.snapshot?.recurringPayments?.first(where: { $0.id == payment.id }),
              current.owner == store.snapshot?.me else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            try await store.mutate("/recurring/" + current.id, method: archive ? "DELETE" : "PATCH",
                                   body: archive ? [:] : ["active": !current.active])
            if let refreshError = store.error {
                error = "요청 후 최신 상태를 확인하지 못했어요. 다시 불러온 뒤 확인해 주세요. " + refreshError
            } else if store.snapshot?.recurringPayments == nil {
                error = "정기결제 상태를 확인할 수 없어요. 다시 불러와 주세요."
            }
        } catch { self.error = error.localizedDescription }
    }
}

struct RecurringPaymentForm: View {
    private enum InputField: Hashable { case note, amount }
    @Environment(LedgerStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var existing: RecurringPayment? = nil
    @State private var creationID = UUID().uuidString
    @State private var submittedCreation: [String: Any]?
    @State private var creationJournal: RecurringCreationJournal?
    @State private var creationAccount: String?
    @State private var recoveryLoaded = false
    @State private var alreadyCreated: RecurringPayment?
    @State private var confirmingExisting = false
    @State private var note = ""
    @State private var amount = ""
    @State private var scope = ""
    @State private var category = ""
    @State private var payer = ""
    @State private var funding = "personal"
    @State private var dayOfMonth = 1
    @State private var startDay = Date()
    @State private var active = true
    @State private var initialized = false
    @State private var busy = false
    @State private var awaitingRefresh = false
    @State private var addingCategory = false
    @State private var error: String?
    @FocusState private var focusedField: InputField?

    private var valid: Bool {
        parsedWon(amount) != nil && validRecurringNote(note) && ["shared", "personal"].contains(scope)
            && (1...31).contains(dayOfMonth) && !payer.isEmpty
    }
    private var needsRecovery: Bool { existing == nil && !recoveryLoaded }
    private var editable: Bool {
        guard let view = store.snapshot, view.recurringPayments != nil else { return false }
        return existing == nil || view.recurringPayments?.contains(where: { $0.id == existing?.id && $0.owner == view.me }) == true
    }
    private var currentCreationAccount: String? {
        guard let credentials = store.credentials, let view = store.snapshot else { return nil }
        return credentials.base.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            + "\n" + view.household.id + "\n" + view.me
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("금액과 한 줄 설명") {
                    TextField("일정 이름", text: $note).accessibilityLabel("일정 이름").accessibilityIdentifier("recurringName")
                        .focused($focusedField, equals: .note)
                        .submitLabel(.next).onSubmit { focusedField = .amount }
                        .frame(minHeight: 44)
                    HStack(alignment: .firstTextBaseline) {
                        TextField("금액", text: $amount).onChange(of: amount) { _, value in amount = formattedWonInput(value) }.accessibilityLabel("금액").keyboardType(.numberPad)
                            .focused($focusedField, equals: .amount)
                            .font(.largeTitle.weight(.bold)).monospacedDigit()
                            .frame(minHeight: 44).accessibilityIdentifier("recurringAmount")
                        Text("원").foregroundStyle(LedgerTheme.muted)
                    }
                    if !amount.isEmpty && parsedWon(amount) == nil {
                        Text("금액은 1원 이상 1천억 원 이하의 정수로 입력해 주세요.").font(.footnote).foregroundStyle(.red)
                    }
                    if !note.isEmpty && !validRecurringNote(note) {
                        Text("설명은 한 줄, 1~120자로 입력해 주세요.").font(.footnote).foregroundStyle(.red)
                    }
                }
                Section("공개 범위") {
                    Picker("공개 범위", selection: $scope) {
                        Text("직접 선택해 주세요").tag("")
                        Text("공용").tag("shared")
                        Text("개인").tag("personal")
                    }.frame(minHeight: 44).accessibilityIdentifier("recurringScope")
                    Text(scope == "shared" ? "상대와 함께 보기"
                         : scope == "personal" ? "나만 보기" : "공용·개인을 선택해 주세요.")
                        .font(.footnote).foregroundStyle(LedgerTheme.muted)
                }
                Section("반복 날짜") {
                    Stepper("매월 \(dayOfMonth)일", value: $dayOfMonth, in: 1...31).frame(minHeight: 44)
                        .accessibilityIdentifier("recurringDayStepper")
                    DatePicker("시작일", selection: $startDay, displayedComponents: .date).frame(minHeight: 44)
                        .accessibilityIdentifier("recurringStartDate")
                    Toggle("일정 사용", isOn: $active).frame(minHeight: 44)
                }
                Section("카테고리") {
                    Picker("분류", selection: $category) {
                        Text("내용으로 자동 분류").tag("")
                        ForEach(store.snapshot?.categories ?? []) { Text($0.name).tag($0.id) }
                    }.frame(minHeight: 44)
                    if category.isEmpty, let suggested = store.snapshot?.recommendedCategory(for: note) {
                        Text("추천: " + suggested.name).font(.footnote).foregroundStyle(LedgerTheme.muted)
                    }
                    Button("카테고리 추가") { addingCategory = true }.frame(minHeight: 44)
                }
                Section("결제 정보") {
                    Picker("결제한 사람", selection: $payer) {
                        ForEach(store.snapshot?.members.filter { scope == "shared" || $0.id == store.snapshot?.me } ?? []) {
                            Text($0.name).tag($0.id)
                        }
                    }.frame(minHeight: 44)
                    if scope == "shared" && store.snapshot?.household.mode == "pool" {
                        Picker("사용할 돈", selection: $funding) {
                            Text("개인 돈").tag("personal")
                            Text("공동자금").tag("fund")
                        }.frame(minHeight: 44)
                    }
                }
                Section {
                    Text("예정 · 지출에 미포함")
                        .font(.footnote).foregroundStyle(LedgerTheme.muted)
                    DisclosureGroup("도움말") {
                        Text("결제 후 직접 기록하거나 기존 지출을 연결해 주세요.")
                        Text("공용 일정은 상대도 보며, 만든 사람만 수정·기록·연결할 수 있어요. 개인 일정은 나만 보여요.")
                        Text("시작일부터 적용하며, 해당 일이 없는 달은 말일로 잡아요. 일시중지·삭제해도 기존 지출은 유지돼요.")
                    }
                    if submittedCreation != nil {
                        Text("입력을 보관했어요. 닫아도 다음 ‘일정 추가’에서 이어서 확인해요.")
                            .font(.footnote).foregroundStyle(LedgerTheme.muted)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .disabled(busy || awaitingRefresh || submittedCreation != nil || needsRecovery || !editable)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    if let error { ErrorNotice(message: error).accessibilityIdentifier("recurringError") }
                    if !valid && error == nil && editable {
                        Text("설명·금액·공개 범위를 확인해 주세요")
                            .font(.footnote).foregroundStyle(LedgerTheme.muted)
                    }
                    if alreadyCreated != nil {
                        Text("이미 등록된 일정이에요. 최신 내용을 확인해 주세요.").font(.subheadline)
                        Button("최신 내용으로 확인") { Task { await reviewExistingCreation() } }
                            .buttonStyle(LedgerPrimaryButtonStyle()).disabled(busy || store.refreshing)
                            .accessibilityIdentifier("reviewExistingRecurring")
                    } else {
                        Button(busy ? "확인 중…" : needsRecovery || awaitingRefresh || submittedCreation != nil ? "저장 상태 다시 확인" : "저장") { Task { await save() } }
                            .buttonStyle(LedgerPrimaryButtonStyle())
                            .disabled(busy || store.refreshing || (!needsRecovery && !awaitingRefresh && submittedCreation == nil && (!valid || !editable)))
                            .accessibilityIdentifier("saveRecurring")
                    }
                }.padding(.horizontal, 20).padding(.vertical, 12).background(LedgerTheme.background)
            }
            .ledgerScreen().listSectionSpacing(20).tint(LedgerTheme.accent)
            .navigationTitle(existing == nil ? "정기결제 추가" : "정기결제 수정")
            .navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(submittedCreation == nil ? "취소" : "나중에 확인") { dismiss() }.frame(minHeight: 44).disabled(busy) }
            }
            .onAppear { fill() }
            .onChange(of: scope) { _, value in
                focusedField = nil
                if value != "shared" { payer = store.snapshot?.me ?? ""; funding = "personal" }
            }
            .sheet(isPresented: $addingCategory) { CategoryForm() }
            .alert("이미 등록된 일정이에요", isPresented: $confirmingExisting, presenting: alreadyCreated) { payment in
                Button("나중에", role: .cancel) {}
                Button("확인하고 닫기") { confirmExistingCreation(payment) }
            } message: { payment in
                Text("\(payment.note) · \(won(payment.amount))\n\(payment.scope == "shared" ? "공용" : "개인") · 매월 \(payment.dayOfMonth)일 · \(payment.active ? "사용 중" : "일시중지")\n최신 일정은 그대로 두고, 보관한 이전 저장 요청만 정리해요.")
            }
        }.interactiveDismissDisabled(busy)
    }

    private func fill() {
        guard !initialized else { return }
        initialized = true
        payer = store.snapshot?.me ?? ""
        if let existing {
            note = existing.note; amount = formattedWonInput(String(existing.amount)); scope = existing.scope
            category = existing.category; payer = existing.payer; funding = existing.funding
            dayOfMonth = existing.dayOfMonth; startDay = parseDay(existing.startDay); active = existing.active
        } else {
            let today = Date()
            startDay = today
            dayOfMonth = Int(dayString(today).suffix(2)) ?? 1
            do { try restoreCreation() }
            catch { self.error = "보관한 저장 요청을 읽지 못했어요. 다시 확인해 주세요. " + error.localizedDescription }
        }
        if !editable { error = "일정을 사용할 수 없어요. 만든 사람만 수정할 수 있으며, 서버의 정기결제 지원이 필요해요." }
    }

    private func restoreCreation() throws {
        guard let account = currentCreationAccount,
              let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw APIError(message: "가계부 연결을 확인해 주세요.")
        }
        let journal = RecurringCreationJournal(directory: directory.appendingPathComponent("RecurringCreation"), account: account)
        let pending = try journal.load()
        creationJournal = journal; creationAccount = account
        if let pending {
            creationID = pending["id"] as! String
            submittedCreation = pending
            note = pending["note"] as! String; amount = formattedWonInput(String(pending["amount"] as! Int))
            scope = pending["scope"] as! String; category = pending["category"] as! String
            payer = pending["payer"] as! String; funding = pending["funding"] as! String
            dayOfMonth = pending["dayOfMonth"] as! Int; startDay = parseDay(pending["startDay"] as! String)
            active = pending["active"] as! Bool
        }
        recoveryLoaded = true
    }

    private func findExistingCreation() -> Bool {
        guard submittedCreation != nil, creationAccount == currentCreationAccount, store.error == nil,
              let view = store.snapshot,
              let saved = view.recurringPayments?.first(where: { $0.id == creationID && $0.owner == view.me }) else { return false }
        alreadyCreated = saved; error = nil
        return true
    }

    @MainActor private func reviewExistingCreation() async {
        guard !busy, !store.refreshing else { return }
        busy = true
        defer { busy = false }
        await store.refresh()
        if findExistingCreation() { confirmingExisting = true }
        else { error = "등록된 일정의 최신 내용을 확인하지 못했어요. 다시 확인해 주세요." }
    }

    private func confirmExistingCreation(_ displayed: RecurringPayment) {
        guard !busy, !store.refreshing, findExistingCreation(),
              let saved = alreadyCreated, saved.id == displayed.id,
              let owner = store.snapshot?.me, let creationJournal else { return }
        do {
            try creationJournal.confirmExisting(saved, id: creationID, owner: owner)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }

    @MainActor private func save() async {
        guard !busy, !store.refreshing else { return }
        if existing == nil {
            do {
                if !recoveryLoaded { try restoreCreation() }
                guard creationAccount == currentCreationAccount else {
                    throw APIError(message: "가계부 연결이 바뀌었어요. 닫은 뒤 다시 열어 주세요.")
                }
            } catch { self.error = error.localizedDescription; return }
        }
        guard awaitingRefresh || submittedCreation != nil || (editable && valid), let value = parsedWon(amount) else {
            error = "설명·금액·공개 범위·결제자를 확인해 주세요."; return
        }
        focusedField = nil
        busy = true; error = nil
        defer { busy = false }
        do {
            if awaitingRefresh {
                await store.refresh()
            } else {
                if submittedCreation == nil {
                    guard let view = store.snapshot,
                      view.members.contains(where: { $0.id == payer }),
                      scope == "shared" || payer == view.me,
                      funding == "personal" || (funding == "fund" && scope == "shared" && view.household.mode == "pool"),
                      category.isEmpty || view.categories.contains(where: { $0.id == category }) else {
                        throw APIError(message: "공개 범위·분류·결제 정보를 확인해 주세요.")
                    }
                }
                var body: [String: Any] = submittedCreation ?? ["note": note.trimmingCharacters(in: .whitespacesAndNewlines),
                    "amount": value, "scope": scope, "payer": payer, "funding": funding,
                    "category": category, "startDay": dayString(startDay), "dayOfMonth": dayOfMonth, "active": active]
                if existing == nil {
                    body["id"] = creationID
                    guard let creationJournal else { throw APIError(message: "저장 요청을 보관하지 못했어요. 다시 열어 주세요.") }
                    // Persist before sending: lost responses and sheet dismissal must reuse this ID.
                    try creationJournal.stage(body)
                    submittedCreation = body
                }
                try await store.mutate(existing.map { "/recurring/" + $0.id } ?? "/recurring",
                                       method: existing == nil ? "POST" : "PATCH", body: body)
                // An acknowledged write only needs a fresh read.
                awaitingRefresh = true
            }
            guard store.error == nil, store.snapshot?.recurringPayments != nil else {
                throw APIError(message: "요청은 전달됐지만 최신 상태를 확인하지 못했어요. 입력은 유지했어요. ‘저장 상태 다시 확인’을 눌러 주세요. " + (store.error ?? ""))
            }
            if let submittedCreation {
                guard creationAccount == currentCreationAccount, let view = store.snapshot,
                      let saved = view.recurringPayments?.first(where: { $0.id == creationID }),
                      recurringCreationMatches(saved, body: submittedCreation, owner: view.me) else {
                    if findExistingCreation() { return }
                    throw APIError(message: "조회한 일정이 제출 내용과 일치하지 않아 완료 처리하지 않았어요. 입력을 유지했어요. 저장 상태를 다시 확인해 주세요.")
                }
                try creationJournal?.clear(id: creationID)
            }
            dismiss()
        } catch let apiError as APIError where apiError.statusCode == 400 || apiError.statusCode == 404 {
            if submittedCreation != nil {
                // A rejected retry can refer to an already-created schedule. Only release the
                // persisted request after a fresh read proves that its ID is absent.
                await store.refresh()
                if findExistingCreation() { return }
                if creationAccount == currentCreationAccount, store.error == nil,
                   let payments = store.snapshot?.recurringPayments,
                   !payments.contains(where: { $0.id == creationID }) {
                    do {
                        try creationJournal?.clear(id: creationID)
                        submittedCreation = nil; awaitingRefresh = false
                    } catch { self.error = error.localizedDescription; return }
                }
            } else { awaitingRefresh = false }
            self.error = apiError.localizedDescription
        } catch {
            self.error = (submittedCreation != nil && !awaitingRefresh
                ? "저장 완료를 확인하지 못했어요. 입력을 유지했어요. ‘저장 상태 다시 확인’을 누르면 같은 내용으로 다시 요청해요. " : "")
                + error.localizedDescription
        }
    }
}

private struct RecurringLinkForm: View {
    @Environment(LedgerStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let payment: RecurringPayment
    let month: String
    @State private var selectedID: String?
    @State private var confirming = false
    @State private var busy = false
    @State private var awaitingRefresh = false
    @State private var error: String?

    private var candidates: [Entry] {
        guard let view = store.snapshot, store.month == month else { return [] }
        // /state only returns nonvoided, visible entries.
        return view.entries.filter { recurringLinkCandidate($0, payment: payment, month: month, me: view.me) }
            .sorted { $0.day == $1.day ? $0.id < $1.id : $0.day > $1.day }
    }
    private var selected: Entry? { candidates.first { $0.id == selectedID } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(payment.note).font(.headline)
                    Text(won(payment.amount)).font(.largeTitle.weight(.bold)).monospacedDigit()
                    Text(month).font(.subheadline).foregroundStyle(LedgerTheme.muted)
                    Text("기존 지출 1건을 선택해요.")
                        .font(.footnote).foregroundStyle(LedgerTheme.muted)
                    DisclosureGroup("도움말") {
                        Text("내가 기록한 같은 달의 지출 중 공개 범위·결제자·사용한 돈·금액이 같은 내역만 표시해요.")
                        Text("이미 정기결제에 연결한 지출은 제외해요. 연결해도 새 지출은 만들지 않아요.")
                    }
                }
                Section("연결할 실제 지출") {
                    if candidates.isEmpty && !awaitingRefresh {
                        Text("연결할 지출이 없어요.")
                            .foregroundStyle(LedgerTheme.muted)
                        Text("같은 달·금액·공개 범위의 지출을 기록한 뒤 연결해 주세요.")
                            .font(.footnote).foregroundStyle(LedgerTheme.muted)
                    }
                    ForEach(candidates) { entry in
                        Button { selectedID = entry.id } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: selectedID == entry.id ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedID == entry.id ? LedgerTheme.accent : LedgerTheme.muted)
                                    .frame(width: 20).padding(.top, 2)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(entry.note).foregroundStyle(LedgerTheme.ink)
                                    Text(entry.day + " · " + won(entry.amount)).font(.subheadline)
                                        .monospacedDigit().foregroundStyle(LedgerTheme.muted)
                                }
                            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .padding(.vertical, 4).contentShape(Rectangle())
                        }.ledgerRowDivider().accessibilityValue(selectedID == entry.id ? "선택됨" : "선택 안 됨")
                            .accessibilityAddTraits(selectedID == entry.id ? .isSelected : [])
                            .listRowBackground(selectedID == entry.id ? LedgerTheme.accentSoft : LedgerTheme.surface)
                    }
                }.disabled(busy || awaitingRefresh || store.refreshing)
            }
            .ledgerScreen().tint(LedgerTheme.accent)
            .navigationTitle("기존 지출 연결").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    ErrorNotice(message: error)
                    Button(busy ? "확인 중…" : awaitingRefresh ? "연결 상태 다시 확인" : "연결") {
                        if awaitingRefresh { Task { await link() } } else { confirming = true }
                    }.buttonStyle(LedgerPrimaryButtonStyle())
                        .disabled(busy || store.refreshing || (!awaitingRefresh && selected == nil))
                }.padding(.horizontal, 20).padding(.vertical, 12).background(LedgerTheme.background)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() }.frame(minHeight: 44).disabled(busy) }
            }
            .alert("선택한 실제 지출을 연결할까요?", isPresented: $confirming, presenting: selected) { _ in
                Button("취소", role: .cancel) {}
                Button("이 지출 연결") { Task { await link() } }
            } message: { entry in
                Text("\(entry.note)\n\(entry.day) · \(won(entry.amount))\n새 지출을 만들지 않고 ‘\(payment.note)’의 \(month) 기록으로 연결해요.")
            }
        }.interactiveDismissDisabled(busy)
    }

    @MainActor private func link() async {
        guard !busy, !store.refreshing else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            guard store.month == month else { throw APIError(message: "선택한 달이 바뀌었어요. 닫은 뒤 다시 연결해 주세요.") }
            if awaitingRefresh {
                await store.refresh()
            } else {
                guard let view = store.snapshot, let entry = selected,
                      let current = view.recurringPayments?.first(where: { $0.id == payment.id }),
                      current.owner == view.me, current.active, current.dueDay != nil, current.entryID == nil,
                      recurringLinkCandidate(entry, payment: current, month: month, me: view.me) else {
                    throw APIError(message: "일정 또는 지출 상태가 바뀌었어요. 닫은 뒤 최신 내역을 확인해 주세요.")
                }
                try await store.mutate("/recurring/" + payment.id + "/link", body: ["month": month, "entryID": entry.id])
                awaitingRefresh = true
            }
            guard store.error == nil,
                  let current = store.snapshot?.recurringPayments?.first(where: { $0.id == payment.id }),
                  current.entryID == selectedID else {
                throw APIError(message: "연결 요청 후 최신 상태를 확인하지 못했어요. ‘연결 상태 다시 확인’을 눌러 주세요. " + (store.error ?? ""))
            }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: - Durable recurring creation

// One unresolved creation per server/member. Closing a sheet or restarting the app
// retains the exact request; no token or real account information goes in the filename.
struct RecurringCreationJournal {
    let directory: URL
    let account: String
    private var file: URL {
        let digest = SHA256.hash(data: Data(account.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest + ".json")
    }

    func load() throws -> [String: Any]? {
        // Corrupt files remain blocking: never guess a new ID or silently discard an
        // unknown request. This is separate from resolving a verified existing schedule.
        let data: Data
        do { data = try Data(contentsOf: file) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              ["id", "note", "scope", "payer", "funding", "category", "startDay"].allSatisfy({ body[$0] is String }),
              let id = body["id"] as? String, !id.isEmpty,
              let amount = body["amount"] as? Int, amount > 0,
              let day = body["dayOfMonth"] as? Int, (1...31).contains(day), body["active"] is Bool else {
            throw APIError(message: "보관한 저장 요청을 확인할 수 없어요. 새 일정은 보내지 않았어요.")
        }
        return body
    }

    func stage(_ body: [String: Any]) throws {
        if let pending = try load() {
            guard NSDictionary(dictionary: pending).isEqual(to: body) else {
                throw APIError(message: "확인 중인 일정이 있어요. 닫은 뒤 ‘일정 추가’에서 먼저 확인해 주세요.")
            }
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(iOS)
        var protectedDirectory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try protectedDirectory.setResourceValues(values)
        let options: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        let options: Data.WritingOptions = [.atomic]
        #endif
        try JSONSerialization.data(withJSONObject: body).write(to: file, options: options)
    }

    func clear(id: String) throws {
        guard let pending = try load() else { return }
        guard pending["id"] as? String == id else {
            throw APIError(message: "다른 저장 요청이 보관되어 있어 삭제하지 않았어요.")
        }
        try FileManager.default.removeItem(at: file)
    }

    // Only called after explicit user acknowledgement; changed contents are not replayed.
    func confirmExisting(_ saved: RecurringPayment, id: String, owner: String) throws {
        guard saved.id == id, saved.owner == owner else {
            throw APIError(message: "내가 등록한 같은 일정인지 확인하지 못해 요청을 유지했어요.")
        }
        try clear(id: id)
    }
}
