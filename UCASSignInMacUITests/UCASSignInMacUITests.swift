import XCTest

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

        XCTAssertTrue(app.staticTexts["演示二维码 · 无签到效力"].waitForExistence(timeout: 5))
        capture(app, name: "Mac-演示二维码")
        clickAfterScrolling(app.buttons["为本节课程签到"], in: app.sheets.scrollViews.firstMatch)
        let completed = app.buttons["已完成签到"]
        XCTAssertTrue(completed.waitForExistence(timeout: 5))
        XCTAssertFalse(completed.isEnabled)
        XCTAssertTrue(app.staticTexts["演示签到成功 · 未向学校提交"].exists)
        app.buttons["完成"].click()

        selectSidebar("profile", in: app)
        clickAfterScrolling(app.buttons["本机签到记录"], in: app.scrollViews["profile.scroll"])
        XCTAssertTrue(app.staticTexts["演示签到成功"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["高级人工智能"].exists)
        capture(app, name: "Mac-演示签到记录")
        app.buttons["完成"].click()
    }

    @MainActor
    func testAccountPrivacyAndLoginSheetCancellation() {
        let app = launchDemo()
        app.typeKey(",", modifierFlags: .command)
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
    func testWidgetLinkOpensTodayAndColdLaunch() {
        let app = launchDemo()
        selectSidebar("profile", in: app)
        app.open(URL(string: "ucas-signin://today")!)
        XCTAssertTrue(app.staticTexts["今日安排"].waitForExistence(timeout: 10))
        app.terminate()
        app.open(URL(string: "ucas-signin://today")!)
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["今日安排"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.windows.count, 1)
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
