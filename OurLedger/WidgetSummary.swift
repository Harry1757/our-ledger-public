import Foundation
import WidgetKit

enum LedgerWidgetPublisher {
    static func publish(_ snapshot: LedgerSnapshot, month: String) {
        guard let data = summary(snapshot, month: month) else { return }
        do {
            try data.write()
            WidgetCenter.shared.reloadTimelines(ofKind: "LedgerSummaryWidget")
        } catch {
            NSLog("OurLedger: widget summary cache could not be saved")
        }
    }

    static func summary(_ snapshot: LedgerSnapshot, month: String, now: Date = Date()) -> LedgerWidgetData? {
        guard month == LedgerWidgetData.currentMonth(at: now) else { return nil }
        let actual = snapshot.entries.filter { $0.day.hasPrefix(month + "-") && ($0.kind == "expense" || $0.kind == "refund") }
        let shared = actual.filter { $0.scope == "shared" }
        let partner = snapshot.members.first { $0.id != snapshot.me }
        return LedgerWidgetData(
            month: month,
            sharedTotal: shared.reduce(0) { $0 + $1.signedAmount },
            personalTotal: actual.filter { $0.scope == "personal" && $0.owner == snapshot.me }
                .reduce(0) { $0 + $1.signedAmount },
            mySharedTotal: shared.filter { $0.payer == snapshot.me }.reduce(0) { $0 + $1.signedAmount },
            partnerSharedTotal: partner.map { member in
                shared.filter { $0.payer == member.id }.reduce(0) { $0 + $1.signedAmount }
            },
            updatedAt: now
        )
    }
}
