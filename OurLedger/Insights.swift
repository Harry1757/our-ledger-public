import SwiftUI
import Charts

struct InsightsView: View {
    @Environment(LedgerStore.self) private var store
    @State private var composing = false
    @AppStorage("ledgerDisplayScope") private var scope = "shared"
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            Group {
            if let view = store.snapshot {
                let summary = LedgerInsights(snapshot: view, scope: scope, month: store.month)
                let spending = summary.spending
                let scopeName = scope == "shared" ? "공용" : "개인"
                let hasHistory = summary.historyStats?.trend.contains { $0.amount != 0 } == true
                List {
                    Section {
                        MonthControl().listRowSeparator(.hidden)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(scope == "shared" ? "함께 쓴 생활비" : "내 개인 지출")
                                .font(.subheadline.weight(.medium)).foregroundStyle(LedgerTheme.muted)
                            Text(won(summary.total))
                                .font(.largeTitle.weight(.bold))
                                .monospacedDigit().foregroundStyle(LedgerTheme.ink)
                                .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                                .minimumScaleFactor(typeSize.isAccessibilitySize ? 1 : 0.75)
                                .fixedSize(horizontal: false, vertical: true)
                            if summary.entries.isEmpty {
                                Text("이번 달 \(scopeName) 기록이 없어요").font(.subheadline).foregroundStyle(LedgerTheme.muted)
                                    .accessibilityIdentifier("insightsEmptyState")
                                Button("첫 거래 기록하기") { composing = true }
                                    .buttonStyle(LedgerPrimaryButtonStyle())
                            }
                        }.padding(.vertical, 8).ledgerTourTarget(.insights).listRowSeparator(.hidden)
                    }.listRowBackground(LedgerTheme.background)
                    if !spending.isEmpty || hasHistory {
                        Section {
                            if let stats = summary.historyStats {
                                SpendingComparison(stats: stats)
                                    .padding(16).background(LedgerTheme.surface, in: RoundedRectangle(cornerRadius: 16))
                                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 0))
                                    .listRowSeparator(.hidden)
                            }
                            if summary.historyStats == nil {
                                Text("현재 월 개인 내역만 집계했어요. 전월 비교와 6개월 추이는 아직 확인할 수 없어요.")
                                    .font(.footnote).foregroundStyle(LedgerTheme.muted)
                                    .accessibilityIdentifier("personalInsightsHistoryUnavailable")
                            }
                        }
                    }
                    if !spending.isEmpty {
                        Section("카테고리별 지출") {
                            let categories = summary.byCategory.filter { group in spending.contains { $0.category == group.id } }
                            if categories.isEmpty {
                                Text("기록하면 분류별 금액을 여기서 볼 수 있어요.")
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(categories) { group in
                                    NavigationLink {
                                        EntryListView(title: store.month + " · " + group.name, entries: spending.filter { $0.category == group.id }, view: view)
                                    } label: {
                                        VStack(alignment: .leading, spacing: 10) {
                                            HStack(alignment: .firstTextBaseline) {
                                                Text(group.name).foregroundStyle(LedgerTheme.ink)
                                                Spacer(minLength: 12)
                                                Text(won(group.amount)).bold().monospacedDigit().foregroundStyle(LedgerTheme.ink)
                                            }.font(.subheadline)
                                            ProgressView(value: Double(max(group.amount, 0)),
                                                         total: Double(max(categories.map(\.amount).max() ?? 0, 1)))
                                                .tint(LedgerTheme.brand).accessibilityHidden(true)
                                        }.padding(.vertical, 8).frame(minHeight: 52)
                                    }.listRowSeparator(.hidden).accessibilityIdentifier("category-" + group.id)
                                }
                            }
                        }
                    }
                    if summary.entries.contains(where: { $0.kind == "income" }) {
                        Section("수입") {
                            let income = summary.entries.filter { $0.kind == "income" }
                            NavigationLink {
                                EntryListView(title: scope == "shared" ? "공용 수입" : "내 개인 수입", entries: income, view: view)
                            } label: {
                                LabeledContent(scope == "shared" ? "공용 수입" : "내 개인 수입", value: "+" + won(summary.incomeTotal))
                                    .monospacedDigit().frame(minHeight: 44)
                            }.listRowSeparator(.hidden).accessibilityIdentifier(scope == "shared" ? "sharedIncomeDetails" : "personalIncomeDetails")
                        }
                    }
                    if !spending.isEmpty {
                        Section("일별 \(scopeName) 지출") {
                            if typeSize < .xxxLarge {
                                Chart(summary.daily) { point in
                                    BarMark(x: .value("일", Int(point.day.suffix(2)) ?? 1), y: .value("금액", point.amount))
                                        .foregroundStyle(LedgerTheme.brand).cornerRadius(3)
                                }.chartXAxis { AxisMarks(values: [1, 5, 10, 15, 20, 25, 30]) }
                                    .frame(height: 160).accessibilityLabel("선택한 달의 일별 \(scopeName) 지출")
                            }
                            DisclosureGroup("날짜별 내역") {
                                ForEach(summary.daily.filter { point in spending.contains { $0.day == point.day } }) { point in
                                    NavigationLink {
                                        EntryListView(title: point.day + " · \(scopeName) 내역", entries: spending.filter { $0.day == point.day }, view: view)
                                    } label: {
                                        LabeledContent(String(point.day.suffix(5)).replacingOccurrences(of: "-", with: "."), value: won(point.amount))
                                            .monospacedDigit().frame(minHeight: 44)
                                    }.accessibilityIdentifier("dayEntries_" + point.day)
                                }
                            }
                        }
                    }
                    if let stats = summary.historyStats, !spending.isEmpty || hasHistory {
                        Section("최근 6개월 \(scopeName) 지출") {
                            if stats.trend.allSatisfy({ $0.amount == 0 }) {
                                Text("최근 6개월 순지출은 0원이에요.").foregroundStyle(LedgerTheme.muted)
                            } else if typeSize < .xxxLarge {
                                Chart(stats.trend) { point in
                                    BarMark(x: .value("월", String(point.month.suffix(2)) + "월"), y: .value("금액", point.amount))
                                        .foregroundStyle(point.month == store.month ? LedgerTheme.brand : LedgerTheme.brand.opacity(0.25)).cornerRadius(4)
                                }.frame(height: 160).accessibilityLabel("선택한 달까지 최근 6개월 \(scopeName) 지출")
                            }
                            DisclosureGroup("월별 금액") {
                                ForEach(stats.trend) { point in LabeledContent(point.month, value: won(point.amount)).font(.subheadline).monospacedDigit() }
                            }
                        }
                    }
                    if scope == "shared", !spending.isEmpty {
                        Section {
                            ForEach(view.stats.byMember) { member in LabeledContent(member.name, value: won(member.amount)).monospacedDigit() }
                        } header: {
                            Text("누가 결제했나요?")
                        } footer: {
                            Text("개인 돈으로 결제한 금액에서 환불을 뺐어요. 정산액과는 달라요.")
                        }
                    }
                    if let error = store.error { Section { ErrorNotice(message: error) } }
                }.listStyle(.insetGrouped).ledgerScreen().listSectionSpacing(16).ledgerRootScreen()
                    .refreshable { await store.refresh() }
                    .sheet(isPresented: $composing) { EntryForm(initialScope: scope) }
            } else {
                VStack(spacing: 16) {
                    if store.refreshing { ProgressView("통계를 불러오는 중…") }
                    else {
                        ContentUnavailableView("통계를 불러오지 못했어요", systemImage: "chart.bar",
                                               description: Text(store.error ?? "잠시 후 다시 확인해 주세요."))
                        Button("다시 불러오기") { Task { await store.refresh() } }
                    }
                }.ledgerScreen().ledgerRootScreen()
            }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                scopePicker
                    .padding(.horizontal, 20).padding(.vertical, 8)
                    .background(LedgerTheme.background)
            }
        }
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
                    .accessibilityIdentifier("insightsScope-" + value)
                    .accessibilityValue(scope == value ? "선택됨" : "선택 안 됨")
                    .accessibilityAddTraits(scope == value ? .isSelected : [])
            }
        }.padding(4).background(LedgerTheme.selectionTrack, in: RoundedRectangle(cornerRadius: 16))
            .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: scope)
            .sensoryFeedback(.selection, trigger: scope)
    }
}

struct SpendingComparison: View {
    let stats: LedgerStats
    var compact = false

    var body: some View {
        let hasPeriod = stats.comparisonTotal != nil && stats.comparisonPreviousTotal != nil
        let total = hasPeriod ? (stats.comparisonTotal ?? stats.total) : stats.total
        let previous = hasPeriod ? (stats.comparisonPreviousTotal ?? stats.previousTotal) : stats.previousTotal
        let difference = total - previous
        VStack(alignment: .leading, spacing: 8) {
            if hasPeriod, let day = stats.comparisonThroughDay {
                Text("각 월 1~\(day)일 비교").font(.subheadline.weight(.medium))
            } else {
                Text("월 전체 비교").font(.subheadline.weight(.medium))
            }
            Text(difference == 0 ? "지난달과 같아요" : "지난달보다 " + won(abs(difference)) + (difference > 0 ? " 더 썼어요" : " 덜 썼어요"))
                .font(.headline).monospacedDigit().foregroundStyle(LedgerTheme.ink)
            if !compact {
                LabeledContent("선택한 달 비교 금액", value: won(total)).monospacedDigit()
                LabeledContent("지난달 비교 금액", value: won(previous)).monospacedDigit()
                if !hasPeriod {
                    Text("월 전체 금액 기준이에요. 진행 중인 달은 지난달과 기록 기간이 다를 수 있어요.")
                        .font(.footnote)
                }
            }
        }.font(.subheadline).foregroundStyle(LedgerTheme.muted)
            .accessibilityIdentifier("spendingComparison")
    }
}

struct SettlementView: View {
    @Environment(LedgerStore.self) private var store
    @State private var confirming = false
    @State private var target: String?
    @State private var candidate: SettlementCandidate?
    @State private var busy = false
    @State private var error: String?
    @State private var confirmationRevision = ""
    @State private var confirmationMonth = ""
    @State private var confirmationAmount = 0
    @State private var confirmationCount = 0
    @State private var confirmationDirection = ""
    @State private var confirmationAction = "송금을 마쳤어요 · 완료 기록"
    @State private var confirmationUsesFund = false
    @State private var requestID = UUID().uuidString
    @State private var completionNotice: String?

    var body: some View {
        Group {
            if let view = store.snapshot {
                let pending = pendingEntries(view)
                List {
                    Section {
                        MonthControl().disabled(busy)
                        Text(view.household.mode == "pool" ? "공동자금 정산" : "공용 생활비 정산")
                            .font(.title3.bold())
                        Text(store.month + " · 이달 기록한 공용 생활비")
                            .font(.caption).foregroundStyle(LedgerTheme.muted).accessibilityIdentifier("settlementPeriod")
                        if view.members.count < 2 {
                            Text("두 사람이 연결되면 정산할 수 있어요.")
                            Button("상대 초대하기") { store.tab = 3 }.buttonStyle(LedgerPrimaryButtonStyle())
                        }
                    }.listRowSeparator(.hidden)
                    if let completionNotice, store.error != nil {
                        Section {
                            Label(completionNotice, systemImage: "checkmark.circle.fill").foregroundStyle(LedgerTheme.accent)
                            if store.error != nil {
                                Text("완료 기록은 저장됐어요. 목록만 다시 불러와 주세요.").font(.subheadline)
                                Button("목록 다시 불러오기") { Task { await store.refresh() } }.disabled(store.refreshing)
                            }
                        }.listRowSeparator(.hidden)
                    }
                    pastDue(view)
                    if view.household.mode == "separate" {
                        Section(view.history.isEmpty ? "남은 정산" : "추가 정산") {
                            if view.members.count == 2 && view.settlement.count > 0 {
                                payment(view, from: view.settlement.fromID, to: view.settlement.toID,
                                        amount: view.settlement.amount, count: view.settlement.count, memberID: nil)
                            } else {
                                Label(view.history.isEmpty ? "정산할 새 내역이 없어요" : "이달 정산을 마쳤어요", systemImage: "checkmark.circle")
                                    .foregroundStyle(LedgerTheme.muted)
                            }
                        }.listRowSeparator(.hidden)
                    } else {
                        Section("공동자금") {
                            LabeledContent("선택한 달 말 잔액", value: won(view.stats.fundBalance)).monospacedDigit()
                            Text("기록 기준 · 은행 잔액과 다를 수 있어요").font(.caption).foregroundStyle(LedgerTheme.muted)
                        }.listRowSeparator(.hidden)
                        ForEach(view.settlement.memberAmounts) { person in
                            let rows = pending.filter { $0.payer == person.id }
                            if !rows.isEmpty {
                                Section(person.name) {
                                    payment(view, from: person.amount >= 0 ? "fund" : person.id,
                                            to: person.amount >= 0 ? person.id : "fund",
                                            amount: abs(person.amount), count: rows.count, memberID: person.id)
                                }.listRowSeparator(.hidden)
                            }
                        }
                    }
                    if !pending.isEmpty {
                        Section("정산에 포함한 기록") {
                            NavigationLink {
                                EntryListView(title: store.month + " · 미정산 공용 내역", entries: pending, view: view)
                            } label: {
                                LabeledContent("공용 내역", value: "\(pending.count)건").frame(minHeight: 44)
                            }.accessibilityIdentifier("settlementPendingEntries")
                            if !view.inbox.isEmpty {
                                Button { store.tab = 1 } label: {
                                    Text("확인 전 알림 \(view.inbox.count)건 · 정산 제외").font(.subheadline)
                                }.frame(minHeight: 44)
                            }
                        }.listRowSeparator(.hidden)
                    }
                    if view.household.mode == "separate" { separateBasis(view) }
                    else {
                        Section {
                            DisclosureGroup("정산 계산 방식") {
                                Text("개인 돈으로 낸 공용 지출에서 환불·개인 계좌로 받은 공용 수입을 빼요. 공동 계좌 수입은 잔액에 바로 더해요.")
                                    .font(.footnote).foregroundStyle(LedgerTheme.muted)
                            }
                        }.listRowSeparator(.hidden)
                    }
                    if !view.history.isEmpty {
                        Section("완료한 정산") {
                            ForEach(view.history) { record in
                                VStack(alignment: .leading, spacing: 8) {
                                    Label(record.month + " 정산 완료", systemImage: "checkmark.circle.fill")
                                        .font(.headline).foregroundStyle(LedgerTheme.accent)
                                    Text(won(record.amount)).font(.title3.bold()).monospacedDigit()
                                    Text(record.amount == 0 ? "송금 없이 마감" : view.memberName(record.fromID) + " → " + view.memberName(record.toID))
                                    Text(String(record.date.prefix(10)) + " · \(record.count)개 내역")
                                        .font(.caption).foregroundStyle(LedgerTheme.muted)
                                }.padding(.vertical, 8)
                            }
                            Text("직접 확인하고 완료로 기록한 내역이에요.").font(.caption).foregroundStyle(LedgerTheme.muted)
                        }.listRowSeparator(.hidden)
                    }
                    if let error { Section { ErrorNotice(message: error) } }
                    if let message = store.error { Section { ErrorNotice(message: message) } }
                }.listStyle(.insetGrouped).ledgerScreen().listSectionSpacing(16)
                    .contentMargins(.top, 8, for: .scrollContent)
                    .disabled(busy)
                    .refreshable { if !busy { await store.refresh() } }
            } else { MonthLoadingView() }
        }
        .navigationTitle("정산").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
        .sheet(item: $candidate) { SettlementConfirmationView(candidate: $0) }
        .onChange(of: store.month) { _, _ in completionNotice = nil }
        .confirmationDialog(confirmationAmount == 0 ? "송금 없이 마감할까요?" : "실제로 주고받은 돈이 맞나요?", isPresented: $confirming, titleVisibility: .visible) {
            Button(confirmationAmount == 0 ? "송금 없이 완료 기록" : confirmationAction) { Task { await complete() } }
            Button("취소", role: .cancel) { }
        } message: {
            Text(confirmationMonth + " · \(confirmationCount)건 · " + won(confirmationAmount) + "\n" + confirmationDirection + "\n" + (confirmationAmount == 0 ? "확인한 내역을 완료로 기록해요." : (confirmationUsesFund ? "공동자금 계좌와 실제로 주고받은 금액을 확인해 주세요. " : "은행 앱에서 금액과 받는 사람을 확인해 주세요. ") + "일부만 보냈다면 남은 금액까지 확인한 뒤 완료해 주세요."))
        }
        .overlay { if busy { ProgressView("정산 기록 중…").padding(20).background(LedgerTheme.surface, in: RoundedRectangle(cornerRadius: 16)) } }
        .interactiveDismissDisabled(busy)
    }

    @ViewBuilder private func pastDue(_ view: LedgerSnapshot) -> some View {
        let todayMonth = String(dayString(Date()).prefix(7))
        let dues = (view.pendingSettlements ?? []).filter { $0.month < todayMonth }.sorted { $0.id < $1.id }
        if !dues.isEmpty {
            Section("지난달 미정산") {
                ForEach(dues) { due in
                    Button { store.month = due.month } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(due.month + " · 미정산").font(.headline).foregroundStyle(LedgerTheme.accent)
                                Text(settlementDirection(due.fromID, due.toID, me: view.me, amount: due.amount, view: view))
                                    .font(.subheadline).foregroundStyle(LedgerTheme.muted)
                                Text(won(due.amount)).font(.headline).monospacedDigit().foregroundStyle(LedgerTheme.ink)
                            }
                            Spacer(minLength: 8)
                            if store.month == due.month { Text("보는 중").font(.caption).foregroundStyle(LedgerTheme.muted) }
                            else { Image(systemName: "chevron.right").foregroundStyle(LedgerTheme.muted) }
                        }.frame(maxWidth: .infinity, minHeight: 44).padding(.vertical, 6).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(busy || store.refreshing || store.month == due.month)
                        .accessibilityIdentifier("overdueMonth-" + due.month)
                }
            }.listRowSeparator(.hidden)
        }
    }

    @ViewBuilder private func payment(_ view: LedgerSnapshot, from: String, to: String, amount: Int, count: Int, memberID: String?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(settlementDirection(from, to, me: view.me, amount: amount, view: view)).font(.headline)
            Text(won(amount)).font(.largeTitle.bold()).monospacedDigit().fixedSize(horizontal: false, vertical: true)
            if amount > 0 {
                Text(view.memberName(from) + " → " + view.memberName(to)).font(.subheadline).foregroundStyle(LedgerTheme.muted)
                SettlementCopyView(amount: amount, month: store.month,
                                   recipient: view.members.first { $0.id == to }, recipientIsMe: to == view.me,
                                   toFund: to == "fund")
            }
            let candidates = (view.settlementCandidates ?? []).filter { $0.due.month == store.month && $0.due.memberID == memberID }
            ForEach(candidates) { match in
                Button { candidate = match } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("정산금액과 같은 알림이 있어요", systemImage: "arrow.left.arrow.right")
                        Text("정산으로 확인").fontWeight(.semibold)
                    }.font(.subheadline).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .padding(12).background(LedgerTheme.accentSoft, in: RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(.plain).disabled(busy || store.refreshing || store.error != nil)
                    .accessibilityIdentifier("settlementCandidate-" + match.id)
            }
            Button(amount == 0 ? "송금 없이 마감" : to == view.me ? "입금을 확인했어요" : from == view.me ? "송금을 마쳤어요" : "주고받은 내역을 확인했어요") {
                prepare(view, target: memberID, amount: amount, count: count, from: from, to: to)
            }.buttonStyle(.bordered).frame(minHeight: 44)
                .disabled(view.members.count < 2 || busy || store.refreshing || store.error != nil)
                .accessibilityIdentifier(memberID.map { "completeSettlement-" + $0 } ?? "completeSettlement")
        }.padding(.vertical, 8)
    }

    private func pendingEntries(_ view: LedgerSnapshot) -> [Entry] {
        view.entries.filter {
            $0.scope == "shared" && (["expense", "refund"].contains($0.kind) || ($0.kind == "income" && $0.funding == "personal")) && $0.settlement == nil
                && (view.household.mode == "separate" || $0.funding == "personal")
        }
    }
    @ViewBuilder private func separateBasis(_ view: LedgerSnapshot) -> some View {
        let total = view.settlement.memberAmounts.reduce(0) { $0 + $1.amount }
        Section("월 전체 계산 근거") {
            DisclosureGroup("자세히") {
                LabeledContent("공용 순부담액", value: won(total)).font(.headline).monospacedDigit()
                Text("지출에서 환불·공용 수입을 뺀 금액이에요. 음수면 함께 쓸 돈이 남은 상태예요. 완료한 내역도 포함해요.").font(.footnote).foregroundStyle(LedgerTheme.muted)
                ForEach(Array(view.members.enumerated()), id: \.element.id) { index, member in
                    let paid = view.settlement.memberAmounts.first { $0.id == member.id }?.amount ?? 0
                    let adjustment = view.history.filter { $0.kind == "separate" }.reduce(0) { result, record in
                        result + (record.toID == member.id ? record.amount : record.fromID == member.id ? -record.amount : 0)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(member.name).font(.headline)
                        LabeledContent("월 지출 − 환불 − 공용 수입", value: won(paid)).monospacedDigit()
                        if view.members.count == 2 {
                            LabeledContent("반반 나눌 순부담액", value: won(halfShare(total: total, first: index == 0))).monospacedDigit()
                        }
                        LabeledContent("완료 정산 순수령", value: won(adjustment)).monospacedDigit()
                    }.padding(.vertical, 6)
                }
                Text("홀수 원은 먼저 참여한 사람에게 1원 더 배분해요. 완료 정산 순수령은 받은 돈에서 보낸 돈을 뺀 값이며, 남은 정산에 이미 반영돼요.")
                    .font(.footnote).foregroundStyle(LedgerTheme.muted)
            }
        }
    }

    private func halfShare(total: Int, first: Bool) -> Int {
        // Swift truncates negative division; the server rounds the first member's share upward.
        let firstShare = total / 2 + (total % 2 > 0 ? 1 : 0)
        assert(firstShare >= total - firstShare && firstShare - (total - firstShare) <= 1)
        return first ? firstShare : total - firstShare
    }

    private func prepare(_ view: LedgerSnapshot, target: String?, amount: Int, count: Int, from: String, to: String) {
        guard !busy && !store.refreshing && store.error == nil else { return }
        if confirmationMonth != store.month || confirmationRevision != view.settlement.revision || self.target != target {
            requestID = UUID().uuidString
        }
        self.target = target
        confirmationRevision = view.settlement.revision
        confirmationMonth = store.month
        confirmationAmount = amount
        confirmationCount = count
        confirmationDirection = amount == 0 ? "송금 없이 마감" : view.memberName(from) + " → " + view.memberName(to)
        confirmationUsesFund = from == "fund" || to == "fund"
        confirmationAction = to == view.me ? "입금을 확인했어요 · 완료 기록" : from == view.me ? "송금을 마쳤어요 · 완료 기록" : "주고받은 내역을 확인했어요 · 완료 기록"
        confirming = true
    }

    private func complete() async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        var body: [String: Any] = ["month": confirmationMonth, "revision": confirmationRevision, "requestID": requestID]
        if let target { body["memberID"] = target }
        do {
            try await store.mutate("/settle", body: body)
            completionNotice = confirmationMonth + " 정산 완료"
        } catch { self.error = error.localizedDescription }
    }
}

private func settlementDirection(_ from: String, _ to: String, me: String, amount: Int, view: LedgerSnapshot) -> String {
    if amount == 0 { return "주고받을 금액이 없어요" }
    if from == me { return to == "fund" ? "공동자금으로 돌려줄 돈" : "내가 보낼 돈" }
    if to == me { return from == "fund" ? "공동자금에서 돌려받을 돈" : "내가 받을 돈" }
    return view.memberName(from) + " → " + view.memberName(to)
}

private struct SettlementCopyView: View {
    @Environment(LedgerStore.self) private var store
    let amount: Int
    let month: String
    let recipient: Member?
    let recipientIsMe: Bool
    let toFund: Bool
    @State private var feedback: String?

    private var hasAccount: Bool {
        guard let recipient else { return false }
        return !recipient.bank.isEmpty && !recipient.account.isEmpty && !recipient.holder.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            copyRow("금액", value: won(amount), copiedValue: String(amount), id: "copySettlementAmount")
            if let recipient, hasAccount {
                copyRow("은행", value: recipient.bank, id: "copySettlementBank")
                copyRow("계좌번호", value: recipient.account, id: "copySettlementAccount")
                copyRow("예금주", value: recipient.holder, id: "copySettlementHolder")
                Button {
                    copy(month + " 생활비 정산\n금액 " + won(amount) + "\n은행 " + recipient.bank + "\n계좌번호 " + recipient.account + "\n예금주 " + recipient.holder, label: "송금 정보")
                } label: {
                    Label(recipientIsMe ? "받을 계좌 정보 복사" : "송금 정보 복사", systemImage: "doc.on.doc")
                }.buttonStyle(LedgerPrimaryButtonStyle()).padding(.top, 8).accessibilityIdentifier("copySettlementAll")
            } else {
                Text(toFund ? "공동 계좌는 은행 앱에서 확인해 주세요." : recipientIsMe ? "받을 계좌를 먼저 등록해 주세요." : "상대가 받을 계좌를 등록해야 해요.")
                    .font(.subheadline).foregroundStyle(LedgerTheme.muted).padding(.vertical, 8)
                if recipientIsMe {
                    Button("계좌 등록하기") { store.tab = 3 }.frame(minHeight: 44)
                }
            }
            if let feedback {
                Label(feedback, systemImage: "checkmark").font(.caption).foregroundStyle(LedgerTheme.accent)
                    .accessibilityIdentifier("settlementCopyFeedback").padding(.top, 6)
            }
        }
    }

    private func copyRow(_ label: String, value: String, copiedValue: String? = nil, id: String) -> some View {
        Button { copy(copiedValue ?? value, label: label) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(label).font(.caption).foregroundStyle(LedgerTheme.muted)
                    Text(value).font(.body.weight(.medium)).monospacedDigit().foregroundStyle(LedgerTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Image(systemName: "doc.on.doc").foregroundStyle(LedgerTheme.accent)
            }.frame(minHeight: 44).padding(.vertical, 4).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(label + " " + value + " 복사").accessibilityIdentifier(id)
    }

    private func copy(_ value: String, label: String) {
        UIPasteboard.general.string = value
        feedback = label + " 복사했어요"
    }
}

struct SettlementConfirmationView: View {
    @Environment(LedgerStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let candidate: SettlementCandidate
    @State private var requestID = UUID().uuidString
    @State private var busy = false
    @State private var completed = false
    @State private var fundConfirmed = false
    private var usesFund: Bool { candidate.due.fromID == "fund" || candidate.due.toID == "fund" }
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if completed {
                    Section {
                        Label(candidate.due.month + " 정산 완료", systemImage: "checkmark.circle.fill")
                            .font(.title2.bold()).foregroundStyle(LedgerTheme.accent)
                            .accessibilityIdentifier("settlementCandidateDone")
                        Text(won(candidate.due.amount)).font(.largeTitle.bold()).monospacedDigit()
                        Text("정산으로 기록했어요. 이 알림은 수입·지출로 다시 기록하지 않아요.")
                            .font(.subheadline).foregroundStyle(LedgerTheme.muted)
                        if store.error != nil {
                            Text("완료 기록은 저장됐어요. 목록만 다시 불러와 주세요.").font(.subheadline)
                            Button("목록 다시 불러오기") { Task { await store.refresh() } }.disabled(store.refreshing)
                        }
                        Button("확인") { dismiss() }.buttonStyle(LedgerPrimaryButtonStyle())
                    }.listRowSeparator(.hidden)
                } else if let view = store.snapshot {
                    let item = view.inbox.first { $0.id == candidate.importID && $0.owner == view.me }
                    Section {
                        Text(candidate.due.month + " 정산으로 처리할까요?").font(.title2.bold())
                        Text(won(candidate.due.amount)).font(.largeTitle.bold()).monospacedDigit()
                            .fixedSize(horizontal: false, vertical: true)
                        Text(view.memberName(candidate.due.fromID) + " → " + view.memberName(candidate.due.toID))
                            .font(.headline).accessibilityIdentifier("settlementCandidateDirection")
                        Text("실제로 주고받은 내역인지 확인해 주세요.").font(.subheadline).foregroundStyle(LedgerTheme.muted)
                    }.listRowSeparator(.hidden)
                    if let item {
                        Section("내가 받은 알림") {
                            if let time = item.time ?? item.receivedAt {
                                Text((item.time == nil ? "수신 " : "거래 ") + (ISO8601DateFormatter().date(from: time)?.formatted(date: .abbreviated, time: .shortened) ?? time))
                                    .font(.caption).foregroundStyle(LedgerTheme.muted)
                            }
                            Text(item.raw).font(.subheadline).textSelection(.enabled)
                                .accessibilityIdentifier("settlementCandidateRaw")
                            Text("금액이 같아도 다른 거래일 수 있어요. 상대와 입출금 방향을 확인해 주세요.")
                                .font(.caption).foregroundStyle(LedgerTheme.muted)
                        }.listRowSeparator(.hidden)
                    } else {
                        Section { Text("알림 상태가 바뀌었어요. 확인함에서 다시 확인해 주세요.") }
                    }
                    if usesFund {
                        Section {
                            Toggle("공동자금 계좌와 주고받은 내역을 확인했어요", isOn: $fundConfirmed)
                                .disabled(busy).accessibilityIdentifier("confirmSettlementFund")
                            Text("이 앱은 공동 계좌를 조회하지 않아요. 알림의 계좌와 실제 입출금을 확인해 주세요.")
                                .font(.caption).foregroundStyle(LedgerTheme.muted)
                        }.listRowSeparator(.hidden)
                    }
                    if let message = store.error {
                        Section {
                            ErrorNotice(message: message)
                            Button("다시 불러오기") { Task { await store.refresh() } }.disabled(busy || store.refreshing)
                        }
                    }
                    if let error { Section { ErrorNotice(message: error) } }
                    Section {
                        Button { Task { await complete() } } label: {
                            if busy { ProgressView("정산 기록 중…") }
                            else { Text("정산 완료로 기록") }
                        }.buttonStyle(LedgerPrimaryButtonStyle()).disabled(busy || store.refreshing || store.error != nil || item == nil || (usesFund && !fundConfirmed))
                            .accessibilityIdentifier("confirmSettlementCandidate")
                        Button("정산이 아니에요") { dismiss() }.frame(maxWidth: .infinity, minHeight: 44)
                            .disabled(busy)
                    }.listRowSeparator(.hidden)
                } else {
                    Section {
                        Text("정산 내역을 다시 불러와 주세요.")
                        Button("다시 불러오기") { Task { await store.refresh() } }.disabled(store.refreshing)
                    }
                }
            }.listStyle(.insetGrouped).ledgerScreen().listSectionSpacing(20)
                .navigationTitle("정산 확인").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() }.disabled(busy) } }
                .interactiveDismissDisabled(busy)
        }.preferredColorScheme(.light)
    }

    private func complete() async {
        guard !busy && !completed && !store.refreshing && store.error == nil && (!usesFund || fundConfirmed) else { return }
        busy = true; error = nil
        defer { busy = false }
        var body: [String: Any] = ["month": candidate.due.month, "revision": candidate.due.revision,
                                   "importID": candidate.importID, "requestID": requestID]
        if let memberID = candidate.due.memberID { body["memberID"] = memberID }
        do {
            try await store.mutate("/settle", body: body)
            completed = true
        } catch { self.error = error.localizedDescription }
    }
}
