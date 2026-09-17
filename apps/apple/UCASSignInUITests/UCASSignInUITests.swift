import XCTest

final class UCASSignInUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testDemoHomeAndScheduleDateNavigation() {
        let app = launchDemo()
        XCTAssertTrue(app.navigationBars["果壳签到"].exists)
        XCTAssertTrue(app.staticTexts["课表、签到，都在这里。"].exists)
        XCTAssertFalse(app.buttons[dateButtonLabel(Date())].exists)
        XCTAssertFalse(app.buttons["选择日期"].exists)
        capture(app, name: "01-今日课程")

        selectTab("课表", in: app)
        XCTAssertTrue(app.navigationBars["课表"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["演示课表 · 所有日期均为示例数据"].exists)
        XCTAssertTrue(app.buttons[dateButtonLabel(Date())].exists)
        capture(app, name: "02-课表")

        let today = Date()
        let nextWeek = schoolCalendar.date(byAdding: .day, value: 7, to: today)!
        app.buttons["下一周"].tap()
        XCTAssertTrue(app.staticTexts[dateHeading(nextWeek)].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["3 门课程"].exists)
        capture(app, name: "03-切换课表日期")

        app.buttons["上一周"].tap()
        XCTAssertTrue(app.staticTexts[dateHeading(today)].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "矩阵分析")).firstMatch.exists)

        app.buttons["下一周"].tap()
        XCTAssertTrue(app.staticTexts[dateHeading(nextWeek)].waitForExistence(timeout: 5))
        selectTab("今日", in: app)
        XCTAssertTrue(app.staticTexts["今日课程"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["今日安排"].exists)
        XCTAssertFalse(app.buttons[dateButtonLabel(today)].exists)
        XCTAssertFalse(app.buttons[dateButtonLabel(nextWeek)].exists)

        selectTab("课表", in: app)
        let selectedDate = app.buttons[dateButtonLabel(nextWeek)]
        assertEventually("切换今日标签页后，课表应保留所选日期") { selectedDate.exists && selectedDate.isSelected }
        XCTAssertTrue(app.staticTexts[dateHeading(nextWeek)].exists)
    }

    @MainActor
    func testRefreshKeepsScheduleSelectionAndToolbarAlignment() {
        let app = launchDemo()
        XCTAssertFalse(app.buttons["today.refresh"].exists)
        XCTAssertFalse(app.buttons["today.reminders"].exists)

        selectTab("课表", in: app)
        let datePicker = app.buttons["schedule.datePicker"]
        XCTAssertTrue(datePicker.waitForExistence(timeout: 5))
        XCTAssertTrue(datePicker.isHittable)
        XCTAssertFalse(app.buttons["schedule.refresh"].exists)

        let nextWeek = schoolCalendar.date(byAdding: .day, value: 7, to: Date())!
        app.buttons["下一周"].tap()
        let selectedDate = app.buttons[dateButtonLabel(nextWeek)]
        assertEventually("课表应选中下一周的日期") { selectedDate.exists && selectedDate.isSelected }
        app.scrollViews["schedule.scroll"].swipeDown()
        assertScheduleSelectionAndCourses(nextWeek, in: app)

        selectTab("今日", in: app)
        let todayCourse = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "矩阵分析")).firstMatch
        XCTAssertFalse(app.buttons["today.refresh"].exists)
        XCTAssertFalse(app.buttons["today.reminders"].exists)
        app.scrollViews["today.scroll"].swipeDown()
        assertEventually("今日下拉刷新应保留课程内容") { todayCourse.exists }

        selectTab("课表", in: app)
        assertScheduleSelectionAndCourses(nextWeek, in: app)
        capture(app, name: "刷新后课表日期与工具栏")
    }

    @MainActor
    func testRecordsLogoutAndLoginSheet() {
        let app = launchDemo()
        selectTab("账户", in: app)
        ensureAccountDetailsVisible(in: app)
        XCTAssertTrue(app.staticTexts["演示同学"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["学号 2026123456"].exists)
        capture(app, name: "04-账户")

        let accountCard = app.buttons["profile.connectAccount"]
        XCTAssertTrue(accountCard.waitForExistence(timeout: 5))
        accountCard.tap()
        XCTAssertTrue(app.staticTexts["连接你的课堂。"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["SEP 邮箱 / 轻新课堂学号"].exists)
        app.buttons["取消"].tap()
        XCTAssertTrue(app.navigationBars["账户"].waitForExistence(timeout: 5))

        tapAfterScrolling(app.buttons["profile.records"], in: app)
        XCTAssertTrue(app.navigationBars["演示签到记录"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["还没有签到记录"].exists)
        capture(app, name: "05-空签到记录")
        returnToParent(from: "演示签到记录", to: "账户", in: app)

        tapAfterScrolling(app.buttons["退出演示模式"], in: app)
        XCTAssertTrue(app.buttons["退出"].waitForExistence(timeout: 5))
        app.buttons["退出"].tap()

        XCTAssertTrue(app.staticTexts["尚未登录"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["profile.privacyToggle"].exists)
        assertMainNavigationAvailable(in: app)
        let profileScroll = app.scrollViews["profile.scroll"]
        for _ in 0..<6 {
            if accountCard.isHittable { break }
            profileScroll.swipeDown()
        }
        XCTAssertTrue(accountCard.isHittable)
        accountCard.tap()
        XCTAssertTrue(app.staticTexts["连接你的课堂。"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["SEP 邮箱 / 轻新课堂学号"].exists)
        app.buttons["取消"].tap()
        XCTAssertTrue(app.navigationBars["账户"].waitForExistence(timeout: 5))

        selectTab("今日", in: app)
        XCTAssertTrue(app.staticTexts["一堂课，也不匆忙。"].waitForExistence(timeout: 5))
        capture(app, name: "06-欢迎页")
        tapAfterScrolling(app.buttons["连接账户"], in: app)

        XCTAssertTrue(app.staticTexts["连接你的课堂。"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["SEP 邮箱 / 轻新课堂学号"].exists)
        XCTAssertTrue(app.secureTextFields["对应账号的密码"].exists)
        XCTAssertTrue(app.buttons["取消"].isHittable)
        capture(app, name: "07-连接账户")
        app.buttons["取消"].tap()
        XCTAssertTrue(app.buttons["连接账户"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testAccountPrivacyToggle() {
        let app = launchDemo()
        addTeardownBlock { [app] in
            await MainActor.run {
                // 偏好跨启动保留；即使用例中途失败，也尽量恢复以免影响其他用例。
                if app.state != .runningForeground { app.launch() }
                let cancel = app.buttons["取消"]
                if cancel.exists && cancel.isHittable { cancel.tap() }
                let accountTab = app.tabBars.buttons["账户"]
                if accountTab.exists && accountTab.isHittable { accountTab.tap() }
                let toggle = app.buttons["profile.privacyToggle"]
                if toggle.exists && toggle.isHittable && toggle.label == "显示账户信息" {
                    toggle.tap()
                }
            }
        }

        selectTab("账户", in: app)
        ensureAccountDetailsVisible(in: app)
        let toggle = app.buttons["profile.privacyToggle"]
        XCTAssertEqual(toggle.label, "隐藏账户信息")
        toggle.tap()
        assertAccountDetailsHidden(in: app)
        XCTAssertFalse(app.staticTexts["连接你的课堂。"].exists)
        XCTAssertFalse(app.textFields["SEP 邮箱 / 轻新课堂学号"].exists)
        capture(app, name: "12-账户隐私隐藏")

        selectTab("课表", in: app)
        selectTab("账户", in: app)
        assertAccountDetailsHidden(in: app)

        app.terminate()
        let relaunchedApp = launchDemo()
        selectTab("账户", in: relaunchedApp)
        assertAccountDetailsHidden(in: relaunchedApp)
        ensureAccountDetailsVisible(in: relaunchedApp)

        // 隐藏姓名后，账户卡片依然能连接账号，且不受独立的眼睛按钮影响。
        relaunchedApp.buttons["profile.privacyToggle"].tap()
        assertAccountDetailsHidden(in: relaunchedApp)
        relaunchedApp.buttons["profile.connectAccount"].tap()
        XCTAssertTrue(relaunchedApp.staticTexts["连接你的课堂。"].waitForExistence(timeout: 5))
        XCTAssertTrue(relaunchedApp.textFields["SEP 邮箱 / 轻新课堂学号"].exists)
        relaunchedApp.buttons["取消"].tap()
        XCTAssertTrue(relaunchedApp.navigationBars["账户"].waitForExistence(timeout: 5))
        assertAccountDetailsHidden(in: relaunchedApp)
        ensureAccountDetailsVisible(in: relaunchedApp)
    }

    @MainActor
    func testCourseQRCodeDemoSignInAndRecord() {
        let app = launchDemo()
        selectTab("课表", in: app)
        let courseRow = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "高级人工智能")).firstMatch
        tapAfterScrolling(courseRow, in: app)

        assertCoursePage(in: app)
        XCTAssertTrue(app.staticTexts["演示二维码 · 无签到效力"].waitForExistence(timeout: 5))
        capture(app, name: "08-课程二维码")
        tapAfterScrolling(app.buttons["为本节课程签到"], in: app)

        let completed = app.buttons["已完成签到"]
        XCTAssertTrue(completed.waitForExistence(timeout: 5))
        XCTAssertFalse(completed.isEnabled)
        XCTAssertTrue(app.staticTexts["演示签到成功 · 未向学校提交"].exists)
        capture(app, name: "09-演示签到完成")
        returnToParent(from: "课程签到", to: "课表", in: app)

        selectTab("账户", in: app)
        tapAfterScrolling(app.buttons["profile.records"], in: app)
        XCTAssertTrue(app.navigationBars["演示签到记录"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["高级人工智能"].exists)
        XCTAssertTrue(app.staticTexts["演示签到成功"].exists)
        capture(app, name: "10-演示签到记录")
        assertMainNavigationAvailable(in: app)
        returnToParent(from: "演示签到记录", to: "账户", in: app)
    }

    @MainActor
    func testCourseEntrypointsRestoreIndependentTabPathsAndScheduleDate() {
        let app = launchDemo()
        tapAfterScrolling(app.buttons["查看课程和签到二维码"], in: app)
        assertCoursePage(in: app)

        selectTab("课表", in: app)
        let nextWeek = schoolCalendar.date(byAdding: .day, value: 7, to: Date())!
        app.buttons["下一周"].tap()
        assertScheduleSelectionAndCourses(nextWeek, in: app)
        let scheduleCourse = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "高级人工智能")).firstMatch
        tapAfterScrolling(scheduleCourse, in: app)
        assertCoursePage(in: app)
        XCTAssertTrue(app.staticTexts["高级人工智能"].exists)

        selectTab("今日", in: app)
        assertCoursePage(in: app)
        returnToParent(from: "课程签到", to: "果壳签到", in: app)
        let todayCourse = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "矩阵分析")).firstMatch
        tapAfterScrolling(todayCourse, in: app)
        assertCoursePage(in: app)
        XCTAssertTrue(app.staticTexts["矩阵分析"].exists)
        if app.windows.firstMatch.frame.width < 600 {
            let window = app.windows.firstMatch
            let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
            let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: end)
            XCTAssertTrue(app.navigationBars["果壳签到"].waitForExistence(timeout: 5))
        } else {
            returnToParent(from: "课程签到", to: "果壳签到", in: app)
        }

        selectTab("课表", in: app)
        assertCoursePage(in: app)
        XCTAssertTrue(app.staticTexts["高级人工智能"].exists)
        returnToParent(from: "课程签到", to: "课表", in: app)
        assertScheduleSelectionAndCourses(nextWeek, in: app)
        capture(app, name: "13-返回课表保留日期")
    }

    @MainActor
    func testAccountSubpagesUseNativeBackAndRestoreAfterTabSwitch() {
        let app = launchDemo()
        selectTab("账户", in: app)
        let pages = [
            (entry: "profile.settings", title: "设置", content: "settings.scroll"),
            (entry: "profile.records", title: "演示签到记录", content: "records.content"),
            (entry: "profile.openSource", title: "项目源码与致谢", content: "openSource.scroll"),
            (entry: "profile.disclaimer", title: "免责声明", content: "disclaimer.scroll")
        ]
        for page in pages {
            tapAfterScrolling(app.buttons[page.entry], in: app)
            XCTAssertTrue(app.navigationBars[page.title].waitForExistence(timeout: 5))
            XCTAssertTrue(app.descendants(matching: .any).matching(identifier: page.content).firstMatch.exists)
            XCTAssertFalse(app.buttons["完成"].exists)
            XCTAssertEqual(app.sheets.count, 0)
            assertMainNavigationAvailable(in: app)
            selectTab("今日", in: app)
            XCTAssertTrue(app.navigationBars["果壳签到"].waitForExistence(timeout: 5))
            selectTab("账户", in: app)
            XCTAssertTrue(app.navigationBars[page.title].waitForExistence(timeout: 5))
            capture(app, name: "14-\(page.title)-子页面")
            returnToParent(from: page.title, to: "账户", in: app)
        }
    }

    @MainActor
    func testLogoutClearsSavedCourseNavigationPaths() {
        let app = launchDemo()
        tapAfterScrolling(app.buttons["查看课程和签到二维码"], in: app)
        assertCoursePage(in: app)
        selectTab("课表", in: app)
        let course = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "高级人工智能")).firstMatch
        tapAfterScrolling(course, in: app)
        assertCoursePage(in: app)

        selectTab("账户", in: app)
        tapAfterScrolling(app.buttons["退出演示模式"], in: app)
        XCTAssertTrue(app.buttons["退出"].waitForExistence(timeout: 5))
        app.buttons["退出"].tap()
        XCTAssertTrue(app.staticTexts["尚未登录"].waitForExistence(timeout: 5))

        selectTab("今日", in: app)
        XCTAssertTrue(app.navigationBars["果壳签到"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.scrollViews["today.scroll"].exists)
        XCTAssertFalse(app.scrollViews["courseDetail.scroll"].exists)
        XCTAssertTrue(app.staticTexts["一堂课，也不匆忙。"].exists)
        selectTab("课表", in: app)
        XCTAssertTrue(app.navigationBars["课表"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.scrollViews["schedule.scroll"].exists)
        XCTAssertFalse(app.scrollViews["courseDetail.scroll"].exists)
        XCTAssertTrue(app.staticTexts["连接你的课堂"].exists)

        selectTab("账户", in: app)
        tapAfterScrolling(app.buttons["profile.records"], in: app)
        XCTAssertTrue(app.navigationBars["本机签到记录"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["还没有签到记录"].exists)
        returnToParent(from: "本机签到记录", to: "账户", in: app)
    }

    @MainActor
    func testWidgetLinkReturnsFromCourseDetailToTodayRoot() throws {
        guard #available(iOS 16.4, *) else { throw XCTSkip("打开应用链接需要 iOS 16.4 或更高版本") }
        let app = launchDemo()
        tapAfterScrolling(app.buttons["查看课程和签到二维码"], in: app)
        assertCoursePage(in: app)
        app.open(URL(string: "ucas-signin://today")!)
        XCTAssertTrue(app.navigationBars["果壳签到"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.scrollViews["today.scroll"].exists)
        XCTAssertFalse(app.scrollViews["courseDetail.scroll"].exists)
        selectTab("账户", in: app)
        selectTab("今日", in: app)
        XCTAssertTrue(app.navigationBars["果壳签到"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testNativeNavigationTitlesAndPinnedScheduleHeader() {
        let app = launchDemo()
        let hasWideLayout = app.windows.firstMatch.frame.width >= 600
        let pages = [
            (tab: "今日", title: "果壳签到", scroll: "today.scroll"),
            (tab: "课表", title: "课表", scroll: "schedule.scroll"),
            (tab: "账户", title: "账户", scroll: "profile.scroll")
        ]

        for page in pages {
            selectTab(page.tab, in: app)
            let scrollView = app.scrollViews[page.scroll]
            XCTAssertTrue(scrollView.waitForExistence(timeout: 5))
            XCTAssertTrue(app.navigationBars[page.title].exists)
            scrollView.swipeUp()
            scrollView.swipeUp()
            if page.tab == "课表" || hasWideLayout {
                // iPad 可完整容纳这些页面；内容不足一屏时系统保留展开的大标题。
                assertNavigationTitleVisible(page.title, in: app)
            } else {
                assertCenteredNavigationTitle(page.title, in: app)
            }
            assertMainNavigationAvailable(in: app)
            capture(app, name: "11-\(page.tab)-原生导航标题")
        }

        // TabView 保留课表的滚动位置，切回来后仍应能操作日期栏。
        selectTab("课表", in: app)
        assertNavigationTitleVisible("课表", in: app)
        let nextWeekButton = app.buttons["下一周"]
        XCTAssertTrue(nextWeekButton.isHittable)
        let nextWeek = schoolCalendar.date(byAdding: .day, value: 7, to: Date())!
        nextWeekButton.tap()
        let selectedDate = app.buttons[dateButtonLabel(nextWeek)]
        assertEventually("滚动后应能切周并点击吸顶日期栏") {
            selectedDate.exists && selectedDate.isHittable && selectedDate.isSelected
        }
        selectedDate.tap()
        assertNavigationTitleVisible("课表", in: app)

        let navigationBar = app.navigationBars["课表"]
        let datePickerButton = navigationBar.buttons["选择日期"]
        XCTAssertTrue(datePickerButton.isHittable)
        datePickerButton.tap()
        XCTAssertTrue(app.navigationBars["选择日期"].waitForExistence(timeout: 5))
        app.navigationBars["选择日期"].buttons["完成"].tap()
        XCTAssertTrue(navigationBar.waitForExistence(timeout: 5))

        selectTab("今日", in: app)
        XCTAssertFalse(app.buttons["today.reminders"].exists)
        XCTAssertFalse(app.buttons["today.refresh"].exists)
        if hasWideLayout {
            assertNavigationTitleVisible("果壳签到", in: app)
        } else {
            assertCenteredNavigationTitle("果壳签到", in: app)
        }
    }


    @MainActor
    func testSavedAccountsSwitchFromMenuAndClearOldCourseNavigation() {
        let app = launchAccounts()
        let course = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "账户一课程")).firstMatch
        tapAfterScrolling(course, in: app)
        XCTAssertTrue(app.scrollViews["courseDetail.scroll"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["演示二维码 · 无签到效力"].exists)
        selectTab("账户", in: app)
        tapAfterScrolling(app.buttons["accounts.manage"], in: app)
        let second = app.buttons["accounts.row.2026000002"]
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        second.tap()
        XCTAssertTrue(app.buttons["profile.privacyToggle"].waitForExistence(timeout: 5))
        selectTab("今日", in: app)
        XCTAssertTrue(app.scrollViews["today.scroll"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.scrollViews["courseDetail.scroll"].exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "账户二课程")).firstMatch.waitForExistence(timeout: 5))

        app.descendants(matching: .any).matching(identifier: "accounts.quickSwitch").firstMatch.tap()
        let first = app.descendants(matching: .any).matching(identifier: "accounts.switch.2026000001").firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        first.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "账户一课程")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "账户二课程")).firstMatch.exists)
    }

    @MainActor
    func testAccountManagementPrivacyAndAddingAccount() {
        let app = launchAccounts()
        selectTab("账户", in: app)
        let privacy = app.buttons["profile.privacyToggle"]
        XCTAssertTrue(privacy.waitForExistence(timeout: 5))
        if privacy.label == "隐藏账户信息" { privacy.tap() }
        selectTab("今日", in: app)
        app.descendants(matching: .any).matching(identifier: "accounts.quickSwitch").firstMatch.tap()
        let hiddenChoice = app.descendants(matching: .any).matching(identifier: "accounts.switch.2026000001").firstMatch
        XCTAssertTrue(hiddenChoice.waitForExistence(timeout: 5))
        XCTAssertTrue(hiddenChoice.label.contains("林同学"))
        XCTAssertFalse(hiddenChoice.label.contains("2026000001"))
        hiddenChoice.tap()
        selectTab("账户", in: app)
        tapAfterScrolling(app.buttons["accounts.manage"], in: app)
        let first = app.buttons["accounts.row.2026000001"]
        let second = app.buttons["accounts.row.2026000002"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertTrue(first.label.contains("林同学"))
        XCTAssertFalse(first.label.contains("2026000001"))
        XCTAssertTrue(second.label.contains("周同学"))
        XCTAssertFalse(second.label.contains("2026000002"))
        app.buttons["accounts.privacyToggle"].tap()
        assertEventually("管理页显示姓名与学号") {
            first.label.contains("林清") && first.label.contains("2026000001")
                && second.label.contains("周宁") && second.label.contains("2026000002")
        }
        app.buttons["accounts.add"].tap()
        let cancel = app.buttons["login.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()
        XCTAssertTrue(app.buttons["profile.privacyToggle"].waitForExistence(timeout: 5))
        tapAfterScrolling(app.buttons["accounts.manage"], in: app)
        XCTAssertTrue(app.buttons["accounts.row.2026000001"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "accounts.row.")).count, 2)
        app.buttons["accounts.add"].tap()
        let username = app.textFields["SEP 邮箱 / 轻新课堂学号"]
        XCTAssertTrue(username.waitForExistence(timeout: 5))
        username.tap()
        username.typeText("2026000003")
        let password = app.secureTextFields["对应账号的密码"]
        password.tap()
        password.typeText("fixture-password")
        app.buttons["登录并同步课程"].tap()
        XCTAssertTrue(app.buttons["profile.privacyToggle"].waitForExistence(timeout: 10))
        tapAfterScrolling(app.buttons["accounts.manage"], in: app)
        let added = app.buttons["accounts.row.2026000003"]
        XCTAssertTrue(added.waitForExistence(timeout: 5))
        XCTAssertTrue(added.label.contains("顾言"))
        XCTAssertTrue(added.label.contains("当前账户"))
        XCTAssertTrue(app.buttons["accounts.row.2026000001"].exists)
        XCTAssertTrue(app.buttons["accounts.row.2026000002"].exists)
        capture(app, name: "多账户管理")
    }

    @MainActor
    func testRemovingCurrentAccountKeepsOtherAccountAndRestoresLastSelection() {
        let app = launchAccounts()
        selectTab("账户", in: app)
        tapAfterScrolling(app.buttons["profile.logout"], in: app)
        let confirm = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "退出并移除此账户", "profile.logout")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        tapAfterScrolling(app.buttons["accounts.manage"], in: app)
        XCTAssertTrue(app.buttons["accounts.row.2026000002"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["accounts.row.2026000001"].exists)
        app.buttons["accounts.done"].tap()
        selectTab("今日", in: app)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "账户二课程")).firstMatch.exists)
        app.descendants(matching: .any).matching(identifier: "accounts.quickSwitch").firstMatch.tap()
        let second = app.descendants(matching: .any).matching(identifier: "accounts.switch.2026000002").firstMatch
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        second.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "账户二课程")).firstMatch.waitForExistence(timeout: 5))
        app.terminate()
        let relaunched = launchAccounts(reset: false, expectedCourse: "账户二课程")
        selectTab("账户", in: relaunched)
        tapAfterScrolling(relaunched.buttons["accounts.manage"], in: relaunched)
        XCTAssertTrue(relaunched.buttons["accounts.row.2026000002"].waitForExistence(timeout: 5))
        XCTAssertFalse(relaunched.buttons["accounts.row.2026000001"].exists)
    }

    @MainActor
    func testSettingsThemePersistsWithoutLeavingPage() {
        let app = launchAccounts()
        selectTab("账户", in: app)
        XCTAssertFalse(app.switches["settings.reminders"].exists)
        tapAfterScrolling(app.buttons["profile.settings"], in: app)
        let appearance = app.buttons["settings.appearance"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        appearance.tap()
        app.buttons["深色"].tap()
        XCTAssertEqual(appearance.value as? String, "深色")
        XCTAssertTrue(app.navigationBars["设置"].exists)
        XCTAssertTrue(app.switches["settings.reminders"].exists)
        XCTAssertTrue(app.switches["settings.autoSign"].exists)
        capture(app, name: "设置-深色")
        app.terminate()
        let relaunched = launchAccounts(reset: false)
        selectTab("账户", in: relaunched)
        tapAfterScrolling(relaunched.buttons["profile.settings"], in: relaunched)
        let restored = relaunched.buttons["settings.appearance"]
        XCTAssertTrue(restored.waitForExistence(timeout: 5))
        XCTAssertEqual(restored.value as? String, "深色")
        restored.tap()
        relaunched.buttons["浅色"].tap()
        XCTAssertEqual(restored.value as? String, "浅色")
        restored.tap()
        relaunched.buttons["跟随系统"].tap()
        returnToParent(from: "设置", to: "账户", in: relaunched)
    }

    @MainActor
    private func launchAccounts(reset: Bool = true, expectedCourse: String = "账户一课程") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--account-fixtures", "--fixture-persist", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        if reset { app.launchArguments.append("--fixture-reset") }
        app.launch()

        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", expectedCourse)).firstMatch.waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func launchDemo() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.staticTexts["演示模式"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func ensureAccountDetailsVisible(in app: XCUIApplication,
                                             file: StaticString = #filePath, line: UInt = #line) {
        let toggle = app.buttons["profile.privacyToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), file: file, line: line)
        if toggle.label == "显示账户信息" { toggle.tap() }
        assertEventually("显示状态应恢复完整姓名和学号", file: file, line: line) {
            toggle.label == "隐藏账户信息"
                && (toggle.value as? String) == "已显示"
                && app.staticTexts["演示同学"].exists
                && app.staticTexts["学号 2026123456"].exists
        }
    }

    @MainActor
    private func assertAccountDetailsHidden(in app: XCUIApplication,
                                            file: StaticString = #filePath, line: UInt = #line) {
        let toggle = app.buttons["profile.privacyToggle"]
        let sensitiveElements = app.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@ OR label CONTAINS %@ OR value CONTAINS %@ OR value CONTAINS %@",
            "演示同学", "2026123456", "演示同学", "2026123456"
        ))
        assertEventually("隐藏状态应替换姓名并从辅助功能树中移除完整个人信息", file: file, line: line) {
            toggle.label == "显示账户信息"
                && (toggle.value as? String) == "已隐藏"
                && app.staticTexts["演同学"].exists
                && app.staticTexts["学号已隐藏"].exists
                && sensitiveElements.count == 0
        }
    }

    @MainActor
    private func assertScheduleSelectionAndCourses(_ date: Date, in app: XCUIApplication,
                                                   file: StaticString = #filePath, line: UInt = #line) {
        let selectedDate = app.buttons[dateButtonLabel(date)]
        let heading = app.staticTexts[dateHeading(date)]
        let course = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "矩阵分析")).firstMatch
        assertEventually("刷新应保留所选课表日期和已有课程", file: file, line: line) {
            selectedDate.exists && selectedDate.isSelected
                && heading.exists
                && app.staticTexts["3 门课程"].exists
                && course.exists
        }
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func selectTab(_ title: String, in app: XCUIApplication,
                           file: StaticString = #filePath, line: UInt = #line) {
        let tab = app.tabBars.buttons[title]
        if tab.exists {
            tab.tap()
            assertEventually("应选中标签页：\(title)", file: file, line: line) { tab.isSelected }
        } else {
            // iPadOS 18 exposes its native top tabs as buttons outside a TabBar.
            let symbols = ["今日": "square.grid.2x2", "课表": "calendar", "账户": "person.crop.circle"]
            let topTab = app.buttons.matching(identifier: symbols[title] ?? title).firstMatch
            XCTAssertTrue(topTab.waitForExistence(timeout: 5), "应显示原生标签页：\(title)", file: file, line: line)
            topTab.tap()
            // Each tab can restore a child destination instead of its root title.
            XCTAssertTrue(topTab.isHittable, file: file, line: line)
        }
    }

    @MainActor
    private func assertCoursePage(in app: XCUIApplication,
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.navigationBars["课程签到"].waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertTrue(app.scrollViews["courseDetail.scroll"].exists, file: file, line: line)
        XCTAssertTrue(app.staticTexts["演示二维码 · 无签到效力"].waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertFalse(app.buttons["完成"].exists, file: file, line: line)
        XCTAssertEqual(app.sheets.count, 0, file: file, line: line)
        assertMainNavigationAvailable(in: app, file: file, line: line)
    }

    @MainActor
    private func assertMainNavigationAvailable(in app: XCUIApplication,
                                               file: StaticString = #filePath, line: UInt = #line) {
        let symbols = ["今日": "square.grid.2x2", "课表": "calendar", "账户": "person.crop.circle"]
        for (title, symbol) in symbols {
            let bottomTab = app.tabBars.buttons[title]
            let tab = bottomTab.exists ? bottomTab : app.buttons.matching(identifier: symbol).firstMatch
            XCTAssertTrue(tab.exists && tab.isHittable, "子页面应保留标签入口：\(title)", file: file, line: line)
        }
    }

    @MainActor
    private func returnToParent(from title: String, to parentTitle: String, in app: XCUIApplication,
                                file: StaticString = #filePath, line: UInt = #line) {
        let navigationBar = app.navigationBars[title]
        XCTAssertTrue(navigationBar.waitForExistence(timeout: 5), file: file, line: line)
        let back = navigationBar.buttons.element(boundBy: 0)
        XCTAssertTrue(back.exists && back.isHittable, "应显示系统返回按钮", file: file, line: line)
        back.tap()
        XCTAssertTrue(app.navigationBars[parentTitle].waitForExistence(timeout: 5), file: file, line: line)
    }

    @MainActor
    private func assertNavigationTitleVisible(_ title: String, in app: XCUIApplication,
                                             file: StaticString = #filePath, line: UInt = #line) {
        let navigationBar = app.navigationBars[title]
        let titleElement = navigationBar.staticTexts[title]
        assertEventually("标题应在导航栏内可见：\(title)", file: file, line: line) {
            guard navigationBar.exists, titleElement.exists, titleElement.isHittable else { return false }
            let barFrame = navigationBar.frame
            let titleFrame = titleElement.frame
            return titleFrame.minX >= barFrame.minX - 2
                && titleFrame.maxX <= barFrame.maxX + 2
                && titleFrame.minY >= barFrame.minY - 2
                && titleFrame.maxY <= barFrame.maxY + 2
        }
    }

    @MainActor
    private func assertCenteredNavigationTitle(_ title: String, in app: XCUIApplication,
                                              file: StaticString = #filePath, line: UInt = #line) {
        let navigationBar = app.navigationBars[title]
        let titleElement = navigationBar.staticTexts[title]
        assertEventually("上滑后标题应留在导航栏内并水平居中：\(title)", file: file, line: line) {
            guard navigationBar.exists, titleElement.exists, titleElement.isHittable else { return false }
            let barFrame = navigationBar.frame
            let titleFrame = titleElement.frame
            let tolerance = max(12, barFrame.width * 0.04)
            return abs(titleFrame.midX - barFrame.midX) <= tolerance
                && titleFrame.minY >= barFrame.minY - 2
                && titleFrame.maxY <= barFrame.maxY + 2
        }
    }

    @MainActor
    private func assertEventually(_ message: String, file: StaticString = #filePath, line: UInt = #line,
                                  condition: @escaping () -> Bool) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed, message, file: file, line: line)
    }

    @MainActor
    private func tapAfterScrolling(_ element: XCUIElement, in app: XCUIApplication,
                                   file: StaticString = #filePath, line: UInt = #line) {
        let scrollView = app.scrollViews.firstMatch
        for _ in 0..<8 {
            if element.exists && element.isHittable {
                element.tap()
                return
            }
            guard scrollView.exists else { break }
            scrollView.swipeUp()
        }
        // 原生标签页保留滚动位置；目标可能位于当前可视区域上方。
        for _ in 0..<8 {
            if element.exists && element.isHittable {
                element.tap()
                return
            }
            guard scrollView.exists else { break }
            scrollView.swipeDown()
        }
        XCTFail("未能在页面中找到可点击的目标：\(element)", file: file, line: line)
    }

    private var schoolCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private func dateHeading(_ date: Date) -> String {
        formattedDate(date, format: "M 月 d 日")
    }

    private func dateButtonLabel(_ date: Date) -> String {
        formattedDate(date, format: "M月d日 EEEE")
    }

    private func formattedDate(_ date: Date, format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = schoolCalendar.timeZone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}
