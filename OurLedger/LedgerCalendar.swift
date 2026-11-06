import Foundation

struct CalendarDayTotals {
    let spending, income, spendingCount, incomeCount: Int

    init(entries: [Entry]) {
        let outgoings = entries.filter { ["expense", "refund"].contains($0.kind) }
        let receipts = entries.filter { $0.kind == "income" }
        spending = outgoings.reduce(0) { $0 + $1.signedAmount }
        income = receipts.reduce(0) { $0 + $1.amount }
        spendingCount = outgoings.count
        incomeCount = receipts.count
    }

    var compactIncome: String { incomeCount == 0 ? "—" : (income > 0 ? "+" : "") + compactCalendarWon(income) }
    var compactSpending: String {
        guard spendingCount > 0 else { return "—" }
        return (spending < 0 ? "환+" : spending > 0 ? "−" : "") + compactCalendarWon(abs(spending))
    }
    var incomeLabel: String { "수입 " + (income > 0 ? "+" : "") + won(income) }
    var spendingLabel: String {
        (spending < 0 ? "환불 초과 +" : spending > 0 ? "순지출 −" : "순지출 ") + won(abs(spending))
    }
    var accessibilitySummary: String {
        incomeLabel + ", \(incomeCount)건, " + spendingLabel + ", 지출·환불 \(spendingCount)건"
    }
}

#if os(iOS)
import SwiftUI

struct LedgerCalendar: View {
    let month: String
    let entries: [Entry]
    @Binding var selectedDay: String?
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let groups = Dictionary(grouping: entries.filter { ["expense", "refund", "income"].contains($0.kind) }, by: \.day)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("거래 달력").font(.headline).foregroundStyle(LedgerTheme.ink)
                Spacer()
                if selectedDay != nil {
                    Button("월 전체") { selectedDay = nil }.font(.subheadline.weight(.semibold)).frame(minWidth: 64, minHeight: 44).accessibilityIdentifier("calendarAllDays")
                }
            }.frame(minHeight: 44)
                .anchorPreference(key: LedgerTourTargetPreferenceKey.self, value: .bounds) { [.calendar: $0] }
            if typeSize >= .xxxLarge {
                if groups.isEmpty { Text("아직 기록한 거래가 없어요.").foregroundStyle(LedgerTheme.muted) }
                ForEach(groups.keys.sorted(), id: \.self) { day in
                    let totals = CalendarDayTotals(entries: groups[day] ?? [])
                    Button { selectedDay = selectedDay == day ? nil : day } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(parseDay(day), format: .dateTime.month().day().weekday())
                            Text(totals.incomeLabel).monospacedDigit().foregroundStyle(LedgerTheme.income)
                            Text(totals.spendingLabel).monospacedDigit().foregroundStyle(LedgerTheme.expense)
                        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .padding(12)
                            .foregroundStyle(selectedDay == day ? LedgerTheme.accent : LedgerTheme.ink)
                            .background {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(selectedDay == day ? LedgerTheme.accentSoft : LedgerTheme.surface)
                                    .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: selectedDay == day)
                            }
                    }.buttonStyle(.plain).accessibilityIdentifier("calendar-" + day)
                        .accessibilityLabel(day + ", " + totals.accessibilitySummary)
                        .accessibilityAddTraits(selectedDay == day ? .isSelected : [])
                        .accessibilityHint(selectedDay == day ? "선택을 해제하고 월 전체 내역 보기" : "이 날짜의 내역 보기")
                }
            } else {
                let days = ledgerMonthDays(month)
                VStack(spacing: 4) {
                    HStack(spacing: 2) {
                        ForEach(["일", "월", "화", "수", "목", "금", "토"], id: \.self) { name in
                            Text(name).font(.caption).foregroundStyle(LedgerTheme.muted).frame(minWidth: 0, maxWidth: .infinity)
                        }
                    }
                    // Eager rows keep this small calendar's height stable inside the native List.
                    ForEach(0..<(days.count / 7), id: \.self) { week in
                        HStack(spacing: 2) {
                            ForEach(0..<7, id: \.self) { weekday in
                                if let day = days[week * 7 + weekday] {
                                    CalendarDayCell(day: day, totals: CalendarDayTotals(entries: groups[day] ?? []), selected: selectedDay == day) {
                                        selectedDay = selectedDay == day ? nil : day
                                    }.frame(minWidth: 0, maxWidth: .infinity)
                                } else { Color.clear.frame(minWidth: 0, maxWidth: .infinity, minHeight: 64).accessibilityHidden(true) }
                            }
                        }
                    }
                }
            }
            if let selectedDay {
                let totals = CalendarDayTotals(entries: groups[selectedDay] ?? [])
                VStack(alignment: .leading, spacing: 6) {
                    Text(parseDay(selectedDay), format: .dateTime.month().day().weekday())
                        .font(.subheadline).foregroundStyle(LedgerTheme.muted)
                    Text(totals.incomeLabel)
                        .font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(LedgerTheme.income)
                    Text(totals.spendingLabel)
                        .font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(LedgerTheme.expense)
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12).background(LedgerTheme.accentSoft, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(selectedDay + ", " + totals.accessibilitySummary)
            }
            let legendLayout = typeSize >= .xxxLarge
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(spacing: 12))
            legendLayout {
                Label("수입", systemImage: "plus").foregroundStyle(LedgerTheme.income)
                Label("지출", systemImage: "minus").foregroundStyle(LedgerTheme.expense)
                if groups.values.contains(where: { CalendarDayTotals(entries: $0).spending < 0 }) {
                    Label { Text("환불") } icon: { Text("환+") }
                        .foregroundStyle(LedgerTheme.expense)
                }
            }.font(.caption)
            if entries.contains(where: { $0.kind == "refund" }) {
                Text("지출은 환불을 뺀 금액이에요.").font(.caption).foregroundStyle(LedgerTheme.muted)
            }
        }
    }
}

private struct CalendarDayCell: View {
    let day: String
    let totals: CalendarDayTotals
    let selected: Bool
    let choose: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var today: Bool { day == dayString(Date()) }
    private var foreground: Color { selected ? LedgerTheme.accent : LedgerTheme.ink }
    private var accessibilitySummary: String {
        day + (today ? " 오늘, " : ", ") + totals.accessibilitySummary
    }
    var body: some View {
        Button(action: choose) { dayContent }
            .buttonStyle(.plain).accessibilityIdentifier("calendar-" + day)
            .accessibilityLabel(Text(accessibilitySummary))
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityHint(Text(selected ? "선택을 해제하고 월 전체 내역 보기" : "이 날짜의 내역 보기"))
    }
    private var dayContent: some View {
        VStack(spacing: 4) {
            Text(String(Int(day.suffix(2)) ?? 0)).font(.subheadline).fontWeight(today ? .bold : .medium)
            Text(verbatim: totals.compactIncome).font(.caption2.weight(.semibold))
                .foregroundStyle(totals.incomeCount == 0 ? LedgerTheme.muted : LedgerTheme.income)
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                .opacity(totals.incomeCount == 0 ? 0 : 1)
                .accessibilityHidden(totals.incomeCount == 0)
            Text(verbatim: totals.compactSpending).font(.caption2.weight(.semibold))
                .foregroundStyle(totals.spendingCount == 0 ? LedgerTheme.muted : LedgerTheme.expense)
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                .opacity(totals.spendingCount == 0 ? 0 : 1)
                .accessibilityHidden(totals.spendingCount == 0)
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 64).foregroundStyle(foreground)
        .contentShape(Rectangle())
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(selected ? LedgerTheme.accentSoft : Color.clear)
                .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: selected)
        }
        .overlay { if today && !selected { RoundedRectangle(cornerRadius: 10).stroke(LedgerTheme.accent, lineWidth: 1) } }
    }
}
#endif
