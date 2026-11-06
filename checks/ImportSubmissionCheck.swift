import Foundation

@main struct ImportSubmissionCheck {
    static func main() {
        var ids = ImportSubmissionIDs()
        let first = ids.id(source: "sms", text: "카드 승인 3,000원")
        precondition(ids.id(source: "sms", text: "카드 승인 3,000원") == first)
        precondition(ids.id(source: "sms", text: "카드 승인 5,000원") != first)
        precondition(ids.id(source: "app", text: "카드 승인 3,000원") != first)
        precondition(ids.id(source: "paste", text: "카드 승인 3,000원") != first)
        precondition(ids.id(source: "sms", text: "카드 승인 3,000원") == first)
        print("Import request retries and edited drafts: passed")
    }
}
