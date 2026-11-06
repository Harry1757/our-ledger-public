import SwiftUI
import WidgetKit

struct LedgerWidgetEntry: TimelineEntry {
    let date: Date
    let data: LedgerWidgetData?
}

private struct LedgerWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> LedgerWidgetEntry {
        LedgerWidgetEntry(date: Date(), data: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (LedgerWidgetEntry) -> Void) {
        let now = Date()
        completion(LedgerWidgetEntry(date: now, data: LedgerWidgetData.read(at: now)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LedgerWidgetEntry>) -> Void) {
        let now = Date()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let nextMonth = calendar.dateInterval(of: .month, for: now)!.end
        // Schedule the empty state at rollover even if WidgetKit delays the next refresh.
        let entries = [LedgerWidgetEntry(date: now, data: LedgerWidgetData.read(at: now)),
                       LedgerWidgetEntry(date: nextMonth, data: nil)]
        completion(Timeline(entries: entries, policy: .after(min(now.addingTimeInterval(900), nextMonth))))
    }
}

struct LedgerWidgetView: View {
    let entry: LedgerWidgetEntry
    @Environment(\.widgetFamily) private var family
    private let accent = Color(red: 204.0 / 255, green: 73.0 / 255, blue: 0)
    private let ink = Color(red: 33.0 / 255, green: 33.0 / 255, blue: 36.0 / 255)
    private let muted = Color(red: 107.0 / 255, green: 112.0 / 255, blue: 117.0 / 255)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("우리 가계부").font(.caption.weight(.semibold))
                Spacer(minLength: 2)
                Text(monthLabel).font(.caption.weight(.semibold)).foregroundStyle(muted)
            }
            if let data = entry.data {
                if family == .systemSmall {
                    amount("공용 지출", value: data.sharedTotal, headline: true)
                    amount("내 개인 지출", value: data.personalTotal, headline: false)
                } else {
                    HStack(alignment: .top, spacing: 12) {
                        amount("공용 지출", value: data.sharedTotal, headline: true)
                        amount("내 개인 지출", value: data.personalTotal, headline: false)
                    }
                    Rectangle().fill(Color(red: 234.0 / 255, green: 235.0 / 255, blue: 238.0 / 255)).frame(height: 1)
                    HStack(alignment: .top, spacing: 12) {
                        amount("내 공용 결제", value: data.mySharedTotal, headline: false)
                        if data.partnerSharedTotal != nil {
                            amount("상대 공용 결제", value: data.partnerSharedTotal, headline: false)
                        } else {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("혼자 사용 중").font(.caption2.weight(.medium)).foregroundStyle(muted)
                                Text("앱에서 상대 초대").font(.caption.weight(.medium))
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                Spacer(minLength: 0)
                Text(data.updatedAt.formatted(Date.FormatStyle(
                    date: .omitted, time: .shortened, locale: Locale(identifier: "ko_KR"),
                    timeZone: TimeZone(identifier: "Asia/Seoul")!).month(.twoDigits).day(.twoDigits)) + " 기준")
                    .font(.caption2).foregroundStyle(muted).lineLimit(1)
            } else {
                Spacer(minLength: 0)
                Text("이번 달 기록을\n불러와 주세요").font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text("앱을 열면 업데이트돼요").font(.caption).foregroundStyle(muted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
        .foregroundStyle(ink)
        .containerBackground(for: .widget) { Color.white }
        .environment(\.colorScheme, .light)
        .widgetURL(URL(string: "ourledger://home"))
    }

    private var monthLabel: String {
        let month = entry.data?.month ?? LedgerWidgetData.currentMonth(at: entry.date)
        return (Int(month.suffix(2)).map(String.init) ?? "") + "월"
    }

    private func amount(_ label: String, value: Int?, headline: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption2.weight(.medium)).foregroundStyle(muted).lineLimit(1)
            Text(value.map { $0.formatted(.number.locale(Locale(identifier: "ko_KR"))) + "원" } ?? "초대 전")
                .font(headline ? .title2.weight(.bold) : .body.weight(.semibold))
                .monospacedDigit().foregroundStyle(headline ? accent : ink)
                .lineLimit(1).minimumScaleFactor(0.65).privacySensitive()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

@main
struct LedgerWidgetBundle: WidgetBundle {
    var body: some Widget {
        LedgerSummaryWidget()
        PaymentActivityWidget()
    }
}

struct LedgerSummaryWidget: Widget {
    let kind = "LedgerSummaryWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LedgerWidgetProvider()) { entry in
            LedgerWidgetView(entry: entry)
        }
        .configurationDisplayName("이번 달 가계부")
        .description("공용·개인 지출 요약. 중간 크기에서 나와 상대의 공용 결제도 확인해요.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
