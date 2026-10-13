import XCTest
import UserNotifications
import Combine
@testable import UCASSignInMac

/// Uses only memory stores and controlled HTTP responses; no school account, Keychain,
/// notification authorization, or shared widget container is touched by these tests.
@MainActor
final class AppModelTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        suiteName = "UCASSignInMacTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    func testRestoreUsesPersistedActiveAccountWithoutRememberedPassword() async {
        let store = MemoryAccountStore(accounts: [accountA, accountB], active: accountB.id)
        let transport = PlannedTransport(["courses:session-b": [.init(courseResponse("乙课程"))]])
        let model = makeModel(store, transport)
        await model.restore()

        XCTAssertEqual(model.activeAccountID, accountB.id)
        XCTAssertEqual(model.session, accountB.session)
        XCTAssertEqual(model.todayCourses.map(\.name), ["乙课程"])
        XCTAssertNil(model.accounts.first { $0.id == accountB.id }?.credentials)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "sessionId"), "session-b")
    }

    func testFailedSwitchWriteKeepsCurrentAccountAndData() async {
        let store = MemoryAccountStore(accounts: [accountA, accountB], active: accountA.id)
        let transport = PlannedTransport(["courses:session-a": [.init(courseResponse("甲课程"))]])
        let model = makeModel(store, transport)
        await model.restore()
        let token = model.accountGeneration
        store.failWrites = true
        await model.switchAccount(id: accountB.id)

        XCTAssertEqual(model.activeAccountID, accountA.id)
        XCTAssertEqual(model.accountGeneration, token)
        XCTAssertEqual(model.todayCourses.map(\.name), ["甲课程"])
        XCTAssertEqual(store.vault.activeAccountID, accountA.id)
        XCTAssertNotNil(model.errorMessage)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testLateOldAccountResponseCannotReplaceCoursesCacheOrWidget() async {
        let gate = ResponseGate()
        let transport = PlannedTransport([
            "courses:session-a": [.init(courseResponse("迟到甲课程"), gate: gate)],
            "courses:session-b": [.init(courseResponse("乙课程"))]
        ])
        let store = MemoryAccountStore(accounts: [accountA, accountB], active: accountA.id)
        let widgets = TestWidgets()
        let model = makeModel(store, transport, widgets: widgets)
        let restore = Task { await model.restore() }
        await assertEventually { await transport.count("courses:session-a") == 1 }
        XCTAssertTrue(model.canChangeAccount, "普通刷新期间应允许切换")
        await model.switchAccount(id: accountB.id)
        await gate.open()
        await restore.value

        XCTAssertEqual(model.activeAccountID, accountB.id)
        XCTAssertEqual(model.todayCourses.map(\.name), ["乙课程"])
        XCTAssertEqual(widgets.snapshot?.courses.map(\.name), ["乙课程"])
        XCTAssertNil(defaults.data(forKey: cacheKey(accountA.id)))
        XCTAssertNotNil(defaults.data(forKey: cacheKey(accountB.id)))
    }

    func testRapidSwitchRejectsOldGenerationEvenWhenCourseIDsMatch() async throws {
        let gate = ResponseGate()
        let transport = PlannedTransport([
            "courses:session-a": [.init(courseResponse("甲课程")), .init(courseResponse("新甲课程"))],
            "courses:session-b": [.init(courseResponse("迟到乙课程"), gate: gate)]
        ])
        let store = MemoryAccountStore(accounts: [accountA, accountB], active: accountA.id)
        let model = makeModel(store, transport)
        await model.restore()
        let oldCourse = try XCTUnwrap(model.todayCourses.first)
        let oldGeneration = model.accountGeneration
        let switchB = Task { await model.switchAccount(id: accountB.id) }
        await assertEventually { await transport.count("courses:session-b") == 1 }
        await model.switchAccount(id: accountA.id)
        await gate.open()
        await switchB.value

        XCTAssertEqual(model.todayCourses.map(\.name), ["新甲课程"])
        XCTAssertFalse(model.canSign(oldCourse, accountGeneration: oldGeneration))
        await model.sign(oldCourse, accountGeneration: oldGeneration)
        let signRequests = await transport.count("sign")
        XCTAssertEqual(signRequests, 0)
    }

    func testCachedCoursesRemainUnsignedUntilSyncedAndKeepWidgetTimestamp() async throws {
        let savedAt = Date(timeIntervalSince1970: 1_000)
        let course = Course(id: "1234567", name: "缓存甲课程", beginTime: "08:00", endTime: "09:40", day: SchoolDate.key(.now))
        let cache = CacheFixture(courses: [course], updatedAt: savedAt)
        defaults.set(try JSONEncoder().encode(cache), forKey: cacheKey(accountA.id))
        let gate = ResponseGate()
        let transport = PlannedTransport(["courses:session-a": [.init(courseResponse("甲课程"), gate: gate)]])
        let widgets = TestWidgets()
        let model = makeModel(MemoryAccountStore(accounts: [accountA], active: accountA.id), transport, widgets: widgets)
        let restore = Task { await model.restore() }
        await assertEventually { await transport.count("courses:session-a") == 1 }

        XCTAssertTrue(model.isCached(on: .now))
        XCTAssertFalse(model.canSign(course))
        XCTAssertEqual(model.lastUpdated(on: .now), savedAt)
        XCTAssertEqual(widgets.snapshot?.updatedAt, savedAt)
        XCTAssertEqual(widgets.snapshot?.courses.map(\.name), ["缓存甲课程"])
        await gate.open()
        await restore.value
        XCTAssertFalse(model.isCached(on: .now))
        XCTAssertTrue(model.canSign(try XCTUnwrap(model.todayCourses.first)))
    }

    func testPreferencesRecordsAndTargetedRemovalStayWithEachAccount() async throws {
        let store = MemoryAccountStore(accounts: [accountA, accountB], active: accountA.id)
        let transport = PlannedTransport([
            "courses:session-a": [.init(courseResponse("甲课程")), .init(courseResponse("甲课程"))],
            "courses:session-b": [.init(courseResponse("乙课程"))]
        ])
        let recordA = AttendanceRecord(courseName: "甲记录", date: .now, message: "成功", succeeded: true)
        let recordB = AttendanceRecord(courseName: "乙记录", date: .now, message: "成功", succeeded: true)
        defaults.set(try JSONEncoder().encode([recordA]), forKey: "records-\(accountA.id)")
        defaults.set(try JSONEncoder().encode([recordB]), forKey: "records-\(accountB.id)")
        defaults.set("keep", forKey: "unrelated-preference")
        let model = makeModel(store, transport)
        await model.restore()
        model.setAutoSign(true)
        await model.setReminders(true)
        await model.switchAccount(id: accountB.id)
        XCTAssertFalse(model.autoSignEnabled)
        XCTAssertFalse(model.remindersEnabled)
        XCTAssertEqual(model.records.map(\.courseName), ["乙记录"])
        await model.switchAccount(id: accountA.id)
        XCTAssertTrue(model.autoSignEnabled)
        XCTAssertTrue(model.remindersEnabled)
        XCTAssertEqual(model.records.map(\.courseName), ["甲记录"])

        model.removeAccount(id: accountA.id)
        XCTAssertNil(model.activeAccountID)
        XCTAssertNil(model.session)
        XCTAssertEqual(model.accounts.map(\.id), [accountB.id])
        XCTAssertNil(defaults.data(forKey: "records-\(accountA.id)"))
        XCTAssertNil(defaults.data(forKey: cacheKey(accountA.id)))
        XCTAssertNotNil(defaults.data(forKey: "records-\(accountB.id)"))
        XCTAssertNotNil(defaults.data(forKey: cacheKey(accountB.id)))
        XCTAssertEqual(defaults.string(forKey: "unrelated-preference"), "keep")
    }

    func testFailedRemovalDoesNotDeleteCredentialsRecordsOrActiveState() async throws {
        let store = MemoryAccountStore(accounts: [accountA, accountB], active: accountA.id)
        let model = makeModel(store, PlannedTransport(["courses:session-a": [.init(courseResponse("甲课程"))]]))
        await model.restore()
        let record = AttendanceRecord(courseName: "保留记录", date: .now, message: "成功", succeeded: true)
        defaults.set(try JSONEncoder().encode([record]), forKey: "records-\(accountA.id)")
        store.failWrites = true
        model.removeAccount(id: accountA.id)
        XCTAssertEqual(model.activeAccountID, accountA.id)
        XCTAssertEqual(model.accounts.count, 2)
        XCTAssertNotNil(defaults.data(forKey: "records-\(accountA.id)"))
        XCTAssertNotNil(defaults.data(forKey: cacheKey(accountA.id)))
    }

    func testFailedAddAndFailedSavePreserveOriginalAccount() async throws {
        let transport = PlannedTransport([
            "courses:session-a": [.init(courseResponse("甲课程"))],
            "login": [.init(#"{"STATUS":"1","ERRMSG":"密码错误"}"#), .init(loginResponse(accountB.session))]
        ])
        let store = MemoryAccountStore(accounts: [accountA], active: accountA.id)
        let model = makeModel(store, transport)
        await model.restore()
        model.presentLogin(accountID: nil)
        let request = try XCTUnwrap(model.loginRequest)
        let failedLogin = await model.login(username: "b@example.edu", password: "bad", remember: true, requestID: request.id)
        XCTAssertFalse(failedLogin)
        XCTAssertEqual(model.activeAccountID, accountA.id)
        store.failWrites = true
        let failedSave = await model.login(username: "b@example.edu", password: "good", remember: true, requestID: request.id)
        XCTAssertFalse(failedSave)
        XCTAssertEqual(model.activeAccountID, accountA.id)
        XCTAssertEqual(model.accounts.map(\.id), [accountA.id])
        XCTAssertEqual(model.todayCourses.map(\.name), ["甲课程"])
    }

    func testExpiredSessionRecoversOnceAndOnlyRetriesCourseRead() async {
        let refreshed = SchoolSession(userId: "user-a", sessionId: "renewed-a", studentNo: accountA.id, name: "林清")
        let transport = PlannedTransport([
            "courses:session-a": [.init(expiredResponse)],
            "login": [.init(loginResponse(refreshed))],
            "courses:renewed-a": [.init(courseResponse("恢复甲课程"))]
        ])
        let store = MemoryAccountStore(accounts: [rememberedAccountA], active: accountA.id)
        let model = makeModel(store, transport)
        await model.restore()
        XCTAssertEqual(model.session, refreshed)
        XCTAssertEqual(model.todayCourses.map(\.name), ["恢复甲课程"])
        XCTAssertFalse(model.showLogin)
        let logins = await transport.count("login")
        let signs = await transport.count("sign")
        XCTAssertEqual(logins, 1)
        XCTAssertEqual(signs, 0)
        XCTAssertEqual(store.vault.accounts.first?.session, refreshed)
    }

    func testConcurrentExpiredReadsShareRecoveryAndBlockSwitchUntilItCompletes() async {
        let loginGate = ResponseGate()
        let expiredGate = ResponseGate()
        let refreshed = SchoolSession(userId: "user-a", sessionId: "renewed-a", studentNo: accountA.id)
        let transport = PlannedTransport([
            "courses:session-a": [.init(courseResponse("甲课程")), .init(expiredResponse, gate: expiredGate), .init(expiredResponse, gate: expiredGate)],
            "login": [.init(loginResponse(refreshed), gate: loginGate)],
            "courses:renewed-a": [.init(courseResponse("恢复甲课程")), .init(courseResponse("恢复甲课程"))]
        ])
        let model = makeModel(MemoryAccountStore(accounts: [rememberedAccountA, accountB], active: accountA.id), transport)
        await model.restore()
        let nextDay = SchoolDate.calendar.date(byAdding: .day, value: 1, to: .now)!
        let first = Task { await model.refresh(on: .now) }
        let second = Task { await model.refresh(on: nextDay) }
        await assertEventually { await transport.count("courses:session-a") == 3 }
        await expiredGate.open()
        await assertEventually { await transport.count("login") == 1 }
        XCTAssertFalse(model.canChangeAccount)
        await model.switchAccount(id: accountB.id)
        XCTAssertEqual(model.activeAccountID, accountA.id)
        await loginGate.open()
        await first.value
        await second.value
        let count = await transport.count("login")
        XCTAssertEqual(count, 1)
        XCTAssertTrue(model.canChangeAccount)
    }

    func testFailedRecoveryDoesNotLoopAndRequiresOriginalAccountLogin() async {
        let transport = PlannedTransport([
            "courses:session-a": [.init(expiredResponse)],
            "login": [.init(loginResponse(accountB.session))]
        ])
        let model = makeModel(MemoryAccountStore(accounts: [rememberedAccountA, accountB], active: accountA.id), transport)
        await model.restore()
        await model.foregroundTick()
        XCTAssertEqual(model.activeAccountID, accountA.id)
        XCTAssertEqual(model.loginRequest?.accountID, accountA.id)
        XCTAssertTrue(model.accounts.first { $0.id == accountA.id }?.requiresLogin == true)
        XCTAssertNotEqual(model.session?.sessionId, accountB.session.sessionId)
        let count = await transport.count("login")
        XCTAssertEqual(count, 1)
    }

    func testExpiredSignNeverResubmitsAfterPasswordRecovery() async throws {
        let transport = PlannedTransport([
            "courses:session-a": [.init(courseResponse("甲课程"))],
            "clock": [.init(clockResponse)],
            "sign": [.init(expiredResponse)],
            "login": [.init(loginResponse(SchoolSession(userId: "user-a", sessionId: "renewed-a", studentNo: accountA.id)))],
            "courses:renewed-a": [.init(courseResponse("甲课程"))]
        ])
        let model = makeModel(MemoryAccountStore(accounts: [rememberedAccountA], active: accountA.id), transport)
        await model.restore()
        await model.sign(try XCTUnwrap(model.todayCourses.first))
        let signCount = await transport.count("sign")
        XCTAssertEqual(signCount, 1, "签到请求即使遇到会话失效也不能自动重发")
        XCTAssertFalse(model.todayCourses.first?.signed == true)
    }

    func testLateNotificationAuthorizationSuccessAndFailureCannotChangeNewAccount() async {
        for fails in [false, true] {
            let permissionGate = ResponseGate()
            let notifications = TestNotifications()
            notifications.authorizationGate = permissionGate
            notifications.authorizationFails = fails
            let transport = PlannedTransport([
                "courses:session-a": [.init(courseResponse("甲课程"))],
                "courses:session-b": [.init(courseResponse("乙课程"))]
            ])
            let store = MemoryAccountStore(accounts: [accountA, accountB], active: accountA.id)
            let model = makeModel(store, transport, notifications: notifications)
            await model.restore()
            let permission = Task { await model.setReminders(true) }
            await assertEventually { notifications.authorizationCalls == 1 }
            await model.switchAccount(id: accountB.id)
            await permissionGate.open()
            await permission.value
            XCTAssertFalse(model.remindersEnabled)
            XCTAssertNil(model.errorMessage)
            XCTAssertFalse(store.vault.accounts.first { $0.id == accountB.id }!.preferences.remindersEnabled)
        }
    }

    func testDeniedNotificationPermissionDoesNotRequestAgainOrSaveReminder() async {
        let notifications = TestNotifications()
        notifications.status = .denied
        let store = MemoryAccountStore(accounts: [accountA], active: accountA.id)
        let transport = PlannedTransport(["courses:session-a": [.init(courseResponse("甲课程"))]])
        let model = makeModel(store, transport, notifications: notifications)
        await model.restore()

        await model.setReminders(true)

        XCTAssertEqual(notifications.authorizationCalls, 0)
        XCTAssertFalse(model.remindersEnabled)
        XCTAssertFalse(store.vault.accounts[0].preferences.remindersEnabled)
        XCTAssertTrue(model.notificationSettingsNeeded)
        XCTAssertTrue(model.errorMessage?.contains("系统设置") == true)
        XCTAssertFalse(model.errorMessage?.contains("UNErrorDomain") == true)
    }

    func testNotificationsNotAllowedErrorUsesPermissionMessage() async {
        let notifications = TestNotifications()
        notifications.authorizationError = NSError(
            domain: UNErrorDomain,
            code: UNError.Code.notificationsNotAllowed.rawValue
        )
        let store = MemoryAccountStore(accounts: [accountA], active: accountA.id)
        let transport = PlannedTransport(["courses:session-a": [.init(courseResponse("甲课程"))]])
        let model = makeModel(store, transport, notifications: notifications)
        await model.restore()

        await model.setReminders(true)

        XCTAssertEqual(notifications.authorizationCalls, 1)
        XCTAssertFalse(model.remindersEnabled)
        XCTAssertTrue(model.notificationSettingsNeeded)
        XCTAssertFalse(model.errorMessage?.contains("UNErrorDomain") == true)
    }

    func testLateCourseReminderAuthorizationCannotChangeNewAccount() async {
        let permissionGate = ResponseGate()
        let notifications = TestNotifications()
        notifications.authorizationGate = permissionGate
        let transport = PlannedTransport([
            "courses:session-a": [.init(courseResponse("甲课程"))],
            "courses:session-b": [.init(courseResponse("乙课程"))]
        ])
        let store = MemoryAccountStore(accounts: [accountA, accountB], active: accountA.id)
        let model = makeModel(store, transport, notifications: notifications)
        await model.restore()

        let permission = Task {
            await model.setCoursePreferences(CoursePreferences(reminders: .enabled), for: "stable-course")
        }
        await assertEventually { notifications.authorizationCalls == 1 }
        await model.switchAccount(id: accountB.id)
        await permissionGate.open()
        let saved = await permission.value

        XCTAssertFalse(saved)
        XCTAssertEqual(model.activeAccountID, accountB.id)
        XCTAssertEqual(model.coursePreferences(for: "stable-course"), CoursePreferences())
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(store.vault.accounts.allSatisfy { $0.preferences.courses.isEmpty })
    }

    func testLateNotificationAddCannotLeakIntoNewAccountOrReportOldFailure() async {
        for fails in [false, true] {
            let addGate = ResponseGate()
            let notifications = TestNotifications()
            notifications.addGate = addGate
            notifications.addFails = fails
            let tomorrow = SchoolDate.calendar.date(byAdding: .day, value: 1, to: .now)!
            let transport = PlannedTransport([
                "courses:session-a": [.init(courseResponse("甲课程")), .init(courseResponse("旧账户明日课程"))],
                "courses:session-b": [.init(courseResponse("乙课程"))]
            ])
            let model = makeModel(MemoryAccountStore(accounts: [accountA, accountB], active: accountA.id), transport, notifications: notifications)
            await model.restore()
            // The loaded future course yields a deterministic future reminder at any wall-clock time.
            await model.refresh(on: tomorrow)
            model.courses = model.courses.filter { $0.day == SchoolDate.key(tomorrow) }
            let setting = Task { await model.setReminders(true) }
            await assertEventually { notifications.addCalls == 1 }
            await model.switchAccount(id: accountB.id)
            await addGate.open()
            await setting.value
            XCTAssertTrue(notifications.pendingIDs.isEmpty)
            XCTAssertNil(model.notice)
            XCTAssertFalse(model.remindersEnabled)
        }
    }


    func testLateSuccessfulReadCannotFreshenAnAccountAfterRecoveryFailed() async {
        let lateGate = ResponseGate()
        let transport = PlannedTransport([
            "courses:session-a": [.init(courseResponse("甲课程")), .init(courseResponse("迟到甲课程"), gate: lateGate), .init(expiredResponse)],
            "login": [.init(expiredResponse)]
        ])
        let model = makeModel(MemoryAccountStore(accounts: [rememberedAccountA], active: accountA.id), transport)
        await model.restore()
        let lateRead = Task { await model.refresh(on: .now) }
        await assertEventually { await transport.count("courses:session-a") == 2 }
        let tomorrow = SchoolDate.calendar.date(byAdding: .day, value: 1, to: .now)!
        await model.refresh(on: tomorrow)
        XCTAssertTrue(model.showLogin)
        await lateGate.open()
        await lateRead.value
        XCTAssertTrue(model.accounts.first?.requiresLogin == true)
        XCTAssertTrue(model.needsCourseRefresh(model.todayCourses[0]))
        XCTAssertFalse(model.canSign(model.todayCourses[0]))
        XCTAssertFalse(model.todayCourses.contains { $0.name == "迟到甲课程" })
    }

    func testOldAccountExpiryDoesNotReplaceAddAccountLoginRequest() async throws {
        let expiredGate = ResponseGate()
        let loginGate = ResponseGate()
        let transport = PlannedTransport([
            "courses:session-a": [.init(courseResponse("甲课程")), .init(expiredResponse, gate: expiredGate)],
            "login": [.init(loginResponse(accountB.session), gate: loginGate)],
            "courses:session-b": [.init(courseResponse("乙课程"))]
        ])
        let model = makeModel(MemoryAccountStore(accounts: [rememberedAccountA], active: accountA.id), transport)
        await model.restore()
        let refresh = Task { await model.refresh() }
        await assertEventually { await transport.count("courses:session-a") == 2 }
        model.presentLogin(accountID: nil)
        let request = try XCTUnwrap(model.loginRequest)
        let login = Task { await model.login(username: "b@example.edu", password: "b", remember: true, requestID: request.id) }
        await assertEventually { await transport.count("login") == 1 }
        XCTAssertFalse(model.canChangeAccount)
        await expiredGate.open()
        await refresh.value
        XCTAssertEqual(model.loginRequest?.id, request.id)
        XCTAssertNil(model.loginRequest?.accountID)
        await loginGate.open()
        let success = await login.value
        XCTAssertTrue(success)
        XCTAssertEqual(model.activeAccountID, accountB.id)
        let count = await transport.count("login")
        XCTAssertEqual(count, 1)
    }


    func testAutomaticSignAttemptIsNotRepeatedAfterSwitchingAwayAndBack() async throws {
        let schoolNow = try XCTUnwrap(CourseTime.parse(day: SchoolDate.key(.now), time: "08:30"))
        let clock = "{\"STATUS\":\"0\",\"timestamp\":\(Int64(schoolNow.timeIntervalSince1970 * 1_000))}"
        let transport = PlannedTransport([
            "courses:session-a": [.init(courseResponse("甲课程")), .init(courseResponse("甲课程")), .init(courseResponse("甲课程"))],
            "courses:session-b": [.init(courseResponse("乙课程"))],
            "clock": [.init(clock), .init(clock), .init(clock)],
            "sign": [.init(#"{"STATUS":"0","result":{"stuSignStatus":"0"}}"#)]
        ])
        let model = makeModel(MemoryAccountStore(accounts: [accountA, accountB], active: accountA.id), transport)
        await model.restore()
        model.setAutoSign(true)
        model.setAutoSignRule(AutoSignPolicy(offsetMinutes: 30))
        model.setAutoSignRunning(true)
        await model.foregroundTick()
        let initialSignCount = await transport.count("sign")
        XCTAssertEqual(initialSignCount, 1)
        XCTAssertFalse(model.todayCourses[0].signed)
        await model.switchAccount(id: accountB.id)
        await model.switchAccount(id: accountA.id)
        XCTAssertTrue(model.autoSignEnabled)
        await model.foregroundTick()
        let finalSignCount = await transport.count("sign")
        XCTAssertEqual(finalSignCount, 1, "本次运行已经自动提交过的账户和课程，切回后不能再次自动提交")
        XCTAssertEqual(model.records.count, 1)
        XCTAssertFalse(model.records[0].succeeded)
    }

    func testManualSignConfirmationDefersSubmissionUntilConfirmed() async throws {
        let transport = PlannedTransport([
            "courses:session-a": [.init(courseResponse("甲课程")), .init(courseResponse("甲课程"))],
            "clock": [.init(clockResponse)],
            "sign": [.init(#"{"STATUS":"0","ERRCODE":"0","result":{"stuSignStatus":"1"}}"#)]
        ])
        let model = makeModel(MemoryAccountStore(accounts: [accountA], active: accountA.id), transport)
        await model.restore()
        model.setConfirmation(true)
        await model.signManually(try XCTUnwrap(model.todayCourses.first))
        let request = try XCTUnwrap(model.pendingSignConfirmation)
        let beforeConfirmation = await transport.count("sign")
        XCTAssertEqual(beforeConfirmation, 0)
        // SwiftUI dismisses the alert before its asynchronous button action runs.
        model.pendingSignConfirmation = nil
        await model.confirmPendingSign(request)
        let afterConfirmation = await transport.count("sign")
        XCTAssertEqual(afterConfirmation, 1)
    }

    func testCancelledManualSignConfirmationDoesNotSubmit() async throws {
        let transport = PlannedTransport(["courses:session-a": [.init(courseResponse("甲课程"))]])
        let model = makeModel(MemoryAccountStore(accounts: [accountA], active: accountA.id), transport)
        await model.restore()
        model.setConfirmation(true)
        await model.signManually(try XCTUnwrap(model.todayCourses.first))
        XCTAssertNotNil(model.pendingSignConfirmation)
        model.pendingSignConfirmation = nil
        await Task.yield()
        let signCount = await transport.count("sign")
        XCTAssertEqual(signCount, 0)
    }

    func testCapturedSignConfirmationCannotSubmitAfterAccountSwitch() async throws {
        let transport = PlannedTransport([
            "courses:session-a": [.init(courseResponse("甲课程"))],
            "courses:session-b": [.init(courseResponse("乙课程"))]
        ])
        let model = makeModel(MemoryAccountStore(accounts: [accountA, accountB], active: accountA.id), transport)
        await model.restore()
        model.setConfirmation(true)
        await model.signManually(try XCTUnwrap(model.todayCourses.first))
        let request = try XCTUnwrap(model.pendingSignConfirmation)
        await model.switchAccount(id: accountB.id)
        await model.confirmPendingSign(request)
        let signCount = await transport.count("sign")
        XCTAssertEqual(signCount, 0)
    }

    func testCourseOverrideCannotBypassOffGlobalSwitch() async throws {
        let schoolNow = try XCTUnwrap(CourseTime.parse(day: SchoolDate.key(.now), time: "08:30"))
        let clock = "{\"STATUS\":\"0\",\"timestamp\":\(Int64(schoolNow.timeIntervalSince1970 * 1_000))}"
        let transport = PlannedTransport([
            "courses:session-a": [.init(courseResponse("甲课程")), .init(courseResponse("甲课程"))],
            "clock": [.init(clock)],
            "sign": [.init(#"{"STATUS":"0","ERRCODE":"0","result":{"stuSignStatus":"1"}}"#)]
        ])
        let model = makeModel(MemoryAccountStore(accounts: [accountA], active: accountA.id), transport)
        await model.restore()
        XCTAssertFalse(model.autoSignEnabled)
        await model.setCoursePreferences(CoursePreferences(autoSign: .enabled), for: "stable-course")
        model.setAutoSignRule(AutoSignPolicy(offsetMinutes: 30))
        await model.foregroundTick()
        let countWhileOff = await transport.count("sign")
        XCTAssertEqual(countWhileOff, 0)
        XCTAssertFalse(model.autoSignRunning)
        model.setAutoSignRunning(true)
        await model.foregroundTick()
        let signCount = await transport.count("sign")
        XCTAssertEqual(signCount, 1)
    }

    func testDisablingCourseBlocksSignInAndPreservesOverrides() async throws {
        var account = accountA
        account.preferences = AccountPreferences(autoSignEnabled: true, remindersEnabled: true,
                                                confirmationEnabled: true)
        let store = MemoryAccountStore(accounts: [account], active: account.id)
        let transport = PlannedTransport(["courses:session-a": [.init(courseResponse("甲课程"))]])
        let model = makeModel(store, transport)
        await model.restore()
        let course = try XCTUnwrap(model.todayCourses.first)
        let preferences = CoursePreferences(confirmation: .enabled, autoSign: .enabled, signInDisabled: true)
        let saved = await model.setCoursePreferences(preferences, for: "stable-course")
        XCTAssertTrue(saved)
        XCTAssertFalse(model.canSign(course))
        XCTAssertFalse(model.effectiveAutoSign(for: "stable-course"))
        XCTAssertFalse(model.effectiveConfirmation(for: "stable-course"))
        XCTAssertTrue(model.effectiveReminders(for: "stable-course"))
        XCTAssertFalse(model.isSignInDisabled(for: "other-course"))
        await model.signManually(course)
        await model.sign(course)
        await model.foregroundTick()
        XCTAssertNil(model.pendingSignConfirmation)
        let signCount = await transport.count("sign")
        XCTAssertEqual(signCount, 0)
        XCTAssertEqual(store.vault.accounts[0].preferences.courses["stable-course"], preferences)

        var enabled = preferences
        enabled.signInDisabled = false
        let restored = await model.setCoursePreferences(enabled, for: "stable-course")
        XCTAssertTrue(restored)
        XCTAssertTrue(model.canSign(course))
        XCTAssertTrue(model.effectiveAutoSign(for: "stable-course"))
        XCTAssertTrue(model.effectiveConfirmation(for: "stable-course"))
    }

    func testDisablingCourseInvalidatesPendingConfirmationAndFailedSaveKeepsState() async throws {
        let store = MemoryAccountStore(accounts: [accountA], active: accountA.id)
        let transport = PlannedTransport(["courses:session-a": [.init(courseResponse("甲课程"))]])
        let model = makeModel(store, transport)
        await model.restore()
        model.setConfirmation(true)
        let course = try XCTUnwrap(model.todayCourses.first)
        await model.signManually(course)
        let request = try XCTUnwrap(model.pendingSignConfirmation)
        store.failWrites = true
        let failed = await model.setCoursePreferences(CoursePreferences(signInDisabled: true), for: "stable-course")
        XCTAssertFalse(failed)
        XCTAssertFalse(model.isSignInDisabled(for: "stable-course"))
        XCTAssertNotNil(model.pendingSignConfirmation)
        store.failWrites = false
        let saved = await model.setCoursePreferences(CoursePreferences(signInDisabled: true), for: "stable-course")
        XCTAssertTrue(saved)
        XCTAssertNil(model.pendingSignConfirmation)
        await model.confirmPendingSign(request)
        let signCount = await transport.count("sign")
        XCTAssertEqual(signCount, 0)
    }

    func testDisablingCourseDuringClockWaitPreventsSubmission() async throws {
        for automatically in [false, true] {
            defaults.removeObject(forKey: "auto-sign-\(accountA.id)")
            let gate = ResponseGate()
            let schoolNow = try XCTUnwrap(CourseTime.parse(day: SchoolDate.key(.now), time: "08:30"))
            let clock = "{\"STATUS\":\"0\",\"timestamp\":\(Int64(schoolNow.timeIntervalSince1970 * 1_000))}"
            let store = MemoryAccountStore(accounts: [accountA], active: accountA.id)
            let transport = PlannedTransport([
                "courses:session-a": [.init(courseResponse("甲课程"))],
                "clock": [.init(clock, gate: gate)]
            ])
            let model = makeModel(store, transport)
            await model.restore()
            model.setAutoSign(true)
            model.setAutoSignRule(AutoSignPolicy(offsetMinutes: 30))
            model.setAutoSignRunning(true)
            let course = try XCTUnwrap(model.todayCourses.first)
            let task = Task {
                if automatically { await model.foregroundTick() }
                else { await model.signManually(course) }
            }
            await assertEventually { await transport.count("clock") == 1 }
            let saved = await model.setCoursePreferences(CoursePreferences(signInDisabled: true), for: "stable-course")
            XCTAssertTrue(saved)
            await gate.open()
            await task.value
            let signCount = await transport.count("sign")
            XCTAssertEqual(signCount, 0)
            XCTAssertTrue(model.records.isEmpty)
            XCTAssertNil(model.errorMessage)
            XCTAssertNil(model.signingID)
        }
    }

    func testDisabledCourseIsIsolatedByAccountAndPersistsAcrossSwitches() async {
        let store = MemoryAccountStore(accounts: [accountA, accountB], active: accountA.id)
        let transport = PlannedTransport([
            "courses:session-a": [.init(courseResponse("甲课程")), .init(courseResponse("甲课程"))],
            "courses:session-b": [.init(courseResponse("乙课程"))]
        ])
        let model = makeModel(store, transport)
        await model.restore()
        let saved = await model.setCoursePreferences(CoursePreferences(signInDisabled: true), for: "stable-course")
        XCTAssertTrue(saved)
        await model.switchAccount(id: accountB.id)
        XCTAssertFalse(model.isSignInDisabled(for: "stable-course"))
        await model.switchAccount(id: accountA.id)
        XCTAssertTrue(model.isSignInDisabled(for: "stable-course"))
    }

    func testCatalogRefreshMergesConcurrentRequestsAndHonorsFreshCache() async {
        let semesterGate = ResponseGate()
        let transport = PlannedTransport([
            "courses:session-a": [.init(courseResponse("甲课程"))],
            "semesters:session-a": [.init(semesterResponse, gate: semesterGate)],
            "catalog:session-a": [.init(catalogResponse)]
        ])
        let model = makeModel(MemoryAccountStore(accounts: [accountA], active: accountA.id), transport)
        await model.restore()

        let first = Task { await model.refreshCatalog(force: true) }
        await assertEventually { await transport.count("semesters:session-a") == 1 }
        let second = Task { await model.refreshCatalog(force: true) }
        for _ in 0..<10 { await Task.yield() }
        await semesterGate.open()
        await first.value
        await second.value

        XCTAssertEqual(model.selectedSemester?.id, "2026202701")
        XCTAssertEqual(model.catalogCourses.map(\.id), ["stable-course"])
        let mergedSemesterRequests = await transport.count("semesters:session-a")
        let mergedCatalogRequests = await transport.count("catalog:session-a")
        XCTAssertEqual(mergedSemesterRequests, 1)
        XCTAssertEqual(mergedCatalogRequests, 1)

        await model.refreshCatalog()
        let cachedSemesterRequests = await transport.count("semesters:session-a")
        let cachedCatalogRequests = await transport.count("catalog:session-a")
        XCTAssertEqual(cachedSemesterRequests, 1)
        XCTAssertEqual(cachedCatalogRequests, 1)
    }

    func testFreshDemoCatalogRefreshDoesNotPublishUnchangedState() async {
        let transport = PlannedTransport([:])
        let model = makeModel(MemoryAccountStore(accounts: [], active: nil), transport)
        model.enterDemo()
        let updatedAt = model.catalogUpdatedAt
        var publications = 0
        let observation = model.objectWillChange.sink { publications += 1 }
        defer { observation.cancel() }

        await model.refreshCatalog()
        await model.refreshCatalog()
        XCTAssertEqual(publications, 0, "Returning to a fresh demo catalog must not redraw unrelated detail content")
        XCTAssertEqual(model.catalogUpdatedAt, updatedAt)

        await model.refreshCatalog(force: true)
        XCTAssertGreaterThan(publications, 0, "A manual refresh still publishes its updated timestamp")
        XCTAssertFalse(model.catalogIsCached)
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testInitialWeekLoadsAsOneRefreshAndCachedWeekStaysVisible() async throws {
        let gate = ResponseGate()
        let transport = PlannedTransport([
            "courses:session-a": [.init(courseResponse("课程"))],
            "semesters:session-a": [.init(scheduleSemesterResponse()), .init(scheduleSemesterResponse())],
            "weekly:session-a": [.init(scheduleWeekResponse(), gate: gate), .init(scheduleWeekResponse())]
        ])
        let model = makeModel(MemoryAccountStore(accounts: [accountA], active: accountA.id), transport)
        await model.restore()
        model.scheduleMode = .week
        XCTAssertTrue(model.isInitialWeekLoading)
        let initial = Task { await model.openScheduleDate(model.selectedDate) }
        await assertEventually { await transport.count("weekly:session-a") == 1 }
        XCTAssertTrue(model.isInitialWeekLoading)
        await gate.open()
        await initial.value
        XCTAssertTrue(model.hasWeekSchedule)
        XCTAssertFalse(model.isInitialWeekLoading)
        await model.openScheduleDate(model.selectedDate)
        let reads = await transport.count("weekly:session-a")
        XCTAssertEqual(reads, 1)
        let daily = await transport.count("courses:session-a")
        XCTAssertEqual(daily, 1)
        await model.refreshSchedule()
        XCTAssertFalse(model.isInitialWeekLoading)
    }

    func testSemesterSyncCommitsEmptyDaysAndColdStartReusesCache() async throws {
        let transport = PlannedTransport([
            "courses:session-a": [.init(courseResponse("课程"))],
            "semesters:session-a": [.init(scheduleSemesterResponse())],
            "weekly:session-a": [.init(scheduleWeekResponse())]
        ])
        let store = MemoryAccountStore(accounts: [accountA], active: accountA.id)
        let model = makeModel(store, transport)
        await model.restore()
        await model.synchronizeSchedules()
        let updated = try XCTUnwrap(model.scheduleUpdatedAt(on: .now))
        XCTAssertEqual(model.semesterSchedules.count, 1)
        for date in SchoolDate.week(containing: .now) { XCTAssertTrue(model.hasSchedule(on: date)) }
        await model.openScheduleDate(.now)
        await model.maintainScheduleCache()
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 3, "Full sync satisfies checks for every covered date")
        XCTAssertEqual(model.scheduleUpdatedAt(on: .now), updated)

        let restartedTransport = PlannedTransport(["courses:session-a": [.init(courseResponse("课程"))]])
        let restarted = makeModel(store, restartedTransport)
        await restarted.restore()
        await restarted.openScheduleDate(.now)
        XCTAssertEqual(restarted.scheduleUpdatedAt(on: .now), updated)
        let restartedRequests = await restartedTransport.requests
        XCTAssertEqual(restartedRequests.count, 1)
    }

    func testWeekPresentationReusesLayoutAndUnchangedDailyCheckDoesNotInvalidateIt() async throws {
        let transport = PlannedTransport([
            "courses:session-a": [.init(courseResponse("课程")), .init(courseResponse("课程"))],
            "semesters:session-a": [.init(scheduleSemesterResponse())],
            "weekly:session-a": [.init(scheduleWeekResponse())]
        ])
        let model = makeModel(MemoryAccountStore(accounts: [accountA], active: accountA.id), transport)
        await model.restore()
        await model.synchronizeSchedules()
        let first = model.weekSchedulePresentation
        let date = model.selectedDate
        model.notice = "进度或其他状态变更"
        XCTAssertTrue(first === model.weekSchedulePresentation)
        let otherDay = SchoolDate.week(containing: date).first!
        model.selectedDate = otherDay
        XCTAssertTrue(first === model.weekSchedulePresentation)
        model.selectedDate = SchoolDate.calendar.date(byAdding: .day, value: 7, to: date)!
        XCTAssertFalse(first === model.weekSchedulePresentation)
        model.selectedDate = date
        XCTAssertTrue(first === model.weekSchedulePresentation)
        await model.refresh(on: date)
        XCTAssertTrue(first === model.weekSchedulePresentation, "An unchanged date check must not rebuild the semester layout")
        model.showOutsideWeekCourses.toggle()
        XCTAssertFalse(first === model.weekSchedulePresentation)
        let previous = model.weekSchedulePresentation
        model.courses.append(Course(id: "new", name: "新课程", beginTime: "19:00", endTime: "20:00", day: SchoolDate.key(date)))
        XCTAssertFalse(previous === model.weekSchedulePresentation)
        XCTAssertTrue(model.weekSchedulePresentation.entries.contains { $0.course.id == "new" })
        model.removeAccount(id: accountA.id)
        XCTAssertTrue(model.weekSchedulePresentation.entries.isEmpty)
    }

    func testAttendanceOnlyChangeDoesNotTriggerSemesterRefresh() async throws {
        let transport = PlannedTransport([
            "courses:session-a": [.init(courseResponse("课程")), .init(courseResponse("课程").replacingOccurrences(of: "\"signStatus\":\"0\"", with: "\"signStatus\":\"1\""))],
            "semesters:session-a": [.init(scheduleSemesterResponse())],
            "weekly:session-a": [.init(scheduleWeekResponse())]
        ])
        let model = makeModel(MemoryAccountStore(accounts: [accountA], active: accountA.id), transport)
        await model.restore()
        await model.synchronizeSchedules()
        let updated = model.scheduleUpdatedAt(on: .now)
        await model.refreshSchedule()
        XCTAssertTrue(try XCTUnwrap(model.todayCourses.first).signed)
        XCTAssertEqual(model.scheduleUpdatedAt(on: .now), updated)
        let weekRequests = await transport.count("weekly:session-a")
        XCTAssertEqual(weekRequests, 1)
    }

    func testArrangementChangeRefreshesCachedSemesterAndKeepsDailyResult() async throws {
        let transport = PlannedTransport([
            "courses:session-a": [.init(courseResponse("课程")), .init(courseResponse("调整后课程"))],
            "semesters:session-a": [.init(scheduleSemesterResponse()), .init(scheduleSemesterResponse())],
            "weekly:session-a": [.init(scheduleWeekResponse()), .init(scheduleWeekResponse(name: "调整后课程"))]
        ])
        let model = makeModel(MemoryAccountStore(accounts: [accountA], active: accountA.id), transport)
        await model.restore()
        await model.synchronizeSchedules()
        let updated = try XCTUnwrap(model.scheduleUpdatedAt(on: .now))
        await model.refreshSchedule()
        XCTAssertEqual(model.todayCourses.first?.name, "调整后课程")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(model.scheduleUpdatedAt(on: .now)), updated)
        let weekRequests = await transport.count("weekly:session-a")
        XCTAssertEqual(weekRequests, 2)
    }

    func testIncompleteSemesterDoesNotAdvanceTimestampAndBacksOff() async throws {
        let transport = PlannedTransport([
            "courses:session-a": [.init(courseResponse("课程"))],
            "semesters:session-a": [.init(scheduleSemesterResponse()), .init(scheduleSemesterResponse())],
            "weekly:session-a": [.init(scheduleWeekResponse()), .init(#"{"STATUS":"0","result":[]}"#)]
        ])
        let model = makeModel(MemoryAccountStore(accounts: [accountA], active: accountA.id), transport)
        await model.restore()
        await model.synchronizeSchedules()
        let updated = model.scheduleUpdatedAt(on: .now)
        await model.synchronizeSchedules(force: true)
        XCTAssertNotNil(model.scheduleSyncError)
        XCTAssertEqual(model.scheduleUpdatedAt(on: .now), updated)
        XCTAssertEqual(model.todayCourses.first?.name, "课程")
        let before = await transport.requests.count
        await model.synchronizeSchedules()
        let after = await transport.requests.count
        XCTAssertEqual(before, after)
        let retryTransport = PlannedTransport([
            "courses:session-a": [.init(courseResponse("课程"))],
            "semesters:session-a": [.init(scheduleSemesterResponse())],
            "weekly:session-a": [.init(scheduleWeekResponse())]
        ])
        let restarted = makeModel(MemoryAccountStore(accounts: [accountA], active: accountA.id), retryTransport)
        await restarted.restore()
        await restarted.openScheduleDate(.now)
        XCTAssertNil(restarted.scheduleSyncError)
        XCTAssertNil(defaults.data(forKey: "schedule-pending-\(accountA.id)"))
        let retriedWeeks = await retryTransport.count("weekly:session-a")
        XCTAssertEqual(retriedWeeks, 1, "An interrupted force refresh must resume even when the old snapshot is under seven days old")
    }

    func testSparseWeekQueriesMissingDaysIncludingEmptyDays() async throws {
        let daily = [PlannedTransport.Response(courseResponse("课程"))] +
            Array(repeating: PlannedTransport.Response(#"{"STATUS":"0","result":[]}"#), count: 7)
        let transport = PlannedTransport([
            "courses:session-a": daily,
            "semesters:session-a": [.init(scheduleSemesterResponse())],
            "weekly:session-a": [.init(#"{"STATUS":"0","result":[]}"#)]
        ])
        let model = makeModel(MemoryAccountStore(accounts: [accountA], active: accountA.id), transport)
        await model.restore()
        await model.synchronizeSchedules()
        XCTAssertNotNil(model.scheduleUpdatedAt(on: .now))
        XCTAssertTrue(model.todayCourses.isEmpty, "Successful empty response removes a cancelled course")
        let dailyRequests = await transport.count("courses:session-a")
        XCTAssertEqual(dailyRequests, 8)
    }

    func testNewerDailyCheckWinsAgainstInFlightSemesterBatch() async throws {
        let gate = ResponseGate()
        let transport = PlannedTransport([
            "courses:session-a": [.init(courseResponse("课程")), .init(courseResponse("新课程"))],
            "semesters:session-a": [.init(scheduleSemesterResponse()), .init(scheduleSemesterResponse())],
            "weekly:session-a": [.init(scheduleWeekResponse(), gate: gate), .init(scheduleWeekResponse(name: "新课程"))]
        ])
        let model = makeModel(MemoryAccountStore(accounts: [accountA], active: accountA.id), transport)
        await model.restore()
        let batch = Task { await model.synchronizeSchedules() }
        await assertEventually { await transport.count("weekly:session-a") == 1 }
        await model.refresh(on: .now)
        await gate.open()
        await batch.value
        XCTAssertEqual(model.todayCourses.first?.name, "新课程")
        XCTAssertEqual(model.semesterSchedules.values.first?.courses.first?.name, "新课程")
    }

    func testAccountSwitchRejectsLateFullSemesterResult() async {
        let gate = ResponseGate()
        let transport = PlannedTransport([
            "courses:session-a": [.init(courseResponse("甲课程"))],
            "courses:session-b": [.init(courseResponse("乙课程"))],
            "semesters:session-a": [.init(scheduleSemesterResponse())],
            "weekly:session-a": [.init(scheduleWeekResponse(name: "迟到甲课程"), gate: gate)]
        ])
        let model = makeModel(MemoryAccountStore(accounts: [accountA, accountB], active: accountA.id), transport)
        await model.restore()
        let batch = Task { await model.synchronizeSchedules() }
        await assertEventually { await transport.count("weekly:session-a") == 1 }
        await model.switchAccount(id: accountB.id)
        await gate.open()
        await batch.value
        XCTAssertEqual(model.todayCourses.first?.name, "乙课程")
        XCTAssertTrue(model.semesterSchedules.isEmpty)
        XCTAssertNil(defaults.data(forKey: "semester-schedules-\(accountA.id)"))
    }

    func testChangeRefreshesEveryCachedSemester() async throws {
        let week = SchoolDate.week(containing: .now)
        let previousWeek = SchoolDate.week(containing: week[0].addingTimeInterval(-7 * 86400))
        let current = SchoolSemester(id: "schedule-term", name: "当前学期", beginDate: SchoolDate.key(week[0]), endDate: SchoolDate.key(week[6]), isCurrent: true)
        let previous = SchoolSemester(id: "previous-term", name: "历史学期", beginDate: SchoolDate.key(previousWeek[0]), endDate: SchoolDate.key(previousWeek[6]), isCurrent: false)
        let course = Course(id: "1234567", courseId: "stable-course", name: "课程", teacher: "教师", beginTime: "08:00", endTime: "09:40", day: SchoolDate.key(.now))
        let snapshots = [SemesterScheduleCache(semester: current, courses: [course], updatedAt: .now),
                         SemesterScheduleCache(semester: previous, courses: [], updatedAt: .now)]
        defaults.set(try JSONEncoder().encode(snapshots), forKey: "semester-schedules-\(accountA.id)")
        let terms = [current, previous].map { ["code": $0.id, "name": $0.name, "beginDate": $0.beginDate, "endDate": $0.endDate, "yearStatus": $0.isCurrent ? "1" : "0"] }
        let semesters = String(data: try JSONSerialization.data(withJSONObject: ["STATUS": "0", "result": terms]), encoding: .utf8)!
        let oldWeek = String(data: try JSONSerialization.data(withJSONObject: ["STATUS": "0", "result": previousWeek.map {
            ["dateStr": SchoolDate.key($0), "schedData": []] as [String: Any]
        }]), encoding: .utf8)!
        let transport = PlannedTransport([
            "courses:session-a": [.init(courseResponse("课程")), .init(courseResponse("调整后课程"))],
            "semesters:session-a": [.init(semesters)],
            "weekly:session-a": [.init(scheduleWeekResponse(name: "调整后课程")), .init(oldWeek)]
        ])
        let model = makeModel(MemoryAccountStore(accounts: [accountA], active: accountA.id), transport)
        await model.restore()
        await model.refreshSchedule()
        let weeks = await transport.count("weekly:session-a")
        XCTAssertEqual(weeks, 2)
        XCTAssertEqual(model.semesterSchedules.count, 2)
        XCTAssertEqual(model.todayCourses.first?.name, "调整后课程")
        XCTAssertGreaterThan(try XCTUnwrap(model.semesterSchedules[previous.id]?.updatedAt), snapshots[1].updatedAt)
    }

    func testLocalAttendanceWinsAgainstInFlightSemesterBatch() async throws {
        let gate = ResponseGate()
        let now = CourseTime.parse(day: SchoolDate.key(.now), time: "08:30")!
        let signed = courseResponse("课程").replacingOccurrences(of: "\"signStatus\":\"0\"", with: "\"signStatus\":\"1\"")
        let transport = PlannedTransport([
            "courses:session-a": [.init(courseResponse("课程")), .init(signed)],
            "semesters:session-a": [.init(scheduleSemesterResponse())],
            "weekly:session-a": [.init(scheduleWeekResponse(), gate: gate)],
            "clock": [.init("{\"STATUS\":\"0\",\"timestamp\":\(Int64(now.timeIntervalSince1970 * 1000))}")],
            "sign": [.init(#"{"STATUS":"0","ERRCODE":"0","result":{"stuSignStatus":"1","stuSignId":"record"}}"#)]
        ])
        let model = makeModel(MemoryAccountStore(accounts: [accountA], active: accountA.id), transport)
        await model.restore()
        let course = try XCTUnwrap(model.todayCourses.first)
        let batch = Task { await model.synchronizeSchedules() }
        await assertEventually { await transport.count("weekly:session-a") == 1 }
        await model.sign(course)
        await gate.open()
        await batch.value
        XCTAssertTrue(try XCTUnwrap(model.todayCourses.first).signed)
        XCTAssertTrue(try XCTUnwrap(model.semesterSchedules.values.first?.courses.first).signed)
    }

    func testWeekViewDoesNotRequestDatesOutsideKnownSemesterRange() async throws {
        let day = SchoolDate.key(.now)
        let term = SchoolSemester(id: "one-day", name: "学期边界", beginDate: day, endDate: day, isCurrent: true)
        let initial = Course(id: "1234567", courseId: "stable-course", name: "课程", teacher: "教师", beginTime: "08:00", endTime: "09:40", day: day)
        defaults.set(try JSONEncoder().encode([SemesterScheduleCache(semester: term, courses: [initial], updatedAt: .now)]),
                     forKey: "semester-schedules-\(accountA.id)")
        let transport = PlannedTransport(["courses:session-a": [.init(courseResponse("课程"))]])
        let model = makeModel(MemoryAccountStore(accounts: [accountA], active: accountA.id), transport)
        await model.restore()
        let updated = model.scheduleUpdatedAt(on: .now)
        model.scheduleMode = .week
        await model.openScheduleDate(model.selectedDate)
        for date in SchoolDate.week(containing: .now) {
            XCTAssertEqual(model.hasSchedule(on: date), SchoolDate.key(date) == day)
            XCTAssertEqual(model.canSelectScheduleDate(date), SchoolDate.key(date) == day)
        }
        XCTAssertNil(model.adjacentScheduleWeek(-1))
        XCTAssertNil(model.adjacentScheduleWeek(1))
        XCTAssertEqual(model.scheduleWeekNumber, 1)
        await model.selectDate(SchoolDate.calendar.date(byAdding: .day, value: 30, to: .now)!)
        XCTAssertEqual(SchoolDate.key(model.selectedDate), day)
        XCTAssertEqual(model.scheduleUpdatedAt(on: .now), updated)
        await model.openScheduleDate(model.selectedDate)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)

        let outside = try XCTUnwrap(SchoolDate.week(containing: .now).first { SchoolDate.key($0) != day })
        await model.refresh(on: outside)
        XCTAssertNotNil(model.scheduleDayErrors[SchoolDate.key(outside)])
        XCTAssertFalse(model.hasVisibleScheduleErrors, "An error outside this semester must not appear on the visible week")
        await model.refresh(on: .now)
        XCTAssertTrue(model.hasVisibleScheduleErrors)
    }

    func testScheduleNavigationIncludesHistoricalTermsAndClampsPartialBoundaryWeeks() async throws {
        func date(_ day: String) -> Date { CourseTime.parse(day: day, time: "00:00")! }
        let terms = [
            SchoolSemester(id: "old", name: "历史学期", beginDate: "20260107", endDate: "20260120", isCurrent: false),
            SchoolSemester(id: "short", name: "短学期", beginDate: "20260202", endDate: "20260215", isCurrent: false),
            SchoolSemester(id: "new", name: "当前学期", beginDate: "20261230", endDate: "20270112", isCurrent: true)
        ]
        defaults.set(try JSONEncoder().encode(terms.map { SemesterScheduleCache(semester: $0, courses: [], updatedAt: .now) }),
                     forKey: "semester-schedules-\(accountA.id)")
        let model = makeModel(MemoryAccountStore(accounts: [accountA], active: accountA.id),
                              PlannedTransport(["courses:session-a": [.init(courseResponse("课程"))]]))
        await model.restore()
        XCTAssertEqual(model.scheduleDateRange, date("20260107")...date("20270112"))
        model.selectedDate = date("20250101")
        XCTAssertFalse(model.hasWeekSchedule, "An out-of-range week has no usable cache")
        model.selectedDate = date("20260112")
        XCTAssertEqual(model.scheduleWeekNumber, 2)
        XCTAssertEqual(model.adjacentScheduleWeek(-1), date("20260107"))
        model.selectedDate = model.boundedScheduleDate(date("20260101"))
        XCTAssertEqual(model.selectedDate, date("20260107"))
        XCTAssertNil(model.adjacentScheduleWeek(-1))
        model.selectedDate = date("20270110")
        XCTAssertEqual(model.adjacentScheduleWeek(1), date("20270112"))
        model.selectedDate = model.boundedScheduleDate(date("20270201"))
        XCTAssertEqual(model.selectedDate, date("20270112"))
        XCTAssertEqual(model.scheduleWeekNumber, 3)
        XCTAssertNil(model.adjacentScheduleWeek(1))
        XCTAssertEqual(model.scheduleDate(selectingSemester: "short"), date("20260210"), "Week 3 clamps to week 2 while retaining Tuesday")
        XCTAssertEqual(model.scheduleDate(selectingSemester: "new"), model.selectedDate)
        model.selectedDate = date("20270106")
        XCTAssertEqual(model.scheduleDate(selectingSemester: "old"), date("20260114"), "Retain week 2 and Wednesday")
        XCTAssertNil(model.scheduleDate(selectingSemester: "missing"))
        XCTAssertTrue(model.canSelectScheduleDate(date("20270112").addingTimeInterval(86399)))
        model.selectedDate = date("20261230")
        XCTAssertEqual(model.scheduleDate(selectingSemester: "short"), date("20260204"))
        XCTAssertNil(model.adjacentScheduleWeek(-1), "Previous must stop at this semester even when historical semesters exist")
        XCTAssertEqual(model.adjacentScheduleWeek(1), date("20270106"))
        XCTAssertFalse(model.canSelectVisibleScheduleDate(date("20261229")))
        XCTAssertTrue(model.canSelectScheduleDate(date("20260107")), "Explicit date/semester selection can still open history")
        model.selectedDate = date("20260120")
        XCTAssertNil(model.adjacentScheduleWeek(1), "Historical semester navigation must also stop at its own end")
        XCTAssertFalse(model.canSelectVisibleScheduleDate(date("20260121")))
        model.selectedDate = date("20260801")
        XCTAssertNil(model.scheduleWeekNumber, "Holidays must not inherit another semester's week number")
        let unknown = makeModel(MemoryAccountStore(accounts: [], active: nil), PlannedTransport([:]))
        XCTAssertNil(unknown.scheduleDateRange)
        XCTAssertTrue(unknown.canSelectScheduleDate(date("20270201")))
    }

    func testWaitingForSyncLoadsNewlySelectedSemester() async throws {
        let gate = ResponseGate()
        let week = SchoolDate.week(containing: .now)
        let next = SchoolDate.week(containing: week[0].addingTimeInterval(7 * 86400))
        let terms: [[String: String]] = [
            ["code": "first", "name": "学期一", "beginDate": SchoolDate.key(week[0]), "endDate": SchoolDate.key(week[6]), "yearStatus": "1"],
            ["code": "next", "name": "学期二", "beginDate": SchoolDate.key(next[0]), "endDate": SchoolDate.key(next[6]), "yearStatus": "0"]
        ]
        let semesters = String(data: try JSONSerialization.data(withJSONObject: ["STATUS": "0", "result": terms]), encoding: .utf8)!
        let nextWeek = String(data: try JSONSerialization.data(withJSONObject: ["STATUS": "0", "result": next.map {
            ["dateStr": SchoolDate.key($0), "schedData": []] as [String: Any]
        }]), encoding: .utf8)!
        let transport = PlannedTransport([
            "courses:session-a": [.init(courseResponse("课程"))],
            "semesters:session-a": [.init(semesters), .init(semesters)],
            "weekly:session-a": [.init(scheduleWeekResponse(), gate: gate), .init(nextWeek)]
        ])
        let model = makeModel(MemoryAccountStore(accounts: [accountA], active: accountA.id), transport)
        await model.restore()
        let first = Task { await model.synchronizeSchedules() }
        await assertEventually { await transport.count("weekly:session-a") == 1 }
        model.selectedDate = next[0]
        let second = Task { await model.synchronizeSchedules() }
        for _ in 0..<10 { await Task.yield() }
        await gate.open()
        await first.value
        await second.value
        XCTAssertNotNil(model.semesterSchedules["first"])
        XCTAssertNotNil(model.semesterSchedules["next"])
        XCTAssertNil(model.scheduleSyncError)
    }

    func testScheduleModePersistsInInjectedDefaults() {
        let store = MemoryAccountStore(accounts: [], active: nil)
        let model = makeModel(store, PlannedTransport([:]))
        XCTAssertEqual(model.scheduleMode, .day)
        model.scheduleMode = .week
        XCTAssertEqual(makeModel(store, PlannedTransport([:])).scheduleMode, .week)
    }

    func testOutsideWeekPreferencePersistsAndDoesNotModifyDailySchedule() async throws {
        let model = makeModel(MemoryAccountStore(accounts: [], active: nil), PlannedTransport([:]))
        XCTAssertFalse(model.showOutsideWeekCourses)
        model.showOutsideWeekCourses = true
        XCTAssertTrue(makeModel(MemoryAccountStore(accounts: [], active: nil), PlannedTransport([:])).showOutsideWeekCourses)
        model.showOutsideWeekCourses = false
        XCTAssertFalse(makeModel(MemoryAccountStore(accounts: [], active: nil), PlannedTransport([:])).showOutsideWeekCourses)

        let now = SchoolDate.calendar.startOfDay(for: .now)
        let previous = SchoolDate.calendar.date(byAdding: .day, value: -7, to: now)!
        let next = SchoolDate.calendar.date(byAdding: .day, value: 7, to: now)!
        let term = SchoolSemester(id: "preview-term", name: "测试学期", beginDate: SchoolDate.key(previous),
                                  endDate: SchoolDate.key(next), isCurrent: true)
        let other = Course(id: "preview", courseId: "preview-course", name: "非本周课程", beginTime: "08:00", endTime: "09:00", day: SchoolDate.key(previous))
        defaults.set(try JSONEncoder().encode([SemesterScheduleCache(semester: term, courses: [other], updatedAt: .now)]),
                     forKey: "semester-schedules-\(accountA.id)")
        let transport = PlannedTransport(["courses:session-a": [.init(courseResponse("本周课程"))],
                                          "courses:session-b": [.init(courseResponse("乙课程"))]])
        let restored = makeModel(MemoryAccountStore(accounts: [accountA, accountB], active: accountA.id), transport)
        await restored.restore()
        let daily = restored.selectedCourses
        let cached = restored.courses
        restored.showOutsideWeekCourses = true
        XCTAssertEqual(restored.weekSchedulePresentation.entries.filter(\.isOutsideWeek).map(\.course), [other])
        XCTAssertEqual(restored.selectedCourses, daily)
        XCTAssertEqual(restored.courses, cached)
        await restored.switchAccount(id: accountB.id)
        XCTAssertTrue(restored.weekSchedulePresentation.entries.filter(\.isOutsideWeek).isEmpty)
    }

    func testScheduleCourseNavigationResolvesCourseIdentityInsteadOfMeetingID() {
        let model = makeModel(MemoryAccountStore(accounts: [], active: nil), PlannedTransport([:]))
        model.enterDemo()
        let scheduled = AppModel.demoCourses(on: .now)[0]
        XCTAssertEqual(model.catalogCourse(for: scheduled), AppModel.demoCatalogCourses[0])
        XCTAssertNotEqual(model.catalogCourse(for: scheduled).id, scheduled.id)

        let missingID = Course(id: "7654321", name: scheduled.name, teacher: scheduled.teacher,
                               beginTime: "08:00", endTime: "09:00", day: scheduled.day)
        XCTAssertEqual(model.catalogCourse(for: missingID).id, "", "没有课程编号或内部 ID 时不通过课程名称猜测关联")
        let unknown = Course(id: "7654321", name: "未匹配课程", beginTime: "08:00", endTime: "09:00", day: scheduled.day)
        XCTAssertEqual(model.catalogCourse(for: unknown).id, "")
        XCTAssertEqual(model.catalogCourse(for: unknown).name, "未匹配课程")
        let uncataloged = Course(id: "7654321", courseId: "real-course", name: scheduled.name,
                                beginTime: "08:00", endTime: "09:00", day: scheduled.day)
        XCTAssertEqual(model.catalogCourse(for: uncataloged).id, "real-course")
    }

    func testCoTeacherSettingsUseOneCatalogIdentityIncludingMissingTeachingID() async throws {
        let store = MemoryAccountStore(accounts: [accountA, accountB], active: accountA.id)
        let transport = PlannedTransport([
            "courses:session-a": [.init(coTeacherResponse(missingThirdID: true))],
            "semesters:session-a": [.init(linkedSemesterResponse)], "catalog:session-a": [.init(linkedCatalogResponse)],
            "courses:session-b": [.init(courseResponse("其他账户"))]
        ])
        let model = makeModel(store, transport)
        await model.restore()
        await model.refreshCatalog()
        let meetings = model.todayCourses
        XCTAssertEqual(meetings.count, 3)
        XCTAssertTrue(meetings.allSatisfy { model.catalogCourse(for: $0).id == "stable-course" })
        let saved = await model.setCoursePreferences(CoursePreferences(confirmation: .enabled, autoSign: .disabled,
            reminders: .disabled, signInDisabled: true), for: "teaching-2")
        XCTAssertTrue(saved)
        XCTAssertEqual(Set(store.vault.accounts[0].preferences.courses.keys), ["stable-course"])
        for course in meetings {
            XCTAssertTrue(model.isSignInDisabled(for: course))
            XCTAssertFalse(model.canSign(course))
            XCTAssertFalse(model.effectiveAutoSign(for: course))
            XCTAssertFalse(model.effectiveReminders(for: course))
        }
        _ = await model.setCoursePreferences(CoursePreferences(confirmation: .enabled), for: "stable-course")
        XCTAssertTrue(meetings.allSatisfy { model.effectiveConfirmation(for: $0) })
        await model.signManually(meetings[1])
        XCTAssertEqual(model.pendingSignConfirmation?.course.id, meetings[1].id)
        _ = await model.setCoursePreferences(CoursePreferences(signInDisabled: true), for: "stable-course")
        XCTAssertNil(model.pendingSignConfirmation)
        let signCount = await transport.count("sign")
        XCTAssertEqual(signCount, 0)
        await model.switchAccount(id: accountB.id)
        XCTAssertEqual(model.canonicalCourseID(for: "teaching-2"), "teaching-2")
        XCTAssertFalse(model.isSignInDisabled(for: "stable-course"))
    }

    func testLegacyTeacherSettingsArePreservedUntilUnifiedSettingIsSaved() async {
        var account = accountA
        account.preferences.courses = ["teaching-2": CoursePreferences(autoSign: .disabled, signInDisabled: true),
                                      "teaching-3": CoursePreferences(confirmation: .enabled, autoSign: .enabled)]
        let store = MemoryAccountStore(accounts: [account], active: account.id)
        let transport = PlannedTransport(["courses:session-a": [.init(coTeacherResponse())],
            "semesters:session-a": [.init(linkedSemesterResponse)], "catalog:session-a": [.init(linkedCatalogResponse)]])
        let model = makeModel(store, transport)
        await model.restore(); await model.refreshCatalog()
        XCTAssertTrue(model.todayCourses.allSatisfy { model.isSignInDisabled(for: $0) })
        _ = await model.setCoursePreferences(CoursePreferences(confirmation: .enabled, autoSign: .disabled), for: "stable-course")
        XCTAssertEqual(Set(store.vault.accounts[0].preferences.courses.keys), ["stable-course"])
        XCTAssertTrue(model.todayCourses.allSatisfy { !model.isSignInDisabled(for: $0) && model.effectiveConfirmation(for: $0) })
    }

    func testCoTeacherAttendanceRequestsAreCanonicalAndCoalesced() async throws {
        let gate = ResponseGate()
        let transport = PlannedTransport(["courses:session-a": [.init(coTeacherResponse())],
            "semesters:session-a": [.init(linkedSemesterResponse)], "catalog:session-a": [.init(linkedCatalogResponse)],
            "attendance:session-a": [.init(linkedAttendanceResponse, gate: gate)]])
        let model = makeModel(MemoryAccountStore(accounts: [accountA], active: accountA.id), transport)
        await model.restore(); await model.refreshCatalog()
        let first = Task { await model.refreshAttendance(for: "teaching-2") }
        await assertEventually { await transport.count("attendance:session-a") == 1 }
        let second = Task { await model.refreshAttendance(for: "teaching-3") }
        await gate.open(); await first.value; await second.value
        let requests = await transport.requests
        let reads = requests.filter { $0.url?.path.hasSuffix("get_my_course_sign_detail.action") == true }
        XCTAssertEqual(reads.count, 1)
        XCTAssertTrue(String(data: try XCTUnwrap(reads.first?.httpBody), encoding: .utf8)?.contains("courseId=stable-course") == true)
        XCTAssertEqual(model.attendanceByCourse["stable-course"]?.records.count, 1)
        XCTAssertEqual(model.attendanceByCourse["stable-course"]?.signedCount, 1)
        XCTAssertNil(model.attendanceByCourse["teaching-2"])
        XCTAssertNil(model.attendanceErrors["stable-course"])
    }

    func testCoTeacherSignSubmitsOriginalMeetingAndUpdatesOnlyThatMeeting() async throws {
        let transport = PlannedTransport(["courses:session-a": [.init(coTeacherResponse()), .init(coTeacherResponse(signedTeacher: 2))],
            "semesters:session-a": [.init(linkedSemesterResponse)], "catalog:session-a": [.init(linkedCatalogResponse)],
            "clock": [.init(clockResponse)], "sign": [.init(#"{"STATUS":"0","result":{"stuSignStatus":"1"}}"#)]])
        let model = makeModel(MemoryAccountStore(accounts: [accountA], active: accountA.id), transport)
        await model.restore(); await model.refreshCatalog()
        let course = try XCTUnwrap(model.todayCourses.first { $0.courseId == "teaching-2" })
        await model.sign(course)
        let requests = await transport.requests
        let submission = try XCTUnwrap(requests.first { $0.url?.path.hasSuffix("stu_scan_sign.action") == true })
        let fields = URLComponents(url: submission.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(fields.first { $0.name == "courseSchedId" }?.value, "1234562")
        XCTAssertEqual(model.todayCourses.filter(\.signed).map(\.id), ["1234562"])
        XCTAssertEqual(model.records.first?.courseId, "stable-course")
        XCTAssertEqual(model.todayCourses.count, 3)
    }

    private func scheduleSemesterResponse() -> String {
        let week = SchoolDate.week(containing: .now)
        return #"{"STATUS":"0","result":[{"code":"schedule-term","name":"测试学期","beginDate":"\#(SchoolDate.key(week[0]))","endDate":"\#(SchoolDate.key(week[6]))","yearStatus":"1"}]}"#
    }

    private func scheduleWeekResponse(name: String = "课程") -> String {
        let today = SchoolDate.key(.now)
        let result: [[String: Any]] = SchoolDate.week(containing: .now).map { date in
            let entries: [[String: Any]] = SchoolDate.key(date) == today ? [[
                "id": "1234567", "courseId": "stable-course", "courseName": name, "teacherName": "教师",
                "classBeginTime": "08:00", "classEndTime": "09:40", "signStatus": "0"
            ]] : []
            return ["dateStr": SchoolDate.key(date), "schedData": entries]
        }
        return String(data: try! JSONSerialization.data(withJSONObject: ["STATUS": "0", "result": result]), encoding: .utf8)!
    }

    func testCourseScheduleReadsHistoricalCacheWithoutMovingEitherSelection() async throws {
        let day = "20260107"
        let term = SchoolSemester(id: "history", name: "历史学期", beginDate: day, endDate: day, isCurrent: false)
        let meeting = Course(id: "old", courseId: "teacher-old", courseNumber: "CS1", name: "历史课程", teacher: "甲", classroom: "B203", beginTime: "08:00", endTime: "10:00", day: day)
        defaults.set(try JSONEncoder().encode([SemesterScheduleCache(semester: term, courses: [meeting], updatedAt: .now)]), forKey: "semester-schedules-\(accountA.id)")
        let directory = #"{"STATUS":"0","result":[{"course_id":"old-catalog","courseNum":"CS1","course_name":"历史课程","semesterId":"history"}]}"#
        let transport = PlannedTransport(["courses:session-a": [.init(courseResponse("今日"))], "catalog:session-a": [.init(directory)]])
        let model = makeModel(MemoryAccountStore(accounts: [accountA], active: accountA.id), transport)
        await model.restore()
        let selectedDate = model.selectedDate
        let selectedSemester = model.selectedSemester
        let course = CatalogCourse(id: "old-catalog", number: "CS1", name: "历史课程", teacher: "", classroom: nil, semesterId: term.id, beginDate: "", endDate: "")
        await model.loadCourseSchedule(for: course)
        var publications = 0
        let observation = model.objectWillChange.sink { publications += 1 }
        defer { observation.cancel() }
        await model.loadCourseSchedule(for: course)
        XCTAssertEqual(publications, 0, "A fresh schedule without an error must not publish unchanged state")
        XCTAssertEqual(model.selectedDate, selectedDate)
        XCTAssertEqual(model.selectedSemester, selectedSemester)
        XCTAssertEqual(model.courseSchedulePresentation(for: course)?.meetings.count, 1)
        XCTAssertNil(model.courseScheduleErrors[term.id])
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2, "A fresh historical semester needs only its directory, then reuses both caches")
    }

    func testCourseScheduleEmptyCompleteAndIncompleteAreDistinguishable() async throws {
        let term = SchoolSemester(id: "history", name: "历史学期", beginDate: "20260107", endDate: "20260107", isCurrent: false)
        defaults.set(try JSONEncoder().encode([SemesterScheduleCache(semester: term, courses: [], updatedAt: .now)]), forKey: "semester-schedules-\(accountA.id)")
        let directory = #"{"STATUS":"0","result":[{"course_id":"old-catalog","courseNum":"CS1","course_name":"历史课程","semesterId":"history"}]}"#
        let transport = PlannedTransport(["courses:session-a": [.init(courseResponse("今日"))], "catalog:session-a": [.init(directory)]])
        let model = makeModel(MemoryAccountStore(accounts: [accountA], active: accountA.id), transport)
        await model.restore()
        let course = CatalogCourse(id: "old-catalog", number: "CS1", name: "历史课程", teacher: "", classroom: nil, semesterId: term.id, beginDate: "", endDate: "")
        await model.loadCourseSchedule(for: course)
        XCTAssertTrue(try XCTUnwrap(model.courseSchedulePresentation(for: course)).meetings.isEmpty)
        XCTAssertNotNil(model.semesterSchedules[term.id])
        let unknown = CatalogCourse(id: "missing", number: "CS2", name: "未知", teacher: "", classroom: nil, semesterId: "unknown", beginDate: "", endDate: "")
        await model.loadCourseSchedule(for: unknown)
        XCTAssertNil(model.courseSchedulePresentation(for: unknown))
        XCTAssertNotNil(model.courseScheduleErrors[unknown.semesterId])
    }

    func testCourseScheduleLoadJoinsWeekSyncAndPreservesNewerDailyResult() async throws {
        let term = SchoolSemester(id: "schedule-term", name: "测试学期", beginDate: SchoolDate.key(.now), endDate: SchoolDate.key(.now), isCurrent: true)
        let gate = ResponseGate()
        let directory = #"{"STATUS":"0","result":[{"course_id":"stable-course","courseNum":"CS1","course_name":"课程","semesterId":"schedule-term"}]}"#
        let transport = PlannedTransport([
            "courses:session-a": [.init(courseResponse("课程")), .init(courseResponse("新安排"))],
            "semesters:session-a": [.init(scheduleSemesterResponse())],
            "weekly:session-a": [.init(scheduleWeekResponse(), gate: gate)],
            "catalog:session-a": [.init(directory)]
        ])
        defaults.set(try JSONEncoder().encode([SemesterScheduleCache(semester: term, courses: [], updatedAt: Date().addingTimeInterval(-8 * 24 * 60 * 60))]), forKey: "semester-schedules-\(accountA.id)")
        let model = makeModel(MemoryAccountStore(accounts: [accountA], active: accountA.id), transport)
        await model.restore()
        let course = CatalogCourse(id: "stable-course", number: "CS1", name: "课程", teacher: "", classroom: nil, semesterId: term.id, beginDate: "", endDate: "")
        let sync = Task { await model.synchronizeSchedules(force: true) }
        await assertEventually { await transport.count("weekly:session-a") == 1 }
        let detail = Task { await model.loadCourseSchedule(for: course) }
        await assertEventually { await transport.count("catalog:session-a") == 1 }
        await model.refresh(on: .now)
        await gate.open()
        await sync.value
        await detail.value
        XCTAssertEqual(model.courseSchedulePresentation(for: course)?.meetings.first?.courses.first?.name, "新安排")
        let count = await transport.count("weekly:session-a")
        XCTAssertEqual(count, 1)
    }

    func testCourseScheduleFailureRetainsSnapshotAndBacksOff() async throws {
        let term = SchoolSemester(id: "history", name: "历史学期", beginDate: "20260107", endDate: "20260107", isCurrent: false)
        let updated = Date().addingTimeInterval(-8 * 24 * 60 * 60)
        let meeting = Course(id: "old", courseId: "catalog", name: "课程", beginTime: "08:00", endTime: "10:00", day: term.beginDate)
        defaults.set(try JSONEncoder().encode([SemesterScheduleCache(semester: term, courses: [meeting], updatedAt: updated)]), forKey: "semester-schedules-\(accountA.id)")
        let directory = #"{"STATUS":"0","result":[{"course_id":"catalog","courseNum":"CS1","course_name":"历史课程","semesterId":"history"}]}"#
        let terms = #"{"STATUS":"0","result":[{"code":"history","name":"历史学期","beginDate":"20260107","endDate":"20260107","yearStatus":"0"}]}"#
        let transport = PlannedTransport([
            "courses:session-a": [.init(courseResponse("今日"))], "catalog:session-a": [.init(directory)],
            "semesters:session-a": [.init(#"{"STATUS":"9","ERRMSG":"测试失败"}"#), .init(terms)],
            "weekly:session-a": [.init(#"{"STATUS":"0","result":[{"dateStr":"20260107","schedData":[]}]}"#)]
        ])
        let model = makeModel(MemoryAccountStore(accounts: [accountA], active: accountA.id), transport)
        await model.restore()
        let course = CatalogCourse(id: "catalog", number: "CS1", name: "历史课程", teacher: "", classroom: nil, semesterId: term.id, beginDate: "", endDate: "")
        await model.loadCourseSchedule(for: course)
        XCTAssertNotNil(model.courseScheduleErrors[term.id])
        XCTAssertEqual(model.semesterSchedules[term.id]?.updatedAt, updated)
        XCTAssertEqual(model.courseSchedulePresentation(for: course)?.meetings.count, 1)
        let before = await transport.requests.count
        await model.loadCourseSchedule(for: course)
        let after = await transport.requests.count
        XCTAssertEqual(before, after)

        // A successful refresh on the timetable clears this page's stale failure, even during backoff.
        await model.synchronizeSchedules(force: true, semester: term)
        let refreshed = await transport.requests.count
        await model.loadCourseSchedule(for: course)
        XCTAssertNil(model.courseScheduleErrors[term.id])
        let reused = await transport.requests.count
        XCTAssertEqual(refreshed, reused)
    }

    func testCourseScheduleLateResponseIsRejectedAfterAccountSwitch() async throws {
        let term = SchoolSemester(id: "history", name: "历史学期", beginDate: "20260107", endDate: "20260107", isCurrent: false)
        defaults.set(try JSONEncoder().encode([SemesterScheduleCache(semester: term, courses: [], updatedAt: .now)]), forKey: "semester-schedules-\(accountA.id)")
        let gate = ResponseGate()
        let directory = #"{"STATUS":"0","result":[{"course_id":"catalog","courseNum":"CS1","course_name":"历史课程","semesterId":"history"}]}"#
        let transport = PlannedTransport(["courses:session-a": [.init(courseResponse("甲"))], "courses:session-b": [.init(courseResponse("乙"))], "catalog:session-a": [.init(directory, gate: gate)]])
        let model = makeModel(MemoryAccountStore(accounts: [accountA, accountB], active: accountA.id), transport)
        await model.restore()
        let course = CatalogCourse(id: "catalog", number: "CS1", name: "历史课程", teacher: "", classroom: nil, semesterId: term.id, beginDate: "", endDate: "")
        let task = Task { await model.loadCourseSchedule(for: course) }
        await assertEventually { await transport.count("catalog:session-a") == 1 }
        await model.switchAccount(id: accountB.id)
        await gate.open()
        await task.value
        XCTAssertNil(model.courseSchedulePresentation(for: course))
        XCTAssertTrue(model.courseScheduleLoading.isEmpty)
        XCTAssertTrue(model.courseScheduleErrors.isEmpty)
    }

    func testCourseScheduleLoadsUncachedHistoricalSemesterWithoutChangingDate() async throws {
        let old = SchoolSemester(id: "history", name: "历史学期", beginDate: "20260107", endDate: "20260107", isCurrent: false)
        let terms = #"{"STATUS":"0","result":[{"code":"history","name":"历史学期","beginDate":"20260107","endDate":"20260107","yearStatus":"0"}]}"#
        let directory = #"{"STATUS":"0","result":[{"course_id":"catalog","courseNum":"CS1","course_name":"历史课程","semesterId":"history"}]}"#
        let week = #"{"STATUS":"0","result":[{"dateStr":"20260107","schedData":[{"id":"old","courseId":"catalog","courseName":"历史课程","classBeginTime":"08:00","classEndTime":"10:00"}]}]}"#
        let transport = PlannedTransport(["courses:session-a": [.init(courseResponse("今日"))],
                                          "catalog:session-a": [.init(directory)], "semesters:session-a": [.init(terms), .init(terms)],
                                          "weekly:session-a": [.init(week)]])
        let model = makeModel(MemoryAccountStore(accounts: [accountA], active: accountA.id), transport)
        await model.restore()
        let date = model.selectedDate
        let course = CatalogCourse(id: "catalog", number: "CS1", name: "历史课程", teacher: "", classroom: nil, semesterId: old.id, beginDate: "", endDate: "")
        await model.loadCourseSchedule(for: course)
        XCTAssertEqual(model.selectedDate, date)
        XCTAssertNil(model.selectedSemester)
        XCTAssertNotNil(model.semesterSchedules[old.id])
        XCTAssertNil(model.courseScheduleErrors[old.id])
        XCTAssertEqual(model.courseSchedulePresentation(for: course)?.meetings.count, 1)
        let weeks = await transport.count("weekly:session-a")
        XCTAssertEqual(weeks, 1)
    }

    func testLaterSemesterSyncCannotDowngradeConfirmedAttendance() async throws {
        let signed = courseResponse("课程").replacingOccurrences(of: "\"signStatus\":\"0\"", with: "\"signStatus\":\"1\"")
        let transport = PlannedTransport([
            "courses:session-a": [.init(signed)],
            "semesters:session-a": [.init(scheduleSemesterResponse())],
            "weekly:session-a": [.init(scheduleWeekResponse())]
        ])
        let store = MemoryAccountStore(accounts: [accountA], active: accountA.id)
        let model = makeModel(store, transport)
        await model.restore(); XCTAssertTrue(try XCTUnwrap(model.todayCourses.first).signed)
        await model.synchronizeSchedules()
        XCTAssertTrue(try XCTUnwrap(model.todayCourses.first).signed)
        XCTAssertNotNil(defaults.data(forKey: "attendance-state-\(accountA.id)"))
        let offline = makeModel(store, PlannedTransport([:]))
        await offline.restore()
        XCTAssertTrue(try XCTUnwrap(offline.todayCourses.first).signed)
    }

    func testSuccessfulSignConflictWaitsForEntryWithoutPolling() async throws {
        let schoolNow = CourseTime.parse(day: SchoolDate.key(.now), time: "08:30")!
        let signed = courseResponse("课程").replacingOccurrences(of: "\"signStatus\":\"0\"", with: "\"signStatus\":\"1\"")
        let transport = PlannedTransport([
            "courses:session-a": [.init(courseResponse("课程")), .init(courseResponse("课程")), .init(signed)],
            "clock": [.init("{\"STATUS\":\"0\",\"timestamp\":\(Int64(schoolNow.timeIntervalSince1970 * 1000))}")],
            "sign": [.init(#"{"STATUS":"0","ERRCODE":"0","result":{"stuSignStatus":"1","stuSignId":"record"}}"#)]
        ])
        let model = makeModel(MemoryAccountStore(accounts: [accountA], active: accountA.id), transport)
        await model.restore()
        await model.sign(try XCTUnwrap(model.todayCourses.first))
        let course = try XCTUnwrap(model.todayCourses.first)
        XCTAssertTrue(course.signed)
        XCTAssertEqual(model.attendanceLabel(for: course), "已签到 · 待核验")
        for second in [5, 30, 120, 150, 3600] {
            model.attendanceNow = { schoolNow.addingTimeInterval(Double(second)) }
            await model.foregroundTick()
            XCTAssertEqual(model.attendanceLabel(for: course), "已签到 · 待核验")
        }
        let reads = await transport.count("courses:session-a")
        let details = await transport.count("attendance:session-a")
        let signs = await transport.count("sign")
        XCTAssertEqual(reads, 2); XCTAssertEqual(details, 0); XCTAssertEqual(signs, 1)
        await model.enterDay(.now)
        let after = await transport.count("courses:session-a")
        XCTAssertEqual(after, 3)
        XCTAssertEqual(model.attendanceLabel(for: course), "已签到")
    }

    func testConcurrentPostSignDayReadersShareFailureWithoutAutomaticRetry() async throws {
        let schoolNow = CourseTime.parse(day: SchoolDate.key(.now), time: "08:30")!
        let gate = ResponseGate()
        let transport = PlannedTransport([
            "courses:session-a": [.init(courseResponse("课程")), .init("invalid response", gate: gate)],
            "clock": [.init("{\"STATUS\":\"0\",\"timestamp\":\(Int64(schoolNow.timeIntervalSince1970 * 1000))}")],
            "sign": [.init(#"{"STATUS":"0","ERRCODE":"0","result":{"stuSignStatus":"1","stuSignId":"record"}}"#)]
        ])
        let model = makeModel(MemoryAccountStore(accounts: [accountA], active: accountA.id), transport)
        await model.restore()
        let course = try XCTUnwrap(model.todayCourses.first)
        let signing = Task { await model.sign(course) }
        await assertEventually { await transport.count("courses:session-a") == 2 }
        var joined = false
        let reading = Task { joined = true; await model.refresh(on: .now) }
        await assertEventually { joined }
        await gate.open(); await signing.value; await reading.value
        let reads = await transport.count("courses:session-a")
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(model.attendanceLabel(for: course), "已签到 · 待核验")
    }

    func testConcurrentDetailReadersShareFailureWithoutAutomaticRetry() async throws {
        let schoolNow = CourseTime.parse(day: SchoolDate.key(.now), time: "08:30")!
        let gate = ResponseGate()
        let transport = PlannedTransport([
            "courses:session-a": [.init(courseResponse("课程")), .init(courseResponse("课程"))],
            "clock": [.init("{\"STATUS\":\"0\",\"timestamp\":\(Int64(schoolNow.timeIntervalSince1970 * 1000))}")],
            "sign": [.init(#"{"STATUS":"0","ERRCODE":"0","result":{"stuSignStatus":"1","stuSignId":"record"}}"#)],
            "attendance:session-a": [.init("invalid response", gate: gate)]
        ])
        let model = makeModel(MemoryAccountStore(accounts: [accountA], active: accountA.id), transport)
        await model.restore()
        let course = try XCTUnwrap(model.todayCourses.first)
        await model.sign(course)
        let first = Task { await model.refreshAttendance(for: "stable-course") }
        await assertEventually { await transport.count("attendance:session-a") == 1 }
        var joined = false
        let second = Task { joined = true; await model.refreshAttendance(for: "stable-course", force: true) }
        await assertEventually { joined }
        await gate.open(); await first.value; await second.value
        let reads = await transport.count("attendance:session-a")
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(model.attendanceLabel(for: course), "已签到 · 待核验")
    }

    func testManualSignUsesPageStateWithoutAnotherPreflightRead() async throws {
        let schoolNow = CourseTime.parse(day: SchoolDate.key(.now), time: "08:32")!
        let gate = ResponseGate()
        let transport = PlannedTransport([
            "courses:session-a": [.init(courseResponse("课程")), .init(courseResponse("课程"))],
            "clock": [.init("{\"STATUS\":\"0\",\"timestamp\":\(Int64(schoolNow.timeIntervalSince1970 * 1000))}")],
            "sign": [.init(#"{"STATUS":"0","ERRCODE":"0","result":{"stuSignStatus":"1","stuSignId":"record"}}"#, gate: gate)]
        ])
        let model = makeModel(MemoryAccountStore(accounts: [accountA], active: accountA.id), transport)
        await model.restore()
        model.setConfirmation(false)
        model.attendanceNow = { schoolNow }
        let course = try XCTUnwrap(model.todayCourses.first)
        let signing = Task { await model.signManually(course) }
        await assertEventually { await transport.count("sign") == 1 }
        let before = await transport.count("courses:session-a")
        XCTAssertEqual(before, 1)
        await gate.open(); await signing.value
        let after = await transport.count("courses:session-a")
        XCTAssertEqual(after, 2)
        model.attendanceNow = { schoolNow.addingTimeInterval(120) }
        await model.signManually(course)
        let repeated = await transport.count("courses:session-a")
        let signs = await transport.count("sign")
        XCTAssertEqual(repeated, 2); XCTAssertEqual(signs, 1)
    }

    func testWeekNavigationDoesNotReadHiddenDayAndEnteringDayIsThrottled() async throws {
        let transport = PlannedTransport([
            "courses:session-a": [.init(courseResponse("课程")), .init(#"{"STATUS":"0","result":[]}"#)],
            "semesters:session-a": [.init(scheduleSemesterResponse())],
            "weekly:session-a": [.init(scheduleWeekResponse())]
        ])
        let model = makeModel(MemoryAccountStore(accounts: [accountA], active: accountA.id), transport)
        await model.restore(); await model.synchronizeSchedules()
        let date = try XCTUnwrap(SchoolDate.week(containing: .now).first { SchoolDate.key($0) != SchoolDate.key(.now) })
        model.scheduleMode = .week
        await model.selectDate(date); await model.foregroundTick()
        let before = await transport.count("courses:session-a")
        XCTAssertEqual(before, 1)
        model.scheduleMode = .day
        await model.openScheduleDate(date); await model.openScheduleDate(date)
        let after = await transport.count("courses:session-a")
        XCTAssertEqual(after, 2)
    }

    func testDisabledAutoSignDoesNotJournalPreviewsSyncOrPreferenceChanges() async {
        let transport = PlannedTransport(["courses:session-a": [.init(courseResponse("课程")), .init(courseResponse("调课课程"))]])
        let model = makeModel(MemoryAccountStore(accounts: [accountA], active: accountA.id), transport)
        await model.restore()
        _ = model.autoSignPlans; _ = model.autoSignPlans
        model.setConfirmation(true)
        model.setAutoSignRule(.init(offsetMinutes: 30))
        _ = await model.setCoursePreferences(.init(autoSignRule: .init(retryMinutes: 5)), for: "stable-course")
        await model.refresh()
        await model.foregroundTick()
        XCTAssertEqual(model.autoSignSettingsStatus, "已关闭")
        XCTAssertTrue(model.autoSignExecutions.isEmpty)
        XCTAssertTrue(model.autoSignHistory.isEmpty)
        XCTAssertNil(defaults.data(forKey: "auto-sign-\(accountA.id)"))
    }

    func testGlobalOffBlocksEnabledCourseAndOccurrenceWithoutHistory() async throws {
        var account = accountA
        account.preferences.autoSignRunning = false
        account.preferences.courses["stable-course"] = .init(autoSign: .enabled)
        let transport = PlannedTransport(["courses:session-a": [.init(courseResponse("课程"))]])
        let model = makeModel(MemoryAccountStore(accounts: [account], active: account.id), transport)
        await model.restore()
        let course = try XCTUnwrap(model.todayCourses.first)
        model.setAutoSignOccurrence(.init(enabled: true, policy: .init(offsetMinutes: 30)), for: course)
        await model.foregroundTick()
        XCTAssertFalse(model.autoSignRunning)
        XCTAssertTrue(model.autoSignHistory.isEmpty)
        XCTAssertTrue(model.autoSignExecutions.isEmpty)
        let count = await transport.count("sign")
        XCTAssertEqual(count, 0)
    }

    func testLateEnableSkipsExpiredPlanInsteadOfCreatingMissedRecord() async throws {
        let store = MemoryAccountStore(accounts: [accountA], active: accountA.id)
        let model = makeModel(store, PlannedTransport(["courses:session-a": [.init(courseResponse("课程"))]]))
        await model.restore()
        model.setAutoSign(true)
        model.setAutoSignRunning(true)
        await model.foregroundTick()
        XCTAssertEqual(try XCTUnwrap(model.autoSignPlans.first).stage, .skipped)
        XCTAssertTrue(model.autoSignHistory.isEmpty)
        XCTAssertEqual(store.vault.accounts[0].preferences.autoSignRunningSince, model.attendanceNow())
        XCTAssertEqual(store.vault.accounts[0].preferences.autoSignDefaultSince, model.attendanceNow())
    }

    func testFutureEnabledPlanIsOnlyPreviewUntilDue() async {
        let model = makeModel(MemoryAccountStore(accounts: [accountA], active: accountA.id),
                              PlannedTransport(["courses:session-a": [.init(courseResponse("课程"))]]))
        await model.restore()
        model.setAutoSignRule(.init(offsetMinutes: 60))
        model.setAutoSign(true)
        model.setAutoSignRunning(true)
        await model.foregroundTick()
        XCTAssertEqual(model.autoSignPlans.first?.stage, .planned)
        XCTAssertTrue(model.autoSignExecutions.isEmpty)
        XCTAssertTrue(model.autoSignHistory.isEmpty)
    }

    func testExistingEnabledMissedPlanRecordsRealMissOnce() async throws {
        var account = accountA
        account.preferences.autoSignEnabled = true
        let model = makeModel(MemoryAccountStore(accounts: [account], active: account.id),
                              PlannedTransport(["courses:session-a": [.init(courseResponse("课程"))], "clock": [.init(clockResponse)]]))
        await model.restore()
        XCTAssertTrue(model.autoSignExecutions.isEmpty)
        await model.foregroundTick()
        let value = try XCTUnwrap(model.autoSignHistory.first)
        XCTAssertEqual(value.stage, .missed)
        XCTAssertEqual(value.submissions, 0)
        XCTAssertEqual(value.courseName, "课程")
        XCTAssertNotNil(value.startedAt)
        await model.foregroundTick()
        XCTAssertEqual(model.autoSignHistory.count, 1)
        XCTAssertEqual(model.autoSignHistory.first?.events.count, value.events.count)
    }

    func testManualBeforeAutoDueOnlyKeepsHiddenTakeover() async throws {
        var account = accountA
        account.preferences.autoSignEnabled = true
        account.preferences.autoSignRule = .init(offsetMinutes: 60)
        let now = try XCTUnwrap(CourseTime.parse(day: SchoolDate.key(.now), time: "08:30"))
        let transport = PlannedTransport([
            "courses:session-a": [.init(courseResponse("课程")), .init(courseResponse("课程"))],
            "clock": [.init("{\"STATUS\":\"0\",\"timestamp\":\(Int64(now.timeIntervalSince1970 * 1000))}")],
            "sign": [.init(#"{"STATUS":"0","ERRCODE":"0","result":{"stuSignStatus":"1"}}"#)]
        ])
        let model = makeModel(MemoryAccountStore(accounts: [account], active: account.id), transport)
        await model.restore()
        await model.signManually(try XCTUnwrap(model.todayCourses.first))
        XCTAssertEqual(model.records.count, 1)
        XCTAssertTrue(model.autoSignHistory.isEmpty)
        let marker = try XCTUnwrap(model.autoSignExecutions.values.first)
        XCTAssertNil(marker.startedAt)
        XCTAssertEqual(marker.stage, .skipped)
        XCTAssertEqual(marker.events.last?.kind, .manualTakeover)
        model.attendanceNow = { now.addingTimeInterval(1800) }
        await model.foregroundTick()
        let count = await transport.count("sign")
        XCTAssertEqual(count, 1)
    }

    func testBrokenAutoSignJournalDoesNotShowGlobalErrorWhenOff() async {
        defaults.set(Data("broken-ledger".utf8), forKey: "auto-sign-\(accountA.id)")
        let model = makeModel(MemoryAccountStore(accounts: [accountA], active: accountA.id),
                              PlannedTransport(["courses:session-a": [.init(courseResponse("课程"))]]))
        await model.restore()
        XCTAssertNil(model.errorMessage)
        XCTAssertNotNil(model.autoSignError)
        XCTAssertEqual(model.autoSignSettingsStatus, "已关闭")
        model.setAutoSignRunning(true)
        XCTAssertEqual(model.autoSignSettingsStatus, "已暂停")
        await model.foregroundTick()
        XCTAssertTrue(model.autoSignExecutions.isEmpty)
    }

    func testSingleEnabledOccurrenceOverridesExcludedCourseWhileGlobalIsOn() async throws {
        let now = try XCTUnwrap(CourseTime.parse(day: SchoolDate.key(.now), time: "08:30"))
        let transport = PlannedTransport([
            "courses:session-a": [.init(courseResponse("课程")), .init(courseResponse("课程"))],
            "clock": [.init("{\"STATUS\":\"0\",\"timestamp\":\(Int64(now.timeIntervalSince1970 * 1000))}")],
            "sign": [.init(#"{"STATUS":"0","ERRCODE":"0","result":{"stuSignStatus":"1"}}"#)]
        ])
        var account = accountA
        account.preferences.courses["stable-course"] = .init(autoSign: .disabled)
        let model = makeModel(MemoryAccountStore(accounts: [account], active: account.id), transport)
        await model.restore()
        XCTAssertFalse(model.autoSignEnabled)
        model.setAutoSignRunning(true)
        model.setAutoSignOccurrence(.init(enabled: true, policy: .init(offsetMinutes: 30)),
                                    for: try XCTUnwrap(model.todayCourses.first))
        await model.foregroundTick()
        let count = await transport.count("sign")
        XCTAssertEqual(count, 1)
        XCTAssertEqual(model.autoSignHistory.first?.submissions, 1)
        XCTAssertEqual(model.autoSignHistory.first?.stage, .signed)
    }

    func testCourseAndOccurrenceSettingsDoNotTurnOnGlobalSwitch() async throws {
        let model = makeModel(MemoryAccountStore(accounts: [accountA], active: accountA.id),
                              PlannedTransport(["courses:session-a": [.init(courseResponse("课程"))]]))
        await model.restore()
        _ = await model.setCoursePreferences(.init(autoSign: .enabled), for: "stable-course")
        model.setAutoSignOccurrence(.init(enabled: true, policy: .init(offsetMinutes: 30)),
                                    for: try XCTUnwrap(model.todayCourses.first))
        XCTAssertFalse(model.autoSignRunning)
        XCTAssertEqual(model.autoSignSettingsStatus, "已关闭")
        await model.foregroundTick()
        XCTAssertTrue(model.autoSignExecutions.isEmpty)
        XCTAssertTrue(model.autoSignHistory.isEmpty)
    }

    func testSingleGlobalSwitchEnablesInheritedCourseAndMirrorsCompatibilityFields() async throws {
        let now = try XCTUnwrap(CourseTime.parse(day: SchoolDate.key(.now), time: "08:30"))
        let store = MemoryAccountStore(accounts: [accountA], active: accountA.id)
        let transport = PlannedTransport([
            "courses:session-a": [.init(courseResponse("课程")), .init(courseResponse("课程"))],
            "clock": [.init("{\"STATUS\":\"0\",\"timestamp\":\(Int64(now.timeIntervalSince1970 * 1000))}")],
            "sign": [.init(#"{"STATUS":"0","ERRCODE":"0","result":{"stuSignStatus":"1"}}"#)]
        ])
        let model = makeModel(store, transport)
        await model.restore()
        model.setAutoSignRule(.init(offsetMinutes: 30))
        XCTAssertFalse(model.autoSignRunning)
        XCTAssertTrue(model.coursePreferences.isEmpty)
        model.setAutoSignRunning(true)
        XCTAssertTrue(model.autoSignEnabled)
        XCTAssertTrue(model.effectiveAutoSign(for: "stable-course"))
        await model.foregroundTick()
        let signs = await transport.count("sign")
        XCTAssertEqual(signs, 1)
        XCTAssertEqual(model.autoSignHistory.first?.submissions, 1)
        XCTAssertEqual(store.vault.accounts[0].preferences.autoSignRunning, true)
        XCTAssertTrue(store.vault.accounts[0].preferences.autoSignEnabled)
        model.setAutoSign(false)
        XCTAssertFalse(model.autoSignRunning, "兼容入口也只控制同一个总开关")
        XCTAssertFalse(model.autoSignEnabled)
        XCTAssertEqual(store.vault.accounts[0].preferences.autoSignRunning, false)
        XCTAssertFalse(store.vault.accounts[0].preferences.autoSignEnabled)
        XCTAssertEqual(model.autoSignHistory.first?.submissions, 1)
    }

    func testOldSplitRunningOnNormalizesInheritedParticipationWithoutCatchingUpPastClass() async throws {
        var account = accountA
        account.preferences.autoSignRunning = true
        XCTAssertFalse(account.preferences.autoSignEnabled)
        let store = MemoryAccountStore(accounts: [account, accountB], active: account.id)
        let transport = PlannedTransport([
            "courses:session-a": [.init(courseResponse("过去课程"))],
            "courses:session-b": [.init(courseResponse("乙课程"))]
        ])
        let model = makeModel(store, transport)
        await model.restore()
        XCTAssertTrue(model.autoSignRunning)
        XCTAssertTrue(model.autoSignEnabled)
        XCTAssertEqual(store.vault.accounts[0].preferences.autoSignRunning, true)
        XCTAssertTrue(store.vault.accounts[0].preferences.autoSignEnabled)
        XCTAssertEqual(store.vault.accounts[0].preferences.autoSignDefaultSince, model.attendanceNow())
        XCTAssertNil(store.vault.accounts[0].preferences.autoSignRunningSince)
        XCTAssertEqual(model.autoSignPlans.first?.stage, .skipped)
        await model.foregroundTick()
        XCTAssertTrue(model.autoSignHistory.isEmpty)
        model.courses.append(.init(id: "1234568", name: "未来课程", beginTime: "09:00", endTime: "10:40", day: SchoolDate.key(.now)))
        XCTAssertTrue(model.autoSignPlans.first { $0.course.id == "1234568" }!.isParticipating)
        await model.switchAccount(id: accountB.id)
        XCTAssertFalse(model.autoSignRunning)
        XCTAssertFalse(model.autoSignEnabled)
        XCTAssertTrue(store.vault.accounts.first { $0.id == account.id }!.preferences.autoSignIsRunning)
    }

    func testLegacyCourseOnlyOptInMigrationPreservesExplicitRulesAndUnknownSubmissionEvidence() async throws {
        var account = accountA
        account.preferences.courses["stable-course"] = .init(autoSign: .enabled)
        account.preferences.courses["excluded-course"] = .init(autoSign: .disabled)
        let now = try XCTUnwrap(CourseTime.parse(day: SchoolDate.key(.now), time: "08:30"))
        let course = Course(id: "1234567", name: "课程", beginTime: "08:00", endTime: "09:40", day: SchoolDate.key(.now))
        let key = AutoSignPlanner.key(account: account.id, course: course)
        var execution = AutoSignExecution(key: key, now: now.addingTimeInterval(-120))
        execution.begin(course: course, now: now.addingTimeInterval(-120))
        execution.submissions = 1; execution.lastSubmissionAt = now.addingTimeInterval(-120)
        execution.negativeReads = 1; execution.firstNegativeAt = now.addingTimeInterval(-60)
        execution.transition(.verifying, now: now.addingTimeInterval(-60), message: "提交结果未知", nextAt: now)
        try UserDefaultsAutoSignStore(defaults: defaults).save(accountID: account.id, executions: [key: execution])
        let store = MemoryAccountStore(accounts: [account], active: account.id)
        let model = makeModel(store, PlannedTransport(["courses:session-a": [.init(courseResponse("课程"))]]))
        await model.restore()
        XCTAssertTrue(model.autoSignRunning)
        XCTAssertTrue(model.autoSignEnabled)
        XCTAssertTrue(model.effectiveAutoSign(for: "stable-course"))
        XCTAssertFalse(model.effectiveAutoSign(for: "excluded-course"))
        let restored = try XCTUnwrap(model.autoSignExecutions[key])
        XCTAssertEqual(restored.submissions, execution.submissions)
        XCTAssertEqual(restored.lastSubmissionAt, execution.lastSubmissionAt)
        XCTAssertEqual(restored.nextAt, execution.nextAt)
        XCTAssertEqual(restored.negativeReads, execution.negativeReads)
        XCTAssertEqual(restored.firstNegativeAt, execution.firstNegativeAt)
        XCTAssertEqual(restored.stage, execution.stage)
        XCTAssertEqual(restored.startedAt, execution.startedAt)
        XCTAssertEqual(Array(restored.events.prefix(execution.events.count)), execution.events)
        XCTAssertNil(store.vault.accounts[0].preferences.autoSignRunningSince)
        XCTAssertEqual(store.vault.accounts[0].preferences.autoSignDefaultSince, now)
        XCTAssertEqual(store.vault.accounts[0].preferences.courses, account.preferences.courses)
        XCTAssertTrue(model.autoSignPlans.first!.isParticipating, "旧明确开启课次不受新增继承边界影响")
    }

    func testFailedSingleControlMigrationKeepsSafeBoundaryAndBlocksAutomaticSubmission() async {
        var account = accountA
        account.preferences.autoSignRunning = true
        account.preferences.autoSignRule = .init(offsetMinutes: 30)
        let store = MemoryAccountStore(accounts: [account], active: account.id)
        store.failWrites = true
        let transport = PlannedTransport(["courses:session-a": [.init(courseResponse("课程"))]])
        let model = makeModel(store, transport)
        await model.restore()
        await model.foregroundTick()
        XCTAssertTrue(model.autoSignRunning)
        XCTAssertTrue(model.autoSignEnabled)
        XCTAssertEqual(model.autoSignSettingsStatus, "已暂停")
        XCTAssertNotNil(model.autoSignError)
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.autoSignHistory.isEmpty)
        let signs = await transport.count("sign")
        XCTAssertEqual(signs, 0)
    }

    func testClockFailureShowsAutoSignNetworkStateWithoutGlobalErrorOrSubmission() async {
        var account = accountA
        account.preferences.autoSignEnabled = true
        account.preferences.autoSignRule = .init(offsetMinutes: 30)
        let transport = PlannedTransport([
            "courses:session-a": [.init(courseResponse("课程"))],
            "clock": [.init("invalid"), .init("invalid")]
        ])
        let model = makeModel(MemoryAccountStore(accounts: [account], active: account.id), transport)
        await model.restore()
        await model.foregroundTick()
        let eventCount = model.autoSignHistory.first?.events.count
        XCTAssertEqual(model.autoSignRuntimeStatus, "等待网络")
        XCTAssertNotNil(model.autoSignError)
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.autoSignHistory.isEmpty)
        await model.foregroundTick()
        XCTAssertEqual(model.autoSignHistory.first?.events.count, eventCount)
        let signCount = await transport.count("sign")
        XCTAssertEqual(signCount, 0)
    }

    func testStructurallyDamagedAutoSignStatePausesWithoutSubmittingOrOverwriting() async throws {
        var account = accountA
        account.preferences.autoSignEnabled = true
        account.preferences.autoSignRule = .init(offsetMinutes: 30)
        let key = "\(account.id)|\(SchoolDate.key(.now))|1234567"
        var execution = AutoSignExecution(key: key, now: .now)
        execution.submissions = 1
        let original = try JSONEncoder().encode(AutoSignLedger(accountID: account.id, executions: [key: execution]))
        defaults.set(original, forKey: "auto-sign-\(account.id)")
        let transport = PlannedTransport(["courses:session-a": [.init(courseResponse("课程"))]])
        let model = makeModel(MemoryAccountStore(accounts: [account], active: account.id), transport)
        await model.restore()
        await model.foregroundTick()
        XCTAssertEqual(model.autoSignSettingsStatus, "已暂停")
        XCTAssertNotNil(model.autoSignError)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(defaults.data(forKey: "auto-sign-\(account.id)"), original)
        let signs = await transport.count("sign")
        XCTAssertEqual(signs, 0)
    }

    func testManualTakeoverDuringRetryReadCannotBeOverwrittenByLateSchoolResult() async throws {
        let now = try XCTUnwrap(CourseTime.parse(day: SchoolDate.key(.now), time: "08:30"))
        let day = SchoolDate.key(.now)
        let course = Course(id: "1234567", name: "课程", beginTime: "08:00", endTime: "09:40", day: day)
        for signedSchoolReply in [false, true] {
            var account = accountA
            account.preferences.autoSignEnabled = true
            account.preferences.autoSignRule = .init(offsetMinutes: 30)
            let key = AutoSignPlanner.key(account: account.id, course: course)
            var execution = AutoSignExecution(key: key, now: now.addingTimeInterval(-120))
            execution.begin(course: course, now: now.addingTimeInterval(-120))
            execution.submissions = 1; execution.lastSubmissionAt = now.addingTimeInterval(-120)
            execution.transition(.verifying, now: now.addingTimeInterval(-120), message: "提交结果未知", nextAt: now)
            try UserDefaultsAutoSignStore(defaults: defaults).save(accountID: account.id, executions: [key: execution])
            let reply = signedSchoolReply ? courseResponse("课程").replacingOccurrences(of: "\"signStatus\":\"0\"", with: "\"signStatus\":\"1\"")
                : courseResponse("课程")
            let gate = ResponseGate()
            let transport = PlannedTransport([
                "courses:session-a": [.init(courseResponse("课程")), .init(reply, gate: gate), .init(reply)],
                "clock": [.init("{\"STATUS\":\"0\",\"timestamp\":\(Int64(now.timeIntervalSince1970 * 1000))}")],
                "sign": [.init(#"{"STATUS":"0","result":{"stuSignStatus":"0"}}"#)]
            ])
            let model = makeModel(MemoryAccountStore(accounts: [account], active: account.id), transport)
            await model.restore()
            let automatic = Task { await model.foregroundTick() }
            await assertEventually { await transport.count("courses:session-a") == 2 }
            let manual = Task { await model.signManually(course) }
            await assertEventually { await transport.count("sign") == 1 }
            XCTAssertEqual(model.autoSignExecutions[key]?.stage, .skipped)
            await gate.open()
            await automatic.value; await manual.value
            let current = try XCTUnwrap(model.autoSignExecutions[key])
            XCTAssertEqual(current.stage, .skipped)
            XCTAssertEqual(current.submissions, 1)
            XCTAssertEqual(current.negativeReads, 0)
            XCTAssertTrue(current.events.contains { $0.kind == .manualTakeover })
            let signs = await transport.count("sign")
            XCTAssertEqual(signs, 1, "只有用户接管后的手动请求，不能复活自动任务")
            let stored = try UserDefaultsAutoSignStore(defaults: defaults).load(accountID: account.id)
            XCTAssertEqual(stored[key]?.stage, .skipped)
            XCTAssertTrue(stored[key]!.events.contains { $0.kind == .manualTakeover })
        }
    }

    func testPostponingOccurrenceDuringClockWaitPreventsEarlySubmission() async throws {
        var account = accountA
        account.preferences.autoSignEnabled = true
        account.preferences.autoSignRule = .init(offsetMinutes: 30)
        let now = try XCTUnwrap(CourseTime.parse(day: SchoolDate.key(.now), time: "08:30"))
        let gate = ResponseGate()
        let transport = PlannedTransport([
            "courses:session-a": [.init(courseResponse("课程"))],
            "clock": [.init("{\"STATUS\":\"0\",\"timestamp\":\(Int64(now.timeIntervalSince1970 * 1000))}", gate: gate)]
        ])
        let model = makeModel(MemoryAccountStore(accounts: [account], active: account.id), transport)
        await model.restore()
        let course = try XCTUnwrap(model.todayCourses.first)
        let automatic = Task { await model.foregroundTick() }
        await assertEventually { await transport.count("clock") == 1 }
        model.setAutoSignOccurrence(.init(at: now.addingTimeInterval(1800)), for: course)
        await gate.open(); await automatic.value
        let signs = await transport.count("sign")
        XCTAssertEqual(signs, 0)
        XCTAssertTrue(model.autoSignHistory.isEmpty, "校时期间推迟尚未到期任务，不创建执行历史")
        XCTAssertEqual(model.autoSignPlans.first?.plannedAt, now.addingTimeInterval(1800))
    }

    func testIncreasingRetryIntervalDuringClockWaitPreservesEvidenceWithoutEarlySubmission() async throws {
        var account = accountA
        account.preferences.autoSignEnabled = true
        account.preferences.autoSignRule = .init(offsetMinutes: 30)
        let now = try XCTUnwrap(CourseTime.parse(day: SchoolDate.key(.now), time: "08:30"))
        let course = Course(id: "1234567", name: "课程", beginTime: "08:00", endTime: "09:40", day: SchoolDate.key(.now))
        let key = AutoSignPlanner.key(account: account.id, course: course)
        var execution = AutoSignExecution(key: key, now: now.addingTimeInterval(-120))
        execution.begin(course: course, now: now.addingTimeInterval(-120))
        execution.submissions = 1; execution.lastSubmissionAt = now.addingTimeInterval(-120)
        execution.negativeReads = 2; execution.firstNegativeAt = now.addingTimeInterval(-90)
        execution.transition(.verifying, now: now.addingTimeInterval(-30), message: "学校已两次确认未签到", nextAt: now)
        try UserDefaultsAutoSignStore(defaults: defaults).save(accountID: account.id, executions: [key: execution])
        let gate = ResponseGate()
        let transport = PlannedTransport([
            "courses:session-a": [.init(courseResponse("课程"))],
            "clock": [.init("{\"STATUS\":\"0\",\"timestamp\":\(Int64(now.timeIntervalSince1970 * 1000))}", gate: gate)]
        ])
        let model = makeModel(MemoryAccountStore(accounts: [account], active: account.id), transport)
        await model.restore()
        let automatic = Task { await model.foregroundTick() }
        await assertEventually { await transport.count("clock") == 1 }
        model.setAutoSignOccurrence(.init(policy: .init(retryMinutes: 5)), for: course)
        await gate.open(); await automatic.value
        let signs = await transport.count("sign")
        XCTAssertEqual(signs, 0)
        XCTAssertEqual(model.autoSignExecutions[key]?.submissions, 1)
        XCTAssertEqual(model.autoSignExecutions[key]?.negativeReads, 2)
        XCTAssertEqual(model.autoSignExecutions[key]?.firstNegativeAt, execution.firstNegativeAt)
        XCTAssertEqual(model.autoSignExecutions[key]?.lastSubmissionAt, execution.lastSubmissionAt)
    }

    func testFuturePlanListExcludesYesterdayButKeepsTodayMissedAndSeparateHistory() async throws {
        var account = accountA
        account.preferences.autoSignEnabled = true
        let now = try XCTUnwrap(CourseTime.parse(day: SchoolDate.key(.now), time: "08:30"))
        let yesterday = SchoolDate.key(now.addingTimeInterval(-86_400))
        let oldCourse = Course(id: "1234560", name: "昨天课程", beginTime: "10:00", endTime: "11:40", day: yesterday)
        let key = AutoSignPlanner.key(account: account.id, course: oldCourse)
        var old = AutoSignExecution(key: key, now: now.addingTimeInterval(-80_000))
        old.begin(course: oldCourse, now: now.addingTimeInterval(-80_000))
        old.transition(.missed, now: now.addingTimeInterval(-80_000), message: "已错过自动执行时间")
        try UserDefaultsAutoSignStore(defaults: defaults).save(accountID: account.id, executions: [key: old])
        let model = makeModel(MemoryAccountStore(accounts: [account], active: account.id),
                              PlannedTransport(["courses:session-a": [.init(courseResponse("今天课程"))]]))
        await model.restore()
        model.courses.append(oldCourse)
        let plans = model.autoSignPlans
        XCTAssertFalse(plans.contains { $0.course.day == yesterday })
        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans.first?.stage, .missed)
        XCTAssertEqual(model.autoSignHistory.first?.courseName, "昨天课程")
        XCTAssertEqual(model.autoSignHistory.first?.key, key)
    }

    func testAutoSignDoesNotRepeatLocallySuccessfulManualSubmissionAfterSchoolCorrection() async throws {
        let now = CourseTime.parse(day: SchoolDate.key(.now), time: "08:30")!
        let clock = TestClock(now)
        var account = accountA
        account.preferences = .init(autoSignEnabled: true, courses: ["stable-course": .init(autoSign: .disabled)], autoSignRunning: true,
                                    autoSignRule: .init(offsetMinutes: 30))
        let transport = PlannedTransport([
            "courses:session-a": Array(repeating: .init(courseResponse("课程")), count: 4),
            "clock": [.init(clockJSON(now))],
            "sign": [.init(#"{"STATUS":"0","ERRCODE":"0","result":{"stuSignStatus":"1"}}"#)]
        ])
        let model = makeModel(MemoryAccountStore(accounts: [account], active: account.id), transport, clock: clock)
        await model.restore()
        let course = try XCTUnwrap(model.todayCourses.first)
        await model.signManually(course)
        clock.set(now.addingTimeInterval(30)); await model.refresh()
        XCTAssertEqual(model.attendanceStatus(for: course), .unsigned)
        _ = await model.setCoursePreferences(.init(autoSign: .enabled), for: "stable-course")
        model.setAutoSignOccurrence(.init(at: now.addingTimeInterval(60)), for: course)
        clock.set(now.addingTimeInterval(60)); await model.foregroundTick()
        let requests = await transport.count("sign")
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(model.autoSignHistory.isEmpty)
        XCTAssertEqual(model.autoSignPlans.first?.stage, .signed)
        XCTAssertEqual(model.autoSignPlans.first?.reason, "本机已有成功记录，不再自动提交")
    }

    func testEffectiveOccurrenceRetryControlsWakeAndRequiresTwoFreshReads() async throws {
        let now = CourseTime.parse(day: SchoolDate.key(.now), time: "08:30")!
        let clock = TestClock(now)
        var account = accountA
        account.preferences = .init(autoSignEnabled: true, autoSignRunning: true, autoSignRule: .init(offsetMinutes: 30, retryMinutes: 5))
        let transport = PlannedTransport([
            "courses:session-a": Array(repeating: .init(courseResponse("课程")), count: 5),
            "clock": [now, now.addingTimeInterval(60), now.addingTimeInterval(90)].map { .init(clockJSON($0)) },
            "sign": [.init(#"{"STATUS":"1","ERRMSG":"结果未知"}"#), .init(#"{"STATUS":"0","result":{"stuSignStatus":"1"}}"#)]
        ])
        let model = makeModel(MemoryAccountStore(accounts: [account], active: account.id), transport, clock: clock)
        await model.restore()
        model.setAutoSignOccurrence(.init(policy: .init(retryMinutes: 1)), for: try XCTUnwrap(model.todayCourses.first))
        await model.foregroundTick()
        XCTAssertEqual(model.autoSignHistory.first?.nextAt, now.addingTimeInterval(60))
        clock.set(now.addingTimeInterval(60)); await model.foregroundTick()
        XCTAssertEqual(model.autoSignHistory.first?.negativeReads, 1)
        let first = await transport.count("sign"); XCTAssertEqual(first, 1)
        clock.set(now.addingTimeInterval(90)); await model.foregroundTick()
        let second = await transport.count("sign"); XCTAssertEqual(second, 2)
        XCTAssertEqual(model.autoSignHistory.first?.submissions, 2)
        XCTAssertEqual(model.autoSignHistory.first?.stage, .signed)
    }

    func testLastUnknownSubmissionKeepsVerifyingWithoutFurtherSubmitAndReconcilesTerminalHistory() async throws {
        let now = CourseTime.parse(day: SchoolDate.key(.now), time: "08:30")!
        let clock = TestClock(now)
        var account = accountA
        account.preferences = .init(autoSignEnabled: true, autoSignRunning: true, autoSignRule: .init(offsetMinutes: 30, maxSubmissions: 1, retryMinutes: 1))
        let signed = courseResponse("课程").replacingOccurrences(of: "\"signStatus\":\"0\"", with: "\"signStatus\":\"1\"")
        let transport = PlannedTransport([
            "courses:session-a": [.init(courseResponse("课程")), .init(courseResponse("课程")), .init(courseResponse("课程")), .init(signed)],
            "clock": [now, now.addingTimeInterval(30), now.addingTimeInterval(90)].map { .init(clockJSON($0)) },
            "sign": [.init(#"{"STATUS":"1","ERRMSG":"结果未知"}"#)]
        ])
        let model = makeModel(MemoryAccountStore(accounts: [account], active: account.id), transport, clock: clock)
        await model.restore(); await model.foregroundTick()
        clock.set(now.addingTimeInterval(30)); await model.foregroundTick()
        XCTAssertEqual(model.autoSignHistory.first?.stage, .needsAttention)
        clock.set(now.addingTimeInterval(90)); await model.foregroundTick()
        let requests = await transport.count("sign")
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(model.autoSignHistory.first?.stage, .signed)
        XCTAssertEqual(model.autoSignHistory.first?.submissions, 1)
    }

    func testSchoolClockCalibratesBothLeadingAndLaggingDeviceBeforeMissedDecision() async throws {
        let school = CourseTime.parse(day: SchoolDate.key(.now), time: "08:30")!
        for offset in [-120.0, 120.0] {
            let clock = TestClock(school.addingTimeInterval(offset))
            var account = accountA
            account.preferences = .init(autoSignEnabled: true, autoSignRunning: true, autoSignRule: .init(offsetMinutes: 30))
            let transport = PlannedTransport([
                "courses:session-a": [.init(courseResponse("课程")), .init(courseResponse("课程"))],
                "clock": [.init(clockJSON(school))],
                "sign": [.init(#"{"STATUS":"0","result":{"stuSignStatus":"1"}}"#)]
            ])
            let model = makeModel(MemoryAccountStore(accounts: [account], active: account.id), transport, clock: clock)
            await model.restore(); await model.foregroundTick()
            let signs = await transport.count("sign")
            XCTAssertEqual(signs, 1, "设备偏差 \(offset) 秒仍按学校时间执行")
            XCTAssertEqual(model.autoSignHistory.first?.stage, .signed)
            XCTAssertFalse(try XCTUnwrap(model.autoSignHistory.first).events.contains { $0.stage == .missed })
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    func testInvalidOccurrenceTimeAndRulesKeepPreviousOverride() async throws {
        let model = makeModel(MemoryAccountStore(accounts: [accountA], active: accountA.id),
                              PlannedTransport(["courses:session-a": [.init(courseResponse("课程"))]]))
        await model.restore()
        let course = try XCTUnwrap(model.todayCourses.first)
        let start = try XCTUnwrap(course.startDate), end = try XCTUnwrap(course.endDate)
        let original = AutoSignOccurrenceOverride(at: start.addingTimeInterval(-25 * 60))
        model.setAutoSignOccurrence(original, for: course)
        let key = AutoSignPlanner.key(account: accountA.id, course: course)
        for invalid in [AutoSignOccurrenceOverride(at: start.addingTimeInterval(-25 * 60 - 1)), .init(at: end), .init(policy: .init(maxSubmissions: 4))] {
            model.setAutoSignOccurrence(invalid, for: course)
            XCTAssertEqual(model.autoSignOccurrences[key]?.at, original.at)
            XCTAssertNotNil(model.errorMessage)
        }
        XCTAssertTrue(model.autoSignHistory.isEmpty)
    }

    func testAutoSignRequestsNotificationPermissionAndDenialDoesNotStopExecution() async throws {
        let notifications = TestNotifications()
        notifications.status = .notDetermined
        notifications.authorizationError = NSError(domain: UNErrorDomain, code: UNError.Code.notificationsNotAllowed.rawValue)
        let model = makeModel(MemoryAccountStore(accounts: [accountA], active: accountA.id),
                              PlannedTransport(["courses:session-a": [.init(courseResponse("课程"))]]), notifications: notifications)
        await model.restore()
        model.setAutoSignRunning(true)
        await assertEventually { notifications.authorizationCalls == 1 && model.autoSignRule.notification == .none }
        XCTAssertTrue(model.autoSignRunning)
        XCTAssertTrue(model.notificationSettingsNeeded)
        XCTAssertTrue(model.autoSignError?.contains("结果通知已关闭") == true)
        model.setAutoSignRunning(false)
        model.setAutoSignRule(.init(notification: .none))
        model.setAutoSignRunning(true)
        await Task.yield()
        XCTAssertEqual(notifications.authorizationCalls, 1, "通知关闭时不再申请权限")
    }

    func testReminderRefreshRetainsAutoSignResultNotification() async throws {
        let now = CourseTime.parse(day: SchoolDate.key(.now), time: "08:30")!
        var account = accountA
        account.preferences = .init(autoSignEnabled: true, remindersEnabled: true, autoSignRunning: true,
                                    autoSignRule: .init(offsetMinutes: 30, notification: .all))
        let notifications = TestNotifications(); notifications.status = .authorized
        notifications.pendingIDs = ["old-reminder"]
        let transport = PlannedTransport([
            "courses:session-a": [.init(courseResponse("课程")), .init(courseResponse("课程"))],
            "clock": [.init(clockJSON(now))],
            "sign": [.init(#"{"STATUS":"0","result":{"stuSignStatus":"1"}}"#)]
        ])
        let model = makeModel(MemoryAccountStore(accounts: [account], active: account.id), transport, notifications: notifications)
        await model.restore(); await model.foregroundTick()
        XCTAssertFalse(notifications.pendingIDs.contains("old-reminder"))
        XCTAssertEqual(notifications.pendingIDs.filter { $0.hasPrefix("auto-sign-") }.count, 1)
    }

    func testMissedTaskNotifiesOnlyOnceAndOffAccountDoesNotReadClock() async throws {
        let school = CourseTime.parse(day: SchoolDate.key(.now), time: "08:30")!
        var account = accountA; account.preferences.autoSignEnabled = true
        let notifications = TestNotifications(); notifications.status = .authorized
        let transport = PlannedTransport(["courses:session-a": [.init(courseResponse("课程"))], "clock": [.init(clockJSON(school))]])
        let model = makeModel(MemoryAccountStore(accounts: [account], active: account.id), transport, notifications: notifications)
        await model.restore(); await model.foregroundTick(); await model.foregroundTick()
        await assertEventually { notifications.pendingIDs.filter { $0.hasPrefix("auto-sign-") }.count == 1 }
        XCTAssertEqual(model.autoSignHistory.first?.stage, .missed)
        let offTransport = PlannedTransport(["courses:session-a": [.init(courseResponse("课程"))]])
        let off = makeModel(MemoryAccountStore(accounts: [accountA], active: accountA.id), offTransport)
        await off.restore(); await off.foregroundTick()
        let reads = await offTransport.count("clock"); XCTAssertEqual(reads, 0)
    }

    func testSchoolClockCacheUsesMonotonicElapsedWhenDeviceClockJumps() async throws {
        let school = CourseTime.parse(day: SchoolDate.key(.now), time: "08:26")!.addingTimeInterval(40)
        let clock = TestClock(school)
        let transport = PlannedTransport(["clock": [.init(clockJSON(school))]])
        let service = QingxinService(transport: transport, now: { clock.get() }, monotonicNow: { clock.elapsed() })
        _ = try await service.schoolNow()
        clock.advance(15); clock.setWallOnly(clock.get().addingTimeInterval(10))
        let reading = try await service.schoolNow()
        XCTAssertEqual(reading, school.addingTimeInterval(15))
        let reads = await transport.count("clock"); XCTAssertEqual(reads, 1)
    }

    func testDeviceClockJumpAfterSubmissionCannotShortenFrozenSchoolRetry() async throws {
        let school = CourseTime.parse(day: SchoolDate.key(.now), time: "08:30")!
        let clock = TestClock(school)
        var account = accountA
        account.preferences = .init(autoSignEnabled: true, autoSignRunning: true, autoSignRule: .init(offsetMinutes: 30))
        let transport = PlannedTransport([
            "courses:session-a": [.init(courseResponse("课程")), .init(courseResponse("课程"))],
            "clock": [.init(clockJSON(school)), .init(clockJSON(school.addingTimeInterval(30)))],
            "sign": [.init(#"{"STATUS":"1","ERRMSG":"结果未知"}"#)]
        ])
        let store = MemoryAccountStore(accounts: [account], active: account.id)
        let model = makeModel(store, transport, clock: clock)
        await model.restore(); await model.foregroundTick()
        XCTAssertEqual(model.autoSignHistory.first?.lastSchoolSubmissionAt, school)
        clock.advance(30); clock.setWallOnly(clock.get().addingTimeInterval(120))
        await model.foregroundTick()
        let signs = await transport.count("sign"); XCTAssertEqual(signs, 1)
        XCTAssertEqual(model.autoSignHistory.first?.negativeReads, 0)
        XCTAssertEqual(model.autoSignHistory.first?.lastSchoolSubmissionAt, school)
        let restartTransport = PlannedTransport(["courses:session-a": [.init(courseResponse("课程"))], "clock": [.init(clockJSON(school.addingTimeInterval(30)))]])
        let restarted = makeModel(store, restartTransport, clock: clock)
        await restarted.restore(); await restarted.foregroundTick()
        let newSigns = await restartTransport.count("sign"); XCTAssertEqual(newSigns, 0)
        XCTAssertEqual(restarted.autoSignHistory.first?.submissions, 1)
        XCTAssertEqual(restarted.autoSignHistory.first?.lastSchoolSubmissionAt, school)
    }

    func testDeviceClockJumpCannotShortenThirtySecondNegativeQuorum() async throws {
        let school = CourseTime.parse(day: SchoolDate.key(.now), time: "08:30")!
        let clock = TestClock(school.addingTimeInterval(120))
        var account = accountA
        account.preferences = .init(autoSignEnabled: true, autoSignRunning: true, autoSignRule: .init(offsetMinutes: 30))
        let course = Course(id: "1234567", name: "课程", beginTime: "08:00", endTime: "09:40", day: SchoolDate.key(.now))
        let key = AutoSignPlanner.key(account: account.id, course: course)
        var old = AutoSignExecution(key: key, now: school.addingTimeInterval(-120))
        old.begin(course: course, now: school.addingTimeInterval(-120))
        old.submissions = 1; old.lastSubmissionAt = school.addingTimeInterval(-120)
        old.lastSchoolSubmissionAt = school.addingTimeInterval(-120)
        old.negativeReads = 1; old.firstNegativeAt = school.addingTimeInterval(-20)
        old.firstSchoolNegativeAt = school.addingTimeInterval(-20)
        old.transition(.verifying, now: school.addingTimeInterval(-20), message: "已核实一次", nextAt: school)
        try UserDefaultsAutoSignStore(defaults: defaults).save(accountID: account.id, executions: [key: old])
        let transport = PlannedTransport([
            "courses:session-a": Array(repeating: .init(courseResponse("课程")), count: 3),
            "clock": [.init(clockJSON(school))],
            "sign": [.init(#"{"STATUS":"0","result":{"stuSignStatus":"1"}}"#)]
        ])
        let model = makeModel(MemoryAccountStore(accounts: [account], active: account.id), transport, clock: clock)
        await model.restore(); await model.foregroundTick()
        let before = await transport.count("sign"); XCTAssertEqual(before, 0)
        XCTAssertEqual(model.autoSignHistory.first?.negativeReads, 1)
        clock.advance(10); await model.foregroundTick()
        let after = await transport.count("sign"); XCTAssertEqual(after, 1)
        XCTAssertEqual(model.autoSignHistory.first?.submissions, 2)
    }

    func testRepeatedAutoSignEnableSharesPendingNotificationPermissionRequest() async {
        let notifications = TestNotifications()
        let gate = ResponseGate(); notifications.authorizationGate = gate
        let model = makeModel(MemoryAccountStore(accounts: [accountA], active: accountA.id),
                              PlannedTransport(["courses:session-a": [.init(courseResponse("课程"))]]), notifications: notifications)
        await model.restore()
        model.setAutoSignRunning(true)
        await assertEventually { notifications.authorizationCalls == 1 }
        model.setAutoSignRunning(true)
        await Task.yield()
        XCTAssertEqual(notifications.authorizationCalls, 1)
        await gate.open()
    }

    func testBackwardDeviceClockJumpStillWakesRetryBySchoolMonotonicTime() async throws {
        let school = CourseTime.parse(day: SchoolDate.key(.now), time: "08:30")!
        let clock = TestClock(school)
        var account = accountA
        account.preferences = .init(autoSignEnabled: true, autoSignRunning: true, autoSignRule: .init(offsetMinutes: 30))
        let transport = PlannedTransport([
            "courses:session-a": Array(repeating: .init(courseResponse("课程")), count: 5),
            "clock": [school, school.addingTimeInterval(120), school.addingTimeInterval(150)].map { .init(clockJSON($0)) },
            "sign": [.init(#"{"STATUS":"1","ERRMSG":"结果未知"}"#), .init(#"{"STATUS":"0","result":{"stuSignStatus":"1"}}"#)]
        ])
        let model = makeModel(MemoryAccountStore(accounts: [account], active: account.id), transport, clock: clock)
        await model.restore(); await model.foregroundTick()
        clock.advance(120); clock.setWallOnly(clock.get().addingTimeInterval(-3600))
        await model.foregroundTick()
        XCTAssertEqual(model.autoSignHistory.first?.negativeReads, 1)
        clock.advance(30); await model.foregroundTick()
        let signs = await transport.count("sign"); XCTAssertEqual(signs, 2)
        XCTAssertEqual(model.autoSignHistory.first?.stage, .signed)
    }

    func testActivationDuringClockAwaitFreezesCreationUptimeDespiteWallJump() async throws {
        let school = CourseTime.parse(day: SchoolDate.key(.now), time: "08:20")!
        let clock = TestClock(school)
        let gate = ResponseGate()
        let store = MemoryAccountStore(accounts: [accountA], active: accountA.id)
        let transport = PlannedTransport([
            "courses:session-a": [.init(courseResponse("课程"))],
            "clock": [.init(clockJSON(school.addingTimeInterval(10)), gate: gate)]
        ])
        let model = makeModel(store, transport, clock: clock)
        await model.restore()
        model.setAutoSignRule(.init(offsetMinutes: 15, missedAction: .tenMinuteGrace, notification: .none))
        model.setAutoSignRunning(true)
        await assertEventually { await transport.count("clock") == 1 }
        clock.advance(20); clock.setWallOnly(clock.get().addingTimeInterval(3600))
        await gate.open(); await model.foregroundTick()
        XCTAssertEqual(store.vault.accounts[0].preferences.autoSignRunningSince, school)
        XCTAssertEqual(store.vault.accounts[0].preferences.autoSignSinceUsesSchoolTime, true)
        XCTAssertTrue(store.vault.accounts[0].preferences.autoSignPendingClockBoundaries.isEmpty)
        XCTAssertFalse(model.autoSignPlans.first!.isParticipating)
        XCTAssertTrue(model.autoSignHistory.isEmpty)
        let signs = await transport.count("sign"); XCTAssertEqual(signs, 0)
    }

    func testFailedClockActivationRestartNeverBackfillsPastGracePlan() async throws {
        let school = CourseTime.parse(day: SchoolDate.key(.now), time: "08:30")!
        let device = school.addingTimeInterval(-600)
        let clock = TestClock(device)
        let store = MemoryAccountStore(accounts: [accountA], active: accountA.id)
        let firstTransport = PlannedTransport(["courses:session-a": [.init(courseResponse("课程"))], "clock": [.init("invalid")]])
        let first = makeModel(store, firstTransport, clock: clock)
        await first.restore()
        first.setAutoSignRule(.init(offsetMinutes: 25, missedAction: .tenMinuteGrace, notification: .none))
        first.setAutoSignRunning(true)
        await first.foregroundTick()
        XCTAssertFalse(store.vault.accounts[0].preferences.autoSignPendingClockBoundaries.isEmpty)
        XCTAssertTrue(first.autoSignHistory.isEmpty)
        let secondTransport = PlannedTransport(["courses:session-a": [.init(courseResponse("课程"))], "clock": [.init(clockJSON(school))]])
        let second = makeModel(store, secondTransport, clock: clock)
        await second.restore(); await second.foregroundTick()
        XCTAssertEqual(store.vault.accounts[0].preferences.autoSignRunningSince, school)
        XCTAssertFalse(second.autoSignPlans.first!.isParticipating)
        XCTAssertTrue(second.autoSignHistory.isEmpty)
        let signs = await secondTransport.count("sign"); XCTAssertEqual(signs, 0)
    }

    func testLegacyReceiptAfterClockCorrectionOnlyVerifiesAndNeverSubmitsAgain() async throws {
        let school = CourseTime.parse(day: SchoolDate.key(.now), time: "08:30")!
        for offset in [-3600.0, 3600.0] {
            let clock = TestClock(school.addingTimeInterval(offset))
            var account = accountA
            account.preferences = .init(autoSignEnabled: true, autoSignRunning: true, autoSignRule: .init(offsetMinutes: 30))
            let course = Course(id: "1234567", name: "课程", beginTime: "08:00", endTime: "09:40", day: SchoolDate.key(.now))
            let key = AutoSignPlanner.key(account: account.id, course: course)
            var old = AutoSignExecution(key: key, now: school.addingTimeInterval(-120))
            old.begin(course: course, now: school.addingTimeInterval(-120))
            old.submissions = 1; old.lastSubmissionAt = school.addingTimeInterval(-120)
            old.negativeReads = 2; old.firstNegativeAt = school.addingTimeInterval(-90)
            old.transition(.verifying, now: school.addingTimeInterval(-30), message: "旧结果未知", nextAt: school)
            try UserDefaultsAutoSignStore(defaults: defaults).save(accountID: account.id, executions: [key: old])
            let transport = PlannedTransport([
                "courses:session-a": [.init(courseResponse("课程")), .init(courseResponse("课程"))],
                "clock": [.init(clockJSON(school))]
            ])
            let model = makeModel(MemoryAccountStore(accounts: [account], active: account.id), transport, clock: clock)
            await model.restore(); await model.foregroundTick()
            let signs = await transport.count("sign"); XCTAssertEqual(signs, 0)
            XCTAssertEqual(model.autoSignHistory.first?.submissions, 1)
            XCTAssertEqual(model.autoSignHistory.first?.negativeReads, 2)
            XCTAssertNil(model.autoSignHistory.first?.lastSchoolSubmissionAt)
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    func testPauseUntilSchoolMidnightResumesDespiteBackwardDeviceClock() async throws {
        let first = CourseTime.parse(day: SchoolDate.key(.now), time: "08:30")!
        let until = SchoolDate.calendar.startOfDay(for: first).addingTimeInterval(86_400)
        let clock = TestClock(first)
        var account = accountA
        account.preferences = .init(autoSignEnabled: true, autoSignRunning: true, autoSignRule: .init(offsetMinutes: 30, notification: .none))
        let midnightCourse = courseResponse("午夜课程").replacingOccurrences(of: "08:00", with: "00:05").replacingOccurrences(of: "09:40", with: "01:40")
        let transport = PlannedTransport([
            "courses:session-a": [.init(courseResponse("课程")), .init(courseResponse("课程")), .init(midnightCourse), .init(midnightCourse)],
            "clock": [.init(clockJSON(first)), .init(clockJSON(until))],
            "sign": [.init(#"{"STATUS":"0","result":{"stuSignStatus":"1"}}"#), .init(#"{"STATUS":"0","result":{"stuSignStatus":"1"}}"#)]
        ])
        let model = makeModel(MemoryAccountStore(accounts: [account], active: account.id), transport, clock: clock)
        await model.restore(); await model.foregroundTick()
        model.setAutoSignRule(.init(notification: .none)); model.pauseAutoSignUntilTomorrow()
        clock.advance(until.timeIntervalSince(first)); clock.setWallOnly(clock.get().addingTimeInterval(-3600))
        await model.refresh(on: until); await model.foregroundTick()
        XCTAssertEqual(model.autoSignSettingsStatus, "运行中")
        let signs = await transport.count("sign"); XCTAssertEqual(signs, 2)
        XCTAssertEqual(model.autoSignHistory.first?.stage, .signed)
    }

    func testCappedReadOnlyWakeUsesFrozenSchoolTimeAfterBackwardClockJump() async throws {
        let school = CourseTime.parse(day: SchoolDate.key(.now), time: "08:30")!
        let clock = TestClock(school)
        var account = accountA
        account.preferences = .init(autoSignEnabled: true, autoSignRunning: true, autoSignRule: .init(offsetMinutes: 30, maxSubmissions: 1, retryMinutes: 1))
        let signed = courseResponse("课程").replacingOccurrences(of: "\"signStatus\":\"0\"", with: "\"signStatus\":\"1\"")
        let transport = PlannedTransport([
            "courses:session-a": [.init(courseResponse("课程")), .init(courseResponse("课程")), .init(signed)],
            "clock": [.init(clockJSON(school)), .init(clockJSON(school.addingTimeInterval(30)))],
            "sign": [.init(#"{"STATUS":"1","ERRMSG":"结果未知"}"#)]
        ])
        let model = makeModel(MemoryAccountStore(accounts: [account], active: account.id), transport, clock: clock)
        await model.restore(); await model.foregroundTick()
        XCTAssertEqual(model.autoSignHistory.first?.nextSchoolVerificationAt, school.addingTimeInterval(30))
        clock.advance(30); clock.setWallOnly(clock.get().addingTimeInterval(-3600))
        await model.foregroundTick()
        XCTAssertEqual(model.autoSignHistory.first?.stage, .signed)
        let signs = await transport.count("sign"); XCTAssertEqual(signs, 1)
    }

    func testActivationBoundaryStillVerifiesExistingSubmissionWithoutNewPost() async throws {
        let school = CourseTime.parse(day: SchoolDate.key(.now), time: "08:30")!
        var account = accountA
        account.preferences = .init(autoSignEnabled: true, autoSignRunning: true, autoSignRule: .init(offsetMinutes: 30),
                                    autoSignRunningSince: school.addingTimeInterval(60), autoSignSinceUsesSchoolTime: true)
        let course = Course(id: "1234567", name: "课程", beginTime: "08:00", endTime: "09:40", day: SchoolDate.key(.now))
        let key = AutoSignPlanner.key(account: account.id, course: course)
        var old = AutoSignExecution(key: key, now: school.addingTimeInterval(-120))
        old.begin(course: course, now: school.addingTimeInterval(-120))
        old.submissions = 1; old.lastSubmissionAt = school.addingTimeInterval(-120)
        old.lastSchoolSubmissionAt = school.addingTimeInterval(-120)
        old.transition(.verifying, now: school, message: "提交结果未知", nextAt: school)
        try UserDefaultsAutoSignStore(defaults: defaults).save(accountID: account.id, executions: [key: old])
        let signed = courseResponse("课程").replacingOccurrences(of: "\"signStatus\":\"0\"", with: "\"signStatus\":\"1\"")
        let transport = PlannedTransport([
            "courses:session-a": [.init(courseResponse("课程")), .init(signed)], "clock": [.init(clockJSON(school))]
        ])
        let model = makeModel(MemoryAccountStore(accounts: [account], active: account.id), transport)
        await model.restore(); await model.foregroundTick()
        XCTAssertEqual(model.autoSignHistory.first?.stage, .signed)
        XCTAssertEqual(model.autoSignHistory.first?.submissions, 1)
        let signs = await transport.count("sign"); XCTAssertEqual(signs, 0)
    }

    func testLegacyReadOnlySchoolWakeSurvivesBackwardClockAndRestartBelowSubmissionCap() async throws {
        let school = CourseTime.parse(day: SchoolDate.key(.now), time: "08:30")!
        let clock = TestClock(school)
        var account = accountA
        account.preferences = .init(autoSignEnabled: true, autoSignRunning: true, autoSignRule: .init(offsetMinutes: 30, maxSubmissions: 3))
        let course = Course(id: "1234567", name: "课程", beginTime: "08:00", endTime: "09:40", day: SchoolDate.key(.now))
        let key = AutoSignPlanner.key(account: account.id, course: course)
        var old = AutoSignExecution(key: key, now: school.addingTimeInterval(-120))
        old.begin(course: course, now: school.addingTimeInterval(-120))
        old.submissions = 1; old.lastSubmissionAt = school.addingTimeInterval(-120)
        old.transition(.needsAttention, now: school, message: "旧记录结果未知，继续核实", nextAt: school.addingTimeInterval(60))
        old.nextSchoolVerificationAt = school.addingTimeInterval(60)
        try UserDefaultsAutoSignStore(defaults: defaults).save(accountID: account.id, executions: [key: old])
        let store = MemoryAccountStore(accounts: [account], active: account.id)
        let transport = PlannedTransport(["courses:session-a": [.init(courseResponse("课程"))], "clock": [.init(clockJSON(school))]])
        let model = makeModel(store, transport, clock: clock)
        await model.restore(); await model.foregroundTick()
        let before = await transport.count("courses:session-a"); XCTAssertEqual(before, 1)
        clock.advance(60); clock.setWallOnly(clock.get().addingTimeInterval(-3600))
        let signed = courseResponse("课程").replacingOccurrences(of: "\"signStatus\":\"0\"", with: "\"signStatus\":\"1\"")
        let restartedTransport = PlannedTransport([
            "courses:session-a": [.init(courseResponse("课程")), .init(signed)], "clock": [.init(clockJSON(school.addingTimeInterval(60)))]
        ])
        let restarted = makeModel(store, restartedTransport, clock: clock)
        await restarted.restore(); await restarted.foregroundTick()
        XCTAssertEqual(restarted.autoSignHistory.first?.stage, .signed)
        XCTAssertEqual(restarted.autoSignHistory.first?.submissions, 1)
        let signs = await restartedTransport.count("sign"); XCTAssertEqual(signs, 0)
    }

    private func makeModel(_ store: MemoryAccountStore, _ transport: PlannedTransport,
                           notifications: TestNotifications? = nil, widgets: TestWidgets? = nil, clock: TestClock? = nil) -> AppModel {
        let now = CourseTime.parse(day: SchoolDate.key(.now), time: "08:30")!
        let localClock = clock ?? TestClock(now)
        let model = AppModel(service: QingxinService(transport: transport, now: { localClock.get() }, monotonicNow: { localClock.elapsed() }), accountStore: store, defaults: defaults,
                             notifications: notifications ?? TestNotifications(), widgets: widgets ?? TestWidgets())
        model.attendanceNow = { localClock.get() }
        model.autoSignMonotonicNow = { localClock.elapsed() }
        return model
    }

    private func assertEventually(_ predicate: @escaping @MainActor () async -> Bool,
                                  file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<300 {
            if await predicate() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("异步操作没有到达预期状态", file: file, line: line)
    }
}

private let accountA = StoredAccount(session: SchoolSession(userId: "user-a", sessionId: "session-a", studentNo: "2026000001", name: "林清"), loginUsername: "a@example.edu")
private let accountB = StoredAccount(session: SchoolSession(userId: "user-b", sessionId: "session-b", studentNo: "2026000002", name: "周宁"), loginUsername: "b@example.edu")
private let rememberedAccountA = StoredAccount(session: accountA.session, credentials: StoredCredentials(username: "a@example.edu", password: "remembered-a"), loginUsername: "a@example.edu")
private let expiredResponse = #"{"STATUS":"1","ERRMSG":"登录已过期，请重新登录"}"#
private var clockResponse: String { clockJSON(CourseTime.parse(day: SchoolDate.key(.now), time: "08:30")!) }
private let semesterResponse = #"{"STATUS":"0","result":[{"code":"2026202701","name":"2026-2027秋季学期","beginDate":"2026-08-31","endDate":"2027-01-31","yearStatus":"1"}]}"#
private let catalogResponse = #"{"STATUS":"0","result":[{"course_id":"stable-course","courseNum":"CS6001","course_name":"高级人工智能","teacher_name":"陈老师","course_address":"教学楼 A101","semesterId":"2026202701","course_beignDate":"2026-08-31","course_endDate":"2027-01-31","jc_num":"16","jc_num_studyed":"3"}]}"#

private var linkedSemesterResponse: String {
    let week = SchoolDate.week(containing: .now)
    return #"{"STATUS":"0","result":[{"code":"linked-term","name":"关联测试学期","beginDate":"\#(SchoolDate.key(week[0]))","endDate":"\#(SchoolDate.key(week[6]))","yearStatus":"1"}]}"#
}
private let linkedCatalogResponse = #"{"STATUS":"0","result":[{"course_id":"stable-course","courseNum":"CS6001","course_name":"联合课程","teacher_name":"教师1,教师2,教师3","course_address":"B203","semesterId":"linked-term"}]}"#
private var linkedAttendanceResponse: String {
    #"{"STATUS":"0","mySignNum":"1","myNoSignNum":"0","result":[{"id":"attendance-1","courseId":"stable-course","courseSchedId":"1234561","teachTime":"\#(SchoolDate.key(.now))","classBeginTime":"08:00","classEndTime":"09:40","signStatus":"1"}]}"#
}
private func coTeacherResponse(missingThirdID: Bool = false, signedTeacher: Int? = nil) -> String {
    let values: [[String: Any]] = (1...3).map { index in
        var value: [String: Any] = ["id": "123456\(index)", "courseId": index == 1 ? "stable-course" : "teaching-\(index)",
            "courseNum": "CS6001", "semesterId": "incorrect-old-term", "teacherId": "teacher-\(index)",
            "teacherName": "教师\(index)", "courseName": "联合课程", "classroomName": "B203",
            "classBeginTime": "08:00", "classEndTime": "09:40", "signStatus": signedTeacher == index ? "1" : "0"]
        if missingThirdID && index == 3 { value.removeValue(forKey: "courseId") }
        return value
    }
    return String(data: try! JSONSerialization.data(withJSONObject: ["STATUS": "0", "result": values]), encoding: .utf8)!
}

private func courseResponse(_ name: String) -> String {
    #"{"STATUS":"0","result":[{"id":"1234567","courseId":"stable-course","courseName":"\#(name)","teacherName":"教师","classBeginTime":"08:00","classEndTime":"09:40","signStatus":"0"}]}"#
}

private func loginResponse(_ session: SchoolSession) -> String {
    #"{"STATUS":"0","result":{"id":"\#(session.userId)","sessionId":"\#(session.sessionId)","studentNo":"\#(session.studentNo)","realName":"\#(session.name ?? "同学")"}}"#
}

@MainActor
private func cacheKey(_ id: String) -> String { "courses-\(id)-\(SchoolDate.key(.now))" }
private struct CacheFixture: Codable { let courses: [Course]; let updatedAt: Date }
private enum TestFailure: Error { case expected }

@MainActor
private final class MemoryAccountStore: AccountStore {
    var vault: AccountVault
    var failWrites = false
    init(accounts: [StoredAccount], active: String?) { vault = AccountVault(accounts: accounts, activeAccountID: active) }
    func load() throws -> AccountVault { vault }
    func save(_ vault: AccountVault) throws {
        if failWrites { throw TestFailure.expected }
        self.vault = vault
    }
    func legacyCredentials() throws -> StoredCredentials? { nil }
}

@MainActor
private final class TestWidgets: WidgetClient {
    var snapshot: WidgetSnapshot?
    func save(_ snapshot: WidgetSnapshot) { self.snapshot = snapshot }
    func clear() { snapshot = nil }
}

@MainActor
private final class TestNotifications: NotificationClient {
    var status: UNAuthorizationStatus = .notDetermined
    var authorizationGate: ResponseGate?
    var authorizationFails = false
    var authorizationError: Error?
    var authorizationCalls = 0
    var addGate: ResponseGate?
    var addFails = false
    var addCalls = 0
    var pendingIDs = Set<String>()
    func authorizationStatus() async -> UNAuthorizationStatus { status }
    func requestAuthorization() async throws -> Bool {
        authorizationCalls += 1
        await authorizationGate?.wait()
        if let authorizationError { throw authorizationError }
        if authorizationFails { throw TestFailure.expected }
        return true
    }
    func add(_ request: UNNotificationRequest) async throws {
        addCalls += 1
        await addGate?.wait()
        if addFails { throw TestFailure.expected }
        pendingIDs.insert(request.identifier)
    }
    func removeAll() { pendingIDs.removeAll() }
    func remove(ids: [String]) { pendingIDs.subtract(ids) }
    func pendingRequestIdentifiers() async -> [String] { Array(pendingIDs) }
}

/// Intentionally ignores cancellation so tests cover transports that deliver a late response.
private actor ResponseGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuations.append($0) }
    }
    func open() {
        isOpen = true
        let waiting = continuations
        continuations.removeAll()
        waiting.forEach { $0.resume() }
    }
}

private actor PlannedTransport: HTTPTransport {
    struct Response: Sendable {
        let body: String
        let gate: ResponseGate?
        init(_ body: String, gate: ResponseGate? = nil) { self.body = body; self.gate = gate }
    }
    private var responses: [String: [Response]]
    private(set) var requests: [URLRequest] = []
    init(_ responses: [String: [Response]]) { self.responses = responses }
    func count(_ route: String) -> Int { requests.filter { Self.route($0) == route }.count }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let key = Self.route(request)
        guard var queue = responses[key], !queue.isEmpty else { throw URLError(.badServerResponse) }
        let response = queue.removeFirst()
        responses[key] = queue
        await response.gate?.wait()
        return (Data(response.body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
    private static func route(_ request: URLRequest) -> String {
        let path = request.url!.path
        if path.hasSuffix("login.action") { return "login" }
        if path.hasSuffix("get_timestamp.do") { return "clock" }
        if path.hasSuffix("stu_scan_sign.action") { return "sign" }
        if path.hasSuffix("get_stu_course_sched_week.action") { return "weekly:\(request.value(forHTTPHeaderField: "sessionId") ?? "")" }
        if path.hasSuffix("get_base_school_year.action") { return "semesters:\(request.value(forHTTPHeaderField: "sessionId") ?? "")" }
        if path.hasSuffix("get_myall_course.action") { return "catalog:\(request.value(forHTTPHeaderField: "sessionId") ?? "")" }
        if path.hasSuffix("get_my_course_sign_detail.action") { return "attendance:\(request.value(forHTTPHeaderField: "sessionId") ?? "")" }
        return "courses:\(request.value(forHTTPHeaderField: "sessionId") ?? "")"
    }
}

private func clockJSON(_ date: Date) -> String { "{\"STATUS\":\"0\",\"timestamp\":\(Int64(date.timeIntervalSince1970 * 1000))}" }
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    private var uptime: TimeInterval = 0
    init(_ value: Date) { self.value = value }
    func get() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func elapsed() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return uptime }
    func set(_ value: Date) { lock.lock(); uptime += max(0, value.timeIntervalSince(self.value)); self.value = value; lock.unlock() }
    func setWallOnly(_ value: Date) { lock.lock(); self.value = value; lock.unlock() }
    func advance(_ seconds: TimeInterval) { lock.lock(); uptime += seconds; value = value.addingTimeInterval(seconds); lock.unlock() }
}
