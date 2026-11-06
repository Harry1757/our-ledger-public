import Foundation
@main struct CalendarCheck {
    static func main() throws {
        let feb = ledgerMonthDays("2028-02")
        precondition(feb.compactMap { $0 }.count == 29)
        precondition(feb.firstIndex { $0 == "2028-02-01" } == 2)
        precondition(feb.count % 7 == 0)
        let month = ledgerMonthDays("2026-10")
        precondition(month.firstIndex { $0 == "2026-10-01" } == 4)
        precondition(month.compactMap { $0 }.last == "2026-10-31")
        precondition(ledgerMonthDays("bad-month").isEmpty)
        precondition(compactCalendarWon(3_200) == "3,200")
        precondition(compactCalendarWon(-10_000).contains("1만"))
        precondition(compactCalendarWon(100_000_000).contains("1억"))
        let mixed = CalendarDayTotals(entries: [entry("income", 50_123), entry("expense", 8_400)])
        precondition(mixed.income == 50_123 && mixed.spending == 8_400)
        precondition(mixed.compactIncome == "+5만" && mixed.compactSpending == "−8,400")
        precondition(mixed.accessibilitySummary == "수입 +50,123원, 1건, 순지출 −8,400원, 지출·환불 1건",
                     "VoiceOver must read exact amounts even when calendar cells round them")

        let partial = CalendarDayTotals(entries: [entry("expense", 8_400), entry("refund", 1_400), entry("income", 50_000)])
        precondition(partial.spending == 7_000 && partial.income == 50_000)
        precondition(partial.compactSpending == "−7,000" && partial.spendingCount == 2)
        let refunded = CalendarDayTotals(entries: [entry("expense", 8_400), entry("refund", 8_400)])
        precondition(refunded.spending == 0 && refunded.compactSpending == "0")
        precondition(refunded.spendingLabel == "순지출 0원" && refunded.compactIncome == "—")
        let refundOnly = CalendarDayTotals(entries: [entry("refund", 12_345)])
        precondition(refundOnly.income == 0 && refundOnly.incomeCount == 0)
        precondition(refundOnly.compactSpending == "환+1.2만" && refundOnly.compactIncome == "—")
        precondition(refundOnly.spendingLabel == "환불 초과 +12,345원")
        let excess = CalendarDayTotals(entries: [entry("expense", 1_000), entry("refund", 3_000), entry("income", 500)])
        precondition(excess.compactSpending == "환+2,000" && excess.compactIncome == "+500",
                     "Refund excess stays on the spending line, separate from income")

        let empty = CalendarDayTotals(entries: [])
        precondition(empty.compactIncome == "—" && empty.compactSpending == "—")
        precondition(empty.incomeLabel == "수입 0원" && empty.spendingLabel == "순지출 0원")
        let zero = CalendarDayTotals(entries: [entry("income", 0), entry("expense", 0)])
        precondition(zero.compactIncome == "0" && zero.compactSpending == "0")
        let incomeOnly = CalendarDayTotals(entries: [entry("income", 500)])
        precondition(incomeOnly.compactIncome == "+500" && incomeOnly.compactSpending == "—")
        let deposit = entry("deposit", 900_000)
        let depositOnly = CalendarDayTotals(entries: [deposit])
        precondition(deposit.signedAmount == 900_000, "Preserve the model's deposit semantics")
        precondition(depositOnly.spendingCount == 0 && depositOnly.incomeCount == 0)
        precondition(depositOnly.spending == 0 && depositOnly.income == 0)
        let withDeposit = CalendarDayTotals(entries: [deposit, entry("income", 500), entry("expense", 700)])
        precondition(withDeposit.income == 500 && withDeposit.spending == 700)

        // Dashboard owns privacy filtering; the calendar only receives its scoped entries.
        let scoped = [entry("income", 500, scope: "personal"), entry("expense", 300, scope: "personal"),
                      entry("refund", 100, scope: "personal")]
        let personal = CalendarDayTotals(entries: scoped)
        precondition(personal.income == 500 && personal.spending == 200)

        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let old = try JSONDecoder().decode(LedgerSnapshot.self, from: data)
        precondition(old.recurringPayments == nil)
        print("PASS: calendar placement, signed income/expense, refunds, zero, deposits, scoped totals, exact accessibility amounts and legacy compatibility")
    }

    static func entry(_ kind: String, _ amount: Int, scope: String = "shared") -> Entry {
        Entry(id: kind, owner: "test-a", payer: "test-a", scope: scope, kind: kind,
              funding: kind == "deposit" ? "fund" : "personal", note: "검증", category: "other",
              day: "2026-10-26", amount: amount, settlement: nil, importID: nil, refundOf: nil,
              recurringID: nil, recurringMonth: nil)
    }
}
