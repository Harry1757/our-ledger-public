import ActivityKit
import Foundation

struct PaymentActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        let merchant: String
        let amount: Int?
    }

    let paymentID: String
    let identity: String
    let practice: Bool
    let practiceRawText: String

    init(paymentID: String, identity: String, practice: Bool, practiceRawText: String = "") {
        self.paymentID = paymentID
        self.identity = identity
        self.practice = practice
        // Real notification text stays in the app, never in the activity payload.
        self.practiceRawText = practice ? practiceRawText : ""
    }
}
