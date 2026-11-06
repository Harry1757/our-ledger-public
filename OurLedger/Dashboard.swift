import SwiftUI

struct DashboardView: View {
    @Environment(LedgerStore.self) private var store
    @Environment(\.ledgerGuideTarget) private var guideTarget
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var composing = false
    @State private var showingExport = false
    private enum ImportDestination: String, Identifiable {
        case capture, text
        var id: String { rawValue }
    }
    @State private var importDestination: ImportDestination?
    @State private var selection: Entry?
    @AppStorage("ledgerDisplayScope") private var scope = "shared"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var payer = ""
    @State private var search = ""
    @State private var showingSearch = false
    @FocusState private var searchFocused: Bool
    @State private var selectedDay: String?

    var body: some View {
        NavigationStack {
            Group {
            if let view = store.snapshot {
                let searching = !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let scoped = view.entries.filter { $0.scope == scope && (scope == "shared" || $0.owner == view.me) }
                let rows = scoped.filter {
                    (scope != "shared" || payer.isEmpty || $0.payer == payer) &&
                    (selectedDay == nil || searching || $0.day == selectedDay) && matchesEntry($0, search: search, view: view)
                }
                let spendingRows = rows.filter { ["expense", "refund"].contains($0.kind) }
                let incomeRows = rows.filter { $0.kind == "income" }
                ScrollViewReader { proxy in
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 8) {
                                MonthControl()
                                Button {
                                    showingSearch.toggle()
                                    if !showingSearch { search = "" }
                                    searchFocused = showingSearch
                                } label: {
                                    Image(systemName: showingSearch ? "xmark" : "magnifyingglass")
                                        .font(.system(size: 19, weight: .semibold)).frame(width: 44, height: 44)
                                        .background(LedgerTheme.surface, in: Circle())
                                }.buttonStyle(.plain)
                                    .accessibilityLabel(showingSearch ? "검색 닫기" : "거래 검색")
                                    .accessibilityIdentifier("toggleLedgerSearch")
                                Button {
                                    searchFocused = false; showingExport = true
                                } label: {
                                    Image(systemName: "square.and.arrow.up")
                                        .font(.system(size: 19, weight: .semibold)).frame(width: 44, height: 44)
                                        .background(LedgerTheme.surface, in: Circle())
                                }.buttonStyle(.plain).accessibilityLabel("엑셀 내보내기")
                                    .accessibilityIdentifier("exportLedger")
                            }
                            if showingSearch {
                                HStack(spacing: 10) {
                                    Image(systemName: "magnifyingglass").foregroundStyle(LedgerTheme.muted).accessibilityHidden(true)
                                    TextField("사용처·메모 검색", text: $search)
                                        .focused($searchFocused).submitLabel(.search)
                                        .onSubmit { searchFocused = false }
                                        .accessibilityLabel("사용처·메모·카테고리·결제자 검색")
                                        .accessibilityIdentifier("ledgerSearch")
                                    if !search.isEmpty {
                                        Button { search = "" } label: {
                                            Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44)
                                        }.accessibilityLabel("검색어 지우기").buttonStyle(.plain)
                                    }
                                }.padding(.leading, 14).padding(.trailing, 4)
                                    .frame(minHeight: 48)
                                    .background(LedgerTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                            }
                            if !searching {
                                summary(view, personalTotal: scoped.filter { ["expense", "refund"].contains($0.kind) }.reduce(0) { $0 + $1.signedAmount })
                            }
                        }
                        if !searching {
                            if scope == "shared" {
                                DisclosureGroup("합계 자세히") {
                                    Text("지출에서 환불을 뺐어요. 수입·정기결제 예정·공동자금 입금은 제외해요.")
                                        .font(.caption).foregroundStyle(LedgerTheme.muted)
                                        .accessibilityIdentifier("summaryExplanation")
                                    SpendingComparison(stats: view.stats, compact: true)
                                    ForEach(view.stats.byMember) { member in
                                        LabeledContent(member.name + " · 개인 돈 결제", value: won(member.amount))
                                            .font(.subheadline).monospacedDigit()
                                    }
                                    if view.household.mode == "pool" {
                                        LabeledContent("선택한 달 말 공동자금 잔액", value: won(view.stats.fundBalance))
                                            .font(.subheadline).monospacedDigit()
                                    }
                                }.font(.subheadline).tint(LedgerTheme.muted)
                            }
                            let actions = typeSize.isAccessibilitySize
                                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                                : AnyLayout(HStackLayout(spacing: 10))
                            actions {
                                Button { composing = true } label: {
                                    Label("기록하기", systemImage: "plus").frame(maxWidth: .infinity)
                                }
                                .buttonStyle(LedgerPrimaryButtonStyle())
                                .accessibilityIdentifier("addEntry")
                                .ledgerTourTarget(.addExpense)
                                Menu {
                                    Button { importDestination = .capture } label: {
                                        Label("캡처 선택", systemImage: "photo")
                                    }.accessibilityIdentifier("homeImportCapture")
                                    Button { importDestination = .text } label: {
                                        Label("문자·알림 붙여넣기", systemImage: "doc.on.clipboard")
                                    }.accessibilityIdentifier("homeImportText")
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "square.and.arrow.down")
                                        Text("가져오기")
                                    }
                                        .font(.subheadline.weight(.semibold))
                                        .fixedSize(horizontal: true, vertical: false)
                                        .padding(.horizontal, 14).padding(.vertical, 12)
                                        .frame(maxWidth: typeSize.isAccessibilitySize ? .infinity : nil, minHeight: 52)
                                        .foregroundStyle(LedgerTheme.accent)
                                        .background(LedgerTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                                        .contentShape(RoundedRectangle(cornerRadius: 12))
                                }.buttonStyle(.plain).accessibilityIdentifier("homeImport")
                            }
                        }
                    }.listRowSeparator(.hidden).listRowBackground(LedgerTheme.background)
                    if !searching {
                        Section {
                            if scope == "shared" {
                                if view.members.count < 2 {
                                    Button { store.tab = 3 } label: {
                                        HStack(spacing: 8) {
                                            shortcutLabel("상대 초대하기", detail: "함께 쓰는 생활비를 연결해요", icon: "person.badge.plus")
                                            Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold))
                                                .foregroundStyle(Color(uiColor: .tertiaryLabel)).accessibilityHidden(true)
                                        }
                                    }.buttonStyle(.plain).listRowSeparator(.hidden)
                                } else {
                                    NavigationLink { SettlementView() } label: {
                                        VStack(alignment: .leading, spacing: 4) {
                                            shortcutLabel("생활비 정산", detail: settlementSummary(view), icon: "arrow.left.arrow.right")
                                            let overdue = Set((view.pendingSettlements ?? []).filter { $0.month < String(dayString(Date()).prefix(7)) }.map(\.month)).count
                                            if overdue > 0 {
                                                Text("이전 달 미정산 \(overdue)개월")
                                                    .font(.caption.weight(.semibold)).foregroundStyle(LedgerTheme.accent)
                                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                                    .background(LedgerTheme.surface, in: Capsule())
                                                    .accessibilityIdentifier("overdueSettlementBadge")
                                            }
                                        }
                                    }.listRowSeparator(.hidden).accessibilityIdentifier("settlementDetails").ledgerTourTarget(.settlement)
                                }
                            }
                            NavigationLink { RecurringPaymentsView(scope: scope) } label: {
                                let pending = (view.recurringPayments ?? []).filter {
                                    $0.scope == scope && $0.active && $0.dueDay != nil && $0.entryID == nil
                                }
                                shortcutLabel("정기결제", detail: pending.isEmpty ? "예정된 결제가 없어요" : "예정 \(pending.count)건 · " + won(pending.reduce(0) { $0 + $1.amount }), icon: "calendar.badge.clock")
                            }.listRowSeparator(.hidden).accessibilityIdentifier("openRecurring")
                        }
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                        .listSectionSeparator(.hidden).listRowBackground(LedgerTheme.background).foregroundStyle(LedgerTheme.ink)
                        Section {
                            LedgerCalendar(month: store.month, entries: scoped, selectedDay: $selectedDay)
                                .id(LedgerTourTarget.calendar)
                        }.listRowSeparator(.hidden).listRowBackground(LedgerTheme.background)
                    }
                    Section {
                        if scope == "shared" {
                            DisclosureGroup("결제자별 보기 · " + (payer.isEmpty ? "모두" : view.memberName(payer))) {
                                Picker("공용 내역 결제자", selection: $payer) {
                                    Text("모두").tag("")
                                    ForEach(view.members) { Text($0.name).tag($0.id) }
                                }.frame(minHeight: 44).accessibilityIdentifier("payerFilter")
                                Text("결제자·검색은 목록에만 적용돼요. 합계·달력·예산·정산은 월 전체 기준이에요.")
                                    .font(.caption).foregroundStyle(LedgerTheme.muted)
                            }
                        }
                        Text("\(spendingRows.count)건 · 지출·환불 합계 " + won(spendingRows.reduce(0) { $0 + $1.signedAmount }))
                            .font(.subheadline.weight(.semibold)).monospacedDigit().accessibilityIdentifier("entryListSummary")
                        if !incomeRows.isEmpty {
                            Text("수입 \(incomeRows.count)건 · +" + won(incomeRows.reduce(0) { $0 + $1.amount }))
                                .font(.subheadline).monospacedDigit().foregroundStyle(LedgerTheme.income)
                        }
                        if rows.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(selectedDay != nil && !searching ? "이날 기록은 아직 없어요" : scoped.isEmpty ? "아직 기록한 거래가 없어요" : "조건에 맞는 기록이 없어요").font(.headline)
                                Text(scoped.isEmpty ? "‘기록하기’로 첫 거래를 남겨보세요." : "날짜나 검색 조건을 바꿔보세요.")
                                    .font(.subheadline).foregroundStyle(LedgerTheme.muted).fixedSize(horizontal: false, vertical: true)
                                if !scoped.isEmpty {
                                    Button("조건 초기화") { search = ""; payer = ""; selectedDay = nil }.frame(minHeight: 44)
                                }
                            }.padding(.vertical, 16).accessibilityIdentifier("dashboardEmptyState")
                        }
                    } header: {
                        HStack {
                            Text((scope == "shared" ? "공용 · " : "개인 · ") + (searching ? "검색 결과" : selectedDay != nil ? String(selectedDay!.suffix(5)).replacingOccurrences(of: "-", with: "/") + " 기록" : "월 전체 기록"))
                            Spacer()
                            if selectedDay != nil { Button("월 전체 보기") { selectedDay = nil }.frame(minHeight: 44) }
                        }.font(.subheadline.weight(.semibold))
                    }.listRowBackground(LedgerTheme.background).listRowSeparator(.hidden)
                    EntryDateSections(entries: rows, view: view, selection: $selection)
                    if let updated = store.updatedAt {
                        Text((store.error == nil ? "업데이트 " : "마지막 조회 ") + updated.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(LedgerTheme.muted).listRowSeparator(.hidden)
                    }
                }
                .listStyle(.insetGrouped).listSectionSpacing(16)
                .scrollContentBackground(.hidden).background(LedgerTheme.surface).tint(LedgerTheme.accent)
                .ledgerRootScreen()
                .scrollDismissesKeyboard(.interactively)
                .refreshable { await store.refresh() }

                .sheet(isPresented: $composing) { EntryForm(initialScope: scope) }
                .sheet(isPresented: $showingExport) {
                    LedgerExportView(snapshot: view, month: store.month, initialScope: scope)
                }
                .sheet(item: $importDestination) { destination in
                    PasteNotificationView(initialSource: destination == .capture ? "paste" : "sms",
                                          openPhotoPicker: destination == .capture)
                }
                .sheet(item: $selection) { EntryDetail(entry: $0) }
                .onChange(of: guideTarget, initial: true) { _, target in
                    guard let target, [.addExpense, .calendar, .settlement].contains(target) else { return }
                    search = ""; showingSearch = false; searchFocused = false
                    Task { @MainActor in
                        await Task.yield()
                        guard guideTarget == target else { return }
                        proxy.scrollTo(target, anchor: .center)
                    }
                }
                }
            } else {
                MonthLoadingView().toolbar(.hidden, for: .navigationBar)
            }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                scopePicker
                    .padding(.horizontal, 20).padding(.vertical, 8)
                    .background(LedgerTheme.background)
            }
        }
        .onChange(of: store.month) { _, _ in selectedDay = nil }
        .onChange(of: scope) { _, _ in selectedDay = nil; payer = "" }
    }

    private func shortcutLabel(_ title: String, detail: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 19, weight: .medium))
                .foregroundStyle(LedgerTheme.muted)
                .frame(width: 36, height: 36)
                .background(LedgerTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.footnote).foregroundStyle(LedgerTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
        }.frame(minHeight: 56).padding(.vertical, 4)
    }

    private var scopePicker: some View {
        HStack(spacing: 4) {
            ForEach(["shared", "personal"], id: \.self) { value in
                Button { scope = value } label: {
                    HStack(spacing: 8) {
                        if !typeSize.isAccessibilitySize {
                            Image(systemName: value == "shared" ? "person.2.fill" : "lock.fill")
                                .font(.subheadline).accessibilityHidden(true)
                        }
                        Text(value == "shared" ? "공용" : "개인").font(.headline).lineLimit(1).minimumScaleFactor(0.75)
                        if scope == value && !typeSize.isAccessibilitySize {
                            Image(systemName: "checkmark").font(.caption.bold()).accessibilityHidden(true)
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .foregroundStyle(scope == value ? (value == "shared" ? LedgerTheme.accent : LedgerTheme.ink) : LedgerTheme.muted)
                    .background(scope == value ? (value == "shared" ? LedgerTheme.accentSoft : LedgerTheme.background) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
                    .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(scope == value ? (value == "shared" ? LedgerTheme.accent.opacity(0.25) : LedgerTheme.border) : .clear, lineWidth: 1) }
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityIdentifier("ledgerScope-" + value)
                    .accessibilityValue(scope == value ? "선택됨" : "선택 안 됨")
                    .accessibilityAddTraits(scope == value ? .isSelected : [])
            }
        }.padding(4).background(LedgerTheme.selectionTrack, in: RoundedRectangle(cornerRadius: 16))
            .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: scope)
            .sensoryFeedback(.selection, trigger: scope)
    }

    private func summary(_ view: LedgerSnapshot, personalTotal: Int) -> some View {
        let shared: Bool = scope == "shared"
        let spendingTitle: String = shared ? "함께 쓴 생활비" : "나만의 지출"
        let spendingAmount: String = won(shared ? view.stats.total : personalTotal)
        let incomeTitle: String = shared ? "공용 수입" : "내 개인 수입"
        let reportedIncome: Int? = shared ? view.stats.incomeTotal : view.stats.personalIncomeTotal
        var fallbackIncome = 0
        for entry in view.entries where entry.kind == "income" && entry.scope == scope {
            if shared || entry.owner == view.me { fallbackIncome += entry.amount }
        }
        let incomeAmount: String = "+" + won(reportedIncome ?? fallbackIncome)
        let budget: Double = Double(view.household.budget)
        let progress: Double = min(max(Double(view.stats.total), 0), max(budget, 0))
        let remaining: Int = view.stats.budgetRemaining
        let budgetLabel: String = remaining >= 0
            ? "예산 " + won(remaining) + " 남았어요"
            : "예산 " + won(-remaining) + " 초과"
        return VStack(alignment: .leading, spacing: 12) {
            let amounts = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                : AnyLayout(HStackLayout(alignment: .bottom, spacing: 16))
            amounts {
                VStack(alignment: .leading, spacing: 6) {
                    Text(spendingTitle)
                        .font(.subheadline.weight(.medium)).foregroundStyle(LedgerTheme.muted)
                    Text(spendingAmount)
                        .font(.largeTitle.bold()).monospacedDigit().foregroundStyle(LedgerTheme.ink)
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                        .minimumScaleFactor(typeSize.isAccessibilitySize ? 1 : 0.75)
                        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("summaryAmount")
                }.frame(maxWidth: .infinity, alignment: .leading)
                if (reportedIncome ?? fallbackIncome) != 0 {
                    VStack(alignment: typeSize.isAccessibilitySize ? .leading : .trailing, spacing: 6) {
                        Text(incomeTitle).font(.caption).foregroundStyle(LedgerTheme.muted).accessibilityHidden(true)
                        Text(incomeAmount).font(.subheadline.bold()).monospacedDigit()
                            .foregroundStyle(LedgerTheme.income)
                            .accessibilityLabel(incomeTitle + ", " + incomeAmount)
                            .accessibilityIdentifier("summaryIncomeAmount")
                    }.fixedSize(horizontal: !typeSize.isAccessibilitySize, vertical: true)
                }
            }
            if !shared {
                Label("나에게만 보여요 · 정산 제외", systemImage: "lock")
                    .font(.caption).foregroundStyle(LedgerTheme.muted).fixedSize(horizontal: false, vertical: true)
            } else if view.household.budget > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: progress, total: budget).tint(LedgerTheme.brand)
                    Text(budgetLabel).font(.caption).foregroundStyle(LedgerTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
    }
    private func settlementSummary(_ view: LedgerSnapshot) -> String {
        if view.household.mode == "pool" { return "개인 돈으로 대신 낸 생활비 확인" }
        if view.settlement.count == 0 { return "남은 정산 내역이 없어요" }
        if view.settlement.amount == 0 { return "송금 없이 마감할 내역 \(view.settlement.count)건" }
        return (view.settlement.fromID == view.me ? "내가 보낼 돈 " : "내가 받을 돈 ") + won(view.settlement.amount)
    }
}

private func matchesEntry(_ entry: Entry, search: String, view: LedgerSnapshot) -> Bool {
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
    return query.isEmpty || [entry.note, view.categoryName(entry.category), view.memberName(entry.payer)]
        .contains { $0.localizedStandardContains(query) }
}

private struct EntryDateSections: View {
    let entries: [Entry]
    let view: LedgerSnapshot
    @Binding var selection: Entry?

    var body: some View {
        let groups = Dictionary(grouping: entries, by: \.day)
        ForEach(groups.keys.sorted(by: >), id: \.self) { day in
            Section {
                ForEach(groups[day] ?? []) { entry in
                    Button { selection = entry } label: { EntryRow(entry: entry, view: view) }
                        .buttonStyle(.plain).listRowSeparator(.hidden)
                        .accessibilityIdentifier("entry-" + entry.id)
                        .listRowBackground(LedgerTheme.background)
                }
            } header: {
                Text(parseDay(day), format: .dateTime.month(.wide).day().weekday(.wide))
                    .font(.footnote.weight(.medium)).foregroundStyle(LedgerTheme.muted)
                    .textCase(nil).padding(.top, 12).padding(.bottom, 4)
            }.listSectionSeparator(.hidden)
        }
    }
}

struct EntryListView: View {
    @Environment(LedgerStore.self) private var store
    let title: String
    let entries: [Entry]
    let view: LedgerSnapshot
    @State private var search = ""
    @State private var selection: Entry?

    var body: some View {
        // Preserve the selected transactions while showing their latest values after edits.
        let ids = Set(entries.map(\.id))
        let snapshot = store.snapshot ?? view
        let current = snapshot.entries.filter { ids.contains($0.id) }
        let rows = current.filter { matchesEntry($0, search: search, view: snapshot) }
        let spendingRows = rows.filter { ["expense", "refund"].contains($0.kind) }
        let incomeRows = rows.filter { $0.kind == "income" }
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(spendingRows.count)건 · 지출·환불 합계 " + won(spendingRows.reduce(0) { $0 + $1.signedAmount }))
                        .font(.headline).monospacedDigit()
                    Text("환불을 뺀 금액이에요")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 4).listRowSeparator(.hidden)
                if !incomeRows.isEmpty {
                    LabeledContent("수입 \(incomeRows.count)건", value: "+" + won(incomeRows.reduce(0) { $0 + $1.amount }))
                        .monospacedDigit().foregroundStyle(LedgerTheme.income)
                }
                if rows.isEmpty { Text("표시할 내역이 없어요.").foregroundStyle(.secondary) }
            }
            EntryDateSections(entries: rows, view: snapshot, selection: $selection)
            if let error = store.error { Section { ErrorNotice(message: error) } }
        }
        .ledgerScreen().listSectionSpacing(16).contentMargins(.top, 8, for: .scrollContent)
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
        .searchable(text: $search, prompt: "사용처·메모·카테고리·결제자 검색")
        .sheet(item: $selection) { EntryDetail(entry: $0) }
        .refreshable { await store.refresh() }
    }
}

struct EntryRow: View {
    let entry: Entry
    let view: LedgerSnapshot

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: entry.kind == "income" ? "arrow.down.left" : entry.kind == "refund" ? "arrow.uturn.backward" : entry.kind == "deposit" ? "tray.and.arrow.down" : "creditcard.fill")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(entry.kind == "income" ? LedgerTheme.income : LedgerTheme.muted)
                .frame(width: 40, height: 40)
                .background(LedgerTheme.surface, in: RoundedRectangle(cornerRadius: 14))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                amount
                description
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.vertical, 12)
            .accessibilityElement(children: .combine)
    }

    private var description: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(entry.note).font(.subheadline).foregroundStyle(LedgerTheme.ink).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 8) {
                LedgerPayerBadge(payer: entry.payer, name: view.memberName(entry.payer), me: view.me)
                    .layoutPriority(1)
                Text((entry.kind == "income" ? "받은 사람 · " : "") + (entry.kind == "deposit" ? "공동자금 입금" : view.categoryName(entry.category)) + " · " + (entry.scope == "shared" ? "공용" : "개인"))
                    .font(.footnote).foregroundStyle(LedgerTheme.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var amount: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text((entry.kind == "refund" ? "−" : ["deposit", "income"].contains(entry.kind) ? "+" : "") + won(entry.amount))
                .font(.title3.weight(.semibold)).monospacedDigit().foregroundStyle(entry.kind == "income" ? LedgerTheme.income : LedgerTheme.ink).fixedSize(horizontal: false, vertical: true)
            if entry.settlement != nil { Text("정산 완료").font(.caption).foregroundStyle(.secondary) }
            else if entry.kind == "income" { Text(entry.funding == "fund" ? "수입 · 공동 계좌" : "수입").font(.caption).foregroundStyle(LedgerTheme.income) }
            else if entry.funding == "fund" { Text("공동자금").font(.caption).foregroundStyle(.secondary) }
            else if entry.kind == "refund" { Text("환불").font(.caption).foregroundStyle(.secondary) }
        }
    }
}

struct EntryDetail: View {
    @Environment(LedgerStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let entry: Entry
    @State private var editing = false
    @State private var deleting = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        let record = store.snapshot?.entries.first { $0.id == entry.id } ?? entry
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(record.note).font(.headline).foregroundStyle(LedgerTheme.muted).fixedSize(horizontal: false, vertical: true)
                        Text((record.kind == "refund" ? "−" : ["income", "deposit"].contains(record.kind) ? "+" : "") + won(record.amount)).font(.largeTitle.weight(.bold)).monospacedDigit()
                            .foregroundStyle(record.kind == "income" ? LedgerTheme.income : LedgerTheme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }.padding(.vertical, 16)
                }.listRowBackground(LedgerTheme.background).listRowSeparator(.hidden)
                Section {
                    LabeledContent("날짜", value: record.day)
                    LabeledContent("범위", value: record.scope == "shared" ? "공용" : "개인")
                    if let view = store.snapshot {
                        LabeledContent(record.kind == "income" ? "받은 사람" : "결제자") {
                            LedgerPayerBadge(payer: record.payer, name: view.memberName(record.payer), me: view.me, showsName: true)
                        }
                    }
                    LabeledContent("종류", value: record.kind == "refund" ? "환불" : record.kind == "deposit" ? "공동자금 입금" : record.kind == "income" ? "수입" : "지출")
                    if record.kind == "income" && record.scope == "shared" && store.snapshot?.household.mode == "pool" {
                        LabeledContent("받은 계좌", value: record.funding == "fund" ? "공동 계좌" : "개인 계좌")
                    }
                    LabeledContent("카테고리", value: store.snapshot?.categoryName(record.category) ?? "")
                    if record.settlement != nil { Text("정산이 완료되어 수정할 수 없어요. 조정이 필요하면 새 내역으로 기록해 주세요.").font(.footnote).foregroundStyle(.secondary) }
                }.listRowBackground(LedgerTheme.surface).listRowSeparator(.hidden)
                Section {
                    if record.owner == store.snapshot?.me && record.settlement == nil {
                        Button("내역 수정") { editing = true }.frame(minHeight: 44).disabled(busy)
                        Button("내역 삭제", role: .destructive) { deleting = true }.frame(minHeight: 44).disabled(busy)
                    }
                    ErrorNotice(message: error)
                }.listRowBackground(LedgerTheme.background).listRowSeparator(.hidden)
            }.ledgerScreen().listSectionSpacing(24)
                .navigationTitle("내역 상세").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() }.frame(minHeight: 44).disabled(busy) } }
                .sheet(isPresented: $editing, onDismiss: { dismiss() }) { EntryForm(existing: record) }
                .confirmationDialog("이 내역을 삭제할까요?", isPresented: $deleting, titleVisibility: .visible) {
                    Button("삭제", role: .destructive) {
                        Task {
                            guard !busy else { return }
                            busy = true
                            defer { busy = false }
                            do { try await store.mutate("/entries/" + record.id, method: "DELETE"); dismiss() }
                            catch { self.error = error.localizedDescription }
                        }
                    }
                }
                .interactiveDismissDisabled(busy)
        }
    }
}
