import Foundation

@main struct ShortcutOpeningCheck {
    @MainActor static func main() async {
        let opening = ShortcutOpening()
        var response: CheckedContinuation<Bool, Never>?
        var requestedURL: URL?
        let first = Task {
            await opening.open(.edit) { url in
                requestedURL = url
                return await withCheckedContinuation { response = $0 }
            }
        }
        while response == nil { await Task.yield() }
        precondition(opening.destination == .edit, "Show loading until the system responds")
        await opening.open(.install) { _ in
            preconditionFailure("An in-flight request must prevent a second navigation")
        }
        response!.resume(returning: false)
        await first.value
        precondition(opening.destination == nil && opening.error != nil,
                     "Failed navigation must stop loading and show recovery instead of silently failing")
        precondition(!opening.requestedInstaller)
        let parts = URLComponents(url: requestedURL!, resolvingAgainstBaseURL: false)!
        precondition(parts.scheme == "shortcuts" && parts.host == "open-shortcut")
        precondition(parts.queryItems == [URLQueryItem(name: "name", value: "결제 알림 자동 수신")])

        await opening.open(.install) { _ in false }
        precondition(!opening.requestedInstaller && opening.error != nil,
                     "A failed installer launch must not advance the install button state")
        await opening.open(.install) { _ in true }
        precondition(opening.requestedInstaller && opening.error == nil && opening.destination == nil)
        var fallbackURL: URL?
        await opening.open(.app) { url in fallbackURL = url; return true }
        precondition(fallbackURL?.absoluteString == "shortcuts://",
                     "Recovery must open the app without depending on the failing shortcut-name route")
        let defaults = UserDefaults(suiteName: "shortcut-opening-check-" + UUID().uuidString)!
        let setup = NotificationSetupState(defaults: defaults, identity: "local-only")
        await opening.open(.edit) { _ in true }
        precondition(!setup.configured && setup.verifiedAt == nil,
                     "A successful URL handoff is not proof of installation or notification delivery")
        print("PASS: opening state, duplicate prevention, failure/retry, independent recovery, no false verification")
    }
}
