"""Run the actual live-activity publisher with concurrent synthetic responses.

ActivityKit is replaced by a locked in-memory double; no phone or cloud access.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'OurLedger/PaymentNotifications.swift').read_text()
position = source.index('static func show(')
start = source.rfind('\n', 0, position) + 1
end = source.index('    static func end(', position)
show = source[start:end]
code = r'''
import Foundation
struct PaymentActivityAttributes {
    struct ContentState { let merchant: String; let amount: Int? }
    let paymentID: String, identity: String
    let practice: Bool
    let practiceRawText: String
}
struct ActivityContent<State> { let state: State; let staleDate: Date? }
struct ActivityAuthorizationInfo { var areActivitiesEnabled: Bool { true } }
final class Activity<Attributes>: @unchecked Sendable {
    static var activities: [Activity<Attributes>] {
        inventoryLock.lock(); defer { inventoryLock.unlock() }
        return inventory.compactMap { $0 as? Activity<Attributes> }
    }
    let attributes: Attributes
    init(_ attributes: Attributes) { self.attributes = attributes }
    static func request(attributes: Attributes, content: ActivityContent<PaymentActivityAttributes.ContentState>, pushType: String?) throws -> Activity<Attributes> {
        // Expose the snapshot/request race when publication is not serialized.
        Thread.sleep(forTimeInterval: 0.02)
        let item = Activity(attributes)
        inventoryLock.lock(); defer { inventoryLock.unlock() }
        inventory.append(item)
        return item
    }
    func update(_ content: ActivityContent<PaymentActivityAttributes.ContentState>) async {}
    enum Policy { case immediate }
    func end(_ content: String?, dismissalPolicy: Policy) async { remove(self) }
}
let inventoryLock = NSLock()
var inventory: [AnyObject] = []
func remove(_ value: AnyObject) {
    inventoryLock.lock(); defer { inventoryLock.unlock() }
    inventory.removeAll { $0 === value }
}
enum PaymentLiveActivities {
SHOW
}
@main struct Check {
    static func main() async {
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<50 {
                group.addTask { await PaymentLiveActivities.show(id: "one-payment", identity: "synthetic", merchant: "합성상점", amount: 8400) }
            }
            for await success in group { precondition(success) }
        }
        precondition(Activity<PaymentActivityAttributes>.activities.count == 1, "Concurrent duplicate replies must leave one live activity")
        _ = await PaymentLiveActivities.show(id: "next-payment", identity: "synthetic", merchant: "다음상점", amount: 100)
        let active = Activity<PaymentActivityAttributes>.activities
        precondition(active.count == 1 && active[0].attributes.paymentID == "next-payment", "The next distinct payment replaces the island card")
        print("PASS: fifty concurrent replies create one card; next distinct payment replaces it")
    }
}
'''.replace('SHOW', show)
with tempfile.TemporaryDirectory(prefix='ourledger-live-dedup-') as directory:
    folder = Path(directory)
    (folder / 'check.swift').write_text(code)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', str(folder / 'check.swift'), '-o', str(folder / 'check')], check=True)
    subprocess.run([str(folder / 'check')], check=True, timeout=20)
