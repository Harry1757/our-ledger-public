import ActivityKit
import Foundation
import SwiftUI
import WidgetKit

private let paymentAccent = Color(red: 204.0 / 255, green: 73.0 / 255, blue: 0)

struct PaymentActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PaymentActivityAttributes.self) { context in
            PaymentActivityCard(context: context)
                .padding(12)
                .foregroundStyle(Color(red: 33.0 / 255, green: 33.0 / 255, blue: 36.0 / 255))
                .background(Color.white)
                .environment(\.colorScheme, .light)
                .activityBackgroundTint(.white)
                .activitySystemActionForegroundColor(paymentAccent)
                .widgetURL(context.attributes.paymentURL())
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("거래 확인", systemImage: "creditcard.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(paymentAccent)
                        .lineLimit(1)
                        .padding(.leading, 12)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("우리 가계부").font(.caption).foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.trailing, 12)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    PaymentActivityCard(context: context, island: true)
                        .foregroundStyle(.white)
                        .padding(.top, 4)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                }
            } compactLeading: {
                Image(systemName: "creditcard.fill")
                    .foregroundStyle(paymentAccent)
                    .accessibilityLabel("우리 가계부 결제 확인")
            } compactTrailing: {
                PaymentActivityAmount(amount: context.state.amount, compact: true)
                    .foregroundStyle(.white)
            } minimal: {
                Image(systemName: "creditcard.fill")
                    .foregroundStyle(paymentAccent)
                    .accessibilityLabel("우리 가계부, \(PaymentActivityAmount.label(context.state.amount)) 결제 확인")
            }
            .widgetURL(context.attributes.paymentURL())
            .keylineTint(paymentAccent)
        }
    }
}

private struct PaymentActivityCard: View {
    let context: ActivityViewContext<PaymentActivityAttributes>
    var island = false

    var body: some View {
        VStack(alignment: .leading, spacing: island ? 4 : 6) {
            HStack(spacing: 6) {
                if !island {
                    Image(systemName: "creditcard.fill")
                        .foregroundStyle(paymentAccent)
                        .accessibilityHidden(true)
                }
                Text(context.state.merchant.isEmpty ? "결제 확인" : context.state.merchant)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .accessibilityLabel("사용처, \(context.state.merchant.isEmpty ? "확인 필요" : context.state.merchant)")
                Spacer(minLength: 0)
                if context.attributes.practice {
                    Text("연습").font(.caption.weight(.semibold))
                        .foregroundStyle(island ? .white : paymentAccent)
                        .fixedSize()
                }
            }
            PaymentActivityAmount(amount: context.state.amount)
                .foregroundStyle(island ? .white : paymentAccent)
            HStack(spacing: 8) {
                action("공용", scope: "shared")
                action("개인", scope: "personal")
                action("제외", scope: "ignore")
            }
            if !island {
                Text("앱에서 확인 후 기록해요")
                    .font(.caption2)
                    .foregroundStyle(Color(red: 98.0 / 255, green: 103.0 / 255, blue: 109.0 / 255))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func action(_ title: String, scope: String) -> some View {
        Group {
            if let url = context.attributes.paymentURL(scope: scope) {
                Link(destination: url) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(island ? .white : paymentAccent)
                        .background(island ? paymentAccent.opacity(0.3) : Color(red: 1, green: 242.0 / 255, blue: 232.0 / 255),
                                    in: RoundedRectangle(cornerRadius: 10))
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(title), 앱에서 결제 확인")
                .accessibilityHint("앱을 열어 선택을 확인해요. 잠금 화면에서는 저장하지 않아요.")
            }
        }
    }
}

private struct PaymentActivityAmount: View {
    let amount: Int?
    var compact = false

    var body: some View {
        Text(compact ? compactLabel : Self.label(amount))
            .font(compact ? .caption2.weight(.bold) : .title2.weight(.bold))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(compact ? 0.7 : 0.55)
            .accessibilityLabel("결제 금액, \(Self.label(amount))")
    }

    static func label(_ amount: Int?) -> String {
        amount.map { $0.formatted(.number.locale(Locale(identifier: "ko_KR"))) + "원" } ?? "금액 확인 필요"
    }

    private var compactLabel: String {
        amount.map { $0.formatted(.number.locale(Locale(identifier: "ko_KR"))) + "원" } ?? "확인"
    }
}

private extension PaymentActivityAttributes {
    func paymentURL(scope: String? = nil) -> URL? {
        var components = URLComponents()
        components.scheme = "ourledger"
        components.host = "payment"
        components.queryItems = [
            URLQueryItem(name: "id", value: paymentID),
            URLQueryItem(name: "identity", value: identity)
        ]
        if let scope {
            components.queryItems?.append(URLQueryItem(name: "scope", value: scope))
        }
        if practice {
            components.queryItems?.append(URLQueryItem(name: "practice", value: "true"))
        }
        return components.url
    }
}
