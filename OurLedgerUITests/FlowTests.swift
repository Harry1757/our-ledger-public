import XCTest

final class FlowTests: XCTestCase {
    @MainActor func testEntryDefaultsSelfExpenseAndPrivacyChoice() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["OURLEDGER_TEST_SERVER"] = "http://127.0.0.1:18817"
        app.launch()
        connectLocalLedgerIfNeeded(in: app)
        app.buttons["addEntry"].tap()
        XCTAssertTrue(app.buttons["entryKind-expense"].isSelected)
        let inheritedShared = app.buttons["scopeShared"].isSelected
        let inheritedPersonal = app.buttons["scopePersonal"].isSelected
        app.textFields["entryAmount"].tap(); app.textFields["entryAmount"].typeText("8400")
        focusEntryNote(in: app)
        let note = "기본값 회귀 " + String(UUID().uuidString.prefix(6))
        app.textFields["entryNote"].typeText(note)
        XCTAssertEqual(app.buttons["scopeShared"].isSelected, inheritedShared)
        XCTAssertEqual(app.buttons["scopePersonal"].isSelected, inheritedPersonal)
        XCTAssertEqual(app.buttons["saveEntry"].isEnabled, inheritedShared || inheritedPersonal, "호출부의 공개 범위를 보존하고 미선택이면 저장을 막는다")
        app.buttons["scopePersonal"].tap()
        XCTAssertTrue(app.buttons["saveEntry"].isEnabled)
        XCTAssertTrue(reveal(app.buttons["entryPaymentOptions"], in: app))
        app.buttons["entryPaymentOptions"].tap()
        // iOS 27 inherits the disclosure group's identifier on its picker rows.
        let payer = app.buttons["결제한 사람, 나"]
        XCTAssertTrue(payer.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(payer.label.contains("나") || (payer.value as? String)?.contains("나") == true, payer.debugDescription)
        capture(app, "entry-default-self-expense-personal")
        app.buttons["saveEntry"].tap()
        XCTAssertTrue(app.textFields["entryNote"].waitForNonExistence(timeout: 10))
        if app.buttons["저장 안내 닫기"].exists { app.buttons["저장 안내 닫기"].tap() }
        XCTAssertTrue(reveal(app.buttons["ledgerScope-personal"], in: app, upward: false))
        app.buttons["ledgerScope-personal"].tap()
        XCTAssertTrue(reveal(app.staticTexts[note], in: app))
    }

    @MainActor func testACoupleInviteSettlementAndDuplicateComparison() async throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["OURLEDGER_TEST_SERVER"] = "http://127.0.0.1:18817"
        app.launch()
        guard app.textFields["memberName"].waitForExistence(timeout: 5) else {
            throw XCTSkip("초대 참여 검사는 운영 연결이 없는 새 시뮬레이터에서 실행해 주세요.")
        }
        let owner = try await call("/households", body: ["name": "검증 가계부", "memberName": "테스트상대", "mode": "separate"])
        let token = owner["token"] as! String
        let invitation = try await call("/invite", body: [:], token: token)
        var link = URLComponents()
        link.scheme = "ourledger"; link.host = "join"
        link.queryItems = [URLQueryItem(name: "server", value: "http://127.0.0.1:18817"), URLQueryItem(name: "invite", value: invitation["invite"] as? String)]
        app.buttons["초대받았어요"].tap()
        app.textFields["memberName"].tap()
        app.textFields["memberName"].typeText("테스트순환\n")
        let field = app.textFields["inviteLink"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(link.url!.absoluteString)
        app.buttons["createHousehold"].tap()
        XCTAssertTrue(app.buttons["addEntry"].waitForExistence(timeout: 15))
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"; formatter.timeZone = TimeZone(identifier: "Asia/Seoul")
        let month = formatter.string(from: Date())
        let state = try await call("/state?month=" + month, token: token)
        let members = state["members"] as! [[String: Any]]
        let me = members.first { ($0["id"] as? String) != (owner["memberID"] as? String) }!["id"] as! String
        _ = try await call("/entries", body: ["amount": 300000, "note": "공용 장보기", "scope": "shared", "day": month + "-01"], token: token)
        _ = try await call("/entries", body: ["amount": 200000, "note": "공용 생활용품", "scope": "shared", "payer": me, "day": month + "-02"], token: token)
        _ = try await call("/entries", body: ["amount": 7300, "note": "상대만의 비공개 기록", "scope": "personal", "day": month + "-02"], token: token)
        _ = try await call("/settings", body: ["budget": 100000], token: token, method: "PATCH")
        app.terminate(); app.launch()
        XCTAssertTrue(reveal(app.buttons["settlementDetails"], in: app))
        app.buttons["settlementDetails"].tap()
        XCTAssertTrue(reveal(app.staticTexts["50,000원"], in: app), "30만/20만 공용 결제는 5만원 정산이어야 함")
        XCTAssertTrue(reveal(app.buttons["completeSettlement"], in: app))
        let settlement = XCTAttachment(screenshot: app.screenshot())
        settlement.name = "settlement-basis"; settlement.lifetime = .keepAlways; add(settlement)
        app.tabBars.buttons["설정"].tap()
        XCTAssertTrue(reveal(app.textFields["bankName"], in: app))
        _ = try await call("/settings", body: ["budget": 200000], token: token, method: "PATCH")
        app.textFields["bankName"].tap(); app.textFields["bankName"].typeText("테스트은행")
        XCTAssertTrue(reveal(app.buttons["saveSettings"], in: app)); app.buttons["saveSettings"].tap()
        XCTAssertTrue(app.buttons["저장했어요"].waitForExistence(timeout: 10))
        let after = try await call("/state?month=" + month, token: token)
        XCTAssertEqual((after["household"] as! [String: Any])["budget"] as? Int, 200000, "계좌만 저장할 때 상대가 바꾼 예산을 되돌리면 안 됨")
        app.tabBars.buttons["확인함"].tap()
        let merchant = "비교테스트마트"
        for (reference, time) in [("111111", "13:00"), ("222222", "13:02")] {
            XCTAssertTrue(reveal(app.buttons["pasteNotification"], in: app))
            app.buttons["pasteNotification"].tap(); app.textViews["notificationText"].tap()
            app.textViews["notificationText"].typeText("카드 1234 승인 3,200원\n가맹점: " + merchant + "\n승인번호 " + reference + "\n" + String(month.suffix(2)) + "/21 " + time)
            app.buttons["importNotification"].tap()
            XCTAssertTrue(app.buttons["importNotification"].waitForNonExistence(timeout: 10))
            if reference == "111111" {
                XCTAssertTrue(app.textFields["entryAmount"].waitForExistence(timeout: 10), "명확한 첫 알림은 기록 화면을 바로 열어야 함")
                XCTAssertEqual(app.textFields["entryAmount"].value as? String, "3,200")
                XCTAssertEqual(app.textFields["entryNote"].value as? String, merchant)
                XCTAssertFalse(app.buttons["saveEntry"].isEnabled)
                app.buttons["취소"].tap()
                XCTAssertTrue(app.buttons["pasteNotification"].waitForExistence(timeout: 5))
                XCTAssertTrue(reveal(app.buttons[merchant + " 기록"], in: app), "중복 비교용 첫 알림은 기록하지 않고 확인함에 남겨야 함")
            }
        }
        let compare = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "mergeCandidate-")).firstMatch
        XCTAssertTrue(reveal(compare, in: app))
        let duplicate = XCTAttachment(screenshot: app.screenshot())
        duplicate.name = "duplicate-comparison"; duplicate.lifetime = .keepAlways; add(duplicate)
        compare.tap(); app.buttons["같은 결제 확인 · 알림 합치기"].tap()
        XCTAssertTrue(reveal(app.buttons["pasteNotification"], in: app, upward: false))
        XCTAssertEqual(app.staticTexts.matching(identifier: merchant).count, 1, "같은 결제의 확인 전 알림은 하나만 남아야 함")
    }

    @MainActor func testFirstRunManualEntryAndNotificationInbox() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["OURLEDGER_TEST_SERVER"] = "http://127.0.0.1:18817"
        app.launch()
        if app.textFields["memberName"].waitForExistence(timeout: 3) {
            app.textFields["memberName"].tap()
            app.textFields["memberName"].typeText("테스트순환")
            app.buttons["createHousehold"].tap()
        }
        XCTAssertTrue(app.buttons["addEntry"].waitForExistence(timeout: 15))
        let suffix = String(UUID().uuidString.prefix(6))
        let note = "시장 반찬 " + suffix
        app.buttons["addEntry"].tap()
        app.textFields["entryAmount"].tap()
        app.textFields["entryAmount"].typeText("18000")
        focusEntryNote(in: app)
        app.textFields["entryNote"].typeText(note)
        XCTAssertFalse(app.buttons["saveEntry"].isEnabled, "공용/개인을 고르기 전에는 기록을 저장하면 안 됨")
        app.buttons["scopeShared"].tap()
        app.buttons["saveEntry"].tap()
        XCTAssertTrue(reveal(app.staticTexts[note], in: app))
        app.tabBars.buttons["통계"].tap()
        XCTAssertTrue(reveal(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "category-")).firstMatch, in: app))
        let statistics = XCTAttachment(screenshot: app.screenshot())
        statistics.name = "statistics"
        statistics.lifetime = .keepAlways
        add(statistics)
        app.tabBars.buttons["확인함"].tap()
        XCTAssertTrue(reveal(app.buttons["pasteNotification"], in: app))
        app.buttons["pasteNotification"].tap()
        app.textViews["notificationText"].tap()
        let merchant = "테스트마트 " + suffix
        let transaction = "카드 1234 승인 32,000원\n가맹점: " + merchant + "\n승인번호 " + suffix + "\n10/20 13:00"
        app.textViews["notificationText"].typeText(transaction)
        app.buttons["importNotification"].tap()
        XCTAssertTrue(app.buttons["importNotification"].waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.textFields["entryAmount"].waitForExistence(timeout: 10), "명확한 알림은 확인함 재선택 없이 기록 화면을 열어야 함")
        XCTAssertEqual(app.textFields["entryAmount"].value as? String, "32,000")
        XCTAssertEqual(app.textFields["entryNote"].value as? String, merchant)
        let inbox = XCTAttachment(screenshot: app.screenshot())
        inbox.name = "import-auto-entry"
        inbox.lifetime = .keepAlways
        add(inbox)
        XCTAssertTrue(app.buttons["saveEntry"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["saveEntry"].isEnabled, "가져온 알림도 사용자가 공개 범위를 선택해야 함")
        app.buttons["scopeShared"].tap()
        app.buttons["saveEntry"].tap()
        XCTAssertTrue(app.staticTexts["paymentFlowComplete"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["finishPaymentFlow"].waitForExistence(timeout: 5))
        app.buttons["finishPaymentFlow"].tap()
        XCTAssertTrue(app.buttons["pasteNotification"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts[merchant].exists)
        app.buttons["pasteNotification"].tap()
        app.buttons["앱 알림"].tap()
        app.textViews["notificationText"].tap()
        app.textViews["notificationText"].typeText(transaction)
        app.buttons["importNotification"].tap()
        XCTAssertTrue(app.buttons["pasteNotification"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts[merchant].exists, "이미 기록한 문자의 앱 알림이 새 결제로 생기면 안 됨")
        app.tabBars.buttons["가계부"].tap()
        let search = openLedgerSearch(in: app)
        search.tap(); search.typeText(merchant + "\n")
        XCTAssertTrue(app.staticTexts["공용 검색 결과"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["거래 달력"].exists, "검색 결과를 달력 아래로 밀지 않아야 함")
        XCTAssertTrue(reveal(app.staticTexts[merchant], in: app))
        let home = XCTAttachment(screenshot: app.screenshot())
        home.name = "ledger"
        home.lifetime = .keepAlways
        add(home)
        app.tabBars.buttons["설정"].tap()
        if app.buttons["초대 링크 만들기"].waitForExistence(timeout: 3) {
            app.buttons["초대 링크 만들기"].tap()
            XCTAssertTrue(app.buttons["초대 링크 복사"].waitForExistence(timeout: 5))
            app.buttons["초대 링크 복사"].tap()
        }
    }

    @MainActor func testScopePolishConnectedScreens() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["OURLEDGER_TEST_SERVER"] = "http://127.0.0.1:18817"
        app.launch()
        connectLocalLedgerIfNeeded(in: app)
        app.buttons["ledgerScope-shared"].tap()
        capture(app, "polish-shared-home")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.83))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.28)))
        XCTAssertTrue(app.buttons["ledgerScope-shared"].isHittable)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.52)))
        capture(app, "polish-action-rows")
        let month = String(dayForUITest().prefix(7))
        let day = app.buttons["calendar-" + month + "-03"]
        XCTAssertTrue(reveal(day, in: app))
        day.tap()
        capture(app, "polish-calendar-both")
        app.buttons["ledgerScope-personal"].tap()
        XCTAssertTrue(app.buttons["ledgerScope-personal"].isSelected)
        capture(app, "polish-sticky-personal")
        XCTAssertTrue(reveal(app.buttons["addEntry"], in: app, upward: false))
        capture(app, "polish-personal-home")
        app.terminate()
        app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.buttons["ledgerScope-personal"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["ledgerScope-personal"].isSelected)
        XCTAssertTrue(app.frame.contains(app.buttons["ledgerScope-personal"].frame))
        XCTAssertLessThan(app.buttons["ledgerScope-personal"].frame.height, 100, "큰 글씨에서 범위 선택이 화면을 차지하지 않음")
        capture(app, "polish-large-personal")
        app.buttons["ledgerScope-shared"].tap()
        XCTAssertTrue(reveal(day, in: app))
        capture(app, "polish-large-calendar")
    }

    private func dayForUITest() -> String {
        let format = DateFormatter(); format.dateFormat = "yyyy-MM-dd"; format.timeZone = TimeZone(identifier: "Asia/Seoul")
        return format.string(from: Date())
    }

    @MainActor func testLedgerScopeSurvivesNavigationAndRelaunch() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["OURLEDGER_TEST_SERVER"] = "http://127.0.0.1:18817"
        app.launch()
        connectLocalLedgerIfNeeded(in: app)
        app.buttons["ledgerScope-shared"].tap()
        capture(app, "scope-before-shared")
        app.buttons["ledgerScope-personal"].tap()
        XCTAssertTrue(app.buttons["ledgerScope-personal"].isSelected)
        capture(app, "scope-personal")
        app.tabBars.buttons["설정"].tap()
        app.tabBars.buttons["가계부"].tap()
        XCTAssertTrue(app.buttons["ledgerScope-personal"].isSelected)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["ledgerScope-personal"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["ledgerScope-personal"].isSelected, "선택한 개인 범위는 앱 재실행 후에도 유지되어야 함")
        capture(app, "scope-restored-personal")
        app.swipeUp()
        XCTAssertTrue(app.buttons["ledgerScope-personal"].isHittable, "스크롤해도 범위 선택이 보여야 함")
        capture(app, "scope-sticky-personal")
        app.tabBars.buttons["설정"].tap()
        XCTAssertTrue(reveal(app.buttons["replayFeatureTour"], in: app))
        app.buttons["replayFeatureTour"].tap()
        for _ in 0..<6 {
            let next = app.buttons["featureTourNext"]
            XCTAssertTrue(next.waitForExistence(timeout: 5))
            next.tap()
        }
        XCTAssertFalse(app.buttons["featureTourNext"].exists)
        app.tabBars.buttons["가계부"].tap()
        XCTAssertTrue(app.buttons["ledgerScope-personal"].isSelected, "사용법 안내 후에도 범위를 바꾸지 않음")
        app.buttons["ledgerScope-shared"].tap()
        XCTAssertTrue(app.buttons["ledgerScope-shared"].isSelected)
    }

    @MainActor func testPersonalScopeSearchAndRecentDraft() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["OURLEDGER_TEST_SERVER"] = "http://127.0.0.1:18817"
        app.launch()
        connectLocalLedgerIfNeeded(in: app)
        XCTAssertTrue(app.buttons["addEntry"].waitForExistence(timeout: 15))
        let note = "개인 커피 " + String(UUID().uuidString.prefix(6))
        app.buttons["addEntry"].tap()
        app.textFields["entryAmount"].tap()
        app.textFields["entryAmount"].typeText("1800")
        XCTAssertEqual((app.textFields["entryAmount"].value as? String)?.replacingOccurrences(of: ",", with: ""), "1800")
        focusEntryNote(in: app)
        app.textFields["entryNote"].typeText(note)
        XCTAssertFalse(app.buttons["saveEntry"].isEnabled)
        app.buttons["scopePersonal"].tap()
        XCTAssertEqual(app.buttons["scopePersonal"].value as? String, "선택됨")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 4), "공개 범위를 선택한 뒤에는 키보드가 선택 내용을 가리면 안 됨")
        let entry = XCTAttachment(screenshot: app.screenshot())
        entry.name = "entry-personal"
        entry.lifetime = .keepAlways
        add(entry)
        app.buttons["saveEntry"].tap()
        XCTAssertTrue(app.buttons["addEntry"].waitForExistence(timeout: 10))
        if app.buttons["저장 안내 닫기"].exists { app.buttons["저장 안내 닫기"].tap() }
        let search = openLedgerSearch(in: app)
        if !search.isHittable { app.swipeDown() }
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText(note + "\n")
        XCTAssertTrue(reveal(app.staticTexts["entryListSummary"], in: app))
        XCTAssertTrue(app.staticTexts["entryListSummary"].label.hasPrefix("0건"), "개인 거래는 공용 검색에 나타나면 안 됨")
        XCTAssertFalse(app.staticTexts[note].exists)
        app.swipeDown()
        let scope = app.buttons["ledgerScope-personal"]
        XCTAssertTrue(reveal(scope, in: app, upward: false))
        scope.tap()
        XCTAssertTrue(reveal(app.staticTexts[note], in: app))
        let privateLedger = XCTAttachment(screenshot: app.screenshot())
        privateLedger.name = "private-search"
        privateLedger.lifetime = .keepAlways
        add(privateLedger)
        XCTAssertTrue(reveal(app.buttons["toggleLedgerSearch"], in: app, upward: false))
        app.buttons["toggleLedgerSearch"].tap()
        XCTAssertTrue(reveal(app.buttons["addEntry"], in: app, upward: false))
        app.buttons["addEntry"].tap()
        XCTAssertFalse(app.buttons["saveEntry"].isEnabled)
        XCTAssertTrue(reveal(app.buttons["recentDrafts"], in: app))
        capture(app, "recent-draft-before-opening")
        app.buttons["recentDrafts"].tap()
        capture(app, "recent-draft-chooser")
        let draft = app.buttons[note + " · 1,800원"]
        XCTAssertTrue(draft.waitForExistence(timeout: 5), app.debugDescription)
        draft.tap()
        XCTAssertEqual(app.textFields["entryNote"].value as? String, note)
        XCTAssertEqual(app.textFields["entryAmount"].value as? String, "1,800")
        XCTAssertEqual(app.buttons["scopeShared"].value as? String, "선택 안 됨")
        XCTAssertEqual(app.buttons["scopePersonal"].value as? String, "선택 안 됨")
        XCTAssertFalse(app.buttons["saveEntry"].isEnabled, "최근 내용을 불러와도 공개 범위를 대신 선택하면 안 됨")
        capture(app, "recent-draft-restored-without-scope")
        app.buttons["취소"].tap()
    }

    @MainActor func testSaveNoticeKeepsRecurringNavigationAccessible() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["OURLEDGER_TEST_SERVER"] = "http://127.0.0.1:18817"
        app.launch()
        if app.textFields["memberName"].waitForExistence(timeout: 3) {
            app.textFields["memberName"].tap()
            app.textFields["memberName"].typeText("화면 검증")
            app.buttons["createHousehold"].tap()
        }
        XCTAssertTrue(app.buttons["addEntry"].waitForExistence(timeout: 10))
        if app.buttons["저장 안내 닫기"].exists { app.buttons["저장 안내 닫기"].tap() }
        XCTAssertTrue(app.staticTexts["summaryAmount"].waitForExistence(timeout: 5))
        capture(app, "home-blue-hero")
        app.buttons["addEntry"].tap()
        app.textFields["entryAmount"].tap(); app.textFields["entryAmount"].typeText("1")
        focusEntryNote(in: app); app.textFields["entryNote"].typeText("탐색 영역 확인")
        XCTAssertTrue(reveal(app.buttons["scopeShared"], in: app)); app.buttons["scopeShared"].tap()
        app.buttons["saveEntry"].tap()
        XCTAssertTrue(app.buttons["addEntry"].waitForExistence(timeout: 10))
        XCTAssertTrue(reveal(app.buttons["openRecurring"], in: app))
        app.buttons["openRecurring"].tap()
        let bar = app.navigationBars["정기결제"]
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        let back = bar.buttons["BackButton"]
        let title = bar.staticTexts["정기결제"]
        XCTAssertTrue(back.isHittable)
        XCTAssertTrue(title.isHittable)
        let noticeClose = app.buttons["저장 안내 닫기"]
        XCTAssertTrue(noticeClose.exists)
        XCTAssertFalse(bar.frame.intersects(noticeClose.frame), "저장 안내가 탐색 막대를 덮으면 안 돼요")
        capture(app, "recurring-navigation-with-save-notice")
        app.buttons["addRecurring"].tap()
        XCTAssertTrue(app.textFields["recurringName"].waitForExistence(timeout: 5))
        capture(app, "recurring-add-after-navigation-fix")
        app.buttons["취소"].tap()
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        XCTAssertTrue(reveal(app.buttons["addEntry"], in: app, upward: false))
    }

    @MainActor func testCalendarRecurringConfirmationAndExistingLink() async throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["OURLEDGER_TEST_SERVER"] = "http://127.0.0.1:18817"
        app.launch()
        guard app.textFields["memberName"].waitForExistence(timeout: 5) else {
            throw XCTSkip("달력·정기결제 검사는 새 전용 시뮬레이터에서 실행해 주세요.")
        }
        let owner = try await call("/households", body: ["name": "푸른 생활 가계부", "memberName": "테스트상대", "mode": "separate"])
        let token = owner["token"] as! String
        let invite = try await call("/invite", body: [:], token: token)
        var url = URLComponents(); url.scheme = "ourledger"; url.host = "join"
        url.queryItems = [URLQueryItem(name: "server", value: "http://127.0.0.1:18817"), URLQueryItem(name: "invite", value: invite["invite"] as? String)]
        app.buttons["초대받았어요"].tap()
        app.textFields["memberName"].tap(); app.textFields["memberName"].typeText("테스트순환\n")
        app.textFields["inviteLink"].typeText(url.url!.absoluteString)
        app.buttons["createHousehold"].tap()
        XCTAssertTrue(app.buttons["addEntry"].waitForExistence(timeout: 15))
        let df = DateFormatter(); df.timeZone = TimeZone(identifier: "Asia/Seoul"); df.dateFormat = "yyyy-MM"
        let month = df.string(from: Date())
        let seeds = [("01",150000,"월초 장보기"),("03",42000,"주말 외식"),("07",38900,"생필품"),("10",15600,"출근 교통"),("14",58400,"마트 장보기"),("18",22000,"주말 브런치"),("20",7300,"동네 빵집"),("21",3200,"아침 커피")]
        for (day, amount, note) in seeds {
            _ = try await call("/entries", body: ["amount": amount,"note": note,"scope": "shared","day": month + "-" + day], token: token)
        }
        _ = try await call("/settings", body: ["budget":500000], token: token, method: "PATCH")
        app.terminate(); app.launch()
        XCTAssertTrue(reveal(app.buttons["calendar-" + month + "-01"], in: app))
        capture(app, "home-calendar-blue")
        app.buttons["calendar-" + month + "-01"].tap()
        XCTAssertTrue(reveal(app.staticTexts["월초 장보기"], in: app))
        XCTAssertFalse(app.staticTexts["주말 외식"].exists)
        capture(app, "calendar-selected-blue")
        XCTAssertTrue(reveal(app.buttons["calendarAllDays"], in: app, upward: false)); app.buttons["calendarAllDays"].tap()
        app.buttons["addEntry"].tap()
        app.textFields["entryAmount"].tap(); app.textFields["entryAmount"].typeText("9800")
        focusEntryNote(in: app); app.textFields["entryNote"].typeText("이미 결제한 구독")
        XCTAssertTrue(reveal(app.buttons["scopeShared"], in: app)); app.buttons["scopeShared"].tap()
        app.buttons["saveEntry"].tap(); XCTAssertTrue(app.buttons["addEntry"].waitForExistence(timeout: 10))
        let baseline = seeds.reduce(0) { $0 + $1.1 } + 9800
        XCTAssertTrue(reveal(app.buttons["openRecurring"], in: app)); app.buttons["openRecurring"].tap()
        func addPlan(_ name: String, _ value: String) {
            XCTAssertTrue(reveal(app.buttons["addRecurring"], in: app, upward: false))
            let add = app.buttons["addRecurring"]
            let noticeClose = app.buttons["저장 안내 닫기"]
            if noticeClose.exists {
                XCTAssertFalse(add.frame.intersects(noticeClose.frame), "저장 안내가 일정 추가를 가리면 안 돼요")
            }
            add.tap()
            XCTAssertTrue(app.textFields["recurringName"].waitForExistence(timeout: 5))
            app.textFields["recurringName"].tap(); app.textFields["recurringName"].typeText(name)
            app.textFields["recurringAmount"].tap(); app.textFields["recurringAmount"].typeText(value)
            XCTAssertTrue(reveal(app.buttons["recurringScope"], in: app)); app.buttons["recurringScope"].tap()
            app.buttons["공용"].tap()
            app.buttons["saveRecurring"].tap()
            XCTAssertTrue(app.buttons["addRecurring"].waitForExistence(timeout: 10))
        }
        addPlan("이미 결제한 구독", "9800")
        var snapshot = try await call("/state?month=" + month, token: token)
        XCTAssertEqual((snapshot["stats"] as! [String:Any])["total"] as? Int, baseline, "예정만 추가하면 실제 지출이 늘면 안 됨")
        var plans = snapshot["recurringPayments"] as! [[String:Any]]
        let linkedID = plans.first { $0["note"] as? String == "이미 결제한 구독" }!["id"] as! String
        capture(app, "recurring-planned-blue")
        XCTAssertTrue(reveal(app.buttons["linkRecurring-" + linkedID], in: app)); app.buttons["linkRecurring-" + linkedID].tap()
        let candidate = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "이미 결제한 구독")).firstMatch
        XCTAssertTrue(reveal(candidate, in: app)); candidate.tap()
        app.buttons["연결"].tap(); app.buttons["이 지출 연결"].tap()
        XCTAssertTrue(app.buttons["addRecurring"].waitForExistence(timeout: 10))
        snapshot = try await call("/state?month=" + month, token: token)
        XCTAssertEqual((snapshot["stats"] as! [String:Any])["total"] as? Int, baseline, "기존 지출 연결은 중복으로 더하면 안 됨")
        addPlan("매달 음악 구독", "3700")
        snapshot = try await call("/state?month=" + month, token: token); plans = snapshot["recurringPayments"] as! [[String:Any]]
        let newID = plans.first { $0["note"] as? String == "매달 음악 구독" }!["id"] as! String
        XCTAssertTrue(reveal(app.buttons["recordRecurring-" + newID], in: app)); app.buttons["recordRecurring-" + newID].tap()
        XCTAssertTrue(app.buttons["saveEntry"].waitForExistence(timeout: 5)); capture(app, "recurring-review-blue")
        app.buttons["saveEntry"].tap()
        XCTAssertTrue(app.buttons["addRecurring"].waitForExistence(timeout: 10))
        snapshot = try await call("/state?month=" + month, token: token)
        XCTAssertEqual((snapshot["stats"] as! [String:Any])["total"] as? Int, baseline + 3700)
        let records = (snapshot["entries"] as! [[String:Any]]).filter { $0["recurringID"] as? String == newID }
        XCTAssertEqual(records.count, 1)
        capture(app, "recurring-recorded-blue")
        app.tabBars.buttons["통계"].tap(); capture(app, "statistics-blue")
        app.tabBars.buttons["확인함"].tap(); capture(app, "inbox-blue")
        app.tabBars.buttons["설정"].tap(); capture(app, "settings-blue")
    }

    @MainActor func testInvitedMemberCanStartFeatureTour() async throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["OURLEDGER_TEST_SERVER"] = "http://127.0.0.1:18817"
        app.launchEnvironment["OURLEDGER_SHOW_GUIDE"] = "automatic"
        app.launch()
        guard app.textFields["memberName"].waitForExistence(timeout: 5) else {
            throw XCTSkip("초대 가이드 검사는 새 격리 시뮬레이터에서 실행해 주세요.")
        }
        let owner = try await call("/households", body: ["name": "초대 가이드 검증", "memberName": "초대한 사람", "mode": "separate"])
        let token = owner["token"] as! String
        let invite = try await call("/invite", body: [:], token: token)
        var url = URLComponents(); url.scheme = "ourledger"; url.host = "join"
        url.queryItems = [URLQueryItem(name: "server", value: "http://127.0.0.1:18817"), URLQueryItem(name: "invite", value: invite["invite"] as? String)]
        app.buttons["초대받았어요"].tap()
        app.textFields["memberName"].tap(); app.textFields["memberName"].typeText("초대받은 사람\n")
        app.textFields["inviteLink"].typeText(url.url!.absoluteString)
        app.buttons["createHousehold"].tap()
        XCTAssertTrue(app.buttons["automationGuideNext"].waitForExistence(timeout: 15))
        for _ in 0..<3 { app.buttons["automationGuideNext"].tap() }
        app.buttons["guideClose"].tap()
        XCTAssertTrue(app.buttons["featureTourNext"].waitForExistence(timeout: 8), "초대 가입 후 첫 설정을 나중으로 미뤄도 사용법은 표시해야 함")
        capture(app, "invite-tour-start")
        app.buttons["featureTourNext"].tap()
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["featureTourNext"].waitForExistence(timeout: 15), "중간 종료한 기능 안내는 다음 실행에서 복구")
        XCTAssertFalse(app.buttons["featureTourBack"].isEnabled)
        capture(app, "invite-tour-resumed")
        for _ in 0..<7 {
            XCTAssertTrue(app.buttons["featureTourNext"].waitForExistence(timeout: 5))
            app.buttons["featureTourNext"].tap()
        }
        XCTAssertTrue(app.buttons["featureTourNext"].waitForNonExistence(timeout: 5))
        capture(app, "invite-tour-complete")
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["addEntry"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["featureTourNext"].exists, "완료한 안내는 매 실행마다 반복하지 않음")
        XCTAssertFalse(app.buttons["automationGuideNext"].exists)
    }

    @MainActor func testAutomationGuideAndFeatureTourStates() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["OURLEDGER_TEST_SERVER"] = "http://127.0.0.1:18817"
        app.launchEnvironment["OURLEDGER_SHOW_GUIDE"] = "1"
        app.launch()
        if app.textFields["memberName"].waitForExistence(timeout: 5) {
            app.textFields["memberName"].tap()
            app.textFields["memberName"].typeText("가이드검증\n")
            app.buttons["createHousehold"].tap()
        }
        XCTAssertTrue(app.buttons["automationGuideNext"].waitForExistence(timeout: 15))
        for _ in 0..<3 {
            if !app.buttons["이전"].exists { break }
            app.buttons["이전"].tap()
        }
        XCTAssertEqual(app.buttons["automationGuideNext"].label, "자동화 설정하기")
        capture(app, "ux-guide-welcome")
        app.buttons["automationGuideNext"].tap()
        XCTAssertTrue(app.buttons["addAutomationShortcut"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["automationDefaults"].exists)
        XCTAssertEqual(app.buttons["addAutomationShortcut"].label, "1. 단축어 추가하기")
        XCTAssertEqual(app.buttons["openAppAutomation"].label, "2. 결제 앱 추가하기")
        XCTAssertFalse(app.staticTexts["테스트용으로 ‘우리 가계부’도 포함해 주세요"].exists)
        capture(app, "ux-guide-setup")
        app.buttons["등록 화면이 안 나오나요?"].tap()
        XCTAssertTrue(app.buttons["openShortcutInstallPage"].waitForExistence(timeout: 5),
                      "A missing import preview needs the installation page, not just the existing collection")
        XCTAssertTrue(app.staticTexts["shortcutInstallRecovery"].exists)
        // shortcut: Safari rendered a blank sheet here; check import/close on iPhone until its simulator service works.
        XCTAssertTrue(app.buttons["openShortcutsApp"].waitForExistence(timeout: 5),
                      "A missed shortcut navigation needs an independent way to open the app")
        XCTAssertTrue(app.staticTexts["shortcutRecoveryInstructions"].exists)
        XCTAssertFalse(app.staticTexts["automationTestPassed"].exists,
                       "Opening help must not certify the notification connection")
        capture(app, "ux-guide-shortcut-recovery")
        XCTAssertTrue(app.buttons["openAppAutomation"].waitForExistence(timeout: 5))
        app.buttons["automationGuideNext"].tap()
        XCTAssertTrue(app.buttons["openAutomationActivation"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["automationActivationReason"].exists)
        XCTAssertTrue(app.staticTexts["메시지 수신 조건"].exists)
        XCTAssertTrue(app.staticTexts["앱 알림 조건"].exists)
        XCTAssertEqual(app.buttons["automationGuideNext"].label, "두 자동화를 켰어요 · 다음")
        capture(app, "ux-guide-automation-activation")
        app.buttons["이전"].tap()
        XCTAssertTrue(app.buttons["openAppAutomation"].waitForExistence(timeout: 5))
        app.buttons["automationGuideNext"].tap()
        XCTAssertTrue(app.buttons["openAutomationActivation"].waitForExistence(timeout: 5))
        app.buttons["automationGuideNext"].tap()
        capture(app, "ux-guide-notification-permission")
        advanceToNotificationTest(in: app)
        XCTAssertFalse(app.staticTexts["automationTestPassed"].exists,
                       "Opening setup and claiming saved must never certify automatic delivery")
        capture(app, "ux-guide-test-unverified")
        app.buttons["sendAutomationTest"].tap()
        let sending = app.activityIndicators["testNotificationSending"]
        XCTAssertTrue(sending.waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["sendAutomationTest"].isEnabled, "보내는 동안 중복 요청을 막아야 함")
        capture(app, "ux-guide-test-sending")
        XCTAssertTrue(sending.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["sendAutomationTest"].isEnabled)
        XCTAssertFalse(app.staticTexts["paymentPracticePassed"].exists, "보내기만으로 기록 연습을 완료 처리하면 안 됨")
        XCTAssertFalse(app.staticTexts["automationTestPassed"].exists, "연습 알림 예약은 자동 전달 성공의 증거가 아님")
        app.buttons["automationGuideNext"].tap()
        XCTAssertTrue(app.buttons["featureTourNext"].waitForExistence(timeout: 8))
        for index in 0..<7 {
            if !app.buttons["featureTourNext"].exists { break }
            XCTAssertTrue(app.buttons["featureTourNext"].waitForExistence(timeout: 5))
            capture(app, "ux-tour-" + String(index))
            app.buttons["featureTourNext"].tap()
        }
        XCTAssertFalse(app.buttons["featureTourNext"].exists)
        app.tabBars.buttons["설정"].tap()
        XCTAssertTrue(app.buttons["replayFeatureTour"].waitForExistence(timeout: 5))
        app.buttons["replayFeatureTour"].tap()
        XCTAssertTrue(app.buttons["featureTourSkip"].waitForExistence(timeout: 5))
        app.buttons["featureTourSkip"].tap()
        app.tabBars.buttons["설정"].tap()
        app.buttons["notificationGuide"].tap()
        XCTAssertTrue(app.buttons["sendAutomationTest"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["addAutomationShortcut"].exists,
                       "Configured devices open the connection/test state, not the first setup CTA")
        app.buttons["guideClose"].tap()
        app.tabBars.buttons["가계부"].tap()
        XCTAssertTrue(app.buttons["addEntry"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["이전 달"].isEnabled)
        XCTAssertFalse(app.buttons["다음 달"].isEnabled)
        capture(app, "ux-empty-home")
        app.buttons["addEntry"].tap()
        XCTAssertFalse(app.buttons["saveEntry"].isEnabled)
        capture(app, "ux-entry-empty")
    }

    @MainActor func testFeatureTourVisualHierarchy() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["OURLEDGER_TEST_SERVER"] = "http://127.0.0.1:18817"
        for size in ["normal", "large"] {
            if size == "large" {
                app.terminate()
                app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
            }
            app.launch()
            connectLocalLedgerIfNeeded(in: app)
            app.tabBars.buttons["설정"].tap()
            XCTAssertTrue(reveal(app.buttons["replayFeatureTour"], in: app))
            app.buttons["replayFeatureTour"].tap()
            for index in 0..<6 {
                let next = app.buttons["featureTourNext"]
                XCTAssertTrue(next.waitForExistence(timeout: 5))
                capture(app, "tour-hierarchy-" + size + "-" + String(index) + "-top")
                for _ in 0..<5 {
                    if next.isHittable && app.frame.contains(next.frame) { break }
                    app.scrollViews.containing(.button, identifier: "featureTourNext").firstMatch.swipeUp()
                }
                XCTAssertTrue(next.isHittable)
                XCTAssertTrue(app.frame.contains(next.frame))
                XCTAssertGreaterThanOrEqual(next.frame.height, 44)
                capture(app, "tour-hierarchy-" + size + "-" + String(index))
                next.tap()
            }
            XCTAssertFalse(app.buttons["featureTourNext"].exists)
        }
    }

    @MainActor func testMobileNavigationVisualPolish() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["OURLEDGER_TEST_SERVER"] = "http://127.0.0.1:18817"
        app.launch()
        connectLocalLedgerIfNeeded(in: app)
        let shared = app.buttons["ledgerScope-shared"]
        let personal = app.buttons["ledgerScope-personal"]
        XCTAssertTrue(shared.waitForExistence(timeout: 5))
        shared.tap()
        XCTAssertGreaterThanOrEqual(shared.frame.height, 48)
        XCTAssertGreaterThanOrEqual(personal.frame.height, 48)
        XCTAssertEqual(shared.frame.width, personal.frame.width, accuracy: 1)
        XCTAssertTrue(shared.isSelected)
        XCTAssertFalse(app.navigationBars.firstMatch.exists, "하단 탭 제목을 상단에 반복하지 않음")
        XCTAssertLessThan(app.staticTexts["selectedMonth"].frame.minY, 205, "고정 범위 선택 아래 월 선택이 바로 이어져야 함")
        capture(app, "01-shared-tab")
        personal.tap()
        XCTAssertTrue(personal.isSelected)
        XCTAssertFalse(shared.isSelected)
        capture(app, "02-personal-tab")
        shared.tap()
        XCTAssertTrue(reveal(app.buttons["openRecurring"], in: app))
        capture(app, "03-home-menu-dividers")
        app.tabBars.buttons["설정"].tap()
        XCTAssertTrue(reveal(app.buttons["recurringPayments"], in: app))
        XCTAssertFalse(app.navigationBars["설정"].exists)
        capture(app, "04-settings-dividers")
        app.buttons["recurringPayments"].tap()
        XCTAssertTrue(app.navigationBars["정기결제"].waitForExistence(timeout: 5), "하위 화면 뒤로 가기는 유지")
        capture(app, "06-recurring")
        app.buttons["addRecurring"].tap()
        XCTAssertTrue(app.textFields["recurringName"].waitForExistence(timeout: 5))
        capture(app, "07-recurring-form")
        app.buttons["취소"].tap()
        app.tabBars.buttons["확인함"].tap()
        XCTAssertFalse(app.navigationBars["확인함"].exists)
        capture(app, "08-inbox")
        app.tabBars.buttons["통계"].tap()
        XCTAssertFalse(app.navigationBars["통계"].exists)
        XCTAssertLessThan(app.staticTexts["selectedMonth"].frame.minY, 130)
        capture(app, "09-statistics")
        app.tabBars.buttons["가계부"].tap()
        XCTAssertTrue(reveal(app.buttons["addEntry"], in: app, upward: false))
        app.buttons["addEntry"].tap()
        XCTAssertTrue(app.buttons["saveEntry"].waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(app.buttons["saveEntry"].frame.height, 52)
        XCTAssertLessThanOrEqual(app.buttons["saveEntry"].frame.height, 56)
        capture(app, "10-entry-form")
        app.buttons["취소"].tap()
        app.terminate()
        app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(reveal(personal, in: app))
        XCTAssertGreaterThanOrEqual(shared.frame.height, 48)
        XCTAssertGreaterThanOrEqual(personal.frame.height, 48)
        XCTAssertTrue(app.frame.contains(personal.frame))
        capture(app, "05-large-text-tabs")
        app.tabBars.buttons["통계"].tap()
        XCTAssertTrue(app.staticTexts["selectedMonth"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.frame.contains(app.staticTexts["selectedMonth"].frame))
        capture(app, "11-large-statistics")
        app.tabBars.buttons["확인함"].tap()
        capture(app, "12-large-inbox")
        app.tabBars.buttons["설정"].tap()
        capture(app, "13-large-settings")
        app.tabBars.buttons["가계부"].tap()
        app.swipeDown(); app.swipeDown(); app.swipeDown()
        XCTAssertTrue(reveal(app.buttons["addEntry"], in: app))
        app.buttons["addEntry"].tap()
        XCTAssertTrue(reveal(app.buttons["scopePersonal"], in: app))
        capture(app, "14-large-entry")
        XCTAssertGreaterThan(app.buttons["scopePersonal"].frame.minY, app.buttons["scopeShared"].frame.minY)
        XCTAssertTrue(reveal(app.buttons["saveEntry"], in: app))
        XCTAssertTrue(app.frame.contains(app.buttons["saveEntry"].frame))
        capture(app, "15-large-entry-save")
    }

    @MainActor func testMoneyGroupingAcrossInputs() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["OURLEDGER_TEST_SERVER"] = "http://127.0.0.1:18817"
        app.launch()
        connectLocalLedgerIfNeeded(in: app)
        app.tabBars.buttons["설정"].tap()
        let budget = app.textFields["budgetAmount"]
        XCTAssertTrue(reveal(budget, in: app))
        let amounts = budget.value as? String == "3,000,000" ? ["0", "3000000"] : ["3000000"]
        for value in amounts {
            budget.tap()
            budget.press(forDuration: 1.2)
            let selectAll = app.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", ["Select All", "전체 선택"])).firstMatch
            XCTAssertTrue(selectAll.waitForExistence(timeout: 5))
            selectAll.tap()
            budget.typeText(XCUIKeyboardKey.delete.rawValue)
            budget.typeText(value)
            XCTAssertEqual(budget.value as? String, value == "0" ? "0" : "3,000,000")
            app.staticTexts["월 생활비 예산"].tap()
            app.buttons["saveSettings"].tap()
            XCTAssertTrue(app.buttons["저장했어요"].waitForExistence(timeout: 10))
        }
        XCTAssertEqual(budget.value as? String, "3,000,000", "저장 후에도 형식 유지")
        app.terminate(); app.launch()
        app.tabBars.buttons["설정"].tap()
        XCTAssertTrue(reveal(budget, in: app))
        XCTAssertEqual(budget.value as? String, "3,000,000", "다시 읽은 예산도 형식 유지")
        capture(app, "money-budget-grouped")
        XCTAssertTrue(reveal(app.buttons["recurringPayments"], in: app, upward: false))
        app.buttons["recurringPayments"].tap()
        app.buttons["addRecurring"].tap()
        let recurring = app.textFields["recurringAmount"]
        XCTAssertTrue(recurring.waitForExistence(timeout: 5))
        recurring.tap(); recurring.typeText("3000000")
        XCTAssertEqual(recurring.value as? String, "3,000,000")
        app.buttons["취소"].firstMatch.tap()
        app.tabBars.buttons["가계부"].tap()
        XCTAssertTrue(reveal(app.buttons["addEntry"], in: app, upward: false))
        app.buttons["addEntry"].tap()
        let amount = app.textFields["entryAmount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        amount.tap(); amount.typeText("3000000")
        XCTAssertEqual(amount.value as? String, "3,000,000")
        amount.typeText(XCUIKeyboardKey.delete.rawValue)
        XCTAssertEqual(amount.value as? String, "300,000")
        amount.typeText("0")
        XCTAssertEqual(amount.value as? String, "3,000,000")
        app.staticTexts["금액"].firstMatch.tap()
        capture(app, "money-entry-grouped")
        app.buttons["취소"].firstMatch.tap()
    }

    @MainActor func testTapOutsideDismissesKeyboardWithoutBlockingControls() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["OURLEDGER_TEST_SERVER"] = "http://127.0.0.1:18817"
        app.launch()
        connectLocalLedgerIfNeeded(in: app)
        app.tabBars.buttons["가계부"].tap()
        XCTAssertTrue(reveal(app.buttons["addEntry"], in: app, upward: false))
        app.buttons["addEntry"].tap()
        let amount = app.textFields["entryAmount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        amount.tap(); amount.typeText("10000")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.staticTexts["금액"].firstMatch.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "입력칸 바깥 설명을 누르면 숫자 키보드도 닫혀야 함")
        XCTAssertEqual(amount.value as? String, "10,000")
        amount.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let note = app.textFields["entryNote"]
        capture(app, "keyboard-before-field-switch")
        // On compact screens the pinned controls cover the next field; use its visible Next action.
        if note.frame.maxY < app.buttons["scopeShared"].frame.minY { note.tap() }
        else { focusEntryNote(in: app) }
        note.typeText("치킨")
        XCTAssertTrue(app.keyboards.firstMatch.exists, "다른 입력칸으로 이동할 때는 키보드 유지")
        XCTAssertEqual(note.value as? String, "치킨")
        note.tap(); note.typeText(" 추가")
        XCTAssertEqual(note.value as? String, "치킨 추가", "입력칸 재탭은 편집을 방해하지 않아야 함")
        XCTAssertTrue(reveal(app.buttons["entryCategoryOptions"], in: app))
        capture(app, "keyboard-before-category-tap")
        app.buttons["entryCategoryOptions"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        capture(app, "keyboard-after-category-tap")
        XCTAssertTrue(reveal(app.buttons["카테고리 추가"], in: app))
        app.buttons["카테고리 추가"].tap()
        let category = app.textFields["categoryName"]
        XCTAssertTrue(category.waitForExistence(timeout: 5))
        category.tap(); category.typeText("검증")
        app.staticTexts["예: 사료, 동물병원. 여러 단어는 쉼표로 나눠 주세요."].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "중첩 입력창에서도 바깥 탭으로 닫힘")
        app.navigationBars["카테고리 추가"].buttons["취소"].tap()
        app.navigationBars["거래 기록"].buttons["취소"].tap()
        app.tabBars.buttons["설정"].tap()
        let bank = app.textFields["bankName"]
        XCTAssertTrue(reveal(bank, in: app))
        bank.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.staticTexts["내 정산 계좌"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "설정 계좌 입력에서도 닫힘")
        app.tabBars.buttons["확인함"].tap()
        XCTAssertTrue(reveal(app.buttons["pasteNotification"], in: app))
        app.buttons["pasteNotification"].tap()
        let raw = app.textViews["notificationText"]
        XCTAssertTrue(raw.waitForExistence(timeout: 5))
        raw.tap(); raw.typeText("검증 알림")
        raw.tap(); raw.typeText(" 추가")
        XCTAssertTrue(app.keyboards.firstMatch.exists, "긴 문구 입력칸 안에서는 편집 유지")
        app.staticTexts["내용 확인"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertEqual(raw.value as? String, "검증 알림 추가")
        capture(app, "keyboard-dismissed-notification")
        app.navigationBars["알림·캡처"].buttons["취소"].tap()
    }

    @MainActor func testImportModesAndCommonStatistics() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["OURLEDGER_TEST_SERVER"] = "http://127.0.0.1:18817"
        app.launch()
        connectLocalLedgerIfNeeded(in: app)
        app.tabBars.buttons["확인함"].tap()
        XCTAssertTrue(reveal(app.buttons["pasteNotification"], in: app))
        app.buttons["pasteNotification"].tap()
        let source = app.segmentedControls["importSource"]
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        XCTAssertTrue(source.buttons["문자"].isSelected)
        XCTAssertFalse(app.buttons["pickPaymentImage"].exists)
        let raw = app.textViews["notificationText"]
        raw.tap(); raw.typeText("문자 초안")
        source.buttons["앱 알림"].tap()
        XCTAssertTrue(source.buttons["앱 알림"].isSelected)
        XCTAssertEqual(raw.value as? String, "")
        XCTAssertFalse(app.buttons["pickPaymentImage"].exists)
        raw.tap(); raw.typeText("앱 알림 초안")
        source.buttons["캡처"].tap()
        XCTAssertTrue(source.buttons["캡처"].isSelected)
        XCTAssertTrue(app.buttons["pickPaymentImage"].waitForExistence(timeout: 5))
        XCTAssertFalse(raw.exists, "캡처를 고르기 전 빈 입력칸은 표시하지 않음")
        XCTAssertFalse(app.buttons["importNotification"].isEnabled)
        capture(app, "qa-import-capture-empty")
        source.buttons["문자"].tap()
        XCTAssertEqual(raw.value as? String, "문자 초안")
        source.buttons["앱 알림"].tap()
        XCTAssertEqual(raw.value as? String, "앱 알림 초안")
        capture(app, "qa-import-app-draft")
        app.navigationBars["알림·캡처"].buttons["취소"].tap()
        app.tabBars.buttons["가계부"].tap()
        let calendarDays = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "calendar-"))
        XCTAssertTrue(reveal(app.staticTexts["거래 달력"], in: app, upward: false))
        var calendar: XCUIElement?
        for _ in 0..<5 {
            calendar = calendarDays.allElementsBoundByIndex.first {
                $0.isHittable && $0.frame.minY > 150 && $0.frame.maxY < app.tabBars.firstMatch.frame.minY
            }
            if calendar != nil { break }
            app.swipeUp()
        }
        XCTAssertNotNil(calendar)
        XCTAssertFalse(app.buttons["달력 기준"].exists)
        calendar?.tap()
        XCTAssertTrue(app.buttons["calendarAllDays"].waitForExistence(timeout: 5))
        capture(app, "qa-calendar-without-help")
        app.buttons["calendarAllDays"].tap()
        app.tabBars.buttons["통계"].tap()
        for scope in ["shared", "personal"] {
            let choice = app.buttons["insightsScope-" + scope]
            XCTAssertTrue(reveal(choice, in: app, upward: false))
            choice.tap()
            XCTAssertTrue(choice.isSelected)
            if app.staticTexts["insightsEmptyState"].exists {
                XCTAssertFalse(app.staticTexts["카테고리별 지출"].exists)
                XCTAssertFalse(app.buttons[scope == "shared" ? "sharedIncomeDetails" : "personalIncomeDetails"].exists)
            } else {
                XCTAssertTrue(reveal(app.staticTexts["카테고리별 지출"], in: app))
                let name = scope == "shared" ? "공용" : "개인"
                XCTAssertTrue(reveal(app.staticTexts["일별 " + name + " 지출"], in: app))
                XCTAssertTrue(reveal(app.staticTexts["최근 6개월 " + name + " 지출"], in: app))
            }
            XCTAssertFalse(app.buttons["도움말"].exists)
            capture(app, "qa-statistics-" + scope)
        }
    }

    @MainActor func testCaptureOCRKeepsEmptyDraft() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["OURLEDGER_TEST_SERVER"] = "http://127.0.0.1:18817"
        app.launch()
        connectLocalLedgerIfNeeded(in: app)
        app.tabBars.buttons["확인함"].tap()
        XCTAssertTrue(reveal(app.buttons["pasteNotification"], in: app))
        app.buttons["pasteNotification"].tap()
        app.segmentedControls["importSource"].buttons["캡처"].tap()
        app.buttons["pickPaymentImage"].tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Loading…"].firstMatch.waitForNonExistence(timeout: 30))
        // Seed the isolated simulator's latest photo with checks' synthetic payment image.
        let photo = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 10))
        photo.tap()
        finishPhotoSelection(in: app)
        let raw = app.textViews["notificationText"]
        XCTAssertTrue(raw.waitForExistence(timeout: 20))
        XCTAssertTrue((raw.value as? String)?.contains("18,400") == true)
        capture(app, "ocr-recognized-draft")
        raw.tap()
        raw.press(forDuration: 1.2)
        let selectAll = app.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", ["Select All", "전체 선택"])).firstMatch
        XCTAssertTrue(selectAll.waitForExistence(timeout: 5))
        selectAll.tap()
        raw.typeText(XCUIKeyboardKey.delete.rawValue)
        XCTAssertTrue(raw.exists, "인식한 문구를 모두 지워도 편집창 유지")
        XCTAssertEqual(raw.value as? String, "")
        XCTAssertFalse(app.buttons["importNotification"].isEnabled)
        raw.typeText("수정한 캡처 18,400원")
        app.staticTexts["인식한 내용"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        let source = app.segmentedControls["importSource"]
        source.buttons["문자"].tap()
        XCTAssertEqual(raw.value as? String, "")
        source.buttons["캡처"].tap()
        XCTAssertEqual(raw.value as? String, "수정한 캡처 18,400원")
        XCTAssertTrue(app.buttons["importNotification"].isEnabled)
        capture(app, "ocr-edited-draft-restored")
        app.navigationBars["알림·캡처"].buttons["취소"].tap()
    }

    @MainActor func testBankCaptureRegistersWithoutBalanceOrFooter() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["OURLEDGER_TEST_SERVER"] = "http://127.0.0.1:18817"
        app.launch()
        connectLocalLedgerIfNeeded(in: app)
        app.tabBars.buttons["확인함"].tap()
        XCTAssertTrue(reveal(app.buttons["pasteNotification"], in: app))
        app.buttons["pasteNotification"].tap()
        app.segmentedControls["importSource"].buttons["캡처"].tap()
        app.buttons["pickPaymentImage"].tap()
        XCTAssertTrue(app.staticTexts["Loading…"].firstMatch.waitForNonExistence(timeout: 30))
        let photo = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 10)); photo.tap()
        finishPhotoSelection(in: app)
        XCTAssertTrue(app.textFields["entryAmount"].waitForExistence(timeout: 25), "명확한 캡처는 확인함을 다시 누르지 않고 기록 화면을 열어야 함")
        XCTAssertFalse(app.buttons["entryKind-refund"].exists)
        capture(app, "bank-capture-auto-record-form")
        XCTAssertEqual(app.textFields["entryAmount"].value as? String, "65,720")
        XCTAssertEqual(app.textFields["entryNote"].value as? String, "테스트보험")
        app.buttons["entryKind-expense"].tap()
        app.buttons["scopePersonal"].tap()
        XCTAssertTrue(app.buttons["saveEntry"].isEnabled)
        app.buttons["saveEntry"].tap()
        XCTAssertTrue(app.textFields["entryAmount"].waitForNonExistence(timeout: 10))
        app.terminate(); app.launch()
        app.tabBars.buttons["가계부"].tap()
        app.buttons["ledgerScope-personal"].tap()
        XCTAssertTrue(reveal(app.staticTexts["테스트보험"].firstMatch, in: app))
        capture(app, "bank-capture-persisted-personal")
    }

    @MainActor private func finishPhotoSelection(in app: XCUIApplication) {
        let add = app.buttons.matching(NSPredicate(format:
            "label BEGINSWITH %@ OR label BEGINSWITH %@ OR label == %@", "Add", "추가", "완료")).firstMatch
        if add.waitForExistence(timeout: 3), add.isHittable { add.tap() }
    }

    @MainActor func testHomeCaptureAndPasteEntryPoints() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["OURLEDGER_TEST_SERVER"] = "http://127.0.0.1:18817"
        app.launch()
        connectLocalLedgerIfNeeded(in: app)
        app.tabBars.buttons["가계부"].tap()
        XCTAssertTrue(reveal(app.buttons["homeImport"], in: app, upward: false))
        capture(app, "home-record-and-import")
        app.buttons["homeImport"].tap()
        app.buttons["homeImportText"].tap()
        XCTAssertTrue(app.segmentedControls["importSource"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.segmentedControls["importSource"].buttons["문자"].isSelected)
        XCTAssertFalse(app.buttons["pickPaymentImage"].exists)
        XCTAssertTrue(app.buttons["pasteNotificationText"].exists)
        XCTAssertEqual(app.textViews["notificationText"].value as? String, "", "클립보드는 명시적인 붙여넣기 전 읽지 않음")
        capture(app, "home-paste-explicit-action")
        app.navigationBars["알림·캡처"].buttons["취소"].tap()
        app.buttons["homeImport"].tap()
        app.buttons["homeImportCapture"].tap()
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), "홈 캡처 선택에서 사진 선택 화면을 직접 연다")
        capture(app, "home-capture-photo-picker")
        cancel.tap()
        XCTAssertTrue(app.buttons["pickPaymentImage"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.segmentedControls["importSource"].buttons["캡처"].isSelected)
        app.navigationBars["알림·캡처"].buttons["취소"].tap()
        app.buttons["addEntry"].tap()
        XCTAssertTrue(app.textFields["entryAmount"].waitForExistence(timeout: 5))
        app.buttons["취소"].tap()
    }

    @MainActor func testHomeImportAtAccessibilityTextSize() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["OURLEDGER_TEST_SERVER"] = "http://127.0.0.1:18817"
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        connectLocalLedgerIfNeeded(in: app)
        app.tabBars.buttons["가계부"].tap()
        let record = app.buttons["addEntry"], imported = app.buttons["homeImport"]
        XCTAssertTrue(reveal(record, in: app, upward: false))
        XCTAssertTrue(reveal(imported, in: app))
        XCTAssertGreaterThanOrEqual(record.frame.height, 44)
        XCTAssertGreaterThanOrEqual(imported.frame.height, 44)
        XCTAssertGreaterThanOrEqual(imported.frame.minY, record.frame.maxY, "큰 글씨에서 두 동작은 겹치지 않고 세로로 배치")
        capture(app, "home-import-accessibility-text")
        imported.tap()
        XCTAssertTrue(app.buttons["homeImportCapture"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["homeImportText"].exists)
        app.terminate()
    }

    @MainActor func testImportedNoteCanBeClearedAndReplaced() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["OURLEDGER_TEST_SERVER"] = "http://127.0.0.1:18817"
        app.launch()
        connectLocalLedgerIfNeeded(in: app)
        app.tabBars.buttons["확인함"].tap()
        XCTAssertTrue(reveal(app.buttons["pasteNotification"], in: app))
        app.buttons["pasteNotification"].tap()
        let title = "아주 긴 결제 알림 제목을 한 번에 지우고 점심으로 바꿀 테스트 가맹점"
        let raw = app.textViews["notificationText"]
        XCTAssertTrue(raw.waitForExistence(timeout: 5))
        raw.tap(); raw.typeText("테스트카드 1234 승인 9,800원\n가맹점: " + title)
        app.buttons["importNotification"].tap()
        let note = app.textFields["entryNote"]
        XCTAssertTrue(note.waitForExistence(timeout: 15))
        XCTAssertEqual(note.value as? String, title)
        app.buttons["scopePersonal"].tap()
        XCTAssertTrue(reveal(app.buttons["clearEntryNote"], in: app))
        capture(app, "clear-note-before")
        app.buttons["clearEntryNote"].tap()
        XCTAssertEqual(note.value as? String, "어디에 썼나요?")
        XCTAssertFalse(app.buttons["clearEntryNote"].exists)
        XCTAssertFalse(app.buttons["saveEntry"].isEnabled, "설명을 지운 상태로 저장하면 안 됨")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        note.typeText("점심")
        XCTAssertEqual(note.value as? String, "점심")
        XCTAssertEqual(app.textFields["entryAmount"].value as? String, "9,800")
        XCTAssertTrue(app.buttons["scopePersonal"].isSelected)
        capture(app, "clear-note-replaced")
        app.buttons["취소"].tap()
    }

    @MainActor func testHomePasteRequiresUserAction() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["OURLEDGER_TEST_SERVER"] = "http://127.0.0.1:18817"
        app.launch()
        connectLocalLedgerIfNeeded(in: app)
        app.tabBars.buttons["가계부"].tap()
        XCTAssertTrue(reveal(app.buttons["homeImport"], in: app, upward: false))
        app.buttons["homeImport"].tap()
        app.buttons["homeImportText"].tap()
        let raw = app.textViews["notificationText"]
        XCTAssertTrue(raw.waitForExistence(timeout: 8))
        XCTAssertEqual(raw.value as? String, "")
        let paste = app.buttons["pasteNotificationText"]
        XCTAssertTrue(paste.isEnabled)
        paste.tap()
        let pasted = NSPredicate(format: "value CONTAINS %@", "7,321원")
        expectation(for: pasted, evaluatedWith: raw)
        waitForExpectations(timeout: 8)
        XCTAssertFalse(app.textFields["entryAmount"].exists, "붙여넣기 자체는 전송·저장하지 않음")
        capture(app, "home-pasted-text-review")
        app.buttons["importNotification"].tap()
        XCTAssertTrue(app.textFields["entryAmount"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.textFields["entryAmount"].value as? String, "7,321")
        XCTAssertEqual(app.textFields["entryNote"].value as? String, "붙여넣기검증")
        XCTAssertFalse(app.buttons["saveEntry"].isEnabled, "공용·개인은 사용자가 선택")
        capture(app, "home-paste-record-form")
        app.terminate()
    }

    @MainActor func testHomeTransactionListCaptureSequence() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["OURLEDGER_TEST_SERVER"] = "http://127.0.0.1:18817"
        app.launch()
        connectLocalLedgerIfNeeded(in: app)
        app.tabBars.buttons["가계부"].tap()
        XCTAssertTrue(reveal(app.buttons["homeImport"], in: app, upward: false))
        app.buttons["homeImport"].tap()
        app.buttons["homeImportCapture"].tap()
        XCTAssertTrue(app.staticTexts["Loading…"].firstMatch.waitForNonExistence(timeout: 30))
        let photo = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 15)); photo.tap()
        finishPhotoSelection(in: app)
        let submit = app.buttons["importNotification"]
        XCTAssertTrue(submit.waitForExistence(timeout: 25))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: submit)
        waitForExpectations(timeout: 25)
        capture(app, "transaction-list-five-candidates")
        submit.tap()
        let expected = ["10,000", "70,000", "3,000", "45,600", "13,760"]
        for (index, value) in expected.enumerated() {
            let amount = app.textFields["entryAmount"]
            XCTAssertTrue(amount.waitForExistence(timeout: 20))
            XCTAssertEqual(amount.value as? String, value, "거래 행 순서 유지, 달력 합계 제외")
            XCTAssertTrue(app.datePickers["unrecognizedTransactionDate"].exists, "연도가 없는 날짜는 임의 확정하지 않는다")
            if value == "45,600" {
                XCTAssertFalse(app.buttons["entryKind-expense"].isSelected)
                XCTAssertFalse(app.buttons["entryKind-income"].isSelected)
                XCTAssertFalse(app.buttons["saveEntry"].isEnabled)
                capture(app, "transaction-list-cancellation-needs-choice")
                let exclude = app.buttons["취소·환불 알림 · 기록 안 함"]
                XCTAssertTrue(reveal(exclude, in: app, upward: false)); exclude.tap()
            } else {
                app.buttons[value == "70,000" ? "entryKind-income" : "entryKind-expense"].tap()
                app.buttons["scopePersonal"].tap()
                XCTAssertTrue(app.buttons["saveEntry"].isEnabled)
                app.buttons["saveEntry"].tap()
            }
            if index < expected.count - 1 {
                expectation(for: NSPredicate(format: "value != %@", value), evaluatedWith: amount)
                waitForExpectations(timeout: 20)
            }
        }
        XCTAssertTrue(app.staticTexts["paymentFlowComplete"].waitForExistence(timeout: 15))
        capture(app, "transaction-list-complete")
        app.buttons["finishPaymentFlow"].tap()
        app.terminate(); app.launch()
        app.tabBars.buttons["확인함"].tap()
        XCTAssertTrue(app.staticTexts["확인할 거래 0건"].waitForExistence(timeout: 15))
    }

    @MainActor func testAmbiguousCaptureRemainsManualWhenNoticeIsMixed() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["OURLEDGER_TEST_SERVER"] = "http://127.0.0.1:18817"
        app.launch()
        connectLocalLedgerIfNeeded(in: app)
        app.tabBars.buttons["가계부"].tap()
        XCTAssertTrue(reveal(app.buttons["homeImport"], in: app, upward: false))
        app.buttons["homeImport"].tap(); app.buttons["homeImportCapture"].tap()
        XCTAssertTrue(app.staticTexts["Loading…"].firstMatch.waitForNonExistence(timeout: 30))
        let photo = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 15)); photo.tap()
        finishPhotoSelection(in: app)
        let raw = app.textViews["notificationText"]
        XCTAssertTrue(raw.waitForExistence(timeout: 25))
        XCTAssertTrue((raw.value as? String)?.contains("17,321") == true)
        XCTAssertTrue((raw.value as? String)?.contains("예정") == true)
        let submit = app.buttons["importNotification"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: submit)
        waitForExpectations(timeout: 15)
        submit.tap()
        let amount = app.textFields["entryAmount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 15), "예정이 섞여도 전체 거래를 버리지 않고 확인 화면을 연다")
        capture(app, "mixed-notice-review-before-input")
        let displayedAmount = amount.value as? String ?? ""
        XCTAssertFalse(displayedAmount.contains(where: \.isNumber), "금액을 임의로 채우면 안 됨: \(displayedAmount)")
        XCTAssertTrue(app.buttons["entryKind-expense"].isSelected, "모호한 새 초안은 지출로 시작한다")
        XCTAssertFalse(app.buttons["entryKind-income"].isSelected)
        capture(app, "mixed-notice-capture-manual-review")
        amount.tap(); amount.typeText("17321")
        app.buttons["saveEntry"].tap() // 금액 키보드의 다음 단계는 설명 입력
        let note = app.textFields["entryNote"]
        note.tap(); note.typeText("수동확인검증")
        app.buttons["scopePersonal"].tap()
        XCTAssertTrue(app.buttons["saveEntry"].isEnabled, "금액·설명·공개 범위를 확인하면 기본 지출로 저장 가능")
        app.buttons["saveEntry"].tap()
        XCTAssertTrue(app.staticTexts["paymentFlowComplete"].waitForExistence(timeout: 15))
        app.buttons["finishPaymentFlow"].tap()
        app.terminate(); app.launch()
        app.tabBars.buttons["확인함"].tap()
        XCTAssertTrue(app.staticTexts["확인할 거래 0건"].waitForExistence(timeout: 15))
    }

    @MainActor func testMultipleTransactionsInOneCapture() throws {
        try recordCaptureBatch(photoCount: 1, expected: ["54,250", "65,720"])
    }

    @MainActor func testMultipleCapturePhotosKeepEveryTransaction() throws {
        try recordCaptureBatch(photoCount: 2, expected: ["54,250", "65,720", "31,000"])
    }

    @MainActor private func recordCaptureBatch(photoCount: Int, expected: [String]) throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["OURLEDGER_TEST_SERVER"] = "http://127.0.0.1:18817"
        app.launch()
        connectLocalLedgerIfNeeded(in: app)
        app.tabBars.buttons["확인함"].tap()
        XCTAssertTrue(reveal(app.buttons["pasteNotification"], in: app))
        app.buttons["pasteNotification"].tap()
        app.segmentedControls["importSource"].buttons["캡처"].tap()
        app.buttons["pickPaymentImage"].tap()
        XCTAssertTrue(app.staticTexts["Loading…"].firstMatch.waitForNonExistence(timeout: 30))
        let photos = app.images.matching(identifier: "PXGGridLayout-Info")
        XCTAssertTrue(photos.firstMatch.waitForExistence(timeout: 15))
        XCTAssertGreaterThanOrEqual(photos.count, photoCount)
        for index in 0..<photoCount { photos.element(boundBy: index).tap() }
        finishPhotoSelection(in: app)
        let submit = app.buttons["importNotification"]
        XCTAssertTrue(submit.waitForExistence(timeout: 25))
        let ready = NSPredicate(format: "enabled == true")
        expectation(for: ready, evaluatedWith: submit)
        waitForExpectations(timeout: 25)
        capture(app, "capture-batch-preview")
        submit.tap()
        var amounts: [String] = []
        for index in expected.indices {
            let amount = app.textFields["entryAmount"]
            XCTAssertTrue(amount.waitForExistence(timeout: 20), "Next capture must open its own record form")
            let value = amount.value as? String ?? ""
            XCTAssertTrue(expected.contains(value), "Balance or non-transaction amount was selected")
            XCTAssertFalse(amounts.contains(value), "Already-recorded candidate appeared again")
            amounts.append(value)
            if photoCount == 1 { XCTAssertEqual(value, expected[index], "Top-to-bottom transaction order") }
            app.buttons[value == "31,000" ? "entryKind-income" : "entryKind-expense"].tap()
            app.buttons["scopePersonal"].tap()
            XCTAssertTrue(app.buttons["saveEntry"].isEnabled)
            capture(app, "capture-batch-form-\(index + 1)")
            app.buttons["saveEntry"].tap()
            if index < expected.count - 1 {
                let changed = NSPredicate(format: "value != %@", value)
                expectation(for: changed, evaluatedWith: amount)
                waitForExpectations(timeout: 20)
            }
        }
        XCTAssertEqual(Set(amounts), Set(expected))
        XCTAssertTrue(app.staticTexts["paymentFlowComplete"].waitForExistence(timeout: 15))
        app.buttons["finishPaymentFlow"].tap()
        app.terminate(); app.launch()
        app.tabBars.buttons["확인함"].tap()
        XCTAssertTrue(app.staticTexts["확인할 거래 0건"].waitForExistence(timeout: 15))
        capture(app, "capture-batch-recorded-after-relaunch")
    }

    @MainActor func testCaptureEntryAndHomeScope() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["OURLEDGER_TEST_SERVER"] = "http://127.0.0.1:18817"
        app.launch()
        connectLocalLedgerIfNeeded(in: app)
        app.tabBars.buttons["가계부"].tap()
        let personal = app.buttons["ledgerScope-personal"]
        XCTAssertTrue(personal.waitForExistence(timeout: 5))
        personal.tap()
        XCTAssertFalse(app.buttons["dashboardInbox"].exists)
        app.tabBars.buttons["확인함"].tap()
        XCTAssertTrue(app.tabBars.buttons["확인함"].isSelected)
        app.tabBars.buttons["가계부"].tap()
        XCTAssertTrue(personal.isSelected)
        XCTAssertTrue(reveal(app.buttons["addEntry"], in: app, upward: false))
        app.buttons["addEntry"].tap()
        XCTAssertTrue(app.buttons["scopePersonal"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["scopePersonal"].isSelected, "개인 화면에서 시작한 기록의 공개 범위 유지")
        app.buttons["취소"].tap()
        XCTAssertFalse(app.buttons["dashboardInbox"].exists)
        app.tabBars.buttons["확인함"].tap()
        XCTAssertTrue(reveal(app.buttons["pasteNotification"], in: app))
        app.buttons["pasteNotification"].tap()
        XCTAssertFalse(app.buttons["pickPaymentImage"].exists)
        app.segmentedControls["importSource"].buttons["캡처"].tap()
        XCTAssertTrue(app.buttons["pickPaymentImage"].waitForExistence(timeout: 5))
        capture(app, "19-capture-import")
        app.buttons["pickPaymentImage"].tap()
        let cancel = app.buttons["Cancel"].exists ? app.buttons["Cancel"] : app.buttons["취소"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        capture(app, "20-photo-picker")
        cancel.tap()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.buttons["pickPaymentImage"].waitForExistence(timeout: 5))
        app.navigationBars["알림·캡처"].buttons["취소"].tap()
        app.tabBars.buttons["가계부"].tap()
        app.buttons["ledgerScope-shared"].tap()
    }

    @MainActor func testIncomeOnlyAndRefundNetZeroInsights() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["OURLEDGER_TEST_SERVER"] = "http://127.0.0.1:18817"
        app.launch()
        connectLocalLedgerIfNeeded(in: app)
        app.tabBars.buttons["통계"].tap()
        app.buttons["insightsScope-personal"].tap()
        guard app.staticTexts["insightsEmptyState"].waitForExistence(timeout: 5) else {
            throw XCTSkip("개인 내역이 없는 별도 시뮬레이터에서 실행")
        }
        for (kind, amount, note) in [("income", "50000", "검증 용돈"), ("expense", "3000", "검증 점심"), ("refund", "3000", "검증 점심 환불")] {
            app.tabBars.buttons["가계부"].tap()
            XCTAssertTrue(reveal(app.buttons["addEntry"], in: app, upward: false))
            app.buttons["addEntry"].tap()
            XCTAssertTrue(app.buttons["entryKind-" + kind].waitForExistence(timeout: 5))
            app.buttons["entryKind-" + kind].tap()
            app.textFields["entryAmount"].tap(); app.textFields["entryAmount"].typeText(amount)
            app.buttons["scopePersonal"].tap()
            focusEntryNote(in: app); app.textFields["entryNote"].typeText(note + "\n")
            app.buttons["saveEntry"].tap()
            XCTAssertTrue(app.textFields["entryNote"].waitForNonExistence(timeout: 10))
            app.tabBars.buttons["통계"].tap()
            XCTAssertTrue(app.buttons["insightsScope-personal"].isSelected)
            XCTAssertFalse(app.staticTexts["insightsEmptyState"].exists)
            if kind == "income" {
                XCTAssertFalse(app.staticTexts["카테고리별 지출"].exists)
                XCTAssertTrue(reveal(app.buttons["personalIncomeDetails"], in: app))
                capture(app, "qa-income-only-insights")
            } else if kind == "refund" {
                XCTAssertTrue(reveal(app.staticTexts["카테고리별 지출"], in: app))
                XCTAssertTrue(reveal(app.staticTexts["일별 개인 지출"], in: app))
                capture(app, "qa-refund-zero-has-records")
            }
        }
    }

    @MainActor func testQAClassificationAndRecurringCreation() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["OURLEDGER_TEST_SERVER"] = "http://127.0.0.1:18817"
        app.launch()
        connectLocalLedgerIfNeeded(in: app)
        app.buttons["addEntry"].tap()
        app.textFields["entryAmount"].tap(); app.textFields["entryAmount"].typeText("3000")
        app.buttons["scopePersonal"].tap()
        focusEntryNote(in: app); app.textFields["entryNote"].typeText("코 약\n")
        XCTAssertTrue(reveal(app.buttons["entryCategoryOptions"], in: app))
        app.buttons["entryCategoryOptions"].tap()
        XCTAssertTrue(reveal(app.staticTexts["추천: 의료"], in: app))
        capture(app, "qa-medical-recommendation")
        app.buttons["취소"].tap()
        app.tabBars.buttons["설정"].tap()
        XCTAssertTrue(reveal(app.buttons["recurringPayments"], in: app))
        app.buttons["recurringPayments"].tap()
        let name = "재시도 검증 " + String(UUID().uuidString.prefix(5))
        app.buttons["addRecurring"].tap()
        XCTAssertTrue(app.textFields["recurringName"].waitForExistence(timeout: 5))
        app.textFields["recurringName"].tap(); app.textFields["recurringName"].typeText(name)
        app.textFields["recurringAmount"].tap(); app.textFields["recurringAmount"].typeText("12000")
        XCTAssertTrue(reveal(app.buttons["recurringScope"], in: app))
        app.buttons["recurringScope"].tap(); app.buttons["공용"].tap()
        app.buttons["saveRecurring"].tap()
        XCTAssertTrue(app.buttons["addRecurring"].waitForExistence(timeout: 10))
        XCTAssertTrue(reveal(app.staticTexts[name], in: app))
        capture(app, "qa-recurring-saved")
        XCTAssertTrue(reveal(app.buttons["addRecurring"], in: app, upward: false))
        app.buttons["addRecurring"].tap()
        XCTAssertTrue(app.textFields["recurringName"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["recurringAmount"].value as? String, "금액", "저장 완료된 요청은 새 입력에 남지 않음")
        XCTAssertFalse(app.buttons["나중에 확인"].exists)
        app.buttons["취소"].tap()
    }

    @MainActor func testQAFixesScopeAndEmptyInsights() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["OURLEDGER_TEST_SERVER"] = "http://127.0.0.1:18817"
        app.launch()
        connectLocalLedgerIfNeeded(in: app)
        app.tabBars.buttons["가계부"].tap()
        app.buttons["ledgerScope-personal"].tap()
        let ledgerScopeFrame = app.buttons["ledgerScope-personal"].frame
        capture(app, "scope-layout-ledger")
        app.tabBars.buttons["통계"].tap()
        let personal = app.buttons["insightsScope-personal"]
        XCTAssertTrue(personal.waitForExistence(timeout: 5))
        XCTAssertTrue(personal.isSelected, "가계부에서 고른 개인 범위를 통계에서도 이어받아야 함")
        XCTAssertEqual(personal.frame.minX, ledgerScopeFrame.minX, accuracy: 1)
        XCTAssertEqual(personal.frame.minY, ledgerScopeFrame.minY, accuracy: 1)
        XCTAssertEqual(personal.frame.width, ledgerScopeFrame.width, accuracy: 1)
        XCTAssertEqual(personal.frame.height, ledgerScopeFrame.height, accuracy: 1)
        capture(app, "scope-layout-insights")
        app.swipeUp()
        XCTAssertTrue(personal.isHittable, "통계에서도 범위 선택을 상단에 고정")
        XCTAssertEqual(personal.frame.minY, ledgerScopeFrame.minY, accuracy: 1)
        app.buttons["insightsScope-shared"].tap()
        app.tabBars.buttons["가계부"].tap()
        XCTAssertTrue(app.buttons["ledgerScope-shared"].isSelected)
        let payer = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "결제자별 보기")).firstMatch
        XCTAssertTrue(reveal(payer, in: app))
        XCTAssertTrue(payer.label.contains("모두"))
        capture(app, "qa-payer-filter-label")
        app.tabBars.buttons["통계"].tap()
        app.buttons["insightsScope-personal"].tap()
        if app.staticTexts["insightsEmptyState"].exists {
            XCTAssertFalse(app.staticTexts["카테고리별 지출"].exists)
            XCTAssertFalse(app.buttons["personalIncomeDetails"].exists)
            XCTAssertFalse(app.staticTexts["일별 개인 지출"].exists)
            capture(app, "qa-compact-empty-insights")
        }
        app.terminate(); app.launch()
        app.tabBars.buttons["가계부"].tap()
        XCTAssertTrue(app.buttons["ledgerScope-personal"].isSelected)
        app.tabBars.buttons["통계"].tap()
        XCTAssertTrue(app.buttons["insightsScope-personal"].isSelected)
    }

    @MainActor func testPersonalInsightsAndAccountLayout() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["OURLEDGER_TEST_SERVER"] = "http://127.0.0.1:18817"
        app.launch()
        connectLocalLedgerIfNeeded(in: app)
        app.tabBars.buttons["가계부"].tap()
        app.buttons["ledgerScope-shared"].tap()
        XCTAssertFalse(app.buttons["dashboardInbox"].exists)
        let details = app.buttons["합계 자세히"]
        XCTAssertTrue(reveal(details, in: app, upward: false))
        details.tap()
        XCTAssertTrue(app.staticTexts["spendingComparison"].exists || app.otherElements["spendingComparison"].exists)
        XCTAssertTrue(app.staticTexts["summaryExplanation"].waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(app.staticTexts["summaryExplanation"].frame.minY, details.frame.maxY,
                             "합계 설명은 펼침 제목과 겹치면 안 됨")
        capture(app, "21-summary-expanded")
        details.tap()
        app.tabBars.buttons["통계"].tap()
        let personal = app.buttons["insightsScope-personal"]
        let shared = app.buttons["insightsScope-shared"]
        XCTAssertTrue(personal.waitForExistence(timeout: 5))
        personal.tap()
        XCTAssertTrue(personal.isSelected)
        XCTAssertTrue(app.staticTexts["내 개인 지출"].exists)
        XCTAssertFalse(app.staticTexts["함께 쓴 생활비"].exists)
        capture(app, "22-personal-insights")
        app.tabBars.buttons["가계부"].tap()
        XCTAssertTrue(app.buttons["ledgerScope-personal"].isSelected, "가계부와 통계는 같은 공용/개인 선택을 유지")
        app.tabBars.buttons["통계"].tap()
        XCTAssertTrue(personal.isSelected)
        app.terminate(); app.launch()
        app.tabBars.buttons["통계"].tap()
        XCTAssertTrue(personal.waitForExistence(timeout: 5))
        XCTAssertTrue(personal.isSelected, "개인 통계 선택은 재실행 후 유지")
        shared.tap()
        XCTAssertTrue(shared.isSelected)
        capture(app, "23-shared-insights")
        app.tabBars.buttons["설정"].tap()
        XCTAssertTrue(reveal(app.textFields["bankName"], in: app))
        capture(app, "24-settlement-account")
        app.tabBars.buttons["가계부"].tap()
        XCTAssertTrue(reveal(app.buttons["addEntry"], in: app, upward: false))
        app.buttons["addEntry"].tap()
        XCTAssertTrue(app.textFields["entryAmount"].waitForExistence(timeout: 5))
        app.textFields["entryAmount"].tap()
        app.textFields["entryAmount"].typeText("10000")
        focusEntryNote(in: app)
        app.textFields["entryNote"].typeText("검증 치킨\n")
        XCTAssertTrue(reveal(app.buttons["entryCategoryOptions"], in: app))
        app.buttons["entryCategoryOptions"].tap()
        XCTAssertTrue(reveal(app.staticTexts["추천: 식비"], in: app))
        capture(app, "25-category-recommendation")
        app.buttons["취소"].tap()
        app.tabBars.buttons["확인함"].tap()
        let original = app.buttons["원본 문구 보기"].firstMatch
        XCTAssertTrue(reveal(original, in: app))
        original.tap()
        let raw = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "importRaw-")).firstMatch
        XCTAssertTrue(raw.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(raw.frame.minY, original.frame.maxY)
        capture(app, "26-inbox-expanded")
    }

    @MainActor func testReleaseDesignDetailScreens() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["OURLEDGER_TEST_SERVER"] = "http://127.0.0.1:18817"
        app.launch()
        connectLocalLedgerIfNeeded(in: app)
        app.tabBars.buttons["가계부"].tap()
        app.buttons["ledgerScope-shared"].tap()
        XCTAssertTrue(reveal(app.buttons["settlementDetails"], in: app))
        app.buttons["settlementDetails"].tap()
        XCTAssertTrue(app.navigationBars["정산"].waitForExistence(timeout: 5))
        XCTAssertLessThan(app.staticTexts["selectedMonth"].frame.minY, 180)
        capture(app, "16-settlement-compact")
        app.navigationBars["정산"].buttons.firstMatch.tap()
        app.tabBars.buttons["통계"].tap()
        let category = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "category-")).firstMatch
        XCTAssertTrue(reveal(category, in: app))
        category.tap()
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 5))
        capture(app, "17-category-detail-compact")
        let entry = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "entry-")).firstMatch
        XCTAssertTrue(reveal(entry, in: app))
        entry.tap()
        XCTAssertTrue(app.navigationBars["내역 상세"].waitForExistence(timeout: 5))
        capture(app, "18-transaction-detail")
        app.buttons["닫기"].tap()
        XCTAssertTrue(app.navigationBars["내역 상세"].waitForNonExistence(timeout: 5))
        app.navigationBars.firstMatch.buttons.firstMatch.tap()
        XCTAssertFalse(app.navigationBars.firstMatch.exists)
    }

    @MainActor func testVisualAuditConnectedLedger() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["OURLEDGER_TEST_SERVER"] = "http://127.0.0.1:18817"
        app.launch()
        connectLocalLedgerIfNeeded(in: app)
        XCTAssertTrue(app.buttons["addEntry"].waitForExistence(timeout: 15))
        capture(app, "orange-home")
        XCTAssertFalse(app.buttons["이전 달"].isHittable)
        XCTAssertFalse(app.buttons["다음 달"].isHittable)
        app.tabBars.buttons["확인함"].tap()
        XCTAssertTrue(app.staticTexts["아직 받은 알림이 없어요"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["inboxConnectionGuide"].exists, "미연결 상태에서 같은 연결 버튼을 중복 표시하지 않음")
        capture(app, "orange-inbox")
        app.tabBars.buttons["통계"].tap(); capture(app, "orange-statistics")
        app.tabBars.buttons["설정"].tap(); capture(app, "orange-settings")
        XCTAssertTrue(reveal(app.buttons["recurringPayments"], in: app))
        app.buttons["recurringPayments"].tap(); capture(app, "orange-recurring")
        app.buttons["addRecurring"].tap()
        XCTAssertTrue(app.textFields["recurringName"].waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(app.buttons["saveRecurring"].frame.height, 44)
        XCTAssertTrue(app.frame.contains(app.buttons["saveRecurring"].frame))
        capture(app, "orange-recurring-form")
        app.buttons["취소"].tap()
        app.tabBars.buttons["가계부"].tap(); app.buttons["addEntry"].tap()
        let save = app.buttons["saveEntry"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(save.frame.height, 44)
        XCTAssertLessThanOrEqual(save.frame.height, 56, "기본 글씨에서 버튼이 과도하게 커지면 안 됨")
        capture(app, "orange-entry")
        app.buttons["entryKind-expense"].tap()
        let categoryOptions = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "카테고리,")).firstMatch
        XCTAssertTrue(reveal(categoryOptions, in: app))
        XCTAssertFalse(app.buttons["카테고리 추가"].exists)
        capture(app, "entry-category-collapsed")
        categoryOptions.tap()
        XCTAssertTrue(reveal(app.buttons["카테고리 추가"], in: app))
        capture(app, "entry-category-expanded")
        app.buttons["카테고리 추가"].tap()
        XCTAssertTrue(app.textFields["categoryName"].waitForExistence(timeout: 5))
        app.navigationBars["카테고리 추가"].buttons["취소"].tap()
        XCTAssertTrue(app.buttons["saveEntry"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["saveEntry"].isEnabled)
        app.terminate()
        app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.buttons["addEntry"].waitForExistence(timeout: 15))
        capture(app, "orange-home-large-text")
        app.tabBars.buttons["확인함"].tap(); capture(app, "orange-inbox-large-text")
        app.tabBars.buttons["가계부"].tap(); app.buttons["addEntry"].tap()
        capture(app, "orange-entry-large-text")
        XCTAssertTrue(reveal(app.buttons["scopePersonal"], in: app))
        capture(app, "orange-entry-large-text-actions")
        XCTAssertGreaterThan(app.buttons["scopePersonal"].frame.minY, app.buttons["scopeShared"].frame.minY)
        XCTAssertTrue(reveal(app.buttons["saveEntry"], in: app))
        capture(app, "orange-entry-large-text-save")
        XCTAssertGreaterThanOrEqual(app.buttons["saveEntry"].frame.height, 44)
        XCTAssertTrue(app.frame.contains(app.buttons["saveEntry"].frame))
    }

    @MainActor private func importMockPayment(in app: XCUIApplication, merchant: String, amount: Int, reference: String) {
        XCTAssertTrue(reveal(app.buttons["pasteNotification"], in: app))
        app.buttons["pasteNotification"].tap()
        app.textViews["notificationText"].tap()
        app.textViews["notificationText"].typeText("카드 1234 승인 \(amount)원\n가맹점: " + merchant + "\n승인번호 " + reference + "\n10/21 13:00")
        app.buttons["importNotification"].tap()
        XCTAssertTrue(app.buttons["importNotification"].waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.textFields["entryAmount"].waitForExistence(timeout: 10))
        XCTAssertEqual((app.textFields["entryAmount"].value as? String)?.replacingOccurrences(of: ",", with: ""), String(amount))
        XCTAssertEqual(app.textFields["entryNote"].value as? String, merchant)
        XCTAssertFalse(app.buttons["saveEntry"].isEnabled, "대기 알림 준비만으로 공개 범위나 기록을 확정하면 안 됨")
        app.buttons["취소"].tap()
        XCTAssertTrue(reveal(app.buttons["pasteNotification"], in: app), "확인함 하단의 가져오기 버튼까지 스크롤")
        XCTAssertTrue(reveal(app.buttons[merchant + " 기록"], in: app), "취소한 알림은 후속 연속 처리용으로 확인함에 남아야 함")
    }

    @MainActor private func advanceToNotificationTest(in app: XCUIApplication) {
        for _ in 0..<5 {
            if app.buttons["sendAutomationTest"].waitForExistence(timeout: 1) { return }
            XCTAssertTrue(app.buttons["automationGuideNext"].waitForExistence(timeout: 5))
            app.buttons["automationGuideNext"].tap()
            allowOwnNotifications()
        }
        XCTAssertTrue(app.buttons["sendAutomationTest"].waitForExistence(timeout: 8))
    }

    @MainActor private func allowOwnNotifications() {
        let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        if alert.waitForExistence(timeout: 2) {
            if alert.buttons["허용"].exists { alert.buttons["허용"].tap() }
            else if alert.buttons["Allow"].exists { alert.buttons["Allow"].tap() }
        }
    }

    @MainActor func testNotificationImportScopeFocusAcceptsTypingWithoutNoteTap() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["OURLEDGER_TEST_SERVER"] = "http://127.0.0.1:18817"
        app.launch()
        if app.textFields["memberName"].waitForExistence(timeout: 3) {
            app.textFields["memberName"].tap()
            app.textFields["memberName"].typeText("입력 초점 검증\n")
            app.buttons["createHousehold"].tap()
        }
        XCTAssertTrue(app.buttons["addEntry"].waitForExistence(timeout: 15))
        app.buttons["addEntry"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.typeText("1700")
        XCTAssertEqual((app.textFields["entryAmount"].value as? String)?.replacingOccurrences(of: ",", with: ""), "1700", "수동 추가는 금액에 바로 입력되어야 함")
        app.buttons["취소"].tap()
        app.tabBars.buttons["확인함"].tap()
        XCTAssertTrue(reveal(app.buttons["pasteNotification"], in: app))
        app.buttons["pasteNotification"].tap()
        let merchant = "초점검증마트 " + String(UUID().uuidString.prefix(6))
        app.textViews["notificationText"].tap()
        app.textViews["notificationText"].typeText("카드 1234 승인 8,400원\n가맹점: " + merchant + "\n10/21 13:00")
        app.buttons["importNotification"].tap()
        XCTAssertTrue(app.buttons["importNotification"].waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.textFields["entryAmount"].waitForExistence(timeout: 10), "첫 확인은 가져오기에서 바로 열린 기록 화면이어야 함")
        for selection in ["scopeShared", "scopePersonal"] {
            if selection == "scopePersonal" {
                XCTAssertTrue(reveal(app.buttons[merchant + " 기록"], in: app))
                app.buttons[merchant + " 기록"].tap()
            }
            XCTAssertTrue(app.buttons[selection].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["saveEntry"].isEnabled, "가져온 알림도 공개 범위를 직접 선택해야 함")
            app.buttons[selection].tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "공개 범위 선택 후 설명에 바로 입력할 수 있어야 함")
            let note = app.textFields["entryNote"]
            XCTAssertTrue(note.isHittable)
            XCTAssertLessThanOrEqual(note.frame.maxY, app.keyboards.firstMatch.frame.minY)
            XCTAssertLessThanOrEqual(note.frame.maxY, app.buttons[selection].frame.minY, "설명을 하단 버튼이 가리면 안 됨")
            app.typeText("-" + selection)
            XCTAssertEqual(note.value as? String, merchant + "-" + selection, "설명 칸을 탭하지 않아도 설명에 입력되어야 함")
            XCTAssertEqual(app.textFields["entryAmount"].value as? String, "8,400")
            XCTAssertEqual(app.buttons[selection].value as? String, "선택됨")
            capture(app, "import-note-direct-typing-" + selection)
            app.buttons["취소"].tap()
        }
        XCTAssertTrue(reveal(app.buttons[merchant + " 기록"], in: app), "입력을 취소한 알림은 지출로 저장되면 안 됨")
    }

    @MainActor func testTwoQueuedImportsKeepOrderAndPrivacy() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["OURLEDGER_TEST_SERVER"] = "http://127.0.0.1:18817"
        app.launch()
        connectLocalLedgerIfNeeded(in: app)
        XCTAssertTrue(app.buttons["addEntry"].waitForExistence(timeout: 15))
        app.tabBars.buttons["확인함"].tap()
        let prefix = "연속검증 " + String(UUID().uuidString.prefix(6))
        let first = prefix + " 첫째", second = prefix + " 둘째", third = prefix + " 셋째"
        importMockPayment(in: app, merchant: first, amount: 1701, reference: "121001")
        importMockPayment(in: app, merchant: second, amount: 2902, reference: "121002")
        importMockPayment(in: app, merchant: third, amount: 4103, reference: "121003")
        app.terminate()
        app.launchEnvironment["OURLEDGER_TEST_QUEUE_PREFIX"] = prefix
        app.launch()
        XCTAssertTrue(app.buttons["notificationChooseShared"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts[first].exists, "두 번째 알림이 첫 번째 확인 화면을 바꾸면 안 됨")
        XCTAssertFalse(app.staticTexts[second].exists)
        app.buttons["notificationChooseShared"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.typeText("-shared\n")
        XCTAssertEqual(app.textFields["entryNote"].value as? String, first + "-shared")
        XCTAssertEqual(app.textFields["entryAmount"].value as? String, "1,701")
        XCTAssertEqual(app.buttons["scopeShared"].value as? String, "선택됨")
        app.buttons["saveEntry"].tap()
        XCTAssertTrue(app.buttons["notificationChoosePersonal"].waitForExistence(timeout: 10), "저장 후 다음 버튼 없이 두 번째 거래가 자동으로 열려야 함")
        capture(app, "queue-second-auto-opened")
        XCTAssertTrue(app.staticTexts[second].exists)
        XCTAssertFalse(app.staticTexts[first].exists)
        app.buttons["notificationChoosePersonal"].tap()
        XCTAssertFalse(app.buttons["scopeShared"].value as? String == "선택됨", "이전 거래의 공용 선택을 넘기면 안 됨")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.typeText("-personal\n")
        XCTAssertEqual(app.textFields["entryNote"].value as? String, second + "-personal")
        XCTAssertEqual(app.textFields["entryAmount"].value as? String, "2,902")
        XCTAssertEqual(app.buttons["scopePersonal"].value as? String, "선택됨")
        app.buttons["saveEntry"].tap()
        XCTAssertTrue(app.buttons["notificationChooseShared"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts[third].exists, "알림을 따로 누르지 않은 세 번째 건도 이어서 보여야 함")
        app.buttons["notificationChooseShared"].tap()
        XCTAssertEqual(app.textFields["entryNote"].value as? String, third)
        XCTAssertEqual(app.textFields["entryAmount"].value as? String, "4,103")
        app.typeText("-shared\n")
        app.buttons["saveEntry"].tap()
        XCTAssertTrue(app.staticTexts["paymentFlowComplete"].waitForExistence(timeout: 10))
        capture(app, "queue-third-complete")
        app.buttons["finishPaymentFlow"].tap()
        XCTAssertTrue(app.buttons["addEntry"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["notificationChoosePersonal"].exists, "이미 처리한 라우터 대기 알림이 다시 열리면 안 됨")
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "OURLEDGER_TEST_QUEUE_PREFIX")
        app.launch()
        XCTAssertTrue(app.buttons["addEntry"].waitForExistence(timeout: 15))
        app.tabBars.buttons["확인함"].tap()
        XCTAssertTrue(app.staticTexts["확인할 거래 0건"].waitForExistence(timeout: 10))
        app.tabBars.buttons["가계부"].tap()
        XCTAssertTrue(reveal(app.buttons["ledgerScope-shared"], in: app, upward: false))
        app.buttons["ledgerScope-shared"].tap()
        let search = openLedgerSearch(in: app)
        XCTAssertTrue(reveal(search, in: app, upward: false))
        search.tap(); search.typeText(prefix + "\n")
        XCTAssertTrue(reveal(app.staticTexts[first + "-shared"], in: app))
        XCTAssertFalse(app.staticTexts[second + "-personal"].exists, "개인 기록은 공용 검색에 공개되면 안 됨")
        capture(app, "queue-shared-search")
        let scope = app.buttons["ledgerScope-personal"]
        XCTAssertTrue(reveal(scope, in: app, upward: false))
        scope.tap()
        XCTAssertTrue(reveal(app.staticTexts[second + "-personal"], in: app))
        XCTAssertFalse(app.staticTexts[first + "-shared"].exists)
        capture(app, "queue-personal-search")
    }

    @MainActor func testInboxSequenceExclusionAndCancelPreservePending() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["OURLEDGER_TEST_SERVER"] = "http://127.0.0.1:18817"
        app.launch(); connectLocalLedgerIfNeeded(in: app)
        XCTAssertTrue(app.buttons["addEntry"].waitForExistence(timeout: 15))
        app.tabBars.buttons["확인함"].tap()
        let prefix = "이어확인 " + String(UUID().uuidString.prefix(6))
        let names = [prefix + " 첫째", prefix + " 둘째"]
        for (index, name) in names.enumerated() {
            XCTAssertTrue(reveal(app.buttons["pasteNotification"], in: app))
            app.buttons["pasteNotification"].tap()
            app.textViews["notificationText"].tap()
            app.textViews["notificationText"].typeText("테스트은행 출금 \(5100 + index)원\n사용처: " + name)
            app.buttons["importNotification"].tap()
            XCTAssertTrue(app.buttons["importNotification"].waitForNonExistence(timeout: 10))
        }
        XCTAssertTrue(reveal(app.buttons[names[0] + " 기록"], in: app))
        app.buttons[names[0] + " 기록"].tap()
        XCTAssertTrue(app.buttons["ignoreTransfer"].waitForExistence(timeout: 10))
        app.buttons["ignoreTransfer"].tap()
        let next = app.textFields["entryNote"]
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", names[1]), object: next)], timeout: 10), .completed)
        XCTAssertEqual(app.textFields["entryAmount"].value as? String, "5,101")
        XCTAssertNotEqual(app.buttons["scopeShared"].value as? String, "선택됨")
        XCTAssertNotEqual(app.buttons["scopePersonal"].value as? String, "선택됨")
        capture(app, "inbox-sequence-next-unselected")
        app.buttons["취소"].tap()
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["addEntry"].waitForExistence(timeout: 15))
        app.tabBars.buttons["확인함"].tap()
        XCTAssertTrue(reveal(app.buttons[names[1] + " 기록"], in: app), "중간 취소 후에도 남은 알림을 보존해야 함")
        XCTAssertFalse(app.buttons[names[0] + " 기록"].exists)
        app.buttons[names[1] + " 기록"].tap()
        XCTAssertTrue(app.buttons["ignoreTransfer"].waitForExistence(timeout: 10))
        app.buttons["ignoreTransfer"].tap()
        XCTAssertTrue(app.buttons["finishPaymentFlow"].waitForExistence(timeout: 10))
        app.buttons["finishPaymentFlow"].tap()
        XCTAssertTrue(app.staticTexts["확인할 거래 0건"].waitForExistence(timeout: 10))
    }

    @MainActor func testLocalLiveActivityExpandedPractice() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["OURLEDGER_TEST_SERVER"] = "http://127.0.0.1:18817"
        app.launch()
        connectLocalLedgerIfNeeded(in: app)
        app.terminate()
        app.launchEnvironment["OURLEDGER_TEST_ACTIVITY"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["addEntry"].waitForExistence(timeout: 15))
        let spending = app.staticTexts["summaryAmount"].label
        let income = app.staticTexts["summaryIncomeAmount"].exists ? app.staticTexts["summaryIncomeAmount"].label : nil
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let island = springboard.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "우리 가계부 결제 확인")).firstMatch
        let appeared = island.waitForExistence(timeout: 15)
        capture(springboard, "local-activity-compact")
        if !appeared {
            let tree = XCTAttachment(string: springboard.debugDescription)
            tree.name = "local-activity-missing-hierarchy"; tree.lifetime = .keepAlways; add(tree)
        }
        XCTAssertTrue(appeared, "연습 활동이 실제로 표시된 뒤 길게 눌러야 함")
        island.press(forDuration: 1)
        let shared = springboard.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "공용, 앱에서 결제 확인")).firstMatch
        let expanded = shared.waitForExistence(timeout: 8)
        capture(springboard, "local-activity-expanded")
        if !expanded {
            let tree = XCTAttachment(string: springboard.debugDescription)
            tree.name = "local-activity-unavailable-hierarchy"; tree.lifetime = .keepAlways; add(tree)
        }
        XCTAssertTrue(expanded, "전용 시뮬레이터에서 펼친 활동의 공용 링크를 확인할 수 없음")
        shared.tap()
        let note = app.textFields["entryNote"]
        XCTAssertTrue(note.waitForExistence(timeout: 10))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let practiceAmountText = try XCTUnwrap(app.textFields["entryAmount"].value as? String)
        let practiceAmount = try XCTUnwrap(Int(practiceAmountText.replacingOccurrences(of: ",", with: "")))
        XCTAssertTrue((100...2000).contains(practiceAmount), "연습 금액은 동적으로 생성한 100~2,000원이어야 함")
        XCTAssertEqual(practiceAmount % 100, 0, "연습 금액은 100원 단위여야 함")
        XCTAssertEqual(app.buttons["scopeShared"].value as? String, "선택됨")
        XCTAssertFalse(app.buttons["카테고리 추가"].exists, "연습에서는 실제 카테고리를 추가하면 안 됨")
        capture(app, "local-activity-note-focused")
        XCTAssertLessThanOrEqual(note.frame.maxY, app.buttons["scopeShared"].frame.minY)
        let original = note.value as? String ?? ""
        app.typeText("-island\n")
        XCTAssertEqual(note.value as? String, original + "-island", "링크 진입 후 설명을 탭하지 않고 입력되어야 함")
        capture(app, "local-activity-note-direct-typing")
        app.buttons["saveEntry"].tap()
        XCTAssertTrue(app.staticTexts["paymentFlowComplete"].waitForExistence(timeout: 5))
        capture(app, "local-activity-practice-complete")
        app.buttons["finishPaymentFlow"].tap()
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "OURLEDGER_TEST_ACTIVITY")
        app.launch()
        XCTAssertTrue(app.buttons["addEntry"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["summaryAmount"].label, spending, "연습은 실제 지출에 포함되면 안 됨")
        XCTAssertEqual(app.staticTexts["summaryIncomeAmount"].exists ? app.staticTexts["summaryIncomeAmount"].label : nil, income)
    }

    @MainActor func testNotificationTapSharedPracticeDoesNotChangeLedger() async throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["OURLEDGER_TEST_SERVER"] = "http://127.0.0.1:18817"
        app.launch()
        guard app.textFields["memberName"].waitForExistence(timeout: 5) else {
            throw XCTSkip("알림 선택 회귀 검사는 새 전용 시뮬레이터에서 실행해 주세요.")
        }
        let owner = try await call("/households", body: ["name": "알림 테스트 가계부", "memberName": "알림 테스트 상대", "mode": "separate"])
        let token = owner["token"] as! String
        let invitation = try await call("/invite", body: [:], token: token)
        var link = URLComponents(); link.scheme = "ourledger"; link.host = "join"
        link.queryItems = [URLQueryItem(name: "server", value: "http://127.0.0.1:18817"), URLQueryItem(name: "invite", value: invitation["invite"] as? String)]
        app.buttons["초대받았어요"].tap()
        app.textFields["memberName"].tap(); app.textFields["memberName"].typeText("알림 기록 검증\n")
        app.textFields["inviteLink"].typeText(link.url!.absoluteString)
        app.buttons["createHousehold"].tap()
        XCTAssertTrue(app.buttons["addEntry"].waitForExistence(timeout: 15))
        let before = try await call("/state?month=" + String(ISO8601DateFormatter().string(from: Date()).prefix(7)), token: token)
        app.tabBars.buttons["설정"].tap(); app.buttons["notificationGuide"].tap()
        XCTAssertTrue(app.buttons["automationGuideNext"].waitForExistence(timeout: 5))
        advanceToNotificationTest(in: app)
        app.buttons["sendAutomationTest"].tap()
        let sent = app.buttons.matching(NSPredicate(format: "identifier == %@ AND label == %@ AND enabled == true", "sendAutomationTest", "다시 테스트하기")).firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: 10), "알림 예약이 끝난 뒤 홈으로 나가야 함")
        app.buttons["sendAutomationTest"].tap()
        XCTAssertTrue(sent.waitForExistence(timeout: 10))
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let notification = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "[테스트] 카드 결제 승인")).firstMatch
        if !notification.waitForExistence(timeout: 3) {
            let top = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.01))
            let bottom = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.6))
            top.press(forDuration: 0.1, thenDragTo: bottom)
        }
        let appeared = notification.waitForExistence(timeout: 15)
        capture(springboard, "payment-practice-system-notification")
        if !appeared {
            let tree = XCTAttachment(string: springboard.debugDescription); tree.name = "notification-system-hierarchy"; tree.lifetime = .keepAlways; add(tree)
        }
        XCTAssertTrue(appeared)
        notification.tap()
        if !app.buttons["notificationChooseShared"].waitForExistence(timeout: 3), notification.exists {
            notification.tap() // The first tap expands a grouped pair of system notifications.
        }
        XCTAssertTrue(app.buttons["notificationChooseShared"].waitForExistence(timeout: 10))
        capture(app, "payment-practice-choice")
        app.buttons["notificationChooseShared"].tap()
        XCTAssertTrue(app.textFields["entryNote"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["카테고리 추가"].exists, "연습에서 실제 카테고리를 추가하면 안 됨")
        focusEntryNote(in: app); app.textFields["entryNote"].typeText(" · 기록 연습\n")
        let firstAmount = app.textFields["entryAmount"].value as? String
        XCTAssertTrue(["100", "200"].contains(firstAmount ?? ""))
        capture(app, "payment-practice-entry")
        app.buttons["saveEntry"].tap()
        XCTAssertTrue(app.buttons["notificationChoosePersonal"].waitForExistence(timeout: 10), "첫 테스트 저장 후 다른 테스트 알림을 자동으로 열어야 함")
        XCTAssertFalse(app.staticTexts["paymentFlowComplete"].exists)
        capture(app, "payment-practice-second-auto-opened")
        app.buttons["notificationChoosePersonal"].tap()
        XCTAssertTrue(app.textFields["entryNote"].waitForExistence(timeout: 5))
        let secondAmount = app.textFields["entryAmount"].value as? String
        XCTAssertTrue(["100", "200"].contains(secondAmount ?? ""))
        XCTAssertNotEqual(firstAmount, secondAmount)
        app.buttons["saveEntry"].tap()
        XCTAssertTrue(app.staticTexts["paymentFlowComplete"].waitForExistence(timeout: 5))
        capture(app, "payment-practice-complete")
        app.buttons["finishPaymentFlow"].tap()
        XCTAssertTrue(app.staticTexts["paymentPracticePassed"].waitForExistence(timeout: 5))
        let after = try await call("/state?month=" + String(ISO8601DateFormatter().string(from: Date()).prefix(7)), token: token)
        XCTAssertEqual((before["stats"] as! [String: Any])["total"] as? Int, (after["stats"] as! [String: Any])["total"] as? Int)
        XCTAssertEqual((before["entries"] as! [[String: Any]]).count, (after["entries"] as! [[String: Any]]).count)
        XCTAssertEqual((before["categories"] as! [[String: Any]]).count, (after["categories"] as! [[String: Any]]).count)
    }

    @MainActor func testSharedIncomeChangesSettlementWithoutChangingSpending() async throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["OURLEDGER_TEST_SERVER"] = "http://127.0.0.1:18817"
        app.launch()
        guard app.textFields["memberName"].waitForExistence(timeout: 5) else {
            throw XCTSkip("수입 저장 검사는 운영 연결이 없는 새 시뮬레이터에서 실행해 주세요.")
        }
        let owner = try await call("/households", body: ["name": "수입 검증 가계부", "memberName": "수입 테스트 상대", "mode": "separate"])
        let token = owner["token"] as! String
        let invitation = try await call("/invite", body: [:], token: token)
        var link = URLComponents()
        link.scheme = "ourledger"; link.host = "join"
        link.queryItems = [URLQueryItem(name: "server", value: "http://127.0.0.1:18817"), URLQueryItem(name: "invite", value: invitation["invite"] as? String)]
        app.buttons["초대받았어요"].tap()
        app.textFields["memberName"].tap(); app.textFields["memberName"].typeText("수입 기록자\n")
        app.textFields["inviteLink"].typeText(link.url!.absoluteString)
        app.buttons["createHousehold"].tap()
        XCTAssertTrue(app.buttons["addEntry"].waitForExistence(timeout: 15))
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"; formatter.timeZone = TimeZone(identifier: "Asia/Seoul")
        let month = formatter.string(from: Date())
        _ = try await call("/entries", body: ["amount": 10000, "note": "수입과 구분할 생활비", "scope": "shared", "day": month + "-01"], token: token)
        let before = try await call("/state?month=" + month, token: token)
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["addEntry"].waitForExistence(timeout: 15))
        app.buttons["addEntry"].tap()
        XCTAssertTrue(app.buttons["entryKind-income"].waitForExistence(timeout: 5), "수입 선택은 추가 설정을 열지 않아도 보여야 함")
        app.buttons["entryKind-income"].tap()
        app.textFields["entryAmount"].tap(); app.textFields["entryAmount"].typeText("150000")
        XCTAssertEqual((app.textFields["entryAmount"].value as? String)?.replacingOccurrences(of: ",", with: ""), "150000")
        let note = "공용 중고 판매 수입 " + String(UUID().uuidString.prefix(6))
        focusEntryNote(in: app); app.textFields["entryNote"].typeText(note)
        XCTAssertFalse(app.buttons["saveEntry"].isEnabled, "수입도 공용·개인을 직접 선택해야 함")
        app.buttons["scopeShared"].tap()
        capture(app, "income-manual-entry")
        app.buttons["saveEntry"].tap()
        XCTAssertTrue(app.textFields["entryNote"].waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["summaryIncomeAmount"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["summaryIncomeAmount"].label, "공용 수입, +150,000원")
        XCTAssertEqual(app.staticTexts["summaryAmount"].label, "10,000원")
        XCTAssertTrue(reveal(app.buttons["settlementDetails"], in: app))
        XCTAssertTrue(app.buttons["settlementDetails"].label.contains("내가 보낼 돈 80,000원"))
        capture(app, "income-separate-from-spending")
        let after = try await call("/state?month=" + month, token: token)
        let beforeStats = before["stats"] as! [String: Any], afterStats = after["stats"] as! [String: Any]
        XCTAssertEqual(afterStats["incomeTotal"] as? Int, 150000)
        XCTAssertEqual(afterStats["total"] as? Int, beforeStats["total"] as? Int)
        XCTAssertEqual(afterStats["personalTotal"] as? Int, beforeStats["personalTotal"] as? Int)
        let oldSettlement = before["settlement"] as! [String: Any], newSettlement = after["settlement"] as! [String: Any]
        XCTAssertEqual(oldSettlement["amount"] as? Int, 5000)
        XCTAssertEqual(newSettlement["amount"] as? Int, 80000)
        XCTAssertEqual(newSettlement["count"] as? Int, 2)
        let recordingMember = (after["members"] as! [[String: Any]]).first { $0["name"] as? String == "수입 기록자" }?["id"] as? String
        XCTAssertNotNil(recordingMember)
        XCTAssertEqual(newSettlement["fromID"] as? String, recordingMember)
        XCTAssertEqual(newSettlement["toID"] as? String, owner["memberID"] as? String)
        XCTAssertNotEqual(newSettlement["revision"] as? String, oldSettlement["revision"] as? String)
        let saved = (after["entries"] as! [[String: Any]]).first { $0["note"] as? String == note }
        XCTAssertEqual(saved?["kind"] as? String, "income")
        XCTAssertEqual(saved?["scope"] as? String, "shared")
        XCTAssertEqual(saved?["amount"] as? Int, 150000)
        XCTAssertTrue(reveal(app.staticTexts["entryListSummary"], in: app))
        XCTAssertTrue(app.staticTexts["entryListSummary"].label.hasPrefix("1건"), "수입은 지출·환불 건수에서 제외해야 함")

        app.tabBars.buttons["확인함"].tap()
        XCTAssertTrue(reveal(app.buttons["pasteNotification"], in: app))
        app.buttons["pasteNotification"].tap()
        let merchant = "거래확인검증회사 " + String(UUID().uuidString.prefix(6))
        app.textViews["notificationText"].tap()
        app.textViews["notificationText"].typeText("우리은행 입금 20,000원\n" + merchant + "\n잔액 120,000원\n" + String(month.suffix(2)) + "/21 12:00")
        app.buttons["importNotification"].tap()
        XCTAssertTrue(reveal(app.buttons[merchant + " 기록"], in: app))
        app.buttons[merchant + " 기록"].tap()
        XCTAssertTrue(app.buttons["entryKind-income"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["entryKind-income"].value as? String, "선택 안 됨", "은행 입금 후보를 수입으로 미리 확정하면 안 됨")
        app.buttons["scopeShared"].tap()
        XCTAssertFalse(app.buttons["saveEntry"].isEnabled, "공용을 골라도 입금의 종류를 확인하기 전에는 저장하면 안 됨")
        app.typeText("\n")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 4))
        app.swipeDown()
        XCTAssertTrue(reveal(app.buttons["entryKind-income"], in: app, upward: false))
        app.buttons["entryKind-income"].tap()
        XCTAssertEqual(app.buttons["entryKind-income"].value as? String, "선택됨")
        XCTAssertTrue(app.buttons["saveEntry"].isEnabled, app.debugDescription)
        XCTAssertTrue(reveal(app.buttons["ignoreTransfer"], in: app, upward: false))
        capture(app, "income-candidate-explicit-confirmation")
        app.buttons["ignoreTransfer"].tap()
        XCTAssertTrue(app.buttons["ignoreTransfer"].waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["paymentFlowComplete"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["finishPaymentFlow"].waitForExistence(timeout: 5))
        app.buttons["finishPaymentFlow"].tap()
        XCTAssertTrue(app.buttons["pasteNotification"].waitForExistence(timeout: 5))
        let afterIgnored = try await call("/state?month=" + month, token: token)
        XCTAssertEqual((afterIgnored["stats"] as! [String: Any])["incomeTotal"] as? Int, 150000, "계좌 이동을 제외하면 수입을 추가하면 안 됨")
        XCTAssertEqual((afterIgnored["entries"] as! [[String: Any]]).count, (after["entries"] as! [[String: Any]]).count)
    }

    @MainActor func testSharedIncomeIntoFundKeepsDestinationWhenEditing() async throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["OURLEDGER_TEST_SERVER"] = "http://127.0.0.1:18817"
        app.launch()
        guard app.textFields["memberName"].waitForExistence(timeout: 5) else {
            throw XCTSkip("공동 계좌 수입 검사는 새 시뮬레이터에서 실행해 주세요.")
        }
        let owner = try await call("/households", body: ["name": "공동 수입 검증", "memberName": "상대", "mode": "pool"])
        let token = owner["token"] as! String
        let invitation = try await call("/invite", body: [:], token: token)
        var link = URLComponents()
        link.scheme = "ourledger"; link.host = "join"
        link.queryItems = [URLQueryItem(name: "server", value: "http://127.0.0.1:18817"), URLQueryItem(name: "invite", value: invitation["invite"] as? String)]
        app.buttons["초대받았어요"].tap()
        app.textFields["memberName"].tap(); app.textFields["memberName"].typeText("기록자\n")
        app.textFields["inviteLink"].typeText(link.url!.absoluteString)
        app.buttons["createHousehold"].tap()
        XCTAssertTrue(app.buttons["addEntry"].waitForExistence(timeout: 15))
        app.buttons["addEntry"].tap()
        app.buttons["entryKind-income"].tap()
        app.textFields["entryAmount"].tap(); app.textFields["entryAmount"].typeText("50000")
        focusEntryNote(in: app); app.textFields["entryNote"].typeText("함께 쓸 용돈")
        app.buttons["scopeShared"].tap()
        XCTAssertTrue(reveal(app.buttons["공동 계좌"], in: app, upward: false))
        app.buttons["공동 계좌"].tap()
        capture(app, "shared-income-fund-destination")
        app.buttons["saveEntry"].tap()
        XCTAssertTrue(app.textFields["entryNote"].waitForNonExistence(timeout: 10))
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM"; formatter.timeZone = TimeZone(identifier: "Asia/Seoul")
        let month = formatter.string(from: Date())
        let saved = try await call("/state?month=" + month, token: token)
        XCTAssertEqual((saved["stats"] as! [String: Any])["fundBalance"] as? Int, 50000)
        XCTAssertEqual((saved["settlement"] as! [String: Any])["count"] as? Int, 0)
        app.tabBars.buttons["통계"].tap()
        XCTAssertTrue(reveal(app.buttons["sharedIncomeDetails"], in: app))
        app.buttons["sharedIncomeDetails"].tap()
        XCTAssertTrue(app.staticTexts["함께 쓸 용돈"].waitForExistence(timeout: 5))
        app.staticTexts["함께 쓸 용돈"].tap()
        XCTAssertTrue(app.buttons["내역 수정"].waitForExistence(timeout: 5))
        app.buttons["내역 수정"].tap()
        XCTAssertTrue(reveal(app.buttons["공동 계좌"], in: app, upward: false))
        XCTAssertTrue(app.buttons["공동 계좌"].isSelected, "편집을 열어도 공동 계좌 수입을 개인 계좌로 바꾸면 안 됨")
        app.buttons["saveEntry"].tap()
        XCTAssertTrue(app.textFields["entryNote"].waitForNonExistence(timeout: 10))
        let after = try await call("/state?month=" + month, token: token)
        XCTAssertEqual((after["stats"] as! [String: Any])["fundBalance"] as? Int, 50000)
        XCTAssertEqual((after["entries"] as! [[String: Any]]).count, 1)
        XCTAssertEqual((after["entries"] as! [[String: Any]])[0]["funding"] as? String, "fund")
    }

    @MainActor func testReleaseDesignWithPopulatedHousehold() async throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["OURLEDGER_TEST_SERVER"] = "http://127.0.0.1:18817"
        app.launch()
        guard app.textFields["memberName"].waitForExistence(timeout: 5) else {
            throw XCTSkip("실제 데이터 검수는 새 로컬 시뮬레이터를 사용하세요.")
        }
        capture(app, "release-01-welcome")
        let owner = try await call("/households", body: ["name": "우리의 생활비", "memberName": "지우", "mode": "separate"])
        let token = owner["token"] as! String
        let df = DateFormatter(); df.dateFormat = "yyyy-MM"; df.timeZone = TimeZone(identifier: "Asia/Seoul")
        let month = df.string(from: Date())
        let previous = df.string(from: Calendar.current.date(byAdding: .month, value: -1, to: Date())!)
        let state = try await call("/state?month=" + month, token: token)
        let categories = state["categories"] as! [[String: Any]]
        for (index, item) in [("01", 78200, "주말 장보기"), ("03", 32000, "함께 먹은 저녁"), ("08", 26000, "세제와 생활용품"), ("15", 8400, "편의점 간식")].enumerated() {
            _ = try await call("/entries", body: ["amount": item.1, "note": item.2, "scope": "shared", "day": month + "-" + item.0, "category": categories[index % categories.count]["id"]!], token: token)
        }
        _ = try await call("/entries", body: ["amount": 210000, "note": "지난달 생활비", "scope": "shared", "day": previous + "-01"], token: token)
        _ = try await call("/entries", body: ["amount": 50000, "note": "함께 쓸 용돈", "kind": "income", "scope": "shared", "day": month + "-03"], token: token)
        _ = try await call("/entries", body: ["amount": 7300, "note": "상대 비공개 내역", "scope": "personal", "day": month + "-03"], token: token)
        _ = try await call("/settings", body: ["budget": 400000], token: token, method: "PATCH")
        _ = try await call("/recurring", body: ["note": "인터넷 요금", "amount": 33000, "scope": "shared", "category": categories[0]["id"]!, "payer": owner["memberID"]!, "funding": "personal", "startDay": month + "-01", "dayOfMonth": 25], token: token)
        let invite = try await call("/invite", body: [:], token: token)
        var link = URLComponents(); link.scheme = "ourledger"; link.host = "join"
        link.queryItems = [URLQueryItem(name: "server", value: "http://127.0.0.1:18817"), URLQueryItem(name: "invite", value: invite["invite"] as? String)]
        app.buttons["초대받았어요"].tap()
        app.textFields["memberName"].tap(); app.textFields["memberName"].typeText("민수\n")
        app.textFields["inviteLink"].typeText(link.url!.absoluteString)
        app.buttons["createHousehold"].tap()
        XCTAssertTrue(app.buttons["addEntry"].waitForExistence(timeout: 15))
        app.buttons["ledgerScope-shared"].tap()
        capture(app, "release-02-home")
        XCTAssertFalse(app.staticTexts["상대 비공개 내역"].exists)
        XCTAssertTrue(reveal(app.staticTexts["거래 달력"], in: app))
        let both = app.buttons["calendar-" + month + "-03"]
        XCTAssertTrue(reveal(both, in: app))
        XCTAssertTrue(both.label.contains("수입 +50,000원"))
        XCTAssertTrue(both.label.contains("순지출 −32,000원"))
        both.tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.83))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.28)))
        capture(app, "release-03-calendar")
        XCTAssertTrue(app.buttons["ledgerScope-shared"].isHittable)
        app.buttons["ledgerScope-personal"].tap()
        XCTAssertTrue(app.buttons["ledgerScope-personal"].isSelected)
        XCTAssertTrue(reveal(app.buttons["openRecurring"], in: app, upward: false))
        XCTAssertTrue(app.buttons["openRecurring"].label.contains("예정된 결제가 없어요"))
        capture(app, "release-03-personal")
        app.buttons["openRecurring"].tap()
        XCTAssertTrue(app.navigationBars["정기결제"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["인터넷 요금"].exists, "개인에서 들어온 정기결제에 공용 일정이 섞이면 안 됨")
        app.navigationBars["정기결제"].buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["ledgerScope-personal"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["ledgerScope-personal"].isSelected)
        XCTAssertTrue(reveal(app.buttons["이전 달"], in: app, upward: false))
        app.buttons["이전 달"].tap()
        XCTAssertTrue(app.buttons["ledgerScope-personal"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["ledgerScope-personal"].isSelected)
        app.buttons["다음 달"].tap()
        XCTAssertTrue(app.buttons["ledgerScope-personal"].waitForExistence(timeout: 10))
        app.buttons["ledgerScope-shared"].tap()
        XCTAssertTrue(reveal(app.buttons["settlementDetails"], in: app, upward: false))
        app.buttons["settlementDetails"].tap()
        XCTAssertTrue(app.navigationBars["정산"].waitForExistence(timeout: 5))
        capture(app, "release-04-settlement")
        app.navigationBars["정산"].buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["addEntry"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars.firstMatch.exists)
        app.tabBars.buttons["통계"].tap()
        capture(app, "release-05-insights")
        let category = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "category-")).firstMatch
        XCTAssertTrue(reveal(category, in: app))
        category.tap()
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 5))
        capture(app, "release-06-category-detail")
        app.navigationBars.firstMatch.buttons.firstMatch.tap()
        XCTAssertFalse(app.navigationBars.firstMatch.exists)
        app.swipeUp(); capture(app, "release-07-insights-charts")
        app.tabBars.buttons["확인함"].tap()
        importMockPayment(in: app, merchant: "동네마트", amount: 28900, reference: "DESIGN-28900")
        XCTAssertTrue(app.buttons["동네마트 기록"].waitForExistence(timeout: 5))
        capture(app, "release-08-inbox")
        app.buttons["동네마트 기록"].tap()
        XCTAssertTrue(app.buttons["scopeShared"].waitForExistence(timeout: 5))
        capture(app, "release-09-entry")
        app.buttons["취소"].tap()
        app.tabBars.buttons["설정"].tap()
        capture(app, "release-10-settings")
        app.buttons["recurringPayments"].tap()
        XCTAssertTrue(app.staticTexts["인터넷 요금"].waitForExistence(timeout: 5))
        capture(app, "release-11-recurring")
    }

    @MainActor func testSettlementCopyPastMonthAndNotification() async throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let token = try await joinSettlementFixture(app, mode: "separate")
        let month = String(dayForUITest().prefix(7))
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM"; formatter.timeZone = TimeZone(identifier: "Asia/Seoul")
        let past = formatter.string(from: Calendar.current.date(byAdding: .month, value: -1, to: Date())!)
        _ = try await call("/settings", body: ["bank": "검증은행", "account": "001-234-56789", "holder": "테스트상대"], token: token, method: "PATCH")
        _ = try await call("/entries", body: ["amount": 2020000, "note": "이전 달 함께 쓴 생활비", "scope": "shared", "day": past + "-02"], token: token)
        _ = try await call("/entries", body: ["amount": 10000, "note": "이번 달 생활비", "scope": "shared", "day": month + "-02"], token: token)
        app.terminate(); app.launch()
        XCTAssertTrue(reveal(app.buttons["settlementDetails"], in: app))
        XCTAssertTrue(app.staticTexts["overdueSettlementBadge"].exists)
        capture(app, "settlement-01-overdue-home")
        app.buttons["settlementDetails"].tap()
        XCTAssertTrue(reveal(app.buttons["overdueMonth-" + past], in: app))
        app.buttons["overdueMonth-" + past].tap()
        XCTAssertTrue(app.staticTexts["settlementPeriod"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["settlementPeriod"].label.hasPrefix(past))
        XCTAssertTrue(reveal(app.buttons["copySettlementAll"], in: app))
        capture(app, "settlement-02-copy-account")
        for identifier in ["copySettlementAll", "copySettlementAmount", "copySettlementBank", "copySettlementAccount", "copySettlementHolder"] {
            XCTAssertTrue(reveal(app.buttons[identifier], in: app, upward: identifier != "copySettlementAmount"))
            app.buttons[identifier].tap()
            XCTAssertTrue(app.staticTexts["settlementCopyFeedback"].label.contains("복사했어요"))
        }
        let before = try await call("/state?month=" + past, token: token)
        XCTAssertTrue((before["history"] as! [[String: Any]]).isEmpty, "복사만으로 정산하면 안 됨")
        app.tabBars.buttons["확인함"].tap()
        XCTAssertTrue(reveal(app.buttons["pasteNotification"], in: app))
        app.buttons["pasteNotification"].tap()
        let input = app.textViews["notificationText"]
        XCTAssertTrue(input.waitForExistence(timeout: 5)); input.tap()
        input.typeText("토스뱅크 출금 1,010,000원 송금 완료\n받는 분: 테스트상대\n" + dayForUITest() + " 12:30")
        app.buttons["importNotification"].tap()
        XCTAssertTrue(app.buttons["importNotification"].waitForNonExistence(timeout: 10))
        let candidate = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "settlementCandidate-")).firstMatch
        XCTAssertTrue(reveal(candidate, in: app))
        capture(app, "settlement-03-inbox-candidate")
        candidate.tap()
        XCTAssertTrue(reveal(app.buttons["confirmSettlementCandidate"], in: app))
        capture(app, "settlement-04-confirm-direction")
        app.buttons["닫기"].tap()
        let record = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "recordImport-")).firstMatch
        XCTAssertTrue(reveal(record, in: app)); record.tap()
        let entryCandidate = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "entrySettlementCandidate-")).firstMatch
        XCTAssertTrue(entryCandidate.waitForExistence(timeout: 5)); entryCandidate.tap()
        XCTAssertTrue(reveal(app.buttons["confirmSettlementCandidate"], in: app))
        capture(app, "settlement-04b-entry-route")
        app.buttons["confirmSettlementCandidate"].tap()
        XCTAssertTrue(app.staticTexts["settlementCandidateDone"].waitForExistence(timeout: 10))
        capture(app, "settlement-05-complete")
        let after = try await call("/state?month=" + past, token: token)
        let history = after["history"] as! [[String: Any]]
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?["amount"] as? Int, 1010000)
        XCTAssertEqual((after["entries"] as! [[String: Any]]).count, 1, "정산 알림을 지출/수입으로 이중 기록하면 안 됨")
        XCTAssertFalse((after["pendingSettlements"] as! [[String: Any]]).contains { $0["month"] as? String == past })
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["addEntry"].waitForExistence(timeout: 10))
        XCTAssertTrue(reveal(app.buttons["settlementDetails"], in: app))
        XCTAssertFalse(app.staticTexts["overdueSettlementBadge"].exists)
        app.buttons["settlementDetails"].tap()
        XCTAssertTrue(reveal(app.buttons["completeSettlement"], in: app))
        app.buttons["completeSettlement"].tap()
        let manual = app.buttons["송금을 마쳤어요 · 완료 기록"]
        XCTAssertTrue(manual.waitForExistence(timeout: 5)); manual.tap()
        XCTAssertTrue(reveal(app.staticTexts[month + " 정산 완료"], in: app))
        let current = try await call("/state?month=" + month, token: token)
        XCTAssertEqual((current["history"] as! [[String: Any]]).count, 1)
        capture(app, "settlement-06-manual-complete")
    }

    @MainActor func testSettlementPoolMissingAccountOnSmallScreen() async throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let token = try await joinSettlementFixture(app, mode: "pool")
        let month = String(dayForUITest().prefix(7))
        let state = try await call("/state?month=" + month, token: token)
        let ownerID = state["me"] as! String
        let memberID = (state["members"] as! [[String: Any]]).first { $0["id"] as? String != ownerID }!["id"] as! String
        _ = try await call("/entries", body: ["amount": 30000, "note": "개인 돈으로 산 공용 물품", "scope": "shared", "payer": memberID, "funding": "personal", "day": month + "-02"], token: token)
        _ = try await call("/entries", body: ["amount": 40000, "note": "함께 받은 생활비", "scope": "shared", "kind": "income", "funding": "personal", "day": month + "-02"], token: token)
        app.terminate(); app.launch()
        XCTAssertTrue(reveal(app.buttons["settlementDetails"], in: app)); app.buttons["settlementDetails"].tap()
        XCTAssertTrue(reveal(app.staticTexts["공동 계좌는 은행 앱에서 확인해 주세요."], in: app))
        XCTAssertFalse(app.buttons["copySettlementAll"].exists)
        capture(app, "settlement-pool-01-fund-return")
        XCTAssertTrue(reveal(app.buttons["계좌 등록하기"], in: app))
        XCTAssertTrue(app.staticTexts["받을 계좌를 먼저 등록해 주세요."].exists)
        capture(app, "settlement-pool-02-own-account-missing")
        app.buttons["계좌 등록하기"].tap()
        XCTAssertTrue(reveal(app.textFields["bankName"], in: app))
        let after = try await call("/state?month=" + month, token: token)
        XCTAssertTrue((after["history"] as! [[String: Any]]).isEmpty)
        XCTAssertEqual((after["pendingSettlements"] as! [[String: Any]]).count, 2)
    }

    @MainActor func testPayerBadgesKeepIdentitySeparateFromFunding() async throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let otherName = "테스트상대이름이아주길어요"
        let token = try await joinSettlementFixture(app, mode: "pool", otherName: otherName)
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "Asia/Seoul")
        let day = formatter.string(from: Date())
        let state = try await call("/state?month=" + String(day.prefix(7)), token: token)
        let members = state["members"] as! [[String: Any]]
        let other = state["me"] as! String
        let me = members.first { ($0["id"] as? String) != other }!["id"] as! String
        for (payer, note, kind) in [(me, "배지 본인 결제", "expense"), (other, "배지 상대 결제", "expense"), (me, "배지 본인 수입", "income")] {
            _ = try await call("/entries", body: ["amount": 1000, "note": note, "scope": "shared", "kind": kind,
                                                 "funding": "fund", "payer": payer, "day": day], token: token)
        }
        app.terminate(); app.launch()
        let search = openLedgerSearch(in: app)
        search.tap(); search.typeText("배지\n")
        let mine = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "배지 본인 결제")).firstMatch
        let theirs = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "배지 상대 결제")).firstMatch
        XCTAssertTrue(reveal(mine, in: app))
        XCTAssertTrue(mine.label.contains("나, 테스트본인"))
        XCTAssertTrue(reveal(theirs, in: app))
        XCTAssertTrue(theirs.label.contains(otherName))
        XCTAssertFalse(theirs.label.contains("상대, " + otherName))
        app.swipeUp()
        capture(app, "payer-badges-default")
        XCTAssertTrue(reveal(mine, in: app, upward: false))
        mine.tap()
        XCTAssertTrue(app.staticTexts["나, 테스트본인"].waitForExistence(timeout: 5))
        app.buttons["닫기"].tap()
        XCTAssertTrue(reveal(theirs, in: app))
        theirs.tap()
        XCTAssertTrue(app.staticTexts[otherName].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts[otherName].label, otherName)
        app.buttons["닫기"].tap()
        app.terminate()
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let largeSearch = openLedgerSearch(in: app)
        largeSearch.tap(); largeSearch.typeText("배지\n")
        XCTAssertTrue(reveal(mine, in: app))
        XCTAssertTrue(mine.label.contains("나, 테스트본인"))
        XCTAssertGreaterThan(mine.frame.height, 80)
        XCTAssertTrue(reveal(theirs, in: app))
        XCTAssertTrue(theirs.label.contains(otherName))
        capture(app, "payer-badges-accessibility-size")
    }

    @MainActor private func joinSettlementFixture(_ app: XCUIApplication, mode: String, otherName: String = "테스트상대") async throws -> String {
        app.launchEnvironment["OURLEDGER_TEST_SERVER"] = "http://127.0.0.1:18817"
        app.launch()
        guard app.textFields["memberName"].waitForExistence(timeout: 5) else {
            throw XCTSkip("정산 초기 상태 검사는 별도 새 시뮬레이터에서 실행해 주세요.")
        }
        let owner = try await call("/households", body: ["name": "정산 검증", "memberName": otherName, "mode": mode])
        let token = owner["token"] as! String
        let invitation = try await call("/invite", body: [:], token: token)
        var link = URLComponents(); link.scheme = "ourledger"; link.host = "join"
        link.queryItems = [URLQueryItem(name: "server", value: "http://127.0.0.1:18817"), URLQueryItem(name: "invite", value: invitation["invite"] as? String)]
        app.buttons["초대받았어요"].tap()
        app.textFields["memberName"].tap(); app.textFields["memberName"].typeText("테스트본인\n")
        let field = app.textFields["inviteLink"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText(link.url!.absoluteString)
        app.buttons["createHousehold"].tap()
        XCTAssertTrue(app.buttons["addEntry"].waitForExistence(timeout: 15))
        return token
    }

    @MainActor private func openLedgerSearch(in app: XCUIApplication) -> XCUIElement {
        let field = app.textFields["ledgerSearch"]
        if !field.exists {
            XCTAssertTrue(reveal(app.buttons["toggleLedgerSearch"], in: app, upward: false))
            app.buttons["toggleLedgerSearch"].tap()
        }
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        return field
    }

    @MainActor private func connectLocalLedgerIfNeeded(in app: XCUIApplication) {
        if app.textFields["memberName"].waitForExistence(timeout: 3) {
            app.textFields["memberName"].tap()
            app.textFields["memberName"].typeText("화면 검증\n")
            app.buttons["createHousehold"].tap()
        }
        let connected = app.buttons["addEntry"].waitForExistence(timeout: 15)
        if !connected { capture(app, "local-connection-failure"); print(app.debugDescription) }
        XCTAssertTrue(connected)
    }

    private func focusEntryNote(in app: XCUIApplication) {
        if app.buttons["saveEntry"].label == "설명 입력" { app.buttons["saveEntry"].tap() }
        else {
            XCTAssertTrue(reveal(app.textFields["entryNote"], in: app))
            app.textFields["entryNote"].tap()
        }
    }

    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name
        attachment.lifetime = .keepAlways; add(attachment)
    }

    @discardableResult private func reveal(_ element: XCUIElement, in app: XCUIApplication, upward: Bool = true) -> Bool {
        for _ in 0..<7 {
            if element.waitForExistence(timeout: 1) && element.isHittable { return true }
            if upward { app.swipeUp() } else { app.swipeDown() }
        }
        return element.exists && element.isHittable
    }

    private func call(_ path: String, body: [String: Any]? = nil, token: String? = nil, method: String? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:18817" + path)!)
        request.httpMethod = method ?? (body == nil ? "GET" : "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
}
