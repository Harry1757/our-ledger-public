import SwiftUI
import UIKit

enum LedgerTheme {
    // SEED light tokens adapted for SwiftUI; see 디자인기준.md.
    static let accent = color(0xB93901)
    static let brand = color(0xFF6600)
    static let action = color(0xE14D00)
    static let income = color(0x1C4DBF)
    static let expense = color(0xBD1F29)
    static let background = Color.white
    static let surface = color(0xF7F8F9)
    static let ink = color(0x1A1C20)
    static let muted = color(0x555D6D)
    static let accentSoft = color(0xFFF2EC)
    static let border = Color.black.opacity(0.08)
    static let selectionTrack = Color.black.opacity(0.05)
    static let onAccent = Color.white
    static let payerMe = color(0x6D4BB1)
    static let payerMeBackground = color(0xF3EEFC)
    static let payerOther = color(0x146B62)
    static let payerOtherBackground = color(0xEAF6F3)
    private static func color(_ value: UInt32) -> Color {
        Color(red: Double((value >> 16) & 255) / 255,
              green: Double((value >> 8) & 255) / 255,
              blue: Double(value & 255) / 255)
    }
}

struct LedgerPayerBadge: View {
    let payer: String
    let name: String
    let me: String
    var showsName = false

    private var label: String { payer == "fund" ? "공동자금" : payer == me ? "나" : name }
    private var foreground: Color { payer == "fund" ? LedgerTheme.muted : payer == me ? LedgerTheme.payerMe : LedgerTheme.payerOther }
    private var background: Color { payer == "fund" ? LedgerTheme.surface : payer == me ? LedgerTheme.payerMeBackground : LedgerTheme.payerOtherBackground }

    var body: some View {
        Text(label + (showsName && payer == me && payer != "fund" && name != label ? " · " + name : ""))
            .font(.caption.weight(.semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(background, in: RoundedRectangle(cornerRadius: 8))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(payer == me && payer != "fund" && name != label ? label + ", " + name : label)
    }
}

extension View {
    // Keep separators under the whole row, including icons and nested labels.
    func ledgerRowDivider() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
            .listRowSeparatorTint(LedgerTheme.border)
    }

    // Root tabs already name the screen; keep that space for the content.
    func ledgerRootScreen() -> some View {
        toolbar(.hidden, for: .navigationBar)
            .contentMargins(.top, 8, for: .scrollContent)
    }

    func ledgerScreen() -> some View {
        scrollContentBackground(.hidden).background(LedgerTheme.background)
            .fontDesign(.default).tint(LedgerTheme.accent)
    }
}

// One primary action across entry, setup and recurring forms.
struct LedgerPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .padding(.horizontal, 20).padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 52)
            .foregroundStyle(enabled ? LedgerTheme.onAccent : LedgerTheme.muted)
            .background(enabled ? LedgerTheme.action : LedgerTheme.surface,
                        in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

// Observe the window so sheet backgrounds work too, without consuming button taps.
struct LedgerKeyboardDismissal: UIViewRepresentable {
    func makeUIView(context: Context) -> Observer { Observer() }
    func updateUIView(_ uiView: Observer, context: Context) {}
    static func dismantleUIView(_ uiView: Observer, coordinator: ()) { uiView.detach() }

    final class Observer: UIView, UIGestureRecognizerDelegate {
        private weak var editingView: UIView?
        private lazy var tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))

        override func didMoveToWindow() {
            super.didMoveToWindow()
            detach()
            isUserInteractionEnabled = false
            tap.cancelsTouchesInView = false
            tap.delaysTouchesEnded = false
            tap.delegate = self
            window?.addGestureRecognizer(tap)
        }

        func detach() { tap.view?.removeGestureRecognizer(tap) }
        @objc private func dismissKeyboard() {
            // Finish the tapped control first; never dismiss a field it just focused.
            let original = editingView
            DispatchQueue.main.async {
                if original?.isFirstResponder == true { original?.resignFirstResponder() }
            }
        }

        private func firstResponder(in view: UIView) -> UIView? {
            if view.isFirstResponder { return view }
            for child in view.subviews {
                if let responder = firstResponder(in: child) { return responder }
            }
            return nil
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var view = touch.view
            while let current = view {
                // Editing, cursor positioning and switching fields must keep their keyboard.
                if current is UITextInput { return false }
                view = current.superview
            }
            editingView = window.flatMap { firstResponder(in: $0) }
            return editingView != nil
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    }
}
