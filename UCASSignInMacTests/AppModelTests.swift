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

private func courseResponse(_ name: String) -> String {
    #"{"STATUS":"0","result":[{"id":"1234567","courseName":"\#(name)","teacherName":"教师","classBeginTime":"08:00","classEndTime":"09:40","signStatus":"0"}]}"#
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
    var authorizationGate: ResponseGate?
    var authorizationFails = false
    var authorizationCalls = 0
    var addGate: ResponseGate?
    var addFails = false
    var addCalls = 0
    var pendingIDs = Set<String>()
    func requestAuthorization() async throws -> Bool {
        authorizationCalls += 1
        await authorizationGate?.wait()
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
        return "courses:\(request.value(forHTTPHeaderField: "sessionId") ?? "")"
    }
}
