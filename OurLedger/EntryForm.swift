import SwiftUI

struct EntryForm: View {
    enum ImportOutcome { case excluded, settled }
    private enum InputField: Hashable { case amount, note }
    @Environment(LedgerStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var existing: Entry?
    var imported: ImportedMessage?
    var recurring: RecurringPayment?
    var initialScope: String? = nil
    var demonstration = false
    var onRecorded: ((String, String, Int) -> Void)? = nil
    var onHandled: ((ImportOutcome) -> Void)? = nil
    var reviewRemaining: Int? = nil
    @State private var recurringMonth = ""
    @State private var entryID = UUID().uuidString
    @State private var amount = ""
    @State private var note = ""
    @State private var scope = ""
    @State private var kind = "expense"
    @State private var funding = "personal"
    @State private var payer = ""
    @State private var category = ""
    @State private var date = Date()
    @State private var busy = false
    @State private var error: String?
    @State private var initialized = false
    @State private var addingCategory = false
    @State private var showingRecent = false
    @State private var settlementCandidate: SettlementCandidate?
    @FocusState private var focusedField: InputField?
    private var settlementMatches: [SettlementCandidate] {
        guard let imported, !demonstration, existing == nil else { return [] }
        return (store.snapshot?.settlementCandidates ?? []).filter { $0.importID == imported.id }
    }
    private var linkedRefund: Bool { existing?.refundOf != nil }
    private var ambiguousImport: Bool {
        guard let imported else { return false }
        return imported.kind == "transfer" || imported.requiresReview
    }
    private var validKind: Bool {
        if existing?.kind == "refund" { return kind == "refund" }
        return ["expense", "income"].contains(kind) ||
            (kind == "deposit" && imported?.kind != "refund" && store.snapshot?.household.mode == "pool" && scope == "shared")
    }
    private var validPayer: Bool {
        guard let view = store.snapshot else { return false }
        return view.members.contains { $0.id == payer } && (scope != "personal" || payer == view.me)
    }
    private var payerOptions: [(id: String, name: String)] {
        var options = (store.snapshot?.members ?? []).filter {
            scope == "shared" || $0.id == store.snapshot?.me || $0.id == payer
        }.map { (id: $0.id, name: $0.id == store.snapshot?.me ? "나" : $0.name) }
        if !options.contains(where: { $0.id == payer }) {
            options.append((payer, payer == "fund" ? "공동자금" : payer.isEmpty ? "불러오는 중…" : "결제자 확인 중…"))
        }
        return options
    }
    private var readyToSave: Bool { validKind && validPayer && parsedWon(amount) != nil && !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && ["shared", "personal"].contains(scope) }
    private var recentEntries: [Entry] {
        var notes = Set<String>()
        return Array((store.snapshot?.entries ?? []).filter {
            $0.owner == store.snapshot?.me && $0.kind == "expense" && notes.insert($0.note).inserted
        }.prefix(5))
    }
    var body: some View {
        NavigationStack { ScrollViewReader { proxy in
            Form {
                if let reviewRemaining, reviewRemaining > 1 {
                    Section {
                        Text("이 거래 포함 \(reviewRemaining)건 남았어요")
                            .font(.subheadline).foregroundStyle(LedgerTheme.muted)
                            .accessibilityIdentifier("entryReviewRemaining")
                    }.listRowSeparator(.hidden)
                }
                if !settlementMatches.isEmpty {
                    Section("정산금액과 같은 알림이에요") {
                        ForEach(settlementMatches) { candidate in
                            Button {
                                focusedField = nil; settlementCandidate = candidate
                            } label: {
                                Label(candidate.due.month + " · " + won(candidate.due.amount) + " 정산으로 확인", systemImage: "arrow.left.arrow.right")
                                    .frame(minHeight: 44)
                            }.accessibilityIdentifier("entrySettlementCandidate-" + candidate.id)
                        }
                        Text("생활비 정산이라면 수입·지출로 다시 기록하지 않아요.")
                            .font(.footnote).foregroundStyle(LedgerTheme.muted)
                    }.listRowSeparator(.hidden)
                }
                if demonstration {
                    Section {
                        Label("[테스트] 기록 연습", systemImage: "checkmark.bubble").ledgerRowDivider()
                        Text("실제 지출에는 포함되지 않아요")
                            .font(.footnote).foregroundStyle(LedgerTheme.muted)
                    }
                }
                if recurring != nil {
                    Section {
                        Label("확인 후 지출로 기록", systemImage: "calendar.badge.clock").ledgerRowDivider()
                            .font(.subheadline).foregroundStyle(LedgerTheme.muted)
                        Text("금액·날짜를 확인해 주세요. 일정 원본은 바뀌지 않아요.")
                            .font(.footnote).foregroundStyle(LedgerTheme.muted)
                    }
                }
                Section {
                    if existing?.kind == "refund" {
                        Label("기존 환불 내역", systemImage: "arrow.uturn.backward")
                            .accessibilityIdentifier("existingRefundKind")
                        Text("수정해도 환불 종류는 유지돼요. 지출이나 수입으로 바뀌지 않아요.")
                            .font(.footnote).foregroundStyle(LedgerTheme.muted)
                    } else {
                        let layout = dynamicTypeSize.isAccessibilitySize
                            ? AnyLayout(VStackLayout(spacing: 8))
                            : AnyLayout(HStackLayout(spacing: 8))
                        layout {
                            kindButton("지출", value: "expense")
                            kindButton("수입", value: "income")
                        }.disabled(linkedRefund || recurring != nil)
                        if store.snapshot?.household.mode == "pool" && scope == "shared" && imported?.kind != "refund" {
                            kindButton("공동자금 입금", value: "deposit").disabled(linkedRefund || recurring != nil)
                        }
                    }
                    if imported?.kind == "refund" {
                        Text("취소·환불 알림이에요. 기존 거래의 환불은 달력에서 해당 내역을 수정하거나 삭제해 주세요. 별도 기록이 필요하면 지출·수입을 직접 선택해 주세요.")
                            .font(.footnote).foregroundStyle(LedgerTheme.muted)
                        Button("취소·환불 알림 · 기록 안 함") { Task { await ignoreTransfer() } }
                            .frame(minHeight: 44).accessibilityIdentifier("ignoreRefund")
                    }
                    if ambiguousImport {
                        Text(imported?.kind == "transfer" || imported?.kind == "income"
                             ? "입금·송금 알림은 내 계좌 이동이나 정산일 수도 있어요. 거래 종류를 직접 선택해 주세요."
                             : "금액과 내용을 확인하고 지출·수입을 선택해 주세요.")
                            .font(.footnote).foregroundStyle(LedgerTheme.muted)
                    }
                    if let imported, ["transfer", "income"].contains(imported.kind) {
                        Button("정산·계좌 이동 · 기록 안 함") { Task { await ignoreTransfer() } }
                            .frame(minHeight: 44).accessibilityIdentifier("ignoreTransfer")
                    }
                    if kind == "income" {
                        Text(scope == "shared" ? "함께 쓸 수입이에요. 받은 사람과 계좌를 기준으로 정산에 반영해요." : scope == "personal" ? "개인 수입은 나만 보고 정산에서 제외해요." : "함께 쓸 돈은 공용, 나만 쓸 돈은 개인으로 골라주세요.")
                            .font(.footnote).foregroundStyle(LedgerTheme.muted)
                    }
                }.listRowSeparator(.hidden).listRowBackground(LedgerTheme.background)
                if kind == "income" && scope == "shared" && store.snapshot?.household.mode == "pool" {
                    Section("어디로 받았나요?") {
                        Picker("받은 계좌", selection: $funding) {
                            Text("개인 계좌").tag("personal")
                            Text("공동 계좌").tag("fund")
                        }.pickerStyle(.segmented).accessibilityIdentifier("incomeDestination")
                        Text(funding == "fund" ? "공동자금 잔액에 바로 더해요." : "받은 사람의 환급액에서 빼고, 남는 돈은 공동자금에 돌려줘요.")
                            .font(.footnote).foregroundStyle(LedgerTheme.muted)
                    }
                }
                Section {
                    HStack(alignment: .firstTextBaseline) {
                        TextField("금액", text: $amount).onChange(of: amount) { _, value in amount = formattedWonInput(value) }.accessibilityLabel("금액").keyboardType(.numberPad).font(.largeTitle.weight(.bold)).monospacedDigit().focused($focusedField, equals: .amount).accessibilityIdentifier("entryAmount")
                            .submitLabel(.next).onSubmit { focusedField = .note }
                        Text("원").foregroundStyle(LedgerTheme.muted)
                    }.padding(.vertical, 8)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("한 줄 설명").font(.subheadline.weight(.semibold)).foregroundStyle(LedgerTheme.ink)
                        HStack(spacing: 8) {
                            TextField(kind == "income" ? "어떤 수입인가요?" : kind == "deposit" ? "어떤 돈을 넣었나요?" : kind == "refund" ? "어떤 환불인가요?" : "어디에 썼나요?", text: $note).accessibilityLabel("한 줄 설명").accessibilityIdentifier("entryNote")
                                .focused($focusedField, equals: .note).submitLabel(.done).onSubmit { focusedField = nil }
                                .font(.title3.weight(.medium)).frame(minHeight: 44)
                            if !note.isEmpty {
                                Button {
                                    note = ""; focusedField = nil
                                    // Restore editing after the window's outside-tap dismissal.
                                    DispatchQueue.main.async { focusedField = .note }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.body).foregroundStyle(LedgerTheme.muted)
                                        .frame(width: 44, height: 44).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                    .accessibilityLabel("설명 모두 지우기")
                                    .accessibilityIdentifier("clearEntryNote")
                            }
                        }
                    }.padding(.vertical, 8).id(InputField.note)
                    if !amount.isEmpty && parsedWon(amount) == nil {
                        Text("금액은 1원 이상 1천억 원 이하의 정수로 입력해 주세요.").font(.footnote).foregroundStyle(.red)
                    }
                } header: { Text("금액").font(.headline).foregroundStyle(LedgerTheme.ink).textCase(nil) }
                    .listRowBackground(LedgerTheme.background).listRowSeparator(.hidden)
                Section {
                    DisclosureGroup {
                        Picker("분류", selection: $category) {
                            Text("내용으로 자동 분류").tag("")
                            ForEach(store.snapshot?.categories ?? []) { Text($0.name).tag($0.id) }
                        }.disabled(linkedRefund)
                        if category.isEmpty, let view = store.snapshot {
                            if let suggested = view.recommendedCategory(for: note) {
                                if suggested.name == "미분류" {
                                    Text("설명에 ‘점심’, ‘커피’처럼 용도를 적거나 분류를 직접 골라주세요.")
                                        .font(.footnote).foregroundStyle(LedgerTheme.muted)
                                        .accessibilityIdentifier("categorySuggestion")
                                } else {
                                    Label("추천: " + suggested.name, systemImage: "tag")
                                        .font(.subheadline).accessibilityIdentifier("categorySuggestion")
                                }
                            } else {
                                Text("내용을 바탕으로 저장할 때 자동 분류해요.").font(.footnote).foregroundStyle(LedgerTheme.muted)
                            }
                        }
                        if !linkedRefund && !demonstration { Button("카테고리 추가") { focusedField = nil; addingCategory = true }.frame(minHeight: 44).accessibilityIdentifier("entryAddCategory") }
                        if linkedRefund { Text("환불의 공개 범위와 결제 정보는 원래 지출을 따라가요.").font(.footnote).foregroundStyle(LedgerTheme.muted) }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("카테고리")
                            let suggestion = store.snapshot?.recommendedCategory(for: note)?.name
                            Text(category.isEmpty ? (suggestion == "미분류" ? "분류를 골라주세요" : "자동 분류 · " + (suggestion ?? "설명으로 추천해요"))
                                 : store.snapshot?.categoryName(category) ?? "직접 선택")
                                .font(.subheadline).foregroundStyle(LedgerTheme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }.padding(.vertical, 4)
                    }.accessibilityIdentifier("entryCategoryOptions")
                }.listRowSeparator(.hidden).listRowBackground(LedgerTheme.background)
                Section {
                    if let imported, imported.time == nil {
                        DatePicker("거래 날짜", selection: $date, displayedComponents: .date)
                            .accessibilityIdentifier("unrecognizedTransactionDate")
                        Text("날짜를 읽지 못해 오늘로 표시했어요. 거래 날짜를 확인해 주세요.")
                            .font(.footnote).foregroundStyle(LedgerTheme.muted)
                    }
                    DisclosureGroup(kind == "income" ? "날짜 · 받은 사람" : kind == "deposit" ? "날짜 · 입금한 사람" : "날짜 · 결제자 · 결제 방식") {
                        if imported?.time != nil || imported == nil {
                            DatePicker("날짜", selection: $date, displayedComponents: .date)
                        }
                        Picker(kind == "income" ? "받은 사람" : kind == "deposit" ? "입금한 사람" : "결제한 사람", selection: $payer) {
                            ForEach(payerOptions, id: \.id) { Text($0.name).tag($0.id) }
                        }.disabled(linkedRefund || recurring != nil).accessibilityIdentifier("entryPayer")
                        if kind == "deposit" {
                            LabeledContent("받는 곳", value: "공동자금")
                        } else if kind != "income" && store.snapshot?.household.mode == "pool" && scope == "shared" {
                            Picker("사용한 돈", selection: $funding) { Text("개인 돈").tag("personal"); Text("공동자금").tag("fund") }.disabled(linkedRefund || recurring != nil)
                        }
                    }.accessibilityIdentifier("entryPaymentOptions")
                }.listRowSeparator(.hidden).listRowBackground(LedgerTheme.background)
                if dynamicTypeSize.isAccessibilitySize { Section { saveControls } }
                if let imported {
                    Section("가져온 알림") {
                        if imported.requiresReview { Text(imported.reason).font(.subheadline) }
                        Text(imported.raw).font(.footnote).foregroundStyle(LedgerTheme.muted).textSelection(.enabled)
                    }
                }
            }
            .ledgerScreen().listSectionSpacing(12)
            .contentMargins(.top, 8, for: .scrollContent)
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) {
                if !dynamicTypeSize.isAccessibilitySize {
                    saveControls.padding(.horizontal, 20).padding(.vertical, 12).background(LedgerTheme.background)
                }
            }
            .navigationTitle(recurring != nil ? "정기결제 확인" : existing != nil ? "내역 수정" : kind == "income" ? "수입 기록" : "거래 기록")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .primaryAction) {
                    if existing == nil && imported == nil && recurring == nil && !recentEntries.isEmpty {
                        Button { focusedField = nil; showingRecent = true } label: { Label("최근 내용 불러오기", systemImage: "clock.arrow.circlepath") }
                            .disabled(busy).accessibilityIdentifier("recentDrafts")
                    }
                }
            }
            .onAppear { fill() }
            .onChange(of: store.snapshot?.me) { _, _ in fillMissingPayer() }
            .sheet(isPresented: $addingCategory) { CategoryForm() }
            .sheet(item: $settlementCandidate, onDismiss: {
                if let imported, store.error == nil, let view = store.snapshot,
                   !view.inbox.contains(where: { $0.id == imported.id }) {
                    if let onHandled { onHandled(.settled) } else { dismiss() }
                }
            }) { SettlementConfirmationView(candidate: $0) }
            .confirmationDialog("최근 내용 불러오기", isPresented: $showingRecent, titleVisibility: .visible) {
                ForEach(recentEntries) { entry in
                    Button(entry.note + " · " + won(entry.amount)) {
                        amount = formattedWonInput(String(entry.amount)); note = entry.note; category = entry.category
                    }
                }
                Button("취소", role: .cancel) {}
            } message: { Text("금액·설명·분류만 채워요. 공개 범위는 직접 선택해 주세요.") }
            .disabled(busy)
            .interactiveDismissDisabled(busy)
            .onChange(of: focusedField) { _, value in
                if value == .note { proxy.scrollTo(InputField.note, anchor: .center) }
            }
            // Initial imported focus can precede the keyboard's layout.
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                if focusedField == .note { proxy.scrollTo(InputField.note, anchor: .center) }
            }
        } }
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
    }
    private var saveControls: some View {
        VStack(spacing: focusedField == nil ? 10 : 6) {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: 8))
                : AnyLayout(HStackLayout(spacing: 8))
            layout {
                scopeButton("공용", value: "shared", symbol: "person.2")
                scopeButton("개인", value: "personal", symbol: "lock")
            }.disabled(linkedRefund || recurring != nil)
            Text(scope == "personal" ? "개인 · 나만 볼 수 있어요" : scope == "shared" ? "공용 · 함께 볼 수 있어요" : "공용·개인을 선택해 주세요")
                .font(.footnote).foregroundStyle(LedgerTheme.muted).fixedSize(horizontal: false, vertical: true)
            ErrorNotice(message: error)
            if focusedField == nil && !validKind { Text("수입·지출 등 거래 종류를 선택해 주세요").font(.footnote).foregroundStyle(LedgerTheme.muted) }
            if focusedField == nil && error == nil && (parsedWon(amount) == nil || note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                Text(parsedWon(amount) == nil ? "금액을 입력해 주세요" : "한 줄 설명을 입력해 주세요")
                    .font(.footnote).foregroundStyle(LedgerTheme.muted)
            }
            Button(busy ? "저장 중…" : focusedField == .amount ? "설명 입력" : demonstration ? "테스트 기록 완료" : "저장") {
                if focusedField == .amount { focusedField = .note }
                else { Task { await save() } }
            }
                .buttonStyle(LedgerPrimaryButtonStyle())
                .disabled(busy || (focusedField == .amount ? parsedWon(amount) == nil : !readyToSave)).accessibilityIdentifier("saveEntry")
        }
    }
    private func fill() {
        guard !initialized else { return }
        initialized = true
        payer = store.snapshot?.me ?? ""
        if let entry = existing {
            amount = formattedWonInput(String(entry.amount)); note = entry.note; scope = entry.scope
            kind = entry.kind
            funding = entry.funding; payer = entry.payer; category = entry.category
            date = parseDay(entry.day)
            entryID = entry.id
        } else if let recurring {
            amount = formattedWonInput(String(recurring.amount)); note = recurring.note; scope = recurring.scope
            payer = recurring.payer; funding = recurring.funding; category = recurring.category
            recurringMonth = store.month
            if let due = recurring.dueDay { date = parseDay(due) }
        } else if let imported {
            amount = imported.amount.map { formattedWonInput(String($0)) } ?? ""
            note = imported.merchant
            kind = imported.kind == "refund" ? "" : imported.kind == "income" ? "income" : "expense"
            if let time = imported.time { date = parseDay(String(time.prefix(10))) }
        }
        if existing == nil && recurring == nil,
           let initialScope, ["shared", "personal"].contains(initialScope) {
            scope = initialScope
        }
        if amount.isEmpty && !dynamicTypeSize.isAccessibilitySize { focusedField = .amount }
        else { focusedField = imported != nil && settlementMatches.isEmpty && ["shared", "personal"].contains(scope) ? .note : nil }
    }
    private func fillMissingPayer() {
        // A late snapshot supplies only the missing default, never reinitializes the draft.
        if payer.isEmpty { payer = store.snapshot?.me ?? "" }
    }
    private func kindButton(_ title: String, value: String) -> some View {
        Button { kind = value; focusedField = nil } label: {
            Text(title).font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .foregroundStyle(kind == value ? LedgerTheme.accent : LedgerTheme.muted)
            .background(kind == value ? LedgerTheme.accentSoft : LedgerTheme.surface, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityAddTraits(kind == value ? .isSelected : [])
            .accessibilityIdentifier("entryKind-" + value)
            .accessibilityValue(kind == value ? "선택됨" : "선택 안 됨")
    }
    private func ignoreTransfer() async {
        guard !busy, let imported, ["transfer", "income", "refund"].contains(imported.kind) else { return }
        if demonstration { dismiss(); return }
        busy = true; error = nil
        defer { busy = false }
        do {
            try await store.mutate("/imports/" + imported.id, method: "DELETE")
            if let onHandled { onHandled(.excluded) } else { dismiss() }
        } catch { self.error = error.localizedDescription }
    }
    private func scopeButton(_ title: String, value: String, symbol: String) -> some View {
        Button {
            scope = value
            if value == "personal" {
                payer = store.snapshot?.me ?? ""; funding = "personal"
                if kind == "deposit" { kind = "expense" }
            }
            focusedField = imported != nil ? .note : nil
        } label: {
            HStack(spacing: 8) {
                Image(systemName: scope == value ? "checkmark.circle.fill" : symbol)
                Text(title).fontWeight(.semibold)
            }.fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .font(.subheadline)
            .foregroundStyle(scope == value ? LedgerTheme.accent : LedgerTheme.muted)
            .background(scope == value ? LedgerTheme.accentSoft : LedgerTheme.background,
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(scope == value ? LedgerTheme.accent : LedgerTheme.border, lineWidth: 1) }
            .accessibilityAddTraits(scope == value ? .isSelected : [])
            .accessibilityIdentifier(value == "shared" ? "scopeShared" : "scopePersonal")
            .accessibilityValue(scope == value ? "선택됨" : "선택 안 됨")
    }
    private func save() async {
        guard !busy else { return }
        guard validKind else { error = "수입·지출 등 거래 종류를 선택해 주세요."; return }
        guard ["shared", "personal"].contains(scope) else { error = "공용 또는 개인을 선택해 주세요."; return }
        guard validPayer else { error = "결제자 정보를 불러온 뒤 확인해 주세요."; return }
        guard let value = parsedWon(amount) else { error = "금액은 1원 이상 1천억 원 이하의 정수로 입력해 주세요."; return }
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedNote.isEmpty else { error = "한 줄 설명을 입력해 주세요."; return }
        var body: [String: Any] = ["id": entryID, "amount": value, "note": note, "scope": scope, "kind": kind,
                                   "funding": kind == "deposit" ? "fund" : funding, "payer": payer, "day": dayString(date)]
        if !category.isEmpty { body["category"] = category }
        if let imported { body["importID"] = imported.id }
        if let recurring {
            body["recurringID"] = recurring.id
            body["recurringMonth"] = recurringMonth
        }
        if demonstration {
            if let onRecorded { onRecorded(scope, trimmedNote, value) }
            else { dismiss() }
            return
        }
        busy = true; error = nil
        defer { busy = false }
        do {
            guard let api = store.api else { throw APIError(message: "가계부를 먼저 연결해 주세요.") }
            let saved: Entry = try await api.request(existing.map { "/entries/" + $0.id } ?? "/entries", method: existing == nil ? "POST" : "PATCH", body: body)
            await store.refresh()
            try saved.validateSubmission(body)
            store.notice = saved.scope == "personal" ? "개인 기록으로 저장했어요. 나에게만 보여요." : "공용 기록으로 저장했어요."
            if let onRecorded { onRecorded(saved.scope, saved.note.trimmingCharacters(in: .whitespacesAndNewlines), saved.amount) }
            else { dismiss() }
        } catch { self.error = error.localizedDescription }
    }
}
