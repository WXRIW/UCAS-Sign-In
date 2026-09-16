import SwiftUI
import UserNotifications

struct AttendanceRecord: Codable, Identifiable {
    var id = UUID()
    let courseName: String
    let date: Date
    let message: String
    let succeeded: Bool
}

@MainActor
final class AppModel: ObservableObject {
    @Published var session: SchoolSession?
    @Published var isDemo = false
    @Published var courses: [Course] = []
    @Published var selectedDate = Date()
    @Published private var isAuthenticating = false
    @Published private var refreshTasks: [String: Task<Void, Never>] = [:]
    @Published var signingID: String?
    @Published var loginRequest: LoginRequest?
    @Published var showAccountManagement = false
    @Published private(set) var accounts: [StoredAccount] = []
    @Published private(set) var activeAccountID: String?
    @Published private(set) var accountGeneration = UUID()
    @Published private var isRecovering = false
    var showLogin: Bool {
        get { loginRequest != nil }
        set { if newValue { presentLogin() } else { loginRequest = nil } }
    }
    var canChangeAccount: Bool { !isAuthenticating && !isRecovering && signingID == nil }
    @Published var notice: String?
    @Published var errorMessage: String?
    @Published var lastUpdated: Date?
    @Published private var courseUpdates: [String: Date] = [:]
    @Published private var courseNotices: [String: String] = [:]
    @Published private var courseFreshness: [String: Bool] = [:]
    @Published var records: [AttendanceRecord] = []
    @Published private(set) var remindersEnabled = false
    @Published private(set) var autoSignEnabled = false
    let service: QingxinService
    private let accountStore: any AccountStore
    private let defaults: UserDefaults
    private let notifications: any NotificationClient
    private let widgets: any WidgetClient
    private var vault = AccountVault()
    private var accountsLoaded = false
    private var recoveryTask: Task<SchoolSession?, Never>?
    private var recoveryAttempts: Set<String> = []
    private var generation: UUID {
        get { accountGeneration }
        set { accountGeneration = newValue }
    }
    private var refreshSequence = 0
    private var courseRefreshSequences: [String: Int] = [:]
    private var reminderGeneration = UUID()
    private var todayIsFresh: Bool { courseFreshness[SchoolDate.key(.now)] == true }
    private var autoAttempts: Set<String> = []
    private var restored = false
    private var automaticRefreshPaused = false

    init(service: QingxinService = QingxinService(), accountStore: (any AccountStore)? = nil,
         defaults: UserDefaults = .standard, notifications: (any NotificationClient)? = nil,
         widgets: (any WidgetClient)? = nil) {
        self.service = service
        self.defaults = defaults
        self.notifications = notifications ?? LiveNotificationClient()
        self.widgets = widgets ?? LiveWidgetClient()
        #if os(macOS)
        let keychain = KeychainStore(service: "\(Bundle.main.bundleIdentifier ?? "cn.ucas.signin.mac").credentials")
        #else
        let keychain = KeychainStore()
        #endif
        self.accountStore = accountStore ?? KeychainAccountStore(keychain: keychain, defaults: defaults)
    }

    var isCached: Bool { isCached(on: selectedDate) }
    var isLoading: Bool { isAuthenticating || isRecovering || !refreshTasks.isEmpty }
    func isRefreshing(on date: Date) -> Bool {
        refreshTasks[SchoolDate.key(date)] != nil
    }
    func lastUpdated(on date: Date) -> Date? { courseUpdates[SchoolDate.key(date)] }
    func notice(on date: Date) -> String? { courseNotices[SchoolDate.key(date)] }
    func isCached(on date: Date) -> Bool {
        !isDemo && courseFreshness[SchoolDate.key(date)] == false
    }
    func needsCourseRefresh(_ course: Course) -> Bool {
        !isDemo && courseFreshness[normalizedDay(course.day)] != true
    }
    func canSign(_ course: Course, accountGeneration expectedGeneration: UUID? = nil) -> Bool {
        guard expectedGeneration == nil || expectedGeneration == generation,
              !isAuthenticating, !isRecovering, !automaticRefreshPaused, !showLogin,
              !accounts.contains(where: { $0.id == activeAccountID && $0.requiresLogin }) else { return false }
        guard let current = courses.first(where: {
            $0.id == course.id && normalizedDay($0.day) == normalizedDay(course.day)
        }) else { return false }
        return !current.signed && signingID == nil && !needsCourseRefresh(current)
    }

    var isConnected: Bool { isDemo || session != nil }
    var selectedCourses: [Course] {
        courses.filter { normalizedDay($0.day) == SchoolDate.key(selectedDate) }
            .sorted { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }
    }
    var todayCourses: [Course] {
        courses.filter { normalizedDay($0.day) == SchoolDate.key(.now) }
            .sorted { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }
    }
    var featuredCourse: Course? {
        let pair = CourseTime.currentAndNext(todayCourses, now: .now)
        if let current = pair.current, !current.signed { return current }
        return pair.next ?? pair.current ?? todayCourses.last
    }
    var todaySignedCount: Int { todayCourses.filter(\.signed).count }
    var accountName: String { isDemo ? "演示同学" : session?.name ?? (session == nil ? "尚未登录" : "同学") }
    var accountStudentNo: String? { isDemo ? "2026123456" : session?.studentNo }

    private func loadAccounts() throws {
        guard !accountsLoaded else { return }
        vault = try accountStore.load()
        accountsLoaded = true
        updateAccountList()
    }

    private func updateAccountList() {
        accounts = vault.accounts.sorted {
            $0.lastUsedAt == $1.lastUsedAt ? $0.id < $1.id : $0.lastUsedAt > $1.lastUsedAt
        }
    }

    private func commit(_ updated: AccountVault) throws {
        try accountStore.save(updated)
        vault = updated
        updateAccountList()
    }

    func restore() async {
        guard !restored else { return }
        restored = true
        // Demo launch arguments never read or migrate the user's real credentials.
        if ProcessInfo.processInfo.arguments.contains("--demo") { enterDemo(); return }
        do {
            try loadAccounts()
            if let account = vault.accounts.first(where: { $0.id == vault.activeAccountID }) {
                activate(account)
                if account.requiresLogin { requestLogin(for: account.id) }
                else { await refresh() }
            }
        } catch { errorMessage = "无法读取本机登录信息：\(error.localizedDescription)" }
    }

    func presentLogin(accountID: String? = nil) {
        guard canChangeAccount else { return }
        if let accountID, !accounts.contains(where: { $0.id == accountID }) { return }
        loginRequest = LoginRequest(accountID: accountID)
    }

    private func requestLogin(for accountID: String) {
        guard activeAccountID == accountID else { return }
        showAccountManagement = false
        // An old refresh must not replace a form the user is already submitting.
        if loginRequest == nil { loginRequest = LoginRequest(accountID: accountID) }
    }

    func login(username: String, password: String, remember: Bool, requestID: UUID) async -> Bool {
        guard canChangeAccount, let request = loginRequest, request.id == requestID else { return false }
        let token = generation
        isAuthenticating = true
        defer { isAuthenticating = false }
        do {
            try loadAccounts()
            let result = try await service.login(username: username, password: password)
            guard generation == token, loginRequest?.id == requestID else { return false }
            if let expected = request.accountID, result.studentNo != expected {
                throw APIError(code: "ACCOUNT_MISMATCH", message: "登录结果与所选账户不符，请使用该账户的账号和密码。")
            }
            var updated = vault
            var account = updated.accounts.first(where: { $0.id == result.studentNo })
                ?? StoredAccount(session: result)
            account.session = result
            account.loginUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
            account.credentials = remember ? StoredCredentials(username: account.loginUsername, password: password) : nil
            account.requiresLogin = false
            account.lastUsedAt = .now
            updated.upsert(account)
            try commit(updated)
            recoveryAttempts = recoveryAttempts.filter { !$0.hasPrefix("\(account.id)|") }
            loginRequest = nil
            activate(account)
            let activatedGeneration = generation
            Task {
                guard self.generation == activatedGeneration else { return }
                await self.refresh()
            }
            return true
        } catch {
            if generation == token, loginRequest?.id == requestID { errorMessage = error.localizedDescription }
            return false
        }
    }

    func savedCredentials(for accountID: String?) -> StoredCredentials? {
        if let accountID { return accounts.first(where: { $0.id == accountID })?.credentials }
        // An orphaned legacy password can only fill the initial connection form.
        guard accounts.isEmpty else { return nil }
        return try? accountStore.legacyCredentials()
    }

    func switchAccount(id: String) async {
        guard canChangeAccount, id != activeAccountID || isDemo else { return }
        do {
            try loadAccounts()
            guard var account = vault.accounts.first(where: { $0.id == id }) else { return }
            account.lastUsedAt = .now
            var updated = vault
            updated.upsert(account)
            try commit(updated)
            loginRequest = nil
            activate(account)
            if account.requiresLogin { requestLogin(for: id) }
            else { await refresh() }
        } catch { errorMessage = "切换账户失败：\(error.localizedDescription)" }
    }

    /// Invalidate all work before exposing a new identity to any view or client.
    private func resetAccountState() {
        generation = UUID()
        cancelRefreshes()
        reminderGeneration = UUID()
        recoveryTask?.cancel()
        recoveryTask = nil
        isRecovering = false
        notifications.removeAll()
        widgets.clear()
        courseFreshness.removeAll()
        automaticRefreshPaused = false
        signingID = nil
        courses = []
        records = []
        lastUpdated = nil
        notice = nil
        errorMessage = nil
        selectedDate = .now
        session = nil
        activeAccountID = nil
        isDemo = false
        autoSignEnabled = false
        remindersEnabled = false
    }

    private func activate(_ account: StoredAccount) {
        resetAccountState()
        session = account.session
        activeAccountID = account.id
        autoSignEnabled = account.preferences.autoSignEnabled
        remindersEnabled = account.preferences.remindersEnabled
        automaticRefreshPaused = account.requiresLogin
        loadRecords()
        if loadCache(for: account.session, date: selectedDate) {
            courseFreshness[SchoolDate.key(selectedDate)] = false
            notice = "正在显示本机缓存，同步成功后即可签到。"
            courseNotices[SchoolDate.key(selectedDate)] = notice
            publishWidget()
        }
    }

    func enterDemo() {
        guard canChangeAccount else { return }
        resetAccountState()
        isDemo = true
        courses = Self.demoCourses(on: selectedDate)
        lastUpdated = .now
        courseUpdates[SchoolDate.key(selectedDate)] = lastUpdated
        loginRequest = nil
    }

    func refresh() async {
        await refresh(on: selectedDate)
    }

    func refresh(on date: Date) async {
        let day = SchoolDate.key(date)
        if let task = refreshTasks[day] {
            // Every caller waits for the same request, including pull-to-refresh.
            await task.value
            return
        }
        guard !Task.isCancelled else { return }
        if isDemo {
            let existing = courses.filter { normalizedDay($0.day) == day }
            if existing.isEmpty { courses.append(contentsOf: Self.demoCourses(on: date)) }
            lastUpdated = .now
            courseUpdates[day] = lastUpdated
            courseNotices[day] = nil
            return
        }
        guard let session else { return }
        if accounts.first(where: { $0.id == activeAccountID })?.requiresLogin == true {
            requestLogin(for: session.studentNo)
            return
        }
        let accountToken = generation
        refreshSequence += 1
        let requestSequence = refreshSequence
        courseRefreshSequences[day] = requestSequence
        let task = Task {
            await performRefresh(on: date, session: session, accountToken: accountToken, requestSequence: requestSequence)
        }
        refreshTasks[day] = task
        await task.value
    }

    private func performRefresh(on date: Date, session: SchoolSession, accountToken: UUID, requestSequence: Int) async {
        let queriedDay = SchoolDate.key(date)
        defer {
            if generation == accountToken { refreshTasks.removeValue(forKey: SchoolDate.key(date)) }
        }
        guard !Task.isCancelled, generation == accountToken else { return }
        var requestSession = session
        do {
            let result: CourseQueryResult
            do {
                result = try await service.courses(session: session, date: date)
            } catch let error as APIError where error.isSessionExpired {
                guard let renewed = await recoverSession(session, accountToken: accountToken) else { throw error }
                guard !Task.isCancelled, generation == accountToken else { return }
                requestSession = renewed
                // Only this read is retried. A second expiry ends this recovery cycle.
                result = try await service.courses(session: renewed, date: date)
            }
            guard !Task.isCancelled, generation == accountToken,
                  self.session?.sessionId == requestSession.sessionId,
                  !accounts.contains(where: { $0.id == activeAccountID && $0.requiresLogin }) else { return }
            let returnedDays = Set(result.courses.map { normalizedDay($0.day) }).union([queriedDay])
            // A weekly fallback may overlap a newer request for another date.
            let acceptedDays = Set(returnedDays.filter { courseRefreshSequences[$0, default: 0] <= requestSequence })
            guard !acceptedDays.isEmpty else { return }
            mergeCourses(result.courses.filter { acceptedDays.contains(normalizedDay($0.day)) }, replacingDays: acceptedDays)
            automaticRefreshPaused = false
            let updatedAt = Date()
            for day in acceptedDays {
                courseRefreshSequences[day] = requestSequence
                courseFreshness[day] = true
                courseUpdates[day] = updatedAt
                courseNotices[day] = nil
                if let courseDate = CourseTime.parse(day: day, time: "00:00") {
                    saveCache(for: session, date: courseDate)
                }
            }
            lastUpdated = updatedAt
            if acceptedDays.contains(queriedDay) {
                notice = result.fromWeeklyFallback ? "所选日期没有课程，课表中可查看学校返回的本周课程。" : nil
                courseNotices[queriedDay] = notice
            }
            publishWidget()
            if remindersEnabled { await scheduleReminders() }
        } catch {
            guard !Task.isCancelled, generation == accountToken,
                  self.session?.sessionId == requestSession.sessionId else { return }
            if error is CancellationError { return }
            if let apiError = error as? APIError, apiError.isSessionExpired {
                markLoginRequired(for: session.studentNo)
                requestLogin(for: session.studentNo)
                return
            }
            guard courseRefreshSequences[queriedDay] == requestSequence else { return }
            if courseFreshness[queriedDay] != nil || loadCache(for: session, date: date) {
                courseFreshness[queriedDay] = false
                notice = "网络暂不可用，正在显示本机缓存。"
                courseNotices[queriedDay] = notice
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func markLoginRequired(for accountID: String) {
        guard activeAccountID == accountID else { return }
        automaticRefreshPaused = true
        courseFreshness = courseFreshness.mapValues { _ in false }
        reminderGeneration = UUID()
        notifications.removeAll()
        var updated = vault
        if let index = updated.accounts.firstIndex(where: { $0.id == accountID }) {
            updated.accounts[index].requiresLogin = true
            do { try commit(updated) }
            catch {
                // Keep the in-memory account paused even when Keychain is unavailable.
                vault = updated
                updateAccountList()
                errorMessage = "无法保存登录状态：\(error.localizedDescription)"
            }
        }
        notice = "登录已过期，请重新登录学校账号。"
        for day in courseFreshness.keys { courseNotices[day] = notice }
    }

    private func recoverSession(_ failedSession: SchoolSession, accountToken: UUID) async -> SchoolSession? {
        guard generation == accountToken, activeAccountID == failedSession.studentNo else { return nil }
        guard !accounts.contains(where: { $0.id == activeAccountID && $0.requiresLogin }) else {
            requestLogin(for: failedSession.studentNo)
            return nil
        }
        if let recoveryTask { return await recoveryTask.value }
        if let current = session, current.sessionId != failedSession.sessionId { return current }
        if loginRequest != nil || isAuthenticating {
            markLoginRequired(for: failedSession.studentNo)
            return nil
        }
        let attemptKey = "\(failedSession.studentNo)|\(failedSession.sessionId)"
        guard let account = accounts.first(where: { $0.id == failedSession.studentNo }),
              !account.requiresLogin, let credentials = account.credentials,
              recoveryAttempts.insert(attemptKey).inserted else {
            markLoginRequired(for: failedSession.studentNo)
            requestLogin(for: failedSession.studentNo)
            return nil
        }
        isRecovering = true
        automaticRefreshPaused = true
        courseFreshness = courseFreshness.mapValues { _ in false }
        reminderGeneration = UUID()
        notifications.removeAll()
        let task = Task<SchoolSession?, Never> {
            defer {
                if self.generation == accountToken {
                    self.isRecovering = false
                    self.recoveryTask = nil
                }
            }
            do {
                let result = try await self.service.login(username: credentials.username, password: credentials.password)
                guard !Task.isCancelled, self.generation == accountToken else { return nil }
                guard result.studentNo == failedSession.studentNo else {
                    throw APIError(code: "ACCOUNT_MISMATCH", message: "保存的凭据与该账户不符，请重新登录。")
                }
                var updated = self.vault
                guard let index = updated.accounts.firstIndex(where: { $0.id == result.studentNo }) else { return nil }
                updated.accounts[index].session = result
                updated.accounts[index].requiresLogin = false
                try self.commit(updated)
                self.session = result
                self.automaticRefreshPaused = false
                return result
            } catch {
                guard !Task.isCancelled, self.generation == accountToken else { return nil }
                self.markLoginRequired(for: failedSession.studentNo)
                self.requestLogin(for: failedSession.studentNo)
                return nil
            }
        }
        recoveryTask = task
        return await task.value
    }

    private func cancelRefreshes() {
        for task in refreshTasks.values { task.cancel() }
        refreshTasks.removeAll()
        refreshSequence = 0
        courseRefreshSequences.removeAll()
        courseUpdates.removeAll()
        courseNotices.removeAll()
    }

    func selectDate(_ date: Date) async {
        selectedDate = date
        if !isCached { notice = nil }
        await refresh(on: date)
    }

    func sign(_ course: Course, accountGeneration expectedGeneration: UUID? = nil) async {
        guard canSign(course, accountGeneration: expectedGeneration) else { return }
        let token = generation
        autoAttempts.insert(attemptKey(for: course))
        signingID = course.id
        defer { if token == generation { signingID = nil } }
        if isDemo {
            try? await Task.sleep(for: .milliseconds(550))
            guard token == generation else { return }
            markSigned(course)
            records.insert(AttendanceRecord(courseName: course.name, date: .now, message: "演示签到成功", succeeded: true), at: 0)
            notice = "演示签到成功 · 未向学校提交"
            courseNotices[normalizedDay(course.day)] = notice
            signInFeedback()
            return
        }
        guard let session else { return }
        do {
            let result = try await service.sign(course: course, session: session)
            guard token == generation else { return }
            let succeeded = result.outcome == .signed
            records.insert(AttendanceRecord(courseName: course.name, date: .now, message: result.message, succeeded: succeeded), at: 0)
            saveRecords()
            if succeeded {
                markSigned(course)
                notice = result.message
                courseNotices[normalizedDay(course.day)] = notice
                publishWidget()
                signInFeedback()
            } else { errorMessage = result.message }
            // Only a read is allowed after an uncertain result; never automatically resubmit.
            if let date = CourseTime.parse(day: course.day, time: "00:00") {
                // A request started before signing cannot confirm the new attendance state.
                if let task = refreshTasks[SchoolDate.key(date)] { await task.value }
                guard token == generation else { return }
                await refresh(on: date)
            }
        } catch {
            guard token == generation else { return }
            errorMessage = "未能确认签到结果：\(error.localizedDescription) 请先刷新课程状态，再决定是否重试。"
            if let error = error as? APIError, error.isSessionExpired {
                if await recoverSession(session, accountToken: token) != nil, generation == token {
                    // The submission is never repeated after restoring authentication.
                    await refresh(on: CourseTime.parse(day: course.day, time: "00:00") ?? selectedDate)
                }
            }
        }
    }

    func foregroundTick() async {
        guard !Task.isCancelled, !isDemo, session != nil, !showLogin, !automaticRefreshPaused,
              !isLoading, signingID == nil else { return }
        let token = generation
        // Cache recovery must also work when automatic attendance is turned off.
        let today = Date()
        if isCached(on: today) { await refresh(on: today) }
        guard !Task.isCancelled, generation == token, !showLogin, !automaticRefreshPaused else { return }
        if SchoolDate.key(selectedDate) != SchoolDate.key(today), isCached { await refresh() }
        guard !Task.isCancelled, generation == token, autoSignEnabled, !showLogin,
              todayIsFresh, !isLoading, signingID == nil else { return }
        guard let schoolNow = try? await service.schoolNow(), !Task.isCancelled, generation == token, autoSignEnabled,
              todayIsFresh, !isLoading, signingID == nil else { return }
        guard let course = todayCourses.first(where: { !$0.signed && CourseTime.isWithinSignWindow($0, now: schoolNow) }) else { return }
        let key = attemptKey(for: course)
        guard autoAttempts.insert(key).inserted else { return }
        await sign(course, accountGeneration: token)
    }

    private func attemptKey(for course: Course) -> String {
        "\(activeAccountID ?? "demo")|\(course.day)|\(course.id)"
    }

    private func signInFeedback() {
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }

    private func savePreferences(autoSign: Bool? = nil, reminders: Bool? = nil) -> Bool {
        if isDemo {
            if let autoSign { autoSignEnabled = autoSign }
            if let reminders { remindersEnabled = reminders }
            return true
        }
        guard let id = activeAccountID, let index = vault.accounts.firstIndex(where: { $0.id == id }) else { return false }
        var updated = vault
        if let autoSign { updated.accounts[index].preferences.autoSignEnabled = autoSign }
        if let reminders { updated.accounts[index].preferences.remindersEnabled = reminders }
        do {
            try commit(updated)
            autoSignEnabled = updated.accounts[index].preferences.autoSignEnabled
            remindersEnabled = updated.accounts[index].preferences.remindersEnabled
            return true
        } catch {
            errorMessage = "偏好未能保存：\(error.localizedDescription)"
            return false
        }
    }

    func setAutoSign(_ enabled: Bool) {
        _ = savePreferences(autoSign: enabled)
    }

    func setReminders(_ enabled: Bool) async {
        if isDemo { remindersEnabled = enabled; return }
        guard activeAccountID != nil else { return }
        let token = generation
        reminderGeneration = UUID()
        let settingToken = reminderGeneration
        var allowed = false
        if enabled {
            do {
                allowed = try await notifications.requestAuthorization()
                guard generation == token, reminderGeneration == settingToken else { return }
                if !allowed {
                    #if os(macOS)
                    errorMessage = "通知尚未开启。请前往系统设置 → 通知 → 果壳签到，允许课程提醒。"
                    #else
                    errorMessage = "通知尚未开启。可前往设置 → 果壳签到 → 通知，允许课程提醒。"
                    #endif
                }
            } catch {
                guard generation == token, reminderGeneration == settingToken else { return }
                errorMessage = error.localizedDescription
            }
        }
        guard generation == token, reminderGeneration == settingToken,
              savePreferences(reminders: enabled && allowed) else { return }
        if remindersEnabled { await scheduleReminders() }
        else { notifications.removeAll() }
    }

    private func scheduleReminders() async {
        guard !isDemo, session != nil, !automaticRefreshPaused else { return }
        let accountToken = generation
        let requestToken = UUID()
        reminderGeneration = requestToken
        notifications.removeAll()
        for course in courses.prefix(60) where !course.signed && !needsCourseRefresh(course) {
            guard generation == accountToken, reminderGeneration == requestToken, remindersEnabled else { return }
            guard let start = course.startDate else { continue }
            let reminder = start.addingTimeInterval(-10 * 60)
            guard reminder > Date() else { continue }
            let content = UNMutableNotificationContent()
            content.title = "还有 10 分钟上课"
            content.body = "\(course.name) · 打开果壳签到查看课程"
            content.sound = .default
            var components = SchoolDate.calendar.dateComponents([.year, .month, .day, .hour, .minute], from: reminder)
            components.timeZone = SchoolDate.calendar.timeZone
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let identifier = "\(requestToken)-\(course.day)-\(course.id)"
            do {
                try await notifications.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
                guard generation == accountToken, reminderGeneration == requestToken, remindersEnabled else {
                    notifications.remove(ids: [identifier])
                    return
                }
            }
            catch {
                guard generation == accountToken, reminderGeneration == requestToken, remindersEnabled else { return }
                notice = "部分课程提醒未能保存，请重新开启提醒。"
                courseNotices[normalizedDay(course.day)] = notice
            }
        }
    }

    func removeAccount(id: String) {
        guard canChangeAccount else { return }
        do {
            try loadAccounts()
            guard vault.accounts.contains(where: { $0.id == id }) else { return }
            var updated = vault
            updated.remove(id: id)
            try commit(updated)
            for key in defaults.dictionaryRepresentation().keys
                where key.hasPrefix("courses-\(id)-") || key == "records-\(id)" {
                defaults.removeObject(forKey: key)
            }
            autoAttempts = autoAttempts.filter { !$0.hasPrefix("\(id)|") }
            recoveryAttempts = recoveryAttempts.filter { !$0.hasPrefix("\(id)|") }
            if activeAccountID == id {
                loginRequest = nil
                resetAccountState()
            }
        } catch { errorMessage = "本机账户未能移除：\(error.localizedDescription)" }
    }

    func logout() {
        guard canChangeAccount else { return }
        if isDemo {
            loginRequest = nil
            resetAccountState()
        } else if let id = activeAccountID {
            removeAccount(id: id)
        }
    }

    private func markSigned(_ course: Course) {
        if let index = courses.firstIndex(where: { $0.id == course.id && $0.day == course.day }) { courses[index].signed = true }
    }
    private func normalizedDay(_ value: String) -> String {
        String(value.filter(\.isNumber).prefix(8))
    }
    private func publishWidget() {
        guard !isDemo else { return }
        let values = todayCourses.compactMap { course -> WidgetCourse? in
            guard let start = course.startDate, let end = course.endDate else { return nil }
            let location = course.classroom.map { "教室 · \($0)" }
                ?? (course.teacher.isEmpty ? "教室暂未提供" : "教师 · \(course.teacher)")
            return WidgetCourse(id: course.id, name: course.name, location: location, startTime: start, endTime: end, isCheckedIn: course.signed)
        }
        guard let updatedAt = lastUpdated(on: .now) else { return }
        widgets.save(WidgetSnapshot(courses: values, updatedAt: updatedAt))
    }
    private func saveCache(for session: SchoolSession, date: Date) {
        let datedCourses = courses.filter { normalizedDay($0.day) == SchoolDate.key(date) }
        guard let data = try? JSONEncoder().encode(CachedCourses(courses: datedCourses, updatedAt: lastUpdated(on: date) ?? .now)) else { return }
        defaults.set(data, forKey: "courses-\(session.studentNo)-\(SchoolDate.key(date))")
    }
    private func loadCache(for session: SchoolSession, date: Date) -> Bool {
        guard let data = defaults.data(forKey: "courses-\(session.studentNo)-\(SchoolDate.key(date))"),
              let cache = try? JSONDecoder().decode(CachedCourses.self, from: data) else { return false }
        mergeCourses(cache.courses, replacing: date); lastUpdated = cache.updatedAt
        courseUpdates[SchoolDate.key(date)] = cache.updatedAt
        return true
    }
    private func mergeCourses(_ updated: [Course], replacing date: Date) {
        let days = Set(updated.map { normalizedDay($0.day) }).union([SchoolDate.key(date)])
        mergeCourses(updated, replacingDays: days)
    }
    private func mergeCourses(_ updated: [Course], replacingDays days: Set<String>) {
        courses.removeAll { days.contains(normalizedDay($0.day)) }
        courses.append(contentsOf: updated)
    }
    private func saveRecords() {
        guard let session, let data = try? JSONEncoder().encode(Array(records.prefix(100))) else { return }
        defaults.set(data, forKey: "records-\(session.studentNo)")
    }
    private func loadRecords() {
        guard let session, let data = defaults.data(forKey: "records-\(session.studentNo)"),
              let saved = try? JSONDecoder().decode([AttendanceRecord].self, from: data) else { return }
        records = saved
    }
    private struct CachedCourses: Codable { let courses: [Course]; let updatedAt: Date }

    static func demoCourses(on date: Date) -> [Course] {
        let day = SchoolDate.key(date)
        return [
            Course(id: "1000001", name: "矩阵分析", teacher: "李明远", classroom: "教学楼 A101", beginTime: "08:30", endTime: "10:10", day: day, signed: true),
            Course(id: "1000002", name: "高级人工智能", teacher: "陈思远", classroom: "教学楼 B203", beginTime: "10:30", endTime: "12:10", day: day),
            Course(id: "1000003", name: "学术英语写作", teacher: "王雅文", beginTime: "13:30", endTime: "15:10", day: day)
        ]
    }
}
