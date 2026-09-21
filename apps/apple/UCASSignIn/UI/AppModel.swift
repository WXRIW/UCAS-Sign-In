import SwiftUI
import UserNotifications

struct AttendanceRecord: Codable, Identifiable {
    var id = UUID()
    let courseId: String?
    let courseName: String
    let date: Date
    let message: String
    let succeeded: Bool

    init(courseId: String? = nil, courseName: String, date: Date, message: String, succeeded: Bool) {
        self.courseId = courseId
        self.courseName = courseName
        self.date = date
        self.message = message
        self.succeeded = succeeded
    }
}

struct PendingSignConfirmation: Identifiable {
    let id = UUID()
    let course: Course
    let accountGeneration: UUID
}

@MainActor
final class AppModel: ObservableObject {
    @Published var session: SchoolSession?
    @Published var isDemo = false
    @Published var courses: [Course] = [] {
        didSet { weekPresentations.removeAll() }
    }
    private var weekPresentations: [String: WeekSchedulePresentation] = [:]
    @Published var selectedDate = Date()
    @Published var scheduleMode: ScheduleMode = .day {
        didSet { defaults.set(scheduleMode.rawValue, forKey: "scheduleViewMode") }
    }
    @Published var showOutsideWeekCourses = false {
        didSet {
            defaults.set(showOutsideWeekCourses, forKey: "showOutsideWeekCourses")
            weekPresentations.removeAll()
        }
    }
    @Published private(set) var semesterSchedules: [String: SemesterScheduleCache] = [:] {
        didSet { weekPresentations.removeAll() }
    }
    @Published private(set) var isSemesterSyncing = false
    @Published private(set) var scheduleSyncError: String?
    @Published private(set) var scheduleSyncProgress = ""
    @Published private(set) var scheduleDayErrors: [String: String] = [:]
    private var scheduleSyncTask: Task<Void, Never>?
    private var scheduleRetryAfter: Date?
    private var scheduleFailureCount = 0
    private var checkedScheduleDays = Set<String>()
    private var dayRetryAfter: [String: Date] = [:]
    private var needsFullScheduleRefresh = false
    private var pendingSemesterRefreshes = Set<String>()
    private var pendingScheduleWeeks = Set<String>()
    private var scheduleMonitoringStarted = false
    @Published private var isAuthenticating = false
    @Published private var refreshTasks: [String: Task<Void, Never>] = [:]
    @Published var signingID: String?
    @Published var loginRequest: LoginRequest?
    @Published var showAccountManagement = false
    @Published var showSettings = false
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
    @Published private(set) var notificationSettingsNeeded = false
    @Published var lastUpdated: Date?
    @Published private var courseUpdates: [String: Date] = [:]
    @Published private var courseNotices: [String: String] = [:]
    @Published private var courseFreshness: [String: Bool] = [:]
    @Published var records: [AttendanceRecord] = []
    @Published private(set) var remindersEnabled = false
    @Published private(set) var autoSignEnabled = false
    @Published private(set) var confirmationEnabled = false
    @Published private(set) var reminderLeadMinutes = 10
    @Published private(set) var coursePreferences: [String: CoursePreferences] = [:]
    @Published private(set) var semesters: [SchoolSemester] = [] {
        didSet { if oldValue != semesters { weekPresentations.removeAll() } }
    }
    @Published private(set) var selectedSemester: SchoolSemester?
    @Published private(set) var catalogCourses: [CatalogCourse] = [] {
        didSet { if oldValue != catalogCourses { weekPresentations.removeAll() } }
    }
    @Published private(set) var catalogUpdatedAt: Date?
    @Published private(set) var catalogIsCached = false
    @Published private(set) var isCatalogRefreshing = false
    @Published private(set) var catalogError: String?
    @Published private(set) var attendanceByCourse: [String: CourseAttendanceSummary] = [:]
    @Published private(set) var attendanceUpdatedAt: [String: Date] = [:]
    @Published private(set) var attendanceErrors: [String: String] = [:]
    @Published private(set) var attendanceRefreshing: Set<String> = []
    @Published var visibleCatalogCourseId: String?
    @Published var pendingSignConfirmation: PendingSignConfirmation?
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
    private var scheduleWriteSequences: [String: Int] = [:]
    private var reminderGeneration = UUID()
    private var todayIsFresh: Bool { courseFreshness[SchoolDate.key(.now)] == true }
    private var autoAttempts: Set<String> = []
    private var restored = false
    private var automaticRefreshPaused = false
    private var catalogRefreshTask: Task<Void, Never>?
    private var attendanceTasks: [String: Task<Void, Never>] = [:]
    private var catalogFailureCount = 0
    private var catalogRetryAfter: Date?
    private var semestersUpdatedAt: Date?

    init(service: QingxinService = QingxinService(), accountStore: (any AccountStore)? = nil,
         defaults: UserDefaults = .standard, notifications: (any NotificationClient)? = nil,
         widgets: (any WidgetClient)? = nil) {
        self.service = service
        self.defaults = defaults
        self.scheduleMode = ScheduleMode(rawValue: defaults.string(forKey: "scheduleViewMode") ?? "") ?? .day
        self.showOutsideWeekCourses = defaults.bool(forKey: "showOutsideWeekCourses")
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
        return !current.signed && !isSignInDisabled(for: current) && signingID == nil && !needsCourseRefresh(current)
    }

    var isConnected: Bool { isDemo || session != nil }
    var selectedCourses: [Course] {
        courses(on: selectedDate)
    }
    var todayCourses: [Course] {
        courses(on: .now)
    }
    var featuredCourse: Course? {
        let pair = CourseTime.currentAndNext(todayCourses, now: .now)
        if let current = pair.current, !current.signed { return current }
        return pair.next ?? pair.current ?? todayCourses.last
    }
    var todaySignedCount: Int { todayCourses.filter(\.signed).count }
    var accountName: String { isDemo ? "演示同学" : session?.name ?? (session == nil ? "尚未登录" : "同学") }
    var accountStudentNo: String? { isDemo ? "2026123456" : session?.studentNo }

    func coursePreferences(for courseId: String) -> CoursePreferences {
        let canonical = canonicalCourseID(for: courseId)
        if let saved = coursePreferences[canonical] { return saved }
        let legacy = coursePreferences.filter { canonicalCourseID(for: $0.key) == canonical }.map(\.value)
        // Preserve restrictive legacy choices until the user explicitly saves the unified course setting.
        func override(_ values: [PreferenceOverride], preferred: PreferenceOverride) -> PreferenceOverride {
            if values.contains(preferred) { return preferred }
            return values.first { $0 != .inherit } ?? .inherit
        }
        return CoursePreferences(confirmation: override(legacy.map(\.confirmation), preferred: .enabled),
                                 autoSign: override(legacy.map(\.autoSign), preferred: .disabled),
                                 reminders: override(legacy.map(\.reminders), preferred: .disabled),
                                 reminderLeadMinutes: legacy.compactMap(\.reminderLeadMinutes).max(),
                                 signInDisabled: legacy.contains { $0.signInDisabled })
    }

    func isSignInDisabled(for course: Course) -> Bool { isSignInDisabled(for: preferenceID(for: course)) }
    func effectiveConfirmation(for course: Course) -> Bool { effectiveConfirmation(for: preferenceID(for: course)) }
    func effectiveAutoSign(for course: Course) -> Bool { effectiveAutoSign(for: preferenceID(for: course)) }
    func effectiveReminders(for course: Course) -> Bool { effectiveReminders(for: preferenceID(for: course)) }
    func effectiveReminderLead(for course: Course) -> Int { effectiveReminderLead(for: preferenceID(for: course)) }
    func isSignInDisabled(for courseId: String?) -> Bool {
        guard let courseId else { return false }
        return coursePreferences(for: courseId).signInDisabled
    }
    func effectiveConfirmation(for courseId: String?) -> Bool {
        guard !isSignInDisabled(for: courseId) else { return false }
        guard let courseId else { return confirmationEnabled }
        return coursePreferences(for: courseId).confirmation.resolve(default: confirmationEnabled)
    }
    func effectiveAutoSign(for courseId: String?) -> Bool {
        guard !isSignInDisabled(for: courseId) else { return false }
        guard let courseId else { return autoSignEnabled }
        return coursePreferences(for: courseId).autoSign.resolve(default: autoSignEnabled)
    }
    func effectiveReminders(for courseId: String?) -> Bool {
        guard let courseId else { return remindersEnabled }
        return coursePreferences(for: courseId).reminders.resolve(default: remindersEnabled)
    }
    func effectiveReminderLead(for courseId: String?) -> Int {
        guard let courseId, let lead = coursePreferences(for: courseId).reminderLeadMinutes else { return reminderLeadMinutes }
        return AccountPreferences.validLeadTimes.contains(lead) ? lead : reminderLeadMinutes
    }

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
        scheduleSyncTask?.cancel()
        scheduleSyncTask = nil
        semesterSchedules = [:]
        isSemesterSyncing = false
        scheduleSyncError = nil
        scheduleSyncProgress = ""
        scheduleDayErrors = [:]
        dayRetryAfter = [:]
        scheduleRetryAfter = nil
        scheduleFailureCount = 0
        needsFullScheduleRefresh = false
        pendingSemesterRefreshes = []
        pendingScheduleWeeks = []
        reminderGeneration = UUID()
        recoveryTask?.cancel()
        recoveryTask = nil
        isRecovering = false
        notifications.removeAll()
        widgets.clear()
        courseFreshness.removeAll()
        automaticRefreshPaused = false
        signingID = nil
        catalogRefreshTask?.cancel()
        catalogRefreshTask = nil
        attendanceTasks.values.forEach { $0.cancel() }
        attendanceTasks.removeAll()
        courses = []
        records = []
        semesters = []
        selectedSemester = nil
        catalogCourses = []
        catalogUpdatedAt = nil
        catalogIsCached = false
        isCatalogRefreshing = false
        catalogError = nil
        attendanceByCourse = [:]
        attendanceUpdatedAt = [:]
        attendanceErrors = [:]
        attendanceRefreshing = []
        visibleCatalogCourseId = nil
        pendingSignConfirmation = nil
        catalogFailureCount = 0
        catalogRetryAfter = nil
        semestersUpdatedAt = nil
        lastUpdated = nil
        notice = nil
        errorMessage = nil
        notificationSettingsNeeded = false
        selectedDate = .now
        session = nil
        activeAccountID = nil
        isDemo = false
        autoSignEnabled = false
        remindersEnabled = false
        confirmationEnabled = false
        reminderLeadMinutes = 10
        coursePreferences = [:]
    }

    private func activate(_ account: StoredAccount) {
        resetAccountState()
        session = account.session
        activeAccountID = account.id
        autoSignEnabled = account.preferences.autoSignEnabled
        remindersEnabled = account.preferences.remindersEnabled
        confirmationEnabled = account.preferences.confirmationEnabled
        reminderLeadMinutes = account.preferences.reminderLeadMinutes
        coursePreferences = account.preferences.courses
        automaticRefreshPaused = account.requiresLogin
        loadRecords()
        loadCatalogCache(for: account.id)
        loadSemesterSchedules(for: account.session)
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
        semesters = [SchoolSemester(id: "demo", name: "演示学期", beginDate: SchoolDate.key(.now), endDate: SchoolDate.key(.now), isCurrent: true)]
        selectedSemester = semesters.first
        catalogCourses = Self.demoCatalogCourses
        catalogUpdatedAt = .now
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
            checkedScheduleDays.insert("demo|\(day)")
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
        if generation == accountToken, scheduleMonitoringStarted, needsFullScheduleRefresh { await synchronizeSchedules() }
    }

    private func performRefresh(on date: Date, session: SchoolSession, accountToken: UUID, requestSequence: Int) async {
        let queriedDay = SchoolDate.key(date)
        defer {
            if generation == accountToken { refreshTasks.removeValue(forKey: SchoolDate.key(date)) }
        }
        guard !Task.isCancelled, generation == accountToken else { return }
        var requestSession = session
        do {
            let result: [Course]
            do {
                result = try await service.dailySchedule(session: session, date: date)
            } catch let error as APIError where error.isSessionExpired {
                guard let renewed = await recoverSession(session, accountToken: accountToken) else { throw error }
                guard !Task.isCancelled, generation == accountToken else { return }
                requestSession = renewed
                // Only this read is retried. A second expiry ends this recovery cycle.
                result = try await service.dailySchedule(session: renewed, date: date)
            }
            guard !Task.isCancelled, generation == accountToken,
                  self.session?.sessionId == requestSession.sessionId,
                  !accounts.contains(where: { $0.id == activeAccountID && $0.requiresLogin }) else { return }
            // dailySchedule returns only this date, including when it uses the weekly endpoint.
            guard courseRefreshSequences[queriedDay, default: 0] <= requestSequence else { return }
            let hadBaseline = courseUpdates[queriedDay] != nil
            let previous = courses.filter { normalizedDay($0.day) == queriedDay }
            let incoming = result.map { value in
                value.preservingIdentity(from: previous.first { $0.id == value.id })
            }
            let changed = !ScheduleCalendar.sameArrangements(previous, incoming)
            let attendanceChanged = previous.contains { old in incoming.first(where: { $0.id == old.id })?.signed != old.signed }
            if hadBaseline && changed {
                needsFullScheduleRefresh = true
                savePendingScheduleSync(for: session)
            }
            if changed || !hadBaseline {
                mergeCourses(incoming, replacingDays: [queriedDay])
            } else if attendanceChanged {
                // Preserve the arrangement objects when only attendance changed.
                var updated = courses
                for index in courses.indices where normalizedDay(courses[index].day) == queriedDay {
                    if let value = incoming.first(where: { $0.id == courses[index].id }) {
                        updated[index].signed = value.signed
                    }
                }
                courses = updated
            }
            checkedScheduleDays.insert("\(session.studentNo)|\(queriedDay)")
            dayRetryAfter[queriedDay] = nil
            scheduleDayErrors[queriedDay] = nil
            automaticRefreshPaused = false
            let updatedAt = Date()
            courseRefreshSequences[queriedDay] = requestSequence
            scheduleWriteSequences[queriedDay] = requestSequence
            courseFreshness[queriedDay] = true
            courseUpdates[queriedDay] = updatedAt
            courseNotices[queriedDay] = nil
            if changed || attendanceChanged || !hadBaseline {
                saveCache(for: session, date: date)
            }
            lastUpdated = updatedAt
            notice = nil
            publishWidget()
            if hasEnabledReminders { await scheduleReminders() }
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
            scheduleDayErrors[queriedDay] = error.localizedDescription
            dayRetryAfter[queriedDay] = Date().addingTimeInterval(60)
            if courseFreshness[queriedDay] != nil || loadCache(for: session, date: date) {
                courseFreshness[queriedDay] = false
                notice = "网络暂不可用，正在显示本机缓存。"
                courseNotices[queriedDay] = notice
            } else {
                courseNotices[queriedDay] = error.localizedDescription
                if !scheduleMonitoringStarted { errorMessage = error.localizedDescription }
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
        notice = "登录已过期，请重新登录账户。"
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
        scheduleWriteSequences.removeAll()
        courseUpdates.removeAll()
        courseNotices.removeAll()
    }

    func selectDate(_ date: Date) async {
        selectedDate = date
        if !isCached { notice = nil }
        await openScheduleDate(date)
    }

    func sign(_ course: Course, accountGeneration expectedGeneration: UUID? = nil, automatically: Bool = false) async {
        let token = generation
        await refreshCourseIdentityIfNeeded(for: [course])
        guard token == generation, !Task.isCancelled, canSign(course, accountGeneration: expectedGeneration) else { return }
        let attempt = attemptKey(for: course)
        autoAttempts.insert(attempt)
        signingID = course.id
        defer { if token == generation { signingID = nil } }
        if isDemo {
            try? await Task.sleep(for: .milliseconds(550))
            guard token == generation, !isSignInDisabled(for: course) else {
                autoAttempts.remove(attempt)
                return
            }
            markSigned(course)
            records.insert(AttendanceRecord(courseId: preferenceID(for: course), courseName: course.name, date: .now,
                                            message: "演示签到成功", succeeded: true), at: 0)
            notice = "演示签到成功 · 未向学校提交"
            courseNotices[normalizedDay(course.day)] = notice
            signInFeedback()
            return
        }
        guard let session else { return }
        do {
            let result = try await service.sign(course: course, session: session) { [self] in
                // School clock synchronization can suspend before the actual submission.
                guard token == generation, !isSignInDisabled(for: course),
                      !automatically || effectiveAutoSign(for: course) else {
                    throw APIError(code: "SIGN_NOT_ALLOWED", message: "签到已取消")
                }
            }
            guard token == generation else { return }
            let succeeded = result.outcome == .signed
            records.insert(AttendanceRecord(courseId: preferenceID(for: course), courseName: course.name, date: .now,
                                            message: result.message, succeeded: succeeded), at: 0)
            saveRecords()
            if succeeded {
                markSigned(course)
                invalidateAttendance(for: preferenceID(for: course))
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
        } catch let error as APIError where error.code == "SIGN_NOT_ALLOWED" {
            // No submission was made, so re-enabling may try again normally.
            autoAttempts.remove(attempt)
        } catch {
            guard token == generation else { return }
            invalidateAttendance(for: preferenceID(for: course))
            errorMessage = "未能确认签到结果：\(error.localizedDescription) 请先刷新课程状态，再决定是否重试。"
            if let error = error as? APIError, error.isSessionExpired {
                if await recoverSession(session, accountToken: token) != nil, generation == token {
                    // The submission is never repeated after restoring authentication.
                    await refresh(on: CourseTime.parse(day: course.day, time: "00:00") ?? selectedDate)
                }
            }
        }
    }

    func signManually(_ course: Course, accountGeneration expectedGeneration: UUID? = nil) async {
        let token = generation
        await refreshCourseIdentityIfNeeded(for: [course])
        guard token == generation, !Task.isCancelled, canSign(course, accountGeneration: expectedGeneration) else { return }
        if effectiveConfirmation(for: course) {
            pendingSignConfirmation = PendingSignConfirmation(course: course, accountGeneration: expectedGeneration ?? generation)
            return
        }
        await sign(course, accountGeneration: expectedGeneration)
    }

    func confirmPendingSign() async {
        guard let request = pendingSignConfirmation else { return }
        pendingSignConfirmation = nil
        guard request.accountGeneration == generation,
              canSign(request.course, accountGeneration: request.accountGeneration) else { return }
        await sign(request.course, accountGeneration: request.accountGeneration)
    }

    func foregroundTick() async {
        guard !Task.isCancelled, !isDemo, session != nil, !showLogin, !automaticRefreshPaused,
              !isLoading, signingID == nil else { return }
        let token = generation
        // Cache recovery must also work when automatic attendance is turned off.
        let today = Date()
        if isCached(on: today), dayRetryAfter[SchoolDate.key(today)].map({ $0 > Date() }) != true {
            await refresh(on: today)
        }
        guard !Task.isCancelled, generation == token, !showLogin, !automaticRefreshPaused else { return }
        if SchoolDate.key(selectedDate) != SchoolDate.key(today), isCached,
           dayRetryAfter[SchoolDate.key(selectedDate)].map({ $0 > Date() }) != true {
            await refresh()
        }
        guard !Task.isCancelled, generation == token, !showLogin,
              todayIsFresh, !isLoading, signingID == nil else { return }
        await refreshCourseIdentityIfNeeded(for: todayCourses)
        guard generation == token, !Task.isCancelled, !showLogin, !automaticRefreshPaused,
              todayIsFresh, !isLoading, signingID == nil else { return }
        let candidates = todayCourses.filter {
            !$0.signed && effectiveAutoSign(for: $0) && !autoAttempts.contains(attemptKey(for: $0))
        }
        guard !candidates.isEmpty else { return }
        guard let schoolNow = try? await service.schoolNow(), !Task.isCancelled, generation == token,
              todayIsFresh, !isLoading, signingID == nil else { return }
        guard let course = candidates.first(where: {
            effectiveAutoSign(for: $0) && CourseTime.isWithinSignWindow($0, now: schoolNow)
        }) else { return }
        let key = attemptKey(for: course)
        guard autoAttempts.insert(key).inserted else { return }
        await sign(course, accountGeneration: token, automatically: true)
    }

    private func attemptKey(for course: Course) -> String {
        "\(activeAccountID ?? "demo")|\(course.day)|\(course.id)"
    }

    private func signInFeedback() {
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }

    private func savePreferences(autoSign: Bool? = nil, reminders: Bool? = nil,
                                 confirmation: Bool? = nil, leadMinutes: Int? = nil,
                                 courses: [String: CoursePreferences]? = nil) -> Bool {
        if isDemo {
            if let autoSign { autoSignEnabled = autoSign }
            if let reminders { remindersEnabled = reminders }
            if let confirmation { confirmationEnabled = confirmation }
            if let leadMinutes { reminderLeadMinutes = leadMinutes }
            if let courses { coursePreferences = courses }
            return true
        }
        guard let id = activeAccountID, let index = vault.accounts.firstIndex(where: { $0.id == id }) else { return false }
        var updated = vault
        if let autoSign { updated.accounts[index].preferences.autoSignEnabled = autoSign }
        if let reminders { updated.accounts[index].preferences.remindersEnabled = reminders }
        if let confirmation { updated.accounts[index].preferences.confirmationEnabled = confirmation }
        if let leadMinutes { updated.accounts[index].preferences.reminderLeadMinutes = leadMinutes }
        if let courses { updated.accounts[index].preferences.courses = courses }
        do {
            try commit(updated)
            autoSignEnabled = updated.accounts[index].preferences.autoSignEnabled
            remindersEnabled = updated.accounts[index].preferences.remindersEnabled
            confirmationEnabled = updated.accounts[index].preferences.confirmationEnabled
            reminderLeadMinutes = updated.accounts[index].preferences.reminderLeadMinutes
            coursePreferences = updated.accounts[index].preferences.courses
            return true
        } catch {
            errorMessage = "偏好未能保存：\(error.localizedDescription)"
            return false
        }
    }

    func setAutoSign(_ enabled: Bool) {
        _ = savePreferences(autoSign: enabled)
    }

    func setConfirmation(_ enabled: Bool) {
        _ = savePreferences(confirmation: enabled)
    }

    func setReminderLead(_ minutes: Int) async {
        guard AccountPreferences.validLeadTimes.contains(minutes), savePreferences(leadMinutes: minutes) else { return }
        await scheduleReminders()
    }

    func setReminders(_ enabled: Bool) async {
        if isDemo { remindersEnabled = enabled; return }
        guard activeAccountID != nil else { return }
        let token = generation
        reminderGeneration = UUID()
        let settingToken = reminderGeneration
        var allowed = false
        if enabled {
            notificationSettingsNeeded = false
            let authorization = await notificationAuthorization()
            guard generation == token, reminderGeneration == settingToken else { return }
            switch authorization {
            case .allowed:
                allowed = true
            case .denied:
                presentNotificationPermissionMessage()
            case .failed:
                errorMessage = "暂时无法检查系统通知权限，课程提醒设置未更改，请稍后重试。"
            }
        }
        guard generation == token, reminderGeneration == settingToken,
              savePreferences(reminders: enabled && allowed) else { return }
        if hasEnabledReminders { await scheduleReminders() }
        else { notifications.removeAll() }
    }

    @discardableResult
    func setCoursePreferences(_ preferences: CoursePreferences, for courseId: String) async -> Bool {
        var preferences = preferences
        guard !courseId.isEmpty else { return false }
        let courseId = canonicalCourseID(for: courseId)
        let accountToken = generation
        let settingToken = UUID()
        reminderGeneration = settingToken
        let enablesNotifications = preferences.reminders.resolve(default: remindersEnabled)
        if enablesNotifications && !effectiveReminders(for: courseId) {
            notificationSettingsNeeded = false
            let authorization = await notificationAuthorization()
            guard generation == accountToken, reminderGeneration == settingToken else { return false }
            guard authorization == .allowed else {
                if authorization == .denied {
                    presentNotificationPermissionMessage()
                } else {
                    errorMessage = "暂时无法检查系统通知权限，课程提醒设置未更改，请稍后重试。"
                }
                return false
            }
        }
        guard generation == accountToken, reminderGeneration == settingToken else { return false }
        if let lead = preferences.reminderLeadMinutes,
           !AccountPreferences.validLeadTimes.contains(lead) { preferences.reminderLeadMinutes = nil }
        var updated = coursePreferences
        for alias in updated.keys.filter({ canonicalCourseID(for: $0) == courseId }) { updated.removeValue(forKey: alias) }
        if preferences == CoursePreferences() { updated.removeValue(forKey: courseId) }
        else { updated[courseId] = preferences }
        guard savePreferences(courses: updated) else { return false }
        if preferences.signInDisabled, let pending = pendingSignConfirmation, preferenceID(for: pending.course) == courseId {
            pendingSignConfirmation = nil
        }
        if hasEnabledReminders { await scheduleReminders() }
        else { notifications.removeAll() }
        return true
    }

    func dismissError() {
        errorMessage = nil
        notificationSettingsNeeded = false
    }

    private enum NotificationAuthorizationResult: Equatable {
        case allowed
        case denied
        case failed
    }

    private func notificationAuthorization() async -> NotificationAuthorizationResult {
        switch await notifications.authorizationStatus() {
        case .authorized, .provisional:
            return .allowed
        #if os(iOS)
        case .ephemeral:
            return .allowed
        #endif
        case .denied:
            return .denied
        case .notDetermined:
            do {
                return try await notifications.requestAuthorization() ? .allowed : .denied
            } catch {
                let error = error as NSError
                if error.domain == UNErrorDomain,
                   error.code == UNError.Code.notificationsNotAllowed.rawValue {
                    return .denied
                }
                return .failed
            }
        @unknown default:
            return .denied
        }
    }

    private func presentNotificationPermissionMessage() {
        notificationSettingsNeeded = true
        #if os(macOS)
        errorMessage = "系统已关闭果壳签到的通知权限，课程提醒设置未更改。请前往系统设置 → 通知 → 果壳签到开启通知。"
        #else
        errorMessage = "系统已关闭果壳签到的通知权限，课程提醒设置未更改。请前往设置 → 果壳签到 → 通知开启权限。"
        #endif
    }

    private var hasEnabledReminders: Bool {
        remindersEnabled || coursePreferences.values.contains { $0.reminders == .enabled }
    }

    private func scheduleReminders() async {
        guard !isDemo, session != nil, !automaticRefreshPaused else { return }
        let accountToken = generation
        let requestToken = UUID()
        reminderGeneration = requestToken
        await refreshCourseIdentityIfNeeded(for: courses)
        guard generation == accountToken, reminderGeneration == requestToken, !Task.isCancelled else { return }
        notifications.removeAll()
        for course in courses.prefix(60) where !course.signed && !needsCourseRefresh(course) && effectiveReminders(for: course) {
            guard generation == accountToken, reminderGeneration == requestToken, hasEnabledReminders else { return }
            guard let start = course.startDate else { continue }
            let lead = effectiveReminderLead(for: course)
            let reminder = start.addingTimeInterval(TimeInterval(-lead * 60))
            guard reminder > Date() else { continue }
            let content = UNMutableNotificationContent()
            content.title = "还有 \(lead) 分钟上课"
            content.body = "\(course.name) · 打开果壳签到查看课程"
            content.sound = .default
            var components = SchoolDate.calendar.dateComponents([.year, .month, .day, .hour, .minute], from: reminder)
            components.timeZone = SchoolDate.calendar.timeZone
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let identifier = "\(requestToken)-\(course.day)-\(course.id)"
            do {
                try await notifications.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
                guard generation == accountToken, reminderGeneration == requestToken, hasEnabledReminders else {
                    notifications.remove(ids: [identifier])
                    return
                }
            }
            catch {
                guard generation == accountToken, reminderGeneration == requestToken, hasEnabledReminders else { return }
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
                where key.hasPrefix("courses-\(id)-") || key == "semester-schedules-\(id)" || key == "schedule-pending-\(id)" || key.hasPrefix("catalog-\(id)") ||
                      key.hasPrefix("attendance-\(id)-") || key == "records-\(id)" {
                defaults.removeObject(forKey: key)
            }
            checkedScheduleDays = checkedScheduleDays.filter { !$0.hasPrefix("\(id)|") }
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
        if let index = courses.firstIndex(where: { $0.id == course.id && $0.day == course.day }) {
            courses[index].signed = true
            refreshSequence += 1
            courseRefreshSequences[normalizedDay(course.day)] = refreshSequence
            scheduleWriteSequences[normalizedDay(course.day)] = refreshSequence
            courseUpdates[normalizedDay(course.day)] = .now
            if let session, let date = CourseTime.parse(day: course.day, time: "00:00") { saveCache(for: session, date: date) }
        }
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
        let day = SchoolDate.key(date)
        let datedCourses = courses.filter { normalizedDay($0.day) == day }
        guard let data = try? JSONEncoder().encode(CachedCourses(courses: datedCourses, updatedAt: lastUpdated(on: date) ?? .now)) else { return }
        defaults.set(data, forKey: "courses-\(session.studentNo)-\(SchoolDate.key(date))")
    }
    private func loadCache(for session: SchoolSession, date: Date) -> Bool {
        guard let data = defaults.data(forKey: "courses-\(session.studentNo)-\(SchoolDate.key(date))"),
              let cache = try? JSONDecoder().decode(CachedCourses.self, from: data) else { return false }
        let day = SchoolDate.key(date)
        if let existing = courseUpdates[day], existing >= cache.updatedAt { return true }
        mergeCourses(cache.courses, replacing: date); lastUpdated = cache.updatedAt
        courseUpdates[SchoolDate.key(date)] = cache.updatedAt
        return true
    }
    private func mergeCourses(_ updated: [Course], replacing date: Date) {
        let days = Set(updated.map { normalizedDay($0.day) }).union([SchoolDate.key(date)])
        mergeCourses(updated, replacingDays: days)
    }
    private func mergeCourses(_ updated: [Course], replacingDays days: Set<String>) {
        let previous = Dictionary(courses.map { ("\(normalizedDay($0.day))|\($0.id)", $0) }, uniquingKeysWith: { first, _ in first })
        let updated = updated.map { value in
            value.preservingIdentity(from: previous["\(normalizedDay(value.day))|\(value.id)"])
        }
        let merged = courses.filter { !days.contains(normalizedDay($0.day)) } + updated
        if courses != merged { courses = merged }
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

    private var identitySemesters: [SchoolSemester] { semesters + semesterSchedules.values.map(\.semester) }

    private func matchedCatalogCourse(for scheduled: Course) -> CatalogCourse? {
        let current = courses.first { $0.id == scheduled.id && normalizedDay($0.day) == normalizedDay(scheduled.day) } ?? scheduled
        if isDemo { return catalogCourses.first { $0.id == current.courseId } }
        return CourseIdentity.catalogCourse(for: current, catalog: catalogCourses, semesters: identitySemesters)
    }

    func canonicalCourseID(for id: String) -> String {
        if catalogCourses.contains(where: { $0.id == id }) { return id }
        let matches = Set(courses.filter { $0.courseId == id }.compactMap {
            CourseIdentity.catalogCourse(for: $0, catalog: catalogCourses, semesters: identitySemesters)?.id
        })
        return matches.count == 1 ? matches.first! : id
    }

    private func preferenceID(for course: Course) -> String? {
        matchedCatalogCourse(for: course)?.id ?? course.courseId.map { canonicalCourseID(for: $0) }
    }

    private func refreshCourseIdentityIfNeeded(for values: [Course]) async {
        guard !isDemo, values.contains(where: { $0.courseNumber != nil && matchedCatalogCourse(for: $0) == nil }) else { return }
        await refreshCatalog()
    }

    func catalogCourse(for scheduled: Course) -> CatalogCourse {
        if let match = matchedCatalogCourse(for: scheduled) { return match }
        let semester = CourseIdentity.semester(for: scheduled, semesters: identitySemesters)
        // A scheduled meeting ID is not a course ID. Missing identities stay read-only.
        return CatalogCourse(id: scheduled.courseId ?? "", number: scheduled.courseNumber ?? "", name: scheduled.name,
                             teacher: scheduled.teacher, classroom: scheduled.classroom,
                             semesterId: semester?.id ?? "", beginDate: "", endDate: "")
    }

    func refreshCatalog(force: Bool = false) async {
        guard !Task.isCancelled else { return }
        if isDemo {
            if force || catalogUpdatedAt == nil { catalogUpdatedAt = .now }
            catalogIsCached = false
            return
        }
        guard let session else { return }
        let now = Date()
        let semestersAreFresh = semestersUpdatedAt.map { now.timeIntervalSince($0) < 24 * 60 * 60 } == true
        let catalogIsFresh = catalogUpdatedAt.map { now.timeIntervalSince($0) < 30 * 60 } == true
        if !force, semestersAreFresh, catalogIsFresh { return }
        if !force, let retryAfter = catalogRetryAfter, retryAfter > Date() { return }
        if let catalogRefreshTask { await catalogRefreshTask.value; return }
        let token = generation
        let task = Task { await self.performCatalogRefresh(session: session, accountToken: token, force: force) }
        catalogRefreshTask = task
        await task.value
    }

    private func performCatalogRefresh(session: SchoolSession, accountToken: UUID, force: Bool) async {
        isCatalogRefreshing = true
        defer {
            if generation == accountToken {
                isCatalogRefreshing = false
                catalogRefreshTask = nil
            }
        }
        var requestSession = session
        do {
            var semesterValues = semesters
            var fetchedSemesters = false
            if force || semesterValues.isEmpty || semestersUpdatedAt.map({ Date().timeIntervalSince($0) >= 24 * 60 * 60 }) != false {
                do { semesterValues = try await service.semesters(session: requestSession) }
                catch let error as APIError where error.isSessionExpired {
                    guard let renewed = await recoverSession(requestSession, accountToken: accountToken) else { throw error }
                    requestSession = renewed
                    semesterValues = try await service.semesters(session: renewed)
                }
                fetchedSemesters = true
            }
            guard !Task.isCancelled, generation == accountToken else { return }
            let semester = try Self.currentSemester(from: semesterValues)
            let semesterChanged = selectedSemester?.id != semester.id
            let needsDirectory = force || semesterChanged || catalogCourses.isEmpty ||
                catalogUpdatedAt.map { Date().timeIntervalSince($0) >= 30 * 60 } != false
            let directory: [CatalogCourse]
            if needsDirectory {
                do { directory = try await service.catalogCourses(session: requestSession, semesterId: semester.id) }
                catch let error as APIError where error.isSessionExpired {
                    guard let renewed = await recoverSession(requestSession, accountToken: accountToken) else { throw error }
                    requestSession = renewed
                    directory = try await service.catalogCourses(session: renewed, semesterId: semester.id)
                }
            } else {
                directory = catalogCourses
            }
            guard !Task.isCancelled, generation == accountToken,
                  self.session?.sessionId == requestSession.sessionId else { return }
            semesters = semesterValues
            if fetchedSemesters || semestersUpdatedAt == nil { semestersUpdatedAt = .now }
            selectedSemester = semester
            catalogCourses = directory.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            if needsDirectory { catalogUpdatedAt = .now }
            catalogIsCached = false
            catalogError = nil
            catalogFailureCount = 0
            catalogRetryAfter = nil
            saveCatalogCache(accountId: session.studentNo)
        } catch {
            guard !Task.isCancelled, generation == accountToken else { return }
            if let apiError = error as? APIError, apiError.isSessionExpired {
                markLoginRequired(for: session.studentNo)
                requestLogin(for: session.studentNo)
                return
            }
            catalogError = error.localizedDescription
            catalogIsCached = !catalogCourses.isEmpty
            catalogFailureCount += 1
            let delays: [TimeInterval] = [60, 120, 300]
            catalogRetryAfter = Date().addingTimeInterval(delays[min(catalogFailureCount - 1, delays.count - 1)])
        }
    }

    func refreshAttendance(for courseId: String, force: Bool = false) async {
        guard !courseId.isEmpty else { return }
        let courseId = canonicalCourseID(for: courseId)
        if isDemo {
            if !force, let updated = attendanceUpdatedAt[courseId], Date().timeIntervalSince(updated) < 5 * 60 { return }
            let matching = courses.filter { preferenceID(for: $0) == courseId }
            let records = matching.map {
                CourseAttendance(id: $0.id, courseId: courseId, scheduledCourseId: $0.id,
                                 day: $0.day, beginTime: $0.beginTime, endTime: $0.endTime, signed: $0.signed)
            }
            attendanceByCourse[courseId] = CourseAttendanceSummary(
                signedCount: records.filter(\.signed).count,
                unsignedCount: records.filter { !$0.signed }.count, records: records)
            attendanceUpdatedAt[courseId] = .now
            return
        }
        guard let session else { return }
        if attendanceByCourse[courseId] == nil { loadAttendanceCache(accountId: session.studentNo, courseId: courseId) }
        if !force, let updated = attendanceUpdatedAt[courseId], Date().timeIntervalSince(updated) < 5 * 60 { return }
        if let task = attendanceTasks[courseId] { await task.value; return }
        let token = generation
        let task = Task { await self.performAttendanceRefresh(courseId: courseId, session: session, accountToken: token) }
        attendanceTasks[courseId] = task
        await task.value
    }

    private func performAttendanceRefresh(courseId: String, session: SchoolSession, accountToken: UUID) async {
        attendanceRefreshing.insert(courseId)
        defer {
            if generation == accountToken {
                attendanceRefreshing.remove(courseId)
                attendanceTasks.removeValue(forKey: courseId)
            }
        }
        var requestSession = session
        do {
            let summary: CourseAttendanceSummary
            do { summary = try await service.courseAttendance(session: requestSession, courseId: courseId) }
            catch let error as APIError where error.isSessionExpired {
                guard let renewed = await recoverSession(requestSession, accountToken: accountToken) else { throw error }
                requestSession = renewed
                summary = try await service.courseAttendance(session: renewed, courseId: courseId)
            }
            guard !Task.isCancelled, generation == accountToken,
                  self.session?.sessionId == requestSession.sessionId else { return }
            attendanceByCourse[courseId] = summary
            attendanceUpdatedAt[courseId] = .now
            attendanceErrors.removeValue(forKey: courseId)
            saveAttendanceCache(accountId: session.studentNo, courseId: courseId, summary: summary)
        } catch {
            guard !Task.isCancelled, generation == accountToken else { return }
            if let apiError = error as? APIError, apiError.isSessionExpired {
                markLoginRequired(for: session.studentNo)
                requestLogin(for: session.studentNo)
                return
            }
            attendanceErrors[courseId] = error.localizedDescription
        }
    }

    private static func currentSemester(from values: [SchoolSemester], now: Date = .now) throws -> SchoolSemester {
        let flagged = values.filter(\.isCurrent)
        if flagged.count == 1 { return flagged[0] }
        let day = SchoolDate.key(now)
        let covering = values.filter { $0.beginDate <= day && day <= $0.endDate }
        guard covering.count == 1 else {
            throw APIError(code: "SEMESTER_AMBIGUOUS", message: "无法确定当前学期，请稍后刷新")
        }
        return covering[0]
    }

    private struct CatalogCache: Codable {
        let version: Int
        let semesters: [SchoolSemester]
        let semestersUpdatedAt: Date
        let selectedSemesterId: String
        let courses: [CatalogCourse]
        let updatedAt: Date
    }
    private struct AttendanceCache: Codable {
        let version: Int
        let summary: CourseAttendanceSummary
        let updatedAt: Date
    }

    private func saveCatalogCache(accountId: String) {
        guard let selectedSemester, let semesterDate = semestersUpdatedAt, let courseDate = catalogUpdatedAt,
              catalogCourses.allSatisfy({ $0.semesterId == selectedSemester.id }),
              let data = try? JSONEncoder().encode(CatalogCache(version: 1, semesters: semesters,
                    semestersUpdatedAt: semesterDate, selectedSemesterId: selectedSemester.id,
                    courses: catalogCourses, updatedAt: courseDate)) else { return }
        defaults.set(data, forKey: "catalog-\(accountId)")
    }

    private func loadCatalogCache(for accountId: String) {
        guard let data = defaults.data(forKey: "catalog-\(accountId)"),
              let cache = try? JSONDecoder().decode(CatalogCache.self, from: data), cache.version == 1,
              let semester = cache.semesters.first(where: { $0.id == cache.selectedSemesterId }),
              cache.courses.allSatisfy({ $0.semesterId == semester.id }) else { return }
        semesters = cache.semesters
        semestersUpdatedAt = cache.semestersUpdatedAt
        selectedSemester = semester
        catalogCourses = cache.courses
        catalogUpdatedAt = cache.updatedAt
        catalogIsCached = true
    }

    private func saveAttendanceCache(accountId: String, courseId: String, summary: CourseAttendanceSummary) {
        guard let updated = attendanceUpdatedAt[courseId],
              let data = try? JSONEncoder().encode(AttendanceCache(version: 1, summary: summary, updatedAt: updated)) else { return }
        defaults.set(data, forKey: "attendance-\(accountId)-\(courseId)")
    }

    private func loadAttendanceCache(accountId: String, courseId: String) {
        guard let data = defaults.data(forKey: "attendance-\(accountId)-\(courseId)"),
              let cache = try? JSONDecoder().decode(AttendanceCache.self, from: data), cache.version == 1,
              cache.summary.records.allSatisfy({ $0.courseId == courseId }) else { return }
        attendanceByCourse[courseId] = cache.summary
        attendanceUpdatedAt[courseId] = cache.updatedAt
    }

    private func invalidateAttendance(for courseId: String?) {
        guard let id = courseId else { return }
        let courseId = canonicalCourseID(for: id)
        attendanceUpdatedAt.removeValue(forKey: courseId)
        if let accountId = activeAccountID { defaults.removeObject(forKey: "attendance-\(accountId)-\(courseId)") }
    }

    static func demoCourses(on date: Date) -> [Course] {
        let day = SchoolDate.key(date)
        return [
            Course(id: "1000001", courseId: "demo-matrix", name: "矩阵分析", teacher: "李明远", classroom: "教学楼 A101", beginTime: "08:30", endTime: "10:10", day: day, signed: true),
            Course(id: "1000002", courseId: "demo-ai", name: "高级人工智能", teacher: "陈思远", classroom: "教学楼 B203", beginTime: "10:30", endTime: "12:10", day: day),
            Course(id: "1000003", courseId: "demo-english", name: "学术英语写作", teacher: "王雅文", beginTime: "13:30", endTime: "15:10", day: day)
        ]
    }

    static let demoCatalogCourses = [
        CatalogCourse(id: "demo-matrix", number: "MATH6001", name: "矩阵分析", teacher: "李明远", classroom: "教学楼 A101", semesterId: "demo", beginDate: SchoolDate.key(.now), endDate: SchoolDate.key(.now), totalSessions: 16, completedSessions: 3),
        CatalogCourse(id: "demo-ai", number: "CS6002", name: "高级人工智能", teacher: "陈思远", classroom: "教学楼 B203", semesterId: "demo", beginDate: SchoolDate.key(.now), endDate: SchoolDate.key(.now), totalSessions: 16, completedSessions: 3),
        CatalogCourse(id: "demo-english", number: "ENG6003", name: "学术英语写作", teacher: "王雅文", classroom: nil, semesterId: "demo", beginDate: SchoolDate.key(.now), endDate: SchoolDate.key(.now), totalSessions: 12, completedSessions: 2)
    ]
}

// Schedule synchronization shares the existing per-day freshness and account-generation guards.
extension AppModel {
    var isScheduleRefreshing: Bool { isSemesterSyncing || isRefreshing(on: selectedDate) }

    var weekSchedulePresentation: WeekSchedulePresentation {
        let key = SchoolDate.key(SchoolDate.week(containing: selectedDate)[0])
        if let cached = weekPresentations[key] { return cached }
        let entries = ScheduleLayout.weekEntries(courses, containing: selectedDate,
                                                semesters: identitySemesters,
                                                includeOutsideWeek: showOutsideWeekCourses, catalog: catalogCourses)
        let value = WeekSchedulePresentation(entries: entries)
        if weekPresentations.count >= 8 { weekPresentations.removeAll() }
        weekPresentations[key] = value
        return value
    }

    func courses(on date: Date) -> [Course] {
        let key = SchoolDate.key(date)
        return courses.filter { normalizedDay($0.day) == key }
            .sorted { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }
    }

    func scheduleUpdatedAt(on date: Date) -> Date? {
        let day = SchoolDate.key(date)
        return semesterSchedules.values.first {
            $0.semester.beginDate <= day && day <= $0.semester.endDate
        }?.updatedAt
    }

    func hasSchedule(on date: Date) -> Bool { courseUpdates[SchoolDate.key(date)] != nil }

    func openScheduleDate(_ date: Date) async {
        let token = generation
        if let session, !hasSchedule(on: date) {
            if loadCache(for: session, date: date) { courseFreshness[SchoolDate.key(date)] = false }
        }
        let key = "\(session?.studentNo ?? "demo")|\(SchoolDate.key(date))"
        if !checkedScheduleDays.contains(key), dayRetryAfter[SchoolDate.key(date)].map({ $0 > Date() }) != true {
            await refresh(on: date)
        }
        guard generation == token, !Task.isCancelled else { return }
        await synchronizeSchedules()
        guard generation == token, !Task.isCancelled, SchoolDate.key(date) == SchoolDate.key(selectedDate) else { return }
        if scheduleMode == .week { await loadVisibleWeek(containing: date) }
    }

    private func loadVisibleWeek(containing date: Date, retryFailed: Bool = false) async {
        let token = generation
        for day in SchoolDate.week(containing: date) {
            guard generation == token, !Task.isCancelled, scheduleMode == .week,
                  SchoolDate.key(date) == SchoolDate.key(selectedDate) else { return }
            let key = SchoolDate.key(day)
            // Semester endpoints can fall midweek. Fill the visible boundary dates without
            // pretending that those dates belong to the completed semester snapshot.
            guard !hasSchedule(on: day) || scheduleDayErrors[key] != nil else { continue }
            if isDemo { populateDemoSemester(containing: day); continue }
            if !retryFailed, dayRetryAfter[key].map({ $0 > Date() }) == true { continue }
            await refresh(on: day)
        }
    }

    func refreshSchedule() async {
        if scheduleMode == .week {
            let token = generation
            let date = selectedDate
            await synchronizeSchedules(force: true)
            guard generation == token else { return }
            await loadVisibleWeek(containing: date, retryFailed: true)
        } else {
            let token = generation
            await refresh(on: selectedDate)
            guard generation == token else { return }
            await synchronizeSchedules()
        }
    }

    /// Called by the foreground lifecycle, not by a background scheduler.
    func maintainScheduleCache() async {
        scheduleMonitoringStarted = true
        await synchronizeSchedules()
    }

    func synchronizeSchedules(force: Bool = false) async {
        guard isConnected, !showLogin, !automaticRefreshPaused, !Task.isCancelled else { return }
        if isDemo { populateDemoSemester(containing: selectedDate); return }
        if let scheduleSyncTask {
            let token = generation
            await scheduleSyncTask.value
            guard generation == token, !Task.isCancelled else { return }
            // The user may have selected another semester while this batch was running.
            await synchronizeSchedules()
            return
        }
        if !force, scheduleRetryAfter.map({ $0 > Date() }) == true { return }
        guard let session else { return }
        let token = generation
        let requestedDate = selectedDate
        if force {
            let day = SchoolDate.key(requestedDate)
            for snapshot in semesterSchedules.values where snapshot.semester.beginDate <= day && day <= snapshot.semester.endDate {
                pendingSemesterRefreshes.insert(snapshot.semester.id)
            }
            savePendingScheduleSync(for: session)
        }
        let task = Task { await self.performScheduleSync(session: session, date: requestedDate, force: force, token: token) }
        scheduleSyncTask = task
        await task.value
        // A date check can detect a change while a batch is already running.
        if generation == token, needsFullScheduleRefresh, scheduleRetryAfter == nil, !Task.isCancelled {
            await synchronizeSchedules()
        }
    }

    private func scheduleRead<T: Sendable>(token: UUID, _ operation: (SchoolSession) async throws -> T) async throws -> T {
        try Task.checkCancellation()
        guard generation == token, let session, !showLogin, !automaticRefreshPaused else { throw CancellationError() }
        let value: T
        do { value = try await operation(session) }
        catch let error as APIError where error.isSessionExpired {
            guard let renewed = await recoverSession(session, accountToken: token) else {
                if generation == token { markLoginRequired(for: session.studentNo); requestLogin(for: session.studentNo) }
                throw error
            }
            do { value = try await operation(renewed) }
            catch let error as APIError where error.isSessionExpired {
                if generation == token { markLoginRequired(for: session.studentNo); requestLogin(for: session.studentNo) }
                throw error
            }
        }
        try Task.checkCancellation()
        guard generation == token, !showLogin, !automaticRefreshPaused else { throw CancellationError() }
        return value
    }

    private func performScheduleSync(session: SchoolSession, date: Date, force: Bool, token: UUID) async {
        defer {
            if generation == token { isSemesterSyncing = false; scheduleSyncProgress = ""; scheduleSyncTask = nil }
        }
        let selectedDay = SchoolDate.key(date)
        let existing = semesterSchedules.values.first { $0.semester.beginDate <= selectedDay && selectedDay <= $0.semester.endDate }
        let due = semesterSchedules.values.contains { $0.needsRefresh(at: .now) }
        guard force || needsFullScheduleRefresh || !pendingSemesterRefreshes.isEmpty || !pendingScheduleWeeks.isEmpty || existing == nil || due else { return }
        isSemesterSyncing = true
        scheduleSyncError = nil
        do {
            let terms = try await scheduleRead(token: token) { try await self.service.semesters(session: $0) }
            let matching = terms.filter { $0.beginDate <= selectedDay && selectedDay <= $0.endDate }
            let allCached = needsFullScheduleRefresh
            let legacyDates = defaults.dictionaryRepresentation().keys.compactMap { key -> String? in
                let prefix = "courses-\(session.studentNo)-"
                guard key.hasPrefix(prefix) else { return nil }
                return CourseTime.normalizeDay(String(key.dropFirst(prefix.count)))
            }
            var targets = terms.filter { term in
                let cache = semesterSchedules[term.id]
                let coversCachedDay = legacyDates.contains { term.beginDate <= $0 && $0 <= term.endDate }
                return matching.contains(where: { $0.id == term.id }) && (force || cache == nil || cache!.needsRefresh(at: .now))
                    || pendingSemesterRefreshes.contains(term.id)
                    || cache?.needsRefresh(at: .now) == true
                    || allCached && (cache != nil || coversCachedDay)
            }
            // Keep historical cached terms even if the semester listing no longer includes them.
            for cache in semesterSchedules.values where !terms.contains(where: { $0.id == cache.semester.id }) {
                if allCached || pendingSemesterRefreshes.contains(cache.semester.id) || cache.needsRefresh(at: .now) { targets.append(cache.semester) }
            }
            targets.sort {
                let lhs = $0.beginDate <= selectedDay && selectedDay <= $0.endDate
                let rhs = $1.beginDate <= selectedDay && selectedDay <= $1.endDate
                return lhs != rhs ? lhs : $0.beginDate > $1.beginDate
            }
            if matching.count > 1 { throw APIError(code: "SEMESTER_AMBIGUOUS", message: "无法确定所选日期的学期，已保留缓存课表。") }
            pendingSemesterRefreshes.formIntersection(Set(terms.map(\.id)).union(semesterSchedules.keys))
            pendingSemesterRefreshes.formUnion(targets.map(\.id))
            if allCached {
                for day in legacyDates where !terms.contains(where: { $0.beginDate <= day && day <= $0.endDate }) {
                    if let value = CourseTime.parse(day: day, time: "00:00"), let start = SchoolDate.week(containing: value).first {
                        pendingScheduleWeeks.insert(SchoolDate.key(start))
                    }
                }
            }
            needsFullScheduleRefresh = false
            savePendingScheduleSync(for: session)
            for term in targets {
                try await synchronizeSemester(term, token: token)
                guard generation == token, !Task.isCancelled else { throw CancellationError() }
                pendingSemesterRefreshes.remove(term.id)
                savePendingScheduleSync(for: session)
            }
            // Legacy weeks outside known semesters also retain failed work for retry.
            for key in pendingScheduleWeeks.sorted() {
                guard let start = CourseTime.parse(day: key, time: "00:00") else { continue }
                try await synchronizeUnassignedWeek(containing: start, token: token)
                pendingScheduleWeeks.remove(key)
                savePendingScheduleSync(for: session)
            }
            if matching.isEmpty {
                try await synchronizeUnassignedWeek(containing: date, token: token)
                throw APIError(code: "SEMESTER_UNKNOWN", message: "无法确定所选日期的学期范围，已更新本周；尚未完成完整学期同步。")
            }
            scheduleRetryAfter = nil
            scheduleFailureCount = 0
        } catch {
            guard generation == token, !(error is CancellationError) else { return }
            scheduleSyncError = "\(scheduleSyncProgress.isEmpty ? "课表" : scheduleSyncProgress)同步未完成：\(error.localizedDescription)"
            scheduleFailureCount += 1
            scheduleRetryAfter = Date().addingTimeInterval([60.0, 120, 300][min(scheduleFailureCount - 1, 2)])
            // Failed and not-yet-started semesters remain pending; successful ones need not repeat.
        }
    }

    private func synchronizeSemester(_ term: SchoolSemester, token: UUID) async throws {
        let days = ScheduleCalendar.days(in: term)
        guard !days.isEmpty else { throw APIError(code: "SEMESTER_RANGE", message: "学期日期范围无效") }
        refreshSequence += 1
        let sequence = refreshSequence
        let wanted = Set(days.map(SchoolDate.key))
        var staged: [Course] = []
        var visited = Set<String>()
        for day in days {
            let week = SchoolDate.week(containing: day)
            let weekKey = SchoolDate.key(week[0])
            guard visited.insert(weekKey).inserted else { continue }
            let required = week.filter { wanted.contains(SchoolDate.key($0)) }
            let rangeStart = SchoolDate.text(required.first!, "yyyy年M月d日")
            let rangeEnd = SchoolDate.text(required.last!, "yyyy年M月d日")
            scheduleSyncProgress = "\(term.name) · \(rangeStart) - \(rangeEnd)"
            let result = try await scheduleRead(token: token) { try await self.service.weeklySchedule(session: $0, date: day) }
            let requiredKeys = Set(required.map(SchoolDate.key))
            staged += result.courses.filter { requiredKeys.contains(normalizedDay($0.day)) }
            for missing in required where !result.coveredDays.contains(SchoolDate.key(missing)) {
                let values = try await scheduleRead(token: token) { try await self.service.dailySchedule(session: $0, date: missing) }
                staged += values
            }
        }
        try Task.checkCancellation()
        guard generation == token, let session else { throw CancellationError() }
        let accepted = Set(wanted.filter { scheduleWriteSequences[$0, default: 0] <= sequence })
        mergeCourses(staged.filter { accepted.contains(normalizedDay($0.day)) }, replacingDays: accepted)
        let now = Date()
        for day in accepted {
            courseRefreshSequences[day] = max(courseRefreshSequences[day, default: 0], sequence)
            scheduleWriteSequences[day] = sequence
            courseFreshness[day] = true
            courseUpdates[day] = now
            courseNotices[day] = nil
            scheduleDayErrors[day] = nil
            dayRetryAfter[day] = nil
            checkedScheduleDays.insert("\(session.studentNo)|\(day)")
        }
        // Include newer daily checks and local attendance writes in the committed snapshot.
        let snapshot = SemesterScheduleCache(semester: term, courses: courses.filter { wanted.contains(normalizedDay($0.day)) }, updatedAt: now)
        semesterSchedules[term.id] = snapshot
        saveSemesterSchedules(for: session)
        lastUpdated = now
        publishWidget()
        if hasEnabledReminders { await scheduleReminders() }
    }

    private func synchronizeUnassignedWeek(containing date: Date, token: UUID) async throws {
        for day in SchoolDate.week(containing: date) {
            refreshSequence += 1
            let sequence = refreshSequence
            let key = SchoolDate.key(day)
            let values = try await scheduleRead(token: token) { try await self.service.dailySchedule(session: $0, date: day) }
            guard courseRefreshSequences[key, default: 0] <= sequence, let session else { continue }
            mergeCourses(values, replacingDays: [key])
            courseRefreshSequences[key] = sequence
            scheduleWriteSequences[key] = sequence
            courseFreshness[key] = true
            courseUpdates[key] = .now
            scheduleDayErrors[key] = nil
            checkedScheduleDays.insert("\(session.studentNo)|\(key)")
            saveCache(for: session, date: day)
        }
    }

    private func saveSemesterSchedules(for session: SchoolSession) {
        guard let data = try? JSONEncoder().encode(Array(semesterSchedules.values)) else { return }
        defaults.set(data, forKey: "semester-schedules-\(session.studentNo)")
    }

    private struct PendingScheduleSync: Codable {
        let allCached: Bool
        let semesters: Set<String>
        let weeks: Set<String>
    }

    private func savePendingScheduleSync(for session: SchoolSession) {
        let key = "schedule-pending-\(session.studentNo)"
        if !needsFullScheduleRefresh && pendingSemesterRefreshes.isEmpty && pendingScheduleWeeks.isEmpty {
            defaults.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(PendingScheduleSync(allCached: needsFullScheduleRefresh,
                                  semesters: pendingSemesterRefreshes, weeks: pendingScheduleWeeks)) {
            defaults.set(data, forKey: key)
        }
    }

    private func loadSemesterSchedules(for session: SchoolSession) {
        if let data = defaults.data(forKey: "schedule-pending-\(session.studentNo)"),
           let pending = try? JSONDecoder().decode(PendingScheduleSync.self, from: data) {
            needsFullScheduleRefresh = pending.allCached
            pendingSemesterRefreshes = pending.semesters
            pendingScheduleWeeks = pending.weeks
        }
        if let data = defaults.data(forKey: "semester-schedules-\(session.studentNo)"),
           let snapshots = try? JSONDecoder().decode([SemesterScheduleCache].self, from: data) {
            for snapshot in snapshots {
                let days = ScheduleCalendar.days(in: snapshot.semester)
                guard !days.isEmpty else { continue }
                semesterSchedules[snapshot.semester.id] = snapshot
                mergeCourses(snapshot.courses, replacingDays: Set(days.map(SchoolDate.key)))
                for date in days {
                    let key = SchoolDate.key(date)
                    courseUpdates[key] = snapshot.updatedAt
                    courseFreshness[key] = false
                }
            }
        }
        // Newer per-day overlays survive restarts without changing the full-sync timestamp.
        for key in defaults.dictionaryRepresentation().keys {
            let prefix = "courses-\(session.studentNo)-"
            guard key.hasPrefix(prefix), let date = CourseTime.parse(day: String(key.dropFirst(prefix.count)), time: "00:00") else { continue }
            if loadCache(for: session, date: date) { courseFreshness[SchoolDate.key(date)] = false }
        }
    }

    private func populateDemoSemester(containing date: Date) {
        let calendar = SchoolDate.calendar
        let year = calendar.component(.year, from: date)
        let autumn = calendar.component(.month, from: date) >= 7
        let begin = String(format: "%04d%02d01", year, autumn ? 7 : 1)
        let end = String(format: "%04d%02d%02d", year, autumn ? 12 : 6, autumn ? 31 : 30)
        let term = SchoolSemester(id: "demo-\(begin)", name: "演示学期", beginDate: begin, endDate: end, isCurrent: true)
        guard semesterSchedules[term.id] == nil else { return }
        let days = ScheduleCalendar.days(in: term)
        for day in days {
            let key = SchoolDate.key(day)
            if !hasSchedule(on: day) {
                mergeCourses(Self.demoCourses(on: day), replacingDays: [key])
                courseUpdates[key] = .now
            }
            checkedScheduleDays.insert("demo|\(key)")
        }
        semesterSchedules[term.id] = SemesterScheduleCache(semester: term, courses: courses.filter {
            term.beginDate <= normalizedDay($0.day) && normalizedDay($0.day) <= term.endDate
        }, updatedAt: .now)
    }
}
