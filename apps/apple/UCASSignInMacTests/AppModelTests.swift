import XCTest
import UserNotifications
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

    func testCourseOverrideCanEnableAutoSignWhenGlobalDefaultIsOff() async throws {
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

    func testWeekViewLoadsDatesOutsideSemesterBoundary() async throws {
        let day = SchoolDate.key(.now)
        let term = SchoolSemester(id: "one-day", name: "学期边界", beginDate: day, endDate: day, isCurrent: true)
        let initial = Course(id: "1234567", courseId: "stable-course", name: "课程", teacher: "教师", beginTime: "08:00", endTime: "09:40", day: day)
        defaults.set(try JSONEncoder().encode([SemesterScheduleCache(semester: term, courses: [initial], updatedAt: .now)]),
                     forKey: "semester-schedules-\(accountA.id)")
        let daily = [PlannedTransport.Response(courseResponse("课程"))] +
            Array(repeating: PlannedTransport.Response(#"{"STATUS":"0","result":[]}"#), count: 6)
        let transport = PlannedTransport(["courses:session-a": daily])
        let model = makeModel(MemoryAccountStore(accounts: [accountA], active: accountA.id), transport)
        await model.restore()
        let updated = model.scheduleUpdatedAt(on: .now)
        model.scheduleMode = .week
        await model.openScheduleDate(model.selectedDate)
        for date in SchoolDate.week(containing: .now) { XCTAssertTrue(model.hasSchedule(on: date)) }
        XCTAssertEqual(model.scheduleUpdatedAt(on: .now), updated)
        await model.openScheduleDate(model.selectedDate)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 7)
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

    private func makeModel(_ store: MemoryAccountStore, _ transport: PlannedTransport,
                           notifications: TestNotifications? = nil, widgets: TestWidgets? = nil) -> AppModel {
        AppModel(service: QingxinService(transport: transport), accountStore: store, defaults: defaults,
                 notifications: notifications ?? TestNotifications(), widgets: widgets ?? TestWidgets())
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
private var clockResponse: String { "{\"STATUS\":\"0\",\"timestamp\":\(Int64(Date().timeIntervalSince1970 * 1_000))}" }
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
