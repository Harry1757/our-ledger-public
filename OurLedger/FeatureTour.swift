import Foundation
import CoreGraphics

enum LedgerTourTarget: String, CaseIterable {
    case addExpense, calendar, inbox, insights, settlement, settings, recurring
}

struct LedgerTourStep {
    let target: LedgerTourTarget
    let tab: Int
    let title: String
    let message: String

    // Tabs match LedgerTabs; targets belong to visible controls, not native Tab labels.
    static let all: [Self] = [
        .init(target: .addExpense, tab: 0, title: "한 줄로 지출 기록",
              message: "금액과 한 줄 설명을 적고 공용·개인을 골라 기록해요."),
        .init(target: .calendar, tab: 0, title: "날짜별로 살펴보기",
              message: "수입은 +, 지출은 −로 보여요. 날짜를 고르면 그날 내역을 볼 수 있어요."),
        .init(target: .inbox, tab: 1, title: "알림은 확인함으로",
              message: "가져온 알림은 공용·개인을 선택해 확정한 뒤 기록돼요."),
        .init(target: .insights, tab: 2, title: "생활비 흐름 한눈에",
              message: "선택한 달의 공용 지출을 항목별로 살펴봐요."),
        .init(target: .settlement, tab: 0, title: "함께 쓴 돈 정산",
              message: "공용으로 기록한 내역의 정산 금액과 계산 근거를 확인해요."),
        .init(target: .settings, tab: 3, title: "우리에게 맞는 설정",
              message: "초대와 예산, 알림 연결을 여기서 관리해요."),
        .init(target: .recurring, tab: 3, title: "매달 나가는 돈 챙기기",
              message: "반복 일정을 모아두고 결제한 뒤 확인해서 기록해요.")
    ]

    static func stepsAvailable(memberCount: Int, scope: String = "shared") -> [Self] {
        all.filter { $0.target != .settlement || (memberCount > 1 && scope == "shared") }
    }

    static func step(at index: Int?, in steps: [Self] = LedgerTourStep.all) -> Self? {
        guard let index, steps.indices.contains(index) else { return nil }
        return steps[index]
    }

    static func next(after index: Int, in steps: [Self] = LedgerTourStep.all) -> Int? {
        guard step(at: index, in: steps) != nil, index < steps.count - 1 else { return nil }
        return index + 1
    }

    static func previous(before index: Int, in steps: [Self] = LedgerTourStep.all) -> Int? {
        guard step(at: index, in: steps) != nil, index > 0 else { return nil }
        return index - 1
    }
}

// Kept separate from the view so layout never depends on the previous step's position.
struct LedgerTourPlacement {
    let card: CGRect
    let hole: CGRect?

    init(viewport: CGRect, safeBounds: CGRect, target: CGRect?, cardHeight: CGFloat) {
        let width = min(420, safeBounds.width)
        let preferredHeight = cardHeight.isFinite ? max(1, cardHeight) : 280
        let x = safeBounds.midX - width / 2
        if let target,
           [target.origin.x, target.origin.y, target.width, target.height].allSatisfy({ $0.isFinite }),
           target.width > 0, target.height > 0, viewport.contains(target) {
            let spotlight = target.insetBy(dx: -12, dy: -12).intersection(viewport.insetBy(dx: 4, dy: 4))
            let above = max(0, min(safeBounds.maxY, spotlight.minY - 40) - safeBounds.minY)
            let below = max(0, safeBounds.maxY - max(safeBounds.minY, spotlight.maxY + 40))
            if spotlight.contains(target), max(above, below) >= min(preferredHeight, 176) {
                let height = min(preferredHeight, max(above, below))
                let y = above >= below ? min(safeBounds.maxY, spotlight.minY - 40) - height
                                       : max(safeBounds.minY, spotlight.maxY + 40)
                card = CGRect(x: x, y: y, width: width, height: height)
                hole = spotlight
                return
            }
        }
        // No fabricated spotlight for absent, clipped, or screen-filling targets.
        let height = min(preferredHeight, safeBounds.height)
        card = CGRect(x: x, y: safeBounds.midY - height / 2, width: width, height: height)
        hole = nil
    }
}

#if os(iOS)
import SwiftUI

private struct LedgerGuideTargetKey: EnvironmentKey {
    static let defaultValue: LedgerTourTarget? = nil
}
extension EnvironmentValues {
    var ledgerGuideTarget: LedgerTourTarget? {
        get { self[LedgerGuideTargetKey.self] }
        set { self[LedgerGuideTargetKey.self] = newValue }
    }
}

struct LedgerTourTargetPreferenceKey: PreferenceKey {
    static let defaultValue: [LedgerTourTarget: Anchor<CGRect>] = [:]

    static func reduce(value: inout [LedgerTourTarget: Anchor<CGRect>],
                       nextValue: () -> [LedgerTourTarget: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

extension View {
    /// Mark one rendered control/area per target, inside the root preference reader.
    func ledgerTourTarget(_ target: LedgerTourTarget) -> some View {
        anchorPreference(key: LedgerTourTargetPreferenceKey.self, value: .bounds) { [target: $0] }.id(target)
    }
}

/// Feature guide only: the host owns first launch, automation setup, test receipt and replay.
/// Set currentStep to 0 to start/replay; skip and completion set it to nil.
/// Pass steps: LedgerTourStep.stepsAvailable(memberCount: memberCount) to omit solo settlement.
/// Read safeAreaInsets BEFORE ignoring safe areas; resolve anchors in an inner full-screen reader:
///
///     .overlayPreferenceValue(LedgerTourTargetPreferenceKey.self) { anchors in
///         GeometryReader { safe in
///             GeometryReader { full in
///                 LedgerFeatureTour(currentStep: $tourStep,
///                     targets: anchors.mapValues { full[$0] }, safeAreaInsets: safe.safeAreaInsets)
///             }.ignoresSafeArea(.container)
///         }
///     }
///
/// Keep this overlay outside TabView/NavigationStack, and hide the underlying accessibility tree.
/// For a scrolled target, use LedgerTourStep.step(at: currentStep, in: steps)?.target;
/// prefer always-visible controls and return navigation stacks to their roots before starting.
struct LedgerFeatureTour: View {
    @Binding var currentStep: Int?
    let targets: [LedgerTourTarget: CGRect]
    let safeAreaInsets: EdgeInsets
    let steps: [LedgerTourStep]

    @Environment(LedgerStore.self) private var store
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AccessibilityFocusState private var cardFocused: Bool
    @State private var cardHeight: CGFloat = 280

    init(currentStep: Binding<Int?>, targets: [LedgerTourTarget: CGRect], safeAreaInsets: EdgeInsets,
         steps: [LedgerTourStep] = LedgerTourStep.all) {
        _currentStep = currentStep
        self.targets = targets
        self.safeAreaInsets = safeAreaInsets
        self.steps = steps
    }

    var body: some View {
        GeometryReader { geometry in
            if let index = currentStep, let step = LedgerTourStep.step(at: index, in: steps) {
                let viewport = CGRect(origin: .zero, size: geometry.size)
                let safe = CGRect(
                    x: safeAreaInsets.leading + 24, y: safeAreaInsets.top + 24,
                    width: max(0, geometry.size.width - safeAreaInsets.leading - safeAreaInsets.trailing - 48),
                    height: max(0, geometry.size.height - safeAreaInsets.top - safeAreaInsets.bottom - 48)
                )
                let placement = LedgerTourPlacement(
                    viewport: viewport, safeBounds: safe,
                    target: store.tab == step.tab ? targets[step.target] : nil, cardHeight: cardHeight
                )
                ZStack(alignment: .topLeading) {
                    // A separate hit plane also blocks taps through the transparent hole.
                    Color.clear.contentShape(Rectangle()).onTapGesture {}
                        .accessibilityHidden(true)
                    Path { path in
                        path.addRect(viewport)
                        if let hole = placement.hole {
                            path.addRoundedRect(in: hole, cornerSize: CGSize(width: 16, height: 16))
                        }
                    }
                    .fill(.black.opacity(0.72), style: FillStyle(eoFill: true))
                    .allowsHitTesting(false).accessibilityHidden(true)

                    if let hole = placement.hole {
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(LedgerTheme.accent, lineWidth: 2.5)
                            .frame(width: hole.width, height: hole.height)
                            .position(x: hole.midX, y: hole.midY)
                            .allowsHitTesting(false).accessibilityHidden(true)
                        Image(systemName: placement.card.maxY <= hole.minY ? "arrow.down" : "arrow.up")
                            .font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                            .background(LedgerTheme.accent, in: Circle())
                            .position(x: hole.midX,
                                      y: placement.card.maxY <= hole.minY
                                        ? (placement.card.maxY + hole.minY) / 2
                                        : (hole.maxY + placement.card.minY) / 2)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                    card(step, index: index)
                        .frame(width: placement.card.width, height: placement.card.height)
                        .background(LedgerTheme.ink, in: RoundedRectangle(cornerRadius: 22))
                        .overlay {
                            RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.16))
                                .allowsHitTesting(false)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 22))
                        .position(x: placement.card.midX, y: placement.card.midY)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .accessibilityElement(children: .contain)
                .accessibilityAddTraits(.isModal)
                .accessibilityAction(.escape) { currentStep = nil }
                .accessibilityIdentifier("ledgerFeatureTour")
            }
        }
        .allowsHitTesting(LedgerTourStep.step(at: currentStep, in: steps) != nil)
        // No moving spotlight/tab transitions, including when Reduce Motion is enabled.
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
        .task(id: currentStep) {
            cardFocused = false
            guard let index = currentStep else { return }
            guard let step = LedgerTourStep.step(at: index, in: steps) else { currentStep = nil; return }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { store.tab = step.tab }
            // Wait for the new tab's accessibility elements; cancel on skip/rapid next.
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            guard !Task.isCancelled, currentStep == index else { return }
            cardFocused = true
        }
        .id(steps.map(\.target))
    }

    private func card(_ step: LedgerTourStep, index: Int) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                let progress = Label("기능 안내 · \(index + 1) / \(steps.count)", systemImage: "info.circle.fill")
                    .font(.caption.weight(.semibold)).foregroundStyle(LedgerTheme.accentSoft)
                    .accessibilityHidden(true)
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 8) {
                        progress
                        skip.frame(maxWidth: .infinity, alignment: .trailing)
                    }
                } else {
                    HStack(spacing: 12) { progress; Spacer(minLength: 0); skip }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(step.title).font(.title3.weight(.bold)).foregroundStyle(.white)
                    Text(step.message).font(.body).foregroundStyle(.white.opacity(0.85))
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(index + 1)단계, 총 \(steps.count)단계, \(step.title), \(step.message)")
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($cardFocused)
                .accessibilityIdentifier("featureTourDescription")

                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 8) { back(index); next(index) }
                } else {
                    HStack(spacing: 12) { back(index); next(index) }
                }
            }
            .padding(24)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cardHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .id(step.target)
    }

    private func back(_ index: Int) -> some View {
        Button("이전") { currentStep = LedgerTourStep.previous(before: index, in: steps) }
            .font(.headline).padding(.horizontal, 16).padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 48)
            .foregroundStyle(.white.opacity(index == 0 ? 0.3 : 0.95))
            .background(.white.opacity(index == 0 ? 0.03 : 0.1), in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(index == 0 ? 0.08 : 0.24)) }
            .contentShape(RoundedRectangle(cornerRadius: 12)).buttonStyle(.plain)
            .disabled(index == 0).accessibilityIdentifier("featureTourBack")
    }

    private var skip: some View {
        Button("건너뛰기") { currentStep = nil }
            .font(.subheadline.weight(.medium)).padding(.horizontal, 12)
            .frame(minHeight: 44)
            .foregroundStyle(.white.opacity(0.8))
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.16)) }
            .contentShape(RoundedRectangle(cornerRadius: 12)).buttonStyle(.plain)
            .accessibilityIdentifier("featureTourSkip")
    }

    private func next(_ index: Int) -> some View {
        Button { currentStep = LedgerTourStep.next(after: index, in: steps) } label: {
            Text(index == steps.count - 1 ? "완료" : "다음")
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(LedgerPrimaryButtonStyle())
        .accessibilityIdentifier("featureTourNext")
    }
}
#endif
