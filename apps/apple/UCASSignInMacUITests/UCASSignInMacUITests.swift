import XCTest
import AppKit

final class UCASSignInMacUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSidebarShortcutsAndReturningToToday() {
        let app = launchDemo()
        XCTAssertTrue(app.staticTexts["课表、签到，都在这里。"].exists)
        // AppKit exposes both the toolbar item and its hosted SwiftUI button.
        let todayRefresh = app.buttons.matching(identifier: "today.refresh").firstMatch
        XCTAssertTrue(todayRefresh.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons.matching(identifier: "today.reminders").firstMatch.exists)
        let refreshFrame = todayRefresh.frame
        selectSidebar("schedule", in: app)
        XCTAssertTrue(app.staticTexts["演示课表 · 所有日期均为示例数据"].waitForExistence(timeout: 5))
        let scheduleRefresh = app.buttons.matching(identifier: "schedule.refresh").firstMatch
        let datePicker = app.buttons.matching(identifier: "schedule.datePicker").firstMatch
        assertEventually("两个页面的刷新按钮应对齐") {
            scheduleRefresh.exists && datePicker.exists
                && datePicker.frame.midX < scheduleRefresh.frame.midX
                && abs(scheduleRefresh.frame.midX - refreshFrame.midX) <= 2
                && abs(scheduleRefresh.frame.midY - refreshFrame.midY) <= 2
        }

        let today = Date()
        let nextWeek = schoolCalendar.date(byAdding: .day, value: 7, to: today)!
        app.buttons["下一周"].click()
        XCTAssertTrue(app.staticTexts[dateHeading(nextWeek)].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons[dateButtonLabel(nextWeek)].exists)
        scheduleRefresh.click()
        assertScheduleSelectionAndCourses(nextWeek, in: app)

        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["今日安排"].waitForExistence(timeout: 5))
        todayRefresh.click()
        let todayCourse = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "矩阵分析")).firstMatch
        assertEventually("今日刷新应保留课程内容") { todayRefresh.isEnabled && todayCourse.exists }
        app.typeKey("r", modifierFlags: .command)
        assertEventually("今日快捷键刷新应保留课程内容") { todayRefresh.isEnabled && todayCourse.exists }
        app.typeKey("2", modifierFlags: .command)
        assertScheduleSelectionAndCourses(nextWeek, in: app)
        app.typeKey("r", modifierFlags: .command)
        assertScheduleSelectionAndCourses(nextWeek, in: app)

        app.typeKey("3", modifierFlags: .command)
        XCTAssertTrue(app.buttons["profile.privacyToggle"].waitForExistence(timeout: 5))
        selectSidebar("today", in: app)
        XCTAssertTrue(app.staticTexts["今日安排"].waitForExistence(timeout: 5))
        capture(app, name: "Mac-侧栏与键盘导航")
    }

    @MainActor
    func testDemoQRCodeSignInAndLocalRecord() {
        let app = launchDemo()
        selectSidebar("schedule", in: app)
        let course = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "高级人工智能")).firstMatch
        clickAfterScrolling(course, in: app.scrollViews["schedule.scroll"])

        assertCoursePage(in: app)
        capture(app, name: "Mac-演示二维码")
        clickAfterScrolling(app.buttons["为本节课程签到"], in: app.scrollViews["courseDetail.scroll"])
        let completed = app.buttons["已完成签到"]
        XCTAssertTrue(completed.waitForExistence(timeout: 5))
        XCTAssertFalse(completed.isEnabled)
        XCTAssertTrue(app.staticTexts["演示签到成功 · 未向学校提交"].exists)
        returnToParent(content: "schedule.scroll", in: app)

        selectSidebar("profile", in: app)
        clickAfterScrolling(app.buttons["profile.records"], in: app.scrollViews["profile.scroll"])
        XCTAssertTrue(app.staticTexts["演示签到成功"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["高级人工智能"].exists)
        capture(app, name: "Mac-演示签到记录")
        assertSidebarAvailable(in: app)
        XCTAssertEqual(app.sheets.count, 0)
        returnToParent(content: "profile.scroll", in: app)
    }

    @MainActor
    func testCourseEntrypointsAndCommandsRestoreIndependentNavigationPaths() {
        let app = launchDemo()
        clickAfterScrolling(app.buttons["查看课程和签到二维码"], in: app.scrollViews["today.scroll"])
        assertCoursePage(in: app)

        app.typeKey("2", modifierFlags: .command)
        let nextWeek = schoolCalendar.date(byAdding: .day, value: 7, to: Date())!
        app.buttons["下一周"].click()
        assertScheduleSelectionAndCourses(nextWeek, in: app)
        let scheduleCourse = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "高级人工智能")).firstMatch
        clickAfterScrolling(scheduleCourse, in: app.scrollViews["schedule.scroll"])
        assertCoursePage(in: app)
        XCTAssertTrue(app.staticTexts["高级人工智能"].exists)

        app.typeKey("1", modifierFlags: .command)
        assertCoursePage(in: app)
        returnToParent(content: "today.scroll", in: app)
        let todayCourse = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "矩阵分析")).firstMatch
        clickAfterScrolling(todayCourse, in: app.scrollViews["today.scroll"])
        assertCoursePage(in: app)
        XCTAssertTrue(app.staticTexts["矩阵分析"].exists)
        returnToParent(content: "today.scroll", in: app)

        selectSidebar("schedule", in: app)
        assertCoursePage(in: app)
        XCTAssertTrue(app.staticTexts["高级人工智能"].exists)
        returnToParent(content: "schedule.scroll", in: app)
        assertScheduleSelectionAndCourses(nextWeek, in: app)
        capture(app, name: "Mac-独立子页面与课表日期")

        // The date picker remains a sheet with its own completion action.
        app.buttons.matching(identifier: "schedule.datePicker").firstMatch.click()
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 5))
        app.sheets.buttons["完成"].click()
        XCTAssertTrue(app.scrollViews["schedule.scroll"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testAccountSubpagesUseNativeBackAndRestoreAfterSidebarSwitch() {
        let app = launchDemo()
        selectSidebar("profile", in: app)
        let pages = [
            (entry: "profile.settings", content: "settings.scroll"),
            (entry: "profile.records", content: "records.content"),
            (entry: "profile.openSource", content: "openSource.scroll"),
            (entry: "profile.disclaimer", content: "disclaimer.scroll")
        ]
        for page in pages {
            clickAfterScrolling(app.buttons[page.entry], in: app.scrollViews["profile.scroll"])
            let content = app.descendants(matching: .any).matching(identifier: page.content).firstMatch
            XCTAssertTrue(content.waitForExistence(timeout: 5))
            XCTAssertEqual(app.sheets.count, 0)
            XCTAssertFalse(app.buttons["完成"].exists)
            assertSidebarAvailable(in: app)
            app.typeKey("1", modifierFlags: .command)
            XCTAssertTrue(app.scrollViews["today.scroll"].waitForExistence(timeout: 5))
            app.typeKey("3", modifierFlags: .command)
            XCTAssertTrue(content.waitForExistence(timeout: 5))
            capture(app, name: "Mac-\(page.entry)-子页面")
            returnToParent(content: "profile.scroll", in: app)
        }
    }

    @MainActor
    func testAccountPrivacyAndLoginSheetCancellation() {
        let app = launchDemo()
        app.typeKey("3", modifierFlags: .command)
        let toggle = app.buttons["profile.privacyToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        if toggle.label == "显示账户信息" { toggle.click() }
        let account = app.buttons["profile.connectAccount"]
        XCTAssertTrue(account.label.contains("演示同学"))
        XCTAssertTrue(account.label.contains("2026123456"))

        toggle.click()
        assertEventually("隐私按钮应隐藏姓名和学号") {
            toggle.label == "显示账户信息"
                && account.label.contains("演同学")
                && !account.label.contains("演示同学")
                && !account.label.contains("2026123456")
        }
        XCTAssertFalse(app.staticTexts["连接你的课堂。"].exists)
        selectSidebar("schedule", in: app)
        selectSidebar("profile", in: app)
        XCTAssertEqual(toggle.label, "显示账户信息")

        app.buttons["profile.connectAccount"].click()
        XCTAssertTrue(app.staticTexts["连接你的课堂。"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["SEP 邮箱 / 轻新课堂学号"].exists)
        XCTAssertTrue(app.secureTextFields["对应账号的密码"].exists)
        capture(app, name: "Mac-登录窗口")
        app.buttons["取消"].click()
        assertEventually("取消登录应返回账户页并保留隐私状态") {
            !app.staticTexts["连接你的课堂。"].exists
                && toggle.exists && toggle.label == "显示账户信息"
        }
        toggle.click()
        assertEventually("显示账户信息应恢复姓名和学号") {
            account.label.contains("演示同学") && account.label.contains("2026123456")
        }
    }

    @MainActor
    func testLogoutClearsSavedCourseNavigationPaths() {
        let app = launchDemo()
        clickAfterScrolling(app.buttons["查看课程和签到二维码"], in: app.scrollViews["today.scroll"])
        assertCoursePage(in: app)
        selectSidebar("schedule", in: app)
        let course = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "高级人工智能")).firstMatch
        clickAfterScrolling(course, in: app.scrollViews["schedule.scroll"])
        assertCoursePage(in: app)

        selectSidebar("profile", in: app)
        clickAfterScrolling(app.buttons["退出演示模式"], in: app.scrollViews["profile.scroll"])
        let confirmLogout = app.sheets.buttons["退出"]
        XCTAssertTrue(confirmLogout.waitForExistence(timeout: 5))
        confirmLogout.click()
        assertEventually("退出演示应显示未登录账户") {
            app.buttons["profile.connectAccount"].label.contains("尚未登录")
        }

        selectSidebar("today", in: app)
        XCTAssertTrue(app.scrollViews["today.scroll"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.scrollViews["courseDetail.scroll"].exists)
        XCTAssertTrue(app.staticTexts["一堂课，也不匆忙。"].exists)
        selectSidebar("schedule", in: app)
        XCTAssertTrue(app.scrollViews["schedule.scroll"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.scrollViews["courseDetail.scroll"].exists)
        XCTAssertTrue(app.staticTexts["连接你的课堂"].exists)

        selectSidebar("profile", in: app)
        clickAfterScrolling(app.buttons["profile.records"], in: app.scrollViews["profile.scroll"])
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "records.content").firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["还没有签到记录"].exists)
        returnToParent(content: "profile.scroll", in: app)
    }

    @MainActor
    func testWidgetLinkOpensTodayAndColdLaunch() async throws {
        let app = launchDemo()
        let applicationURL = try XCTUnwrap(NSWorkspace.shared.frontmostApplication?.bundleURL)
        XCTAssertEqual(applicationURL.lastPathComponent, "UCASSignInMac.app")
        clickAfterScrolling(app.buttons["查看课程和签到二维码"], in: app.scrollViews["today.scroll"])
        assertCoursePage(in: app)
        try await openWidgetLink(applicationURL: applicationURL, arguments: app.launchArguments)
        app.activate()
        XCTAssertTrue(app.scrollViews["today.scroll"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.scrollViews["courseDetail.scroll"].exists)
        selectSidebar("profile", in: app)
        try await openWidgetLink(applicationURL: applicationURL, arguments: app.launchArguments)
        app.activate()
        XCTAssertTrue(app.staticTexts["今日安排"].waitForExistence(timeout: 10))
        app.terminate()
        try await openWidgetLink(applicationURL: applicationURL, arguments: app.launchArguments)
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["今日安排"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.windows.count, 1)
    }

    @MainActor
    private func openWidgetLink(applicationURL: URL, arguments: [String]) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        configuration.arguments = arguments
        // XCUIApplication.open forces a new process on macOS. Deliver the URL to the
        // exact build already under test so warm-link navigation uses its current state.
        let application = try await NSWorkspace.shared.open(
            [URL(string: "ucas-signin://today")!],
            withApplicationAt: applicationURL,
            configuration: configuration
        )
        XCTAssertEqual(application.bundleURL?.standardizedFileURL, applicationURL.standardizedFileURL)
    }

    @MainActor
    func testSavedAccountsSwitchFromMenuAndClearOldCourseNavigation() {
        let app = launchAccounts()
        let course = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "账户一课程")).firstMatch
        clickAfterScrolling(course, in: app.scrollViews["today.scroll"])
        XCTAssertTrue(app.scrollViews["courseDetail.scroll"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["演示二维码 · 无签到效力"].exists)
        selectSidebar("profile", in: app)
        clickAfterScrolling(app.buttons["accounts.manage"], in: app.scrollViews["profile.scroll"])
        let second = app.buttons["accounts.row.2026000002"]
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        second.click()
        XCTAssertTrue(app.buttons["profile.privacyToggle"].waitForExistence(timeout: 5))
        selectSidebar("today", in: app)
        XCTAssertTrue(app.scrollViews["today.scroll"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.scrollViews["courseDetail.scroll"].exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "账户二课程")).firstMatch.waitForExistence(timeout: 5))

        app.descendants(matching: .any).matching(identifier: "accounts.quickSwitch").firstMatch.click()
        let first = app.descendants(matching: .any).matching(identifier: "accounts.switch.2026000001").firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        first.click()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "账户一课程")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "账户二课程")).firstMatch.exists)
    }

    @MainActor
    func testAccountManagementPrivacyAndAddingAccount() {
        let app = launchAccounts()
        selectSidebar("profile", in: app)
        let privacy = app.buttons["profile.privacyToggle"]
        XCTAssertTrue(privacy.waitForExistence(timeout: 5))
        if privacy.label == "隐藏账户信息" { privacy.click() }
        selectSidebar("today", in: app)
        app.descendants(matching: .any).matching(identifier: "accounts.quickSwitch").firstMatch.click()
        let hiddenChoice = app.descendants(matching: .any).matching(identifier: "accounts.switch.2026000001").firstMatch
        XCTAssertTrue(hiddenChoice.waitForExistence(timeout: 5))
        XCTAssertTrue(hiddenChoice.title.contains("林同学"))
        XCTAssertFalse(hiddenChoice.title.contains("2026000001"))
        hiddenChoice.click()
        selectSidebar("profile", in: app)
        clickAfterScrolling(app.buttons["accounts.manage"], in: app.scrollViews["profile.scroll"])
        let first = app.buttons["accounts.row.2026000001"]
        let second = app.buttons["accounts.row.2026000002"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertTrue(first.label.contains("林同学"))
        XCTAssertFalse(first.label.contains("2026000001"))
        XCTAssertTrue(second.label.contains("周同学"))
        XCTAssertFalse(second.label.contains("2026000002"))
        app.buttons["accounts.privacyToggle"].click()
        assertEventually("管理页显示姓名与学号") {
            first.label.contains("林清") && first.label.contains("2026000001")
                && second.label.contains("周宁") && second.label.contains("2026000002")
        }
        app.buttons["accounts.add"].click()
        let cancel = app.buttons["login.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.click()
        XCTAssertTrue(app.buttons["profile.privacyToggle"].waitForExistence(timeout: 5))
        clickAfterScrolling(app.buttons["accounts.manage"], in: app.scrollViews["profile.scroll"])
        XCTAssertTrue(app.buttons["accounts.row.2026000001"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "accounts.row.")).count, 2)
        app.buttons["accounts.add"].click()
        let username = app.textFields["SEP 邮箱 / 轻新课堂学号"]
        XCTAssertTrue(username.waitForExistence(timeout: 5))
        username.click()
        username.typeText("2026000003")
        let password = app.secureTextFields["对应账号的密码"]
        password.click()
        password.typeText("fixture-password")
        app.buttons["登录并同步课程"].click()
        XCTAssertTrue(app.buttons["profile.privacyToggle"].waitForExistence(timeout: 10))
        clickAfterScrolling(app.buttons["accounts.manage"], in: app.scrollViews["profile.scroll"])
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
        selectSidebar("profile", in: app)
        clickAfterScrolling(app.buttons["profile.logout"], in: app.scrollViews["profile.scroll"])
        let confirm = app.sheets.buttons["退出并移除此账户"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()
        clickAfterScrolling(app.buttons["accounts.manage"], in: app.scrollViews["profile.scroll"])
        XCTAssertTrue(app.buttons["accounts.row.2026000002"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["accounts.row.2026000001"].exists)
        app.buttons["accounts.done"].click()
        selectSidebar("today", in: app)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "账户二课程")).firstMatch.exists)
        app.descendants(matching: .any).matching(identifier: "accounts.quickSwitch").firstMatch.click()
        let second = app.descendants(matching: .any).matching(identifier: "accounts.switch.2026000002").firstMatch
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        second.click()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "账户二课程")).firstMatch.waitForExistence(timeout: 5))
        app.terminate()
        let relaunched = launchAccounts(reset: false, expectedCourse: "账户二课程")
        selectSidebar("profile", in: relaunched)
        clickAfterScrolling(relaunched.buttons["accounts.manage"], in: relaunched.scrollViews["profile.scroll"])
        XCTAssertTrue(relaunched.buttons["accounts.row.2026000002"].waitForExistence(timeout: 5))
        XCTAssertFalse(relaunched.buttons["accounts.row.2026000001"].exists)
    }

    @MainActor
    func testSettingsShortcutAndThemePersistence() {
        let app = launchAccounts()
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.scrollViews["settings.scroll"].waitForExistence(timeout: 5))
        let appearance = app.popUpButtons["settings.appearance"]
        XCTAssertTrue(appearance.exists)
        appearance.click()
        app.menuItems["深色"].click()
        XCTAssertEqual(appearance.value as? String, "深色")
        XCTAssertTrue(app.scrollViews["settings.scroll"].exists)
        capture(app, name: "Mac-设置-深色")
        app.terminate()
        let relaunched = launchAccounts(reset: false)
        relaunched.typeKey(",", modifierFlags: .command)
        let restored = relaunched.popUpButtons["settings.appearance"]
        XCTAssertTrue(restored.waitForExistence(timeout: 5))
        XCTAssertEqual(restored.value as? String, "深色")
        restored.click()
        relaunched.menuItems["浅色"].click()
        XCTAssertEqual(restored.value as? String, "浅色")
        restored.click()
        relaunched.menuItems["跟随系统"].click()
        returnToParent(content: "profile.scroll", in: relaunched)
    }

    @MainActor
    private func launchAccounts(reset: Bool = true, expectedCourse: String = "账户一课程") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--account-fixtures", "--fixture-persist", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        if reset { app.launchArguments.append("--fixture-reset") }
        app.launch()
        app.activate()
        if !app.windows.firstMatch.exists { app.typeKey("1", modifierFlags: .command) }
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", expectedCourse)).firstMatch.waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func launchDemo() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        app.activate()
        // XCTest can spawn a single-Window app without the Launch Services
        // open event. Its public navigation command also opens the main window.
        if !app.windows.firstMatch.exists { app.typeKey("1", modifierFlags: .command) }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["演示模式"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func selectSidebar(_ page: String, in app: XCUIApplication,
                               file: StaticString = #filePath, line: UInt = #line) {
        let row = app.descendants(matching: .any).matching(identifier: "mac.sidebar.\(page)").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "应显示 Mac 侧栏入口：\(page)", file: file, line: line)
        row.click()
    }

    @MainActor
    private func assertCoursePage(in app: XCUIApplication,
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.scrollViews["courseDetail.scroll"].waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertTrue(app.staticTexts["演示二维码 · 无签到效力"].waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertFalse(app.buttons["完成"].exists, file: file, line: line)
        XCTAssertEqual(app.sheets.count, 0, file: file, line: line)
        XCTAssertEqual(app.windows.count, 1, file: file, line: line)
        assertSidebarAvailable(in: app, file: file, line: line)
    }

    @MainActor
    private func assertSidebarAvailable(in app: XCUIApplication,
                                        file: StaticString = #filePath, line: UInt = #line) {
        for page in ["today", "schedule", "profile"] {
            let row = app.descendants(matching: .any).matching(identifier: "mac.sidebar.\(page)").firstMatch
            XCTAssertTrue(row.exists && row.isHittable, "子页面应保留 Mac 侧栏入口：\(page)", file: file, line: line)
        }
    }

    @MainActor
    private func returnToParent(content identifier: String, in app: XCUIApplication,
                                file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(
            format: "label IN %@ OR identifier IN %@ OR label BEGINSWITH %@ OR label BEGINSWITH %@",
            ["返回", "后退", "Back", "Go back"], ["BackButton", "NavigationBackButton"], "返回", "Go back"
        )
        let toolbarBack = app.toolbars.buttons.matching(predicate).firstMatch
        let back = toolbarBack.exists ? toolbarBack : app.buttons.matching(predicate).firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5) && back.isHittable, "应显示系统返回按钮", file: file, line: line)
        back.click()
        XCTAssertTrue(app.scrollViews[identifier].waitForExistence(timeout: 5), file: file, line: line)
    }

    @MainActor
    private func assertScheduleSelectionAndCourses(_ date: Date, in app: XCUIApplication,
                                                   file: StaticString = #filePath, line: UInt = #line) {
        let selectedDate = app.buttons[dateButtonLabel(date)]
        let heading = app.staticTexts[dateHeading(date)]
        let course = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "矩阵分析")).firstMatch
        assertEventually("刷新和切换页面应保留所选课表日期和已有课程", condition: {
            selectedDate.exists && selectedDate.isSelected
                && heading.exists
                && app.staticTexts["3 门课程"].exists
                && course.exists
                && app.buttons.matching(identifier: "schedule.refresh").firstMatch.isEnabled
        }, file: file, line: line)
    }

    @MainActor
    private func clickAfterScrolling(_ element: XCUIElement, in scrollView: XCUIElement,
                                     file: StaticString = #filePath, line: UInt = #line) {
        for delta in [-400.0, 400.0] {
            for _ in 0..<8 {
                if element.exists && element.isHittable {
                    element.click()
                    return
                }
                guard scrollView.exists else { break }
                scrollView.scroll(byDeltaX: 0, deltaY: delta)
            }
        }
        XCTFail("未能找到可点击的目标：\(element)", file: file, line: line)
    }

    @MainActor
    private func assertEventually(_ message: String, condition: @escaping () -> Bool,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed, message, file: file, line: line)
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private var schoolCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private func dateHeading(_ date: Date) -> String { formattedDate(date, format: "M 月 d 日") }
    private func dateButtonLabel(_ date: Date) -> String { formattedDate(date, format: "M月d日 EEEE") }

    private func formattedDate(_ date: Date, format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = schoolCalendar.timeZone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}
