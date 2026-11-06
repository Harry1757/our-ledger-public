import Foundation

@main struct NotificationSetupCheck {
    @MainActor static func main() {
        let router = PaymentNotificationRouter()
        func route(_ id: String, identity: String = "a") -> PaymentNotificationRoute {
            PaymentNotificationRoute(id: id, identity: identity, rawText: "", scope: nil, practice: false, ignored: false)
        }
        router.receive(route("first")); router.receive(route("second")); router.receive(route("second")); router.receive(route("first"))
        if case .payment(let current) = router.presentation { precondition(current.id == "first") } else { preconditionFailure() }
        precondition(router.queued.count == 1, "Arriving alerts must not replace an unfinished note or queue duplicates")
        precondition(!router.showNextQueued())
        router.presentation = nil
        precondition(router.showNextQueued() && router.queued.isEmpty)
        if case .payment(let next) = router.presentation { precondition(next.id == "second") } else { preconditionFailure() }
        router.receive(route("third")); router.connectionChanged(identity: "b")
        precondition(router.presentation == nil && router.queued.isEmpty, "Queued payments cannot cross account connections")
        router.receive(route("first")); router.receive(route("second")); router.deferQueued()
        precondition(router.presentation != nil && router.queued.isEmpty, "Closing a batch defers unhandled items to the server inbox")
        let base = "ourledger://payment?id=payment-a&identity=member-a"
        precondition(PaymentActivityLink(URL(string: base)!, identity: "member-a")?.scope == nil)
        precondition(PaymentActivityLink(URL(string: base + "&scope=shared")!, identity: "member-a")?.scope == "shared")
        precondition(PaymentActivityLink(URL(string: base + "&scope=ignore&practice=true")!, identity: "member-a")?.practice == true)
        for suffix in ["&scope=bad", "&scope=shared&scope=ignore", "&practice=false", "&token=secret", "#fragment"] {
            precondition(PaymentActivityLink(URL(string: base + suffix)!, identity: "member-a") == nil)
        }
        precondition(PaymentActivityLink(URL(string: base)!, identity: "member-b") == nil)
        precondition(PaymentActivityLink(URL(string: "https://payment?id=a&identity=member-a")!, identity: "member-a") == nil)
        let name = "ourledger-setup-check-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let setup = NotificationSetupState(defaults: defaults, identity: "test-member-a")
        let other = NotificationSetupState(defaults: defaults, identity: "test-member-b")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // Regression: a second send must not invalidate either earlier receipt or practice.
        let testA = setup.beginTest(now: now)
        let testB = setup.beginTest(now: now.addingTimeInterval(1))
        precondition(NotificationSetupState.practiceAmount(testA) == 100)
        precondition(NotificationSetupState.practiceAmount(testB) == 200)
        precondition(NotificationSetupState.practiceAmount("legacy-token") == 8400)
        let firstReceiptSurvives = setup.confirmTest(testA, now: now.addingTimeInterval(2))
        let secondReceiptSurvives = setup.confirmTest(testB, now: now.addingTimeInterval(3))
        setup.reset()
        setup.beginPractice(testA, now: now)
        setup.beginPractice(testB, now: now.addingTimeInterval(1))
        let firstPracticeCompletes = setup.completePractice(testA, now: now.addingTimeInterval(2))
        precondition(NotificationSetupState.practiceAmount(testB) == 200, "Amount must survive removal of an earlier test")
        let secondPracticeRemains = setup.matchesPractice(testB, now: now.addingTimeInterval(3))
        let secondPracticeCompletes = setup.completePractice(testB, now: now.addingTimeInterval(4))
        let regression = "Two sends: firstReceipt=\(firstReceiptSurvives), secondReceipt=\(secondReceiptSurvives), firstPractice=\(firstPracticeCompletes), nextRemains=\(secondPracticeRemains), nextCompletes=\(secondPracticeCompletes)\n"
        FileHandle.standardOutput.write(Data(regression.utf8))
        precondition(firstReceiptSurvives && secondReceiptSurvives && firstPracticeCompletes && secondPracticeRemains && secondPracticeCompletes,
                     "A second test/practice send must preserve the first token and completing one must leave the next usable")
        setup.reset()
        let unregistered = setup.beginTest(now: now)
        precondition(setup.pendingPracticeTokens(now: now).isEmpty, "Connection tests alone are not practice")
        let queueFirst = setup.beginTest(now: now)
        let queueSecond = setup.beginTest(now: now.addingTimeInterval(1))
        setup.beginPractice(queueFirst, now: now)
        setup.beginPractice(queueSecond, now: now.addingTimeInterval(1))
        precondition(setup.pendingPracticeTokens(now: now.addingTimeInterval(2)) == [queueFirst, queueSecond])
        precondition(other.pendingPracticeTokens(now: now.addingTimeInterval(2)).isEmpty)
        precondition(setup.practiceDate(queueFirst) == now && setup.practiceDate(queueSecond) == now.addingTimeInterval(1))
        precondition(setup.practiceDate(unregistered) == nil)
        precondition(setup.practiceToken(in: "승인 8,400원\n" + queueFirst, now: now) == queueFirst)
        precondition(setup.practiceToken(in: queueFirst + "9", now: now) == nil, "A token prefix is not a complete token")
        precondition(!setup.matchesTest(queueFirst + "9", now: now))
        precondition(setup.pendingPracticeTokens(now: now.addingTimeInterval(-1)).isEmpty)
        precondition(setup.pendingPracticeTokens(now: now.addingTimeInterval(600)) == [queueFirst, queueSecond])
        precondition(setup.pendingPracticeTokens(now: now.addingTimeInterval(601)) == [queueSecond])
        precondition(setup.pendingPracticeTokens(now: now.addingTimeInterval(602)).isEmpty)
        precondition(setup.matchesTest(queueFirst, now: now.addingTimeInterval(300)))
        precondition(!setup.matchesTest(queueFirst, now: now.addingTimeInterval(301)))
        precondition(setup.matchesTest(queueSecond, now: now.addingTimeInterval(301)))
        let reloaded = NotificationSetupState(defaults: UserDefaults(suiteName: name)!, identity: setup.identity)
        precondition(reloaded.pendingPracticeTokens(now: now.addingTimeInterval(2)) == [queueFirst, queueSecond])
        setup.discardPractice(queueFirst)
        precondition(setup.practiceCompletedAt == nil && setup.verifiedAt == nil && !setup.configured)
        precondition(setup.practiceDate(queueFirst) == nil && !setup.matchesTest(queueFirst, now: now))
        precondition(setup.pendingPracticeTokens(now: now.addingTimeInterval(2)) == [queueSecond])
        precondition(setup.completePractice(queueSecond, now: now.addingTimeInterval(3)))
        precondition(setup.confirmTest(queueSecond, now: now.addingTimeInterval(4)), "Late test receipt may verify connection")
        precondition(setup.practiceToken(in: queueSecond, now: now.addingTimeInterval(4)) == nil, "Late receipt cannot revive completed practice")
        setup.discardPractice(queueSecond)
        precondition(setup.practiceCompletedAt == now.addingTimeInterval(3))
        setup.reset()
        var bounded: [String] = []
        for index in 0..<21 {
            let date = now.addingTimeInterval(Double(index))
            let token = setup.beginTest(now: date)
            setup.beginPractice(token, now: date)
            bounded.append(token)
        }
        precondition(setup.pendingPracticeTokens(now: now.addingTimeInterval(21)) == Array(bounded.dropFirst()))
        precondition(!setup.completePractice(bounded[0], now: now.addingTimeInterval(21)))
        precondition(!setup.confirmTest(bounded[0], now: now.addingTimeInterval(21)))
        setup.reset()
        let legacyPrefix = "notificationSetup.v1." + setup.identity + "."
        defaults.set(testA, forKey: legacyPrefix + "testToken")
        defaults.set(now, forKey: legacyPrefix + "testStartedAt")
        defaults.set(testA, forKey: legacyPrefix + "practiceToken")
        defaults.set(now, forKey: legacyPrefix + "practiceStartedAt")
        precondition(setup.pendingPracticeTokens(now: now) == [testA])
        precondition(setup.practiceDate(testA) == now && setup.confirmTest(testA, now: now))
        precondition(setup.completePractice(testA, now: now))
        precondition(defaults.object(forKey: legacyPrefix + "testToken") == nil)
        precondition(defaults.object(forKey: legacyPrefix + "practiceToken") == nil)
        precondition(reloaded.pendingPracticeTokens(now: now).isEmpty && !reloaded.confirmTest(testA, now: now))
        setup.reset()
        defaults.set(testA, forKey: legacyPrefix + "practiceToken")
        precondition(setup.pendingPracticeTokens(now: now).isEmpty, "A legacy token without a creation time cannot migrate as fresh")
        setup.reset()
        let concurrentIdentity = setup.identity
        DispatchQueue.concurrentPerform(iterations: 20) { _ in
            let state = NotificationSetupState(defaults: UserDefaults(suiteName: name)!, identity: concurrentIdentity)
            let token = state.beginTest(now: now)
            state.beginPractice(token, now: now)
        }
        let concurrentTokens = setup.pendingPracticeTokens(now: now)
        precondition(concurrentTokens.count == 20 && Set(concurrentTokens).count == 20)
        let consumed = concurrentTokens[0]
        let resultLock = NSLock()
        var completions = 0, confirmations = 0
        DispatchQueue.concurrentPerform(iterations: 20) { _ in
            let state = NotificationSetupState(defaults: UserDefaults(suiteName: name)!, identity: concurrentIdentity)
            let complete = state.completePractice(consumed, now: now)
            let confirm = state.confirmTest(consumed, now: now)
            resultLock.lock()
            if complete { completions += 1 }; if confirm { confirmations += 1 }
            resultLock.unlock()
        }
        precondition(completions == 1 && confirmations == 1, "Concurrent duplicate completion/receipt succeeds exactly once")
        precondition(setup.pendingPracticeTokens(now: now).count == 19)
        for kind in ["test", "practice"] {
            let data = defaults.data(forKey: legacyPrefix + kind + "Queue.v2")!
            let records = try! JSONSerialization.jsonObject(with: data) as! [[String: Any]]
            precondition(records.allSatisfy { Set($0.keys) == ["token", "startedAt"] })
        }
        other.beginPractice(testB, now: now)
        setup.reset()
        precondition(setup.pendingPracticeTokens(now: now).isEmpty && other.pendingPracticeTokens(now: now) == [testB])
        other.reset()
        print("PASS: practice-only FIFO, ID dates, 5/10-minute boundaries, exact body match, discard, late receipt, 20-token limit, migration, reload, concurrent one-use and connection isolation")
        let firstDelivery = setup.beginDelivery(now: now)
        let secondDelivery = setup.beginDelivery(now: now.addingTimeInterval(1))
        setup.recordDelivery(secondDelivery, stage: .submitting, now: now.addingTimeInterval(2))
        setup.recordDelivery(firstDelivery, stage: .filterExcluded, now: now.addingTimeInterval(3))
        precondition(setup.deliveries.map(\.id) == [secondDelivery, firstDelivery])
        precondition(setup.deliveries.map(\.stage) == [.submitting, .filterExcluded])
        precondition(setup.deliveries[0].stage.title.contains("완료 미확인"))
        setup.recordDelivery(secondDelivery, stage: .serverAcknowledged)
        setup.recordDelivery(secondDelivery, stage: .failed)
        precondition(setup.deliveries[0].stage == .serverAcknowledged, "A later display failure cannot erase acknowledgement")
        let otherDelivery = other.beginDelivery(now: now)
        setup.reset()
        setup.recordDelivery(firstDelivery, stage: .submitting)
        precondition(setup.deliveries.isEmpty && other.deliveries.map(\.id) == [otherDelivery])
        DispatchQueue.concurrentPerform(iterations: 20) { index in
            let state = NotificationSetupState(defaults: UserDefaults(suiteName: name)!, identity: "test-member-a")
            let id = state.beginDelivery(now: now.addingTimeInterval(Double(index)))
            state.recordDelivery(id, stage: .submitting)
            state.recordDelivery(id, stage: index.isMultiple(of: 2) ? .serverAcknowledged : .failed)
        }
        precondition(setup.deliveries.count == 20 && Set(setup.deliveries.map(\.id)).count == 20)
        precondition(setup.deliveries.filter { $0.stage == .serverAcknowledged }.count == 10)
        precondition(setup.deliveries.filter { $0.stage == .failed && $0.failedStage == .submitting }.count == 10)
        let evicted = setup.deliveries.last!.id
        DispatchQueue.concurrentPerform(iterations: 60) { _ in
            let setup = NotificationSetupState(defaults: UserDefaults(suiteName: name)!, identity: "test-member-a")
            let id = setup.beginDelivery()
            setup.recordDelivery(id, stage: .serverAcknowledged)
        }
        precondition(setup.deliveries.count == 20 && Set(setup.deliveries.map(\.id)).count == 20)
        precondition(setup.deliveries.allSatisfy { $0.stage == .serverAcknowledged })
        setup.recordDelivery(evicted, stage: .failed)
        precondition(!setup.deliveries.contains { $0.id == evicted })
        let persisted = NotificationSetupState(defaults: UserDefaults(suiteName: name)!, identity: setup.identity)
        precondition(persisted.deliveries.map(\.id) == setup.deliveries.map(\.id))
        let encoded = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(setup.deliveries)) as! [[String: Any]]
        precondition(encoded.allSatisfy { Set($0.keys).isSubset(of: ["id", "startedAt", "updatedAt", "stage", "failedStage"]) })
        DispatchQueue.concurrentPerform(iterations: 60) { index in
            let setup = NotificationSetupState(defaults: UserDefaults(suiteName: name)!, identity: "test-member-a")
            if index.isMultiple(of: 3) { setup.reset() }
            else { setup.recordDelivery(evicted, stage: .submitting) }
        }
        precondition(setup.deliveries.isEmpty && other.deliveries.map(\.id) == [otherDelivery])
        print("PASS: delivery interleaving, 20 concurrent invocations, 80-record bound, persistence, reset, identity isolation and closed fields")
        precondition(!setup.configured && setup.verifiedAt == nil)
        setup.configured = true
        precondition(setup.configured && !other.configured && setup.verifiedAt == nil)
        precondition(!setup.featureTourSeen && !other.featureTourSeen)
        setup.featureTourSeen = true
        precondition(NotificationSetupState(defaults: UserDefaults(suiteName: name)!, identity: setup.identity).featureTourSeen)
        precondition(!other.featureTourSeen, "Feature guide completion must remain per connection")

        let token = setup.beginTest(now: now)
        precondition(!setup.matchesTest("결제 테스트", now: now))
        precondition(!other.matchesTest(token, now: now))
        precondition(setup.matchesTest("우리 가계부 연결 테스트\n" + token, now: now.addingTimeInterval(10)))
        precondition(!setup.matchesTest(token, now: now.addingTimeInterval(301)))
        precondition(!setup.matchesTest(token, now: now.addingTimeInterval(-1)))
        precondition(setup.confirmTest(token, now: now))
        precondition(setup.verifiedAt == now && setup.configured)
        precondition(!setup.matchesTest(token, now: now))
        let next = setup.beginTest(now: now)
        precondition(!setup.matchesTest(token, now: now) && setup.matchesTest(next, now: now))
        setup.reset()
        precondition(!setup.configured && setup.verifiedAt == nil && !setup.matchesTest(next, now: now))
        let practice = setup.beginTest(now: now)
        setup.beginPractice(practice, now: now)
        precondition(setup.matchesPractice(practice, now: now))
        precondition(!other.matchesPractice(practice, now: now))
        precondition(!setup.matchesPractice(practice, now: now.addingTimeInterval(601)))
        precondition(!setup.matchesPractice(practice, now: now.addingTimeInterval(-1)))
        precondition(!setup.completePractice("unknown", now: now))
        precondition(setup.confirmTest(practice, now: now))
        precondition(setup.matchesPractice(practice, now: now), "Connection receipt must not pretend the user finished recording")
        precondition(setup.practiceCompletedAt == nil)
        precondition(setup.completePractice(practice, now: now.addingTimeInterval(10)))
        precondition(setup.practiceCompletedAt == now.addingTimeInterval(10))
        precondition(!setup.completePractice(practice, now: now.addingTimeInterval(11)))
        precondition(!NotificationSetupState.isPayment("우리결제카페 · 3,800원 · 눌러서 기록해 주세요."))
        precondition(NotificationSetupState.isPayment("현대카드 승인 12,300원 카페"))
        precondition(NotificationSetupState.isPayment("롯데카드 승인 USD 13.20"))
        precondition(NotificationSetupState.isPayment("계좌에서 10,000원이 출금되었습니다"))
        precondition(NotificationSetupState.isPayment("카카오페이 결제취소 5,000원"))
        precondition(!NotificationSetupState.isPayment("[광고] 카드 결제하면 10,000원 할인"))
        precondition(!NotificationSetupState.isPayment("10,000원 결제 시 할인 혜택"))
        precondition(!NotificationSetupState.isPayment("결제 예정 25,000원 안내"))
        precondition(!NotificationSetupState.isPayment("카드 결제 할인 쿠폰 10,000원 지급"))
        precondition(NotificationSetupState.isPayment("카드 1234 승인 10,000원, 청구 할인 적용"))
        precondition(NotificationSetupState.isPayment("급여 3,000,000원 지급"))
        precondition(NotificationSetupState.isPayment("우리은행 입금 1,000,000원"))
        precondition(!NotificationSetupState.isPayment("새로운 서비스가 생겼어요"))
        precondition(!NotificationSetupState.isPayment("이번달 혜택을 확인하세요 10,000원"))
        precondition(!NotificationSetupState.isPayment("공용으로 쓴 돈인가요? 카페 · 1,000원"))
        precondition(!NotificationSetupState.isPayment("[우리 가계부 연결 테스트] " + next))
        // User-masked notice plus synthetic messages and TEST-ONLY coupon codes.
        var financeFixtures: [(String, Bool)] = [
            ("자동이체\n오늘 테스트보험 외 1곳에서 119,970원\n출금할 예정이에요. 토스뱅크 통장 (0000)에서\n출금돼요.", false),
            ("[Web발신] 안녕하세요, T다이렉트샵입니다. 다이렉트 플랜을 이용해주신 고객님께 감사의 마음으로 쿠폰을 드립니다. (6개월 간 유지 시 매월 지급) 상품명: 카카오페이 38,000원 쿠폰번호: TEST-ONLY [유의사항] 등록기간이 만료된 쿠폰은 효력이 상실되며 연장 및 환불이 불가하오니 기간 내 꼭 등록바랍니다.", false),
            ("쿠폰 발송 안내\n38,000원\n취소/환불 불가", false),
            ("쿠폰번호: TEST-ONLY\n38,000원\n승인번호: TEST1234\n환불 불가", false),
            ("38,000원\n취소/환불 불가", false),
            ("환불 38,000원\n가맹점: 쿠폰상점", true),
            ("입금 38,000원\n쿠폰 판매대금", true)
        ]
        for notice in ["출금 예정", "오늘 출금예정", "결제 예정", "청구 예정", "청구 안내",
                       "출금할 예정", "결제될 예정", "출금 예정이에요",
                       "결제일 안내", "결제예정일: 10/30", "입금 예정", "지급 예정", "송금 예정", "이체 예정"] {
            financeFixtures.append(("테스트은행 \(notice)\n38,000원\n가맹점: 테스트상점", false))
        }
        for event in ["카드 1234 승인", "출금 완료", "입금 완료", "환불 완료", "카드 1234 승인취소",
                      "결제 완료", "송금 완료", "이체 완료"] {
            for extra in ["", "\n결제예정일: 11/25", "\n결제 예정일: 2026-11-25",
                          "\n[유의사항] 쿠폰은 연장 및 환불이 불가합니다.", "\n[유의사항] 쿠폰 취소/환불 불가",
                          "\n쿠폰 안내: 쿠폰번호 TEST-ONLY, 환불이 불가합니다.",
                          "\n결제예정일: 11/25\n쿠폰 안내: 환불 불가"] {
                financeFixtures.append(("\(event)\n38,000원\n가맹점: 테스트상점\(extra)", true))
            }
        }
        let mismatches = financeFixtures.filter { NotificationSetupState.isPayment($0.0) != $0.1 }
        precondition(mismatches.isEmpty, "Finance filter mismatches: \(mismatches)")
        print("PASS: \(financeFixtures.count) notice/transaction fixtures")
        print("PASS: setup stages, member isolation, expiring one-use notification test, finance filter and recursion guard")
    }
}
