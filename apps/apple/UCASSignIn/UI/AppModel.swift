import SwiftUI
import UserNotifications
import CloudKit

typealias AttendanceRecord = SyncAttendanceRecord

struct PendingSignConfirmation: Identifiable {
    let id = UUID()
    let course: Course
    let accountGeneration: UUID
}

/// NotificationCenter tokens may be removed from any thread. This owner keeps
/// destruction outside AppModel's actor-isolated state under Swift 6.
private final class CloudSyncNotificationObservation: @unchecked Sendable {
    private let token: NSObjectProtocol
    init(_ token: NSObjectProtocol) { self.token = token }
    deinit { NotificationCenter.default.removeObserver(token) }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var session: SchoolSession?
    @Published var isDemo = false
    @Published var courses: [Course] = [] {
        didSet {
            weekPresentations.removeAll()
            if !courseSchedulePresentations.isEmpty, !ScheduleCalendar.sameArrangements(oldValue, courses) { courseSchedulePresentations.removeAll() }
        }
    }
    @Published private var attendanceStates: [String: AttendanceEvidence] = [:]
    private var invalidatedAttendance = Set<String>()
    private var attendanceVersions: [String: Int] = [:]
    private var attendanceRevisions: [String: Int] = [:]
    private var dayVerifiedAt: [String: Date] = [:]
    private var autoSignQueryStartedAt: [String: Date] = [:]
    private var syncingSemesterID: String?
    var attendanceNow: () -> Date = Date.init
    private var invalidatedDays = Set<String>()
    private var semesterReadTask: Task<[SchoolSemester], Error>?
    private var directoryReadTasks: [String: Task<[CatalogCourse], Error>] = [:]
    private var weekPresentations: [String: WeekSchedulePresentation] = [:]
    private var courseSchedulePresentations: [CatalogCourse: CourseSchedulePresentation] = [:]
    private var courseScheduleDirectories: [String: (courses: [CatalogCourse], updatedAt: Date)] = [:]
    private var courseScheduleTasks: [String: Task<Void, Never>] = [:]
    private var courseScheduleRetryAfter: [String: Date] = [:]
    @Published private(set) var courseScheduleLoading: Set<String> = []
    @Published private(set) var courseScheduleErrors: [String: String] = [:]
    @Published var visibleCourseSchedule: CatalogCourse?
    private var scheduleColors: [String: ScheduleColors] = [:]
    @Published var selectedDate = Date()
    @Published var scheduleMode: ScheduleMode = .day {
        didSet { defaults.set(scheduleMode.rawValue, forKey: "scheduleViewMode"); recordCloudChanges() }
    }
    @Published var showOutsideWeekCourses = false {
        didSet {
            defaults.set(showOutsideWeekCourses, forKey: "showOutsideWeekCourses")
            weekPresentations.removeAll()
            recordCloudChanges()
        }
    }
    @Published private(set) var semesterSchedules: [String: SemesterScheduleCache] = [:] {
        didSet { weekPresentations.removeAll(); courseSchedulePresentations.removeAll() }
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
    @Published private var refreshTasks: [String: (task: Task<Void, Never>, revision: Int)] = [:]
    @Published var signingID: String?
    @Published var loginRequest: LoginRequest?
    @Published var showAccountManagement = false
    @Published var showSettings = false
    @Published private(set) var accounts: [StoredAccount] = []
    @Published private(set) var activeAccountID: String?
    @Published private(set) var accountGeneration = UUID()
    @Published private(set) var iCloudSyncEnabled = true
    @Published private(set) var iCloudSyncStatus = CloudSyncStatus.syncing
    @Published private(set) var iCloudLastSyncedAt: Date?
    @Published private(set) var iCloudPendingAccounts: [SyncAccountProfile] = []
    @Published private(set) var syncedAutoSignHistory: [String: [SyncAutoSignHistory]] = [:]
    @Published private(set) var syncedPreferencesRevision = 0
    @Published private(set) var historyRetention = HistoryRetentionSettings()
    @Published private var isRecovering = false
    var showLogin: Bool {
        get { loginRequest != nil }
        set { if newValue { presentLogin() } else { loginRequest = nil } }
    }
    var canChangeAccount: Bool { !isAuthenticating && !isRecovering && signingID == nil }
    @Published var notice: String?
    @Published var errorMessage: String? {
        // The settings action belongs to a permission message, not later errors.
        didSet { notificationSettingsNeeded = false }
    }
    @Published private(set) var notificationSettingsNeeded = false
    @Published var lastUpdated: Date?
    @Published private var courseUpdates: [String: Date] = [:]
    @Published private var courseNotices: [String: String] = [:]
    @Published private var courseFreshness: [String: Bool] = [:]
    @Published var records: [AttendanceRecord] = []
    @Published private(set) var remindersEnabled = false
    @Published private(set) var autoSignEnabled = false
    @Published private(set) var autoSignRunning = false
    private var autoSignRunningSince: Date?
    private var autoSignDefaultSince: Date?
    private var autoSignSchoolOffset: TimeInterval = 0
    private var autoSignClockWallAt: Date?
    private var autoSignClockSchoolAt: Date?
    var autoSignMonotonicNow: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    private var autoSignClockUptimeAt: TimeInterval?
    private var autoSignUncalibratedBoundaries = Set<Date>()
    private var autoSignActivationUptimes: [Date: TimeInterval] = [:]
    private var autoSignNotificationIssue: String?
    private var autoSignQuerySchoolStartedAt: [String: Date] = [:]
    private var autoSignVerifiedQuerySequence: [String: Int] = [:]
    private var autoSignClockTask: Task<Void, Never>?
    private var autoSignPermissionTask: Task<Void, Never>?
    private var autoSignPermissionGeneration = UUID()
    private var autoSignNotificationOutcomes: [String: Set<String>] = [:]
    @Published private(set) var autoSignRule = AutoSignPolicy()
    @Published private(set) var autoSignOccurrences: [String: AutoSignOccurrenceOverride] = [:]
    @Published private(set) var autoSignPausedUntil: Date?
    @Published private(set) var autoSignMigrationPending = false
    @Published private(set) var autoSignExecutions: [String: AutoSignExecution] = [:]
    @Published private(set) var autoSignError: String?
    @Published private(set) var confirmationEnabled = false
    @Published private(set) var reminderLeadMinutes = 10
    @Published private(set) var coursePreferences: [String: CoursePreferences] = [:]
    @Published private(set) var semesters: [SchoolSemester] = [] {
        didSet { if oldValue != semesters { weekPresentations.removeAll(); courseSchedulePresentations.removeAll() } }
    }
    @Published private(set) var selectedSemester: SchoolSemester?
    @Published private(set) var catalogCourses: [CatalogCourse] = [] {
        didSet { if oldValue != catalogCourses { weekPresentations.removeAll(); courseSchedulePresentations.removeAll() } }
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
    private let autoSignStore: any AutoSignStore
    private var autoSignStoreAvailable = true
    private var autoSignNetworkIssue = false
    private let defaults: UserDefaults
    private let notifications: any NotificationClient
    private let widgets: any WidgetClient
    private var cloudSync: CloudSyncCoordinator
    private var cloudDefaultsObserver: CloudSyncNotificationObservation?
    private var cloudAccountObserver: CloudSyncNotificationObservation?
    private var isApplyingCloudSync = false
    private var cloudVerifiedSessions: Set<String> = []
    private var cloudDeletedAccounts: Set<String> = []
    private var cloudAppliedIdentity: String?
    private var cloudSessionValidationIssue: String?
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
    private var attendanceTasks: [String: (task: Task<Void, Never>, revision: Int)] = [:]
    private var catalogFailureCount = 0
    private var catalogRetryAfter: Date?
    private var semestersUpdatedAt: Date?

    init(service: QingxinService = QingxinService(), accountStore: (any AccountStore)? = nil,
         defaults: UserDefaults = .standard, notifications: (any NotificationClient)? = nil,
         widgets: (any WidgetClient)? = nil, cloudSync: CloudSyncCoordinator? = nil) {
        self.service = service
        self.defaults = defaults
        self.scheduleMode = ScheduleMode(rawValue: defaults.string(forKey: "scheduleViewMode") ?? "") ?? .day
        self.showOutsideWeekCourses = defaults.bool(forKey: "showOutsideWeekCourses")
        self.historyRetention = (try? HistoryRetentionSettings.from(applicationPreferences:
            Dictionary(uniqueKeysWithValues: HistoryRetentionSettings.applicationKeys.compactMap { key in
                defaults.data(forKey: key).map { (key, $0) }
            }))) ?? .init()
        self.notifications = notifications ?? LiveNotificationClient()
        self.widgets = widgets ?? LiveWidgetClient()
        #if os(macOS)
        let keychain = KeychainStore(service: "\(Bundle.main.bundleIdentifier ?? "cn.ucas.signin.mac").credentials")
        #else
        let keychain = KeychainStore()
        #endif
        self.accountStore = accountStore ?? KeychainAccountStore(keychain: keychain, defaults: defaults)
        self.autoSignStore = accountStore == nil ? FileAutoSignStore() : UserDefaultsAutoSignStore(defaults: defaults)
        self.cloudSync = cloudSync ?? CloudSyncEnvironment.make(defaults: defaults,
            allowLive: accountStore == nil && !AppLaunchEnvironment.isUnitTestHost
                && !ProcessInfo.processInfo.arguments.contains("--demo"))
        self.iCloudSyncEnabled = defaults.object(forKey: "iCloudSyncEnabled") as? Bool ?? true
        self.cloudSync.setEnabled(iCloudSyncEnabled)
        self.cloudSync.snapshot = { [weak self] in try self?.cloudSnapshot() ?? CloudSyncLocalSnapshot() }
        self.cloudSync.apply = { [weak self] changes in try await self?.applyCloudChanges(changes) }
        self.cloudSync.onChange = { [weak self] in self?.updateCloudStatus() }
        self.cloudDefaultsObserver = CloudSyncNotificationObservation(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
            object: defaults, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.recordCloudChanges() }
            })
        self.cloudAccountObserver = CloudSyncNotificationObservation(NotificationCenter.default.addObserver(forName: .CKAccountChanged,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.iCloudPendingAccounts = []
                    self?.syncedAutoSignHistory = [:]
                    self?.cloudVerifiedSessions = []
                    self?.cloudDeletedAccounts = []
                    self?.cloudSessionValidationIssue = nil
                    self?.cloudSync.accountDidChange()
                }
            })
        updateCloudStatus()
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
        !isDemo && (courseFreshness[normalizedDay(course.day)] != true || attendanceStatus(for: course) == .unknown)
    }
    func canSign(_ course: Course, accountGeneration expectedGeneration: UUID? = nil) -> Bool {
        guard expectedGeneration == nil || expectedGeneration == generation,
              !isAuthenticating, !isRecovering, !automaticRefreshPaused, !showLogin,
              !accounts.contains(where: { $0.id == activeAccountID && $0.requiresLogin }) else { return false }
        guard let current = courses.first(where: {
            $0.id == course.id && normalizedDay($0.day) == normalizedDay(course.day)
        }) else { return false }
        return attendanceStatus(for: current) == .unsigned && !isSignInDisabled(for: current) && signingID == nil && !needsCourseRefresh(current)
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
        let legacy = coursePreferences.filter { canonicalCourseID(for: $0.key) == canonical }.sorted { $0.key < $1.key }.map(\.value)
        // Preserve restrictive legacy choices until the user explicitly saves the unified course setting.
        func override(_ values: [PreferenceOverride], preferred: PreferenceOverride) -> PreferenceOverride {
            if values.contains(preferred) { return preferred }
            return values.first { $0 != .inherit } ?? .inherit
        }
        let autoRule = AutoSignPolicyOverride(offsetMinutes: legacy.compactMap { $0.autoSignRule?.offsetMinutes }.last,
            missedAction: legacy.compactMap { $0.autoSignRule?.missedAction }.last,
            maxSubmissions: legacy.compactMap { $0.autoSignRule?.maxSubmissions }.last,
            retryMinutes: legacy.compactMap { $0.autoSignRule?.retryMinutes }.last,
            notification: legacy.compactMap { $0.autoSignRule?.notification }.last)
        return CoursePreferences(confirmation: override(legacy.map(\.confirmation), preferred: .enabled),
                                 autoSign: override(legacy.map(\.autoSign), preferred: .disabled),
                                 reminders: override(legacy.map(\.reminders), preferred: .disabled),
                                 reminderLeadMinutes: legacy.compactMap(\.reminderLeadMinutes).max(),
                                 signInDisabled: legacy.contains { $0.signInDisabled },
                                 autoSignRule: autoRule.hasValues ? autoRule : nil,
                                 autoSignEnabledSince: legacy.compactMap(\.autoSignEnabledSince).max())
    }

    func isSignInDisabled(for course: Course) -> Bool { isSignInDisabled(for: preferenceID(for: course)) }
    func effectiveConfirmation(for course: Course) -> Bool { effectiveConfirmation(for: preferenceID(for: course)) }
    func effectiveAutoSign(for course: Course) -> Bool { effectiveAutoSign(for: preferenceID(for: course)) }
    func effectiveReminders(for course: Course) -> Bool { effectiveReminders(for: preferenceID(for: course)) }
    func effectiveReminderLead(for course: Course) -> Int { effectiveReminderLead(for: preferenceID(for: course)) }
    func isSignInDisabled(for courseId: String?) -> Bool {
        if let activeAccountID, cloudDeletedAccounts.contains(activeAccountID) { return true }
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
        guard let courseId else { return autoSignRunning }
        return autoSignRunning && coursePreferences(for: courseId).autoSign.resolve(default: true)
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
        recordCloudChanges()
    }

    func restore() async {
        guard !restored else { return }
        restored = true
        // Demo launch arguments never read or migrate the user's real credentials.
        if ProcessInfo.processInfo.arguments.contains("--demo") { enterDemo(); return }
        do {
            try loadAccounts()
            let captured = recordCloudChanges()
            // Shared retention choices must be fetched before expiring startup history.
            if !iCloudSyncEnabled, captured { maintainHistoryRetention(recordCleanup: true) }
            if let account = vault.accounts.first(where: { $0.id == vault.activeAccountID }) {
                activate(account)
                if account.requiresLogin { requestLogin(for: account.id) }
                else { await refresh() }
            }
            if iCloudSyncEnabled { Task { await self.synchronizeICloud() } }
        } catch { errorMessage = "无法读取本机登录信息：\(error.localizedDescription)" }
    }

    func presentLogin(accountID: String? = nil) {
        guard canChangeAccount else { return }
        if let accountID, !accounts.contains(where: { $0.id == accountID }),
           !iCloudPendingAccounts.contains(where: { $0.studentNo == accountID }) { return }
        loginRequest = LoginRequest(accountID: accountID)
    }

    private func requestLogin(for accountID: String) {
        guard activeAccountID == accountID, accounts.contains(where: { $0.id == accountID && $0.requiresLogin }) else { return }
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
            cloudDeletedAccounts.remove(account.id)
            recordCloudChanges(explicitLogin: account.id)
            iCloudPendingAccounts.removeAll { $0.studentNo == account.id }
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
        autoSignClockTask?.cancel(); autoSignClockTask = nil
        autoSignPermissionTask?.cancel(); autoSignPermissionTask = nil
        autoSignPermissionGeneration = UUID()
        autoSignSchoolOffset = 0
        autoSignClockWallAt = nil; autoSignClockUptimeAt = nil; autoSignClockSchoolAt = nil
        autoSignUncalibratedBoundaries = []; autoSignActivationUptimes = [:]; autoSignNotificationIssue = nil; autoSignQuerySchoolStartedAt = [:]; autoSignVerifiedQuerySequence = [:]
        autoSignNotificationOutcomes = [:]
        generation = UUID()
        attendanceStates = [:]; invalidatedAttendance = []; syncingSemesterID = nil
        attendanceVersions = [:]; attendanceRevisions = [:]; dayVerifiedAt = [:]; autoSignQueryStartedAt = [:]; invalidatedDays = []
        semesterReadTask?.cancel(); semesterReadTask = nil
        directoryReadTasks.values.forEach { $0.cancel() }; directoryReadTasks = [:]
        cancelRefreshes()
        scheduleSyncTask?.cancel()
        scheduleSyncTask = nil
        semesterSchedules = [:]
        scheduleColors = [:]
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
        Task { await clearCourseReminderNotifications() }
        widgets.clear()
        courseFreshness.removeAll()
        automaticRefreshPaused = false
        signingID = nil
        catalogRefreshTask?.cancel()
        catalogRefreshTask = nil
        attendanceTasks.values.forEach { $0.task.cancel() }
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
        visibleCourseSchedule = nil
        courseScheduleTasks.values.forEach { $0.cancel() }
        courseScheduleTasks.removeAll()
        courseScheduleDirectories.removeAll()
        courseSchedulePresentations.removeAll()
        courseScheduleLoading = []
        courseScheduleErrors = [:]
        courseScheduleRetryAfter = [:]
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
        autoSignRunning = false
        autoSignRunningSince = nil
        autoSignDefaultSince = nil
        autoSignRule = .init()
        autoSignOccurrences = [:]
        autoSignPausedUntil = nil
        autoSignMigrationPending = false
        autoSignExecutions = [:]
        autoSignError = nil
        autoSignStoreAvailable = true
        autoSignNetworkIssue = false
        remindersEnabled = false
        confirmationEnabled = false
        reminderLeadMinutes = 10
        coursePreferences = [:]
    }

    private func activate(_ account: StoredAccount) {
        resetAccountState()
        var account = account
        let prior = account.preferences
        autoSignUncalibratedBoundaries = Set(prior.autoSignPendingClockBoundaries)
        if prior.autoSignSinceUsesSchoolTime != true && autoSignUncalibratedBoundaries.isEmpty {
            autoSignUncalibratedBoundaries = Set([prior.autoSignRunningSince, prior.autoSignDefaultSince].compactMap { $0 }
                + prior.courses.values.compactMap(\.autoSignEnabledSince) + prior.autoSignOccurrences.values.compactMap(\.enabledSince))
        }
        if prior.autoSignIsRunning && (prior.autoSignRunning == nil || !prior.autoSignEnabled)
            || prior.autoSignRunning != nil && prior.autoSignEnabled != prior.autoSignIsRunning {
            account.preferences = prior.unifyingAutoSign(at: attendanceNow())
            if let since = account.preferences.autoSignDefaultSince, since != prior.autoSignDefaultSince { autoSignUncalibratedBoundaries.insert(since); autoSignActivationUptimes[since] = autoSignMonotonicNow() }
            var updated = vault
            if let index = updated.accounts.firstIndex(where: { $0.id == account.id }) {
                updated.accounts[index].preferences = account.preferences
                do { try commit(updated) }
                catch {
                    // Keep the safe participation boundary in memory while storage is unavailable.
                    vault = updated
                    updateAccountList()
                    autoSignStoreAvailable = false
                    autoSignError = "自动签到已暂停：设置升级未能保存：\(error.localizedDescription)"
                }
            }
        }
        session = account.session
        activeAccountID = account.id
        cloudSync.setEnabled(iCloudSyncEnabled)
        autoSignEnabled = account.preferences.autoSignIsRunning
        autoSignRunning = account.preferences.autoSignIsRunning
        autoSignRunningSince = account.preferences.autoSignRunningSince
        autoSignDefaultSince = account.preferences.autoSignDefaultSince
        autoSignRule = account.preferences.autoSignRule
        autoSignOccurrences = account.preferences.autoSignOccurrences
        autoSignPausedUntil = account.preferences.autoSignPausedUntil
        autoSignMigrationPending = account.preferences.needsAutoSignMigrationNotice
        remindersEnabled = account.preferences.remindersEnabled
        confirmationEnabled = account.preferences.confirmationEnabled
        reminderLeadMinutes = account.preferences.reminderLeadMinutes
        coursePreferences = account.preferences.courses
        automaticRefreshPaused = account.requiresLogin
        loadRecords()
        do {
            autoSignExecutions = try autoSignStore.load(accountID: account.id)
            for key in autoSignExecutions.keys where (autoSignExecutions[key]?.submissions ?? 0) > 0 && autoSignExecutions[key]?.lastSchoolSubmissionAt == nil {
                autoSignExecutions[key]?.nextAt = attendanceNow()
            }
            for key in autoSignExecutions.keys where autoSignExecutions[key]?.stage == .submitting {
                autoSignExecutions[key]?.transition(.verifying, now: .now, message: "上次提交结果未知，等待学校状态核实")
            }
        } catch {
            autoSignStoreAvailable = false
            autoSignError = "自动签到已暂停：\(error.localizedDescription)"
        }
        loadAttendanceState()
        loadCatalogCache(for: account.id)
        loadSemesterSchedules(for: account.session)
        if loadCache(for: account.session, date: selectedDate) {
            courseFreshness[SchoolDate.key(selectedDate)] = false
            notice = "正在显示本机缓存，同步成功后即可签到。"
            courseNotices[SchoolDate.key(selectedDate)] = notice
            publishWidget()
        }
        if autoSignRunning { warmAutoSignClock() }
    }

    func enterDemo() {
        guard canChangeAccount else { return }
        resetAccountState()
        isDemo = true
        cloudSync.setEnabled(false)
        courses = Self.demoCourses(on: selectedDate)
        semesters = [Self.demoSemester(containing: selectedDate)]
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
        if let read = refreshTasks[day] {
            let token = generation
            await read.task.value
            if generation == token, invalidatedDays.contains(day), courseRefreshSequences[day] != read.revision {
                await refresh(on: date)
            }
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
        autoSignQueryStartedAt[day] = attendanceNow()
        autoSignQuerySchoolStartedAt[day] = autoSignSchoolNow
        let task = Task {
            await performRefresh(on: date, session: session, accountToken: accountToken, requestSequence: requestSequence)
        }
        refreshTasks[day] = (task, requestSequence)
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
            for value in result { observeAttendance(value, source: .daily, sequence: requestSequence) }
            dayVerifiedAt[queriedDay] = attendanceNow()
            autoSignVerifiedQuerySequence[queriedDay] = requestSequence
            reconcileAutoSignSuccesses(result)
            invalidatedDays.remove(queriedDay)
            saveAttendanceState()
            let incoming = result.map { value in
                projectAttendance(value.preservingIdentity(from: previous.first { $0.id == value.id }))
            }
            let changed = !ScheduleCalendar.sameArrangements(previous, incoming)
            let attendanceChanged = previous.contains { old in incoming.first(where: { $0.id == old.id })?.signed != old.signed }
            if hadBaseline && changed {
                if let syncingSemesterID, semesters.contains(where: { $0.id == syncingSemesterID && $0.beginDate <= queriedDay && queriedDay <= $0.endDate }) {
                    pendingSemesterRefreshes.formUnion(semesterSchedules.keys.filter { $0 != syncingSemesterID })
                } else { needsFullScheduleRefresh = true }
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
                        updated[index].signStatusKnown = value.signStatusKnown
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
            if autoSignRunning { warmAutoSignClock() }
            if hasEnabledReminders { await scheduleReminders() }
        } catch {
            guard !Task.isCancelled, generation == accountToken,
                  self.session?.sessionId == requestSession.sessionId else { return }
            if error is CancellationError { return }
            if let apiError = error as? APIError, apiError.isSessionExpired {
                markLoginRequired(for: session.studentNo, failedSession: requestSession)
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

    private func markLoginRequired(for accountID: String, failedSession: SchoolSession) {
        try? cloudSync.invalidateLocalSession(failedSession)
        guard activeAccountID == accountID, session?.sessionId == failedSession.sessionId else { return }
        automaticRefreshPaused = true
        courseFreshness = courseFreshness.mapValues { _ in false }
        reminderGeneration = UUID()
        Task { await clearCourseReminderNotifications() }
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
            markLoginRequired(for: failedSession.studentNo, failedSession: failedSession)
            return nil
        }
        let attemptKey = "\(failedSession.studentNo)|\(failedSession.sessionId)"
        guard let account = accounts.first(where: { $0.id == failedSession.studentNo }),
              !account.requiresLogin, let credentials = account.credentials,
              recoveryAttempts.insert(attemptKey).inserted else {
            markLoginRequired(for: failedSession.studentNo, failedSession: failedSession)
            requestLogin(for: failedSession.studentNo)
            return nil
        }
        isRecovering = true
        automaticRefreshPaused = true
        courseFreshness = courseFreshness.mapValues { _ in false }
        reminderGeneration = UUID()
        Task { await clearCourseReminderNotifications() }
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
                self.markLoginRequired(for: failedSession.studentNo, failedSession: failedSession)
                self.requestLogin(for: failedSession.studentNo)
                return nil
            }
        }
        recoveryTask = task
        return await task.value
    }

    private func cancelRefreshes() {
        for read in refreshTasks.values { read.task.cancel() }
        refreshTasks.removeAll()
        refreshSequence = 0
        courseRefreshSequences.removeAll()
        scheduleWriteSequences.removeAll()
        courseUpdates.removeAll()
        courseNotices.removeAll()
    }

    func selectDate(_ date: Date) async {
        let date = boundedScheduleDate(date)
        selectedDate = date
        if !isCached { notice = nil }
        await openScheduleDate(date)
    }

    func sign(_ course: Course, accountGeneration expectedGeneration: UUID? = nil, automatically: Bool = false) async {
        guard canSign(course, accountGeneration: expectedGeneration) else { return }
        let token = generation
        if automatically, !isDemo, !CachePolicy.isFresh(dayVerifiedAt[normalizedDay(course.day)], at: attendanceNow(), lifetime: 60),
           let date = CourseTime.parse(day: course.day, time: "00:00") { await enterDay(date) }
        guard token == generation else { return }
        await refreshCourseIdentityIfNeeded(for: [course])
        guard token == generation, !Task.isCancelled, canSign(course, accountGeneration: expectedGeneration) else { return }
        let attempt = attemptKey(for: course)
        if !automatically, autoSignExecutions[attempt] != nil || autoSignPlans.contains(where: { $0.key == attempt && $0.isParticipating }) {
            var existing = autoSignExecutions[attempt] ?? AutoSignExecution(key: attempt, now: attendanceNow())
            existing.transition(.skipped, now: attendanceNow(), message: "用户已手动接管", kind: .manualTakeover)
            autoSignExecutions[attempt] = existing
            try? saveAutoSignExecutions()
        }
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
        var autoSubmissionReserved = false
        do {
            let result = try await service.sign(course: course, session: session, authorizeSynchronizedSubmission: { [self] schoolNow in
                // School clock synchronization can suspend before the actual submission.
                guard token == generation, !isSignInDisabled(for: course),
                      attendanceStatus(for: course) == .unsigned, !needsCourseRefresh(course),
                      !automatically || (autoSignRunning && !hasLocalSignSuccess(course)
                          && autoSignPlans.first(where: { $0.key == attempt })?.isParticipating == true
                          && CachePolicy.isFresh(dayVerifiedAt[normalizedDay(course.day)], at: attendanceNow(), lifetime: 60)) else {
                    throw APIError(code: "SIGN_NOT_ALLOWED", message: "签到已取消")
                }
                if automatically {
                    try reserveAutoSignSubmission(course, token: token, schoolNow: schoolNow)
                    autoSubmissionReserved = true
                }
            })
            guard token == generation else { return }
            let succeeded = result.outcome == .signed
            records.insert(AttendanceRecord(courseId: preferenceID(for: course), courseName: course.name, date: .now,
                                            message: result.message, succeeded: succeeded), at: 0)
            if succeeded {
                markSigned(course)
                invalidateAttendance(for: preferenceID(for: course))
                notice = result.message
                courseNotices[normalizedDay(course.day)] = notice
                publishWidget()
                signInFeedback()
            } else { errorMessage = result.message }
            if automatically, var execution = autoSignExecutions[attempt], execution.stage != .signed {
                execution.transition(succeeded ? .signed : result.outcome == .outsideSignWindow ? .needsAttention : .verifying,
                                     now: attendanceNow(), message: result.message,
                                     nextAt: succeeded || result.outcome == .outsideSignWindow ? nil
                                         : nextAutoSignVerification(attempt))
                if !succeeded && result.outcome != .outsideSignWindow && execution.submissions >= (autoSignPlans.first { $0.key == attempt }?.policy.maxSubmissions ?? autoSignRule.maxSubmissions) {
                    execution.nextSchoolVerificationAt = autoSignSchoolNow.addingTimeInterval(30)
                }
                autoSignExecutions[attempt] = execution
                try? saveAutoSignExecutions()
            }
            if automatically { await notifyAutoSign(course, message: result.message, succeeded: succeeded) }
            saveRecords()
            // Only a read is allowed after an uncertain result; never automatically resubmit.
            if let date = CourseTime.parse(day: course.day, time: "00:00") {
                // A request started before signing cannot confirm the new attendance state.
                if let read = refreshTasks[SchoolDate.key(date)] { await read.task.value }
                guard token == generation else { return }
                await refresh(on: date)
            }
        } catch let error as APIError where error.code == "SIGN_NOT_ALLOWED" {
            // No submission was made, so re-enabling may try again normally.
            autoAttempts.remove(attempt)
        } catch {
            guard token == generation else { return }
            if automatically && !autoSubmissionReserved {
                autoAttempts.remove(attempt)
                if autoSignStoreAvailable {
                    autoSignNetworkIssue = true
                    autoSignError = "自动签到等待网络：\(error.localizedDescription)"
                }
                return
            }
            if automatically, var execution = autoSignExecutions[attempt], execution.stage != .signed {
                execution.transition(.verifying, now: attendanceNow(), message: "提交结果未知，等待学校状态核实",
                                     nextAt: nextAutoSignVerification(attempt))
                if execution.submissions >= (autoSignPlans.first { $0.key == attempt }?.policy.maxSubmissions ?? autoSignRule.maxSubmissions) {
                    execution.nextSchoolVerificationAt = autoSignSchoolNow.addingTimeInterval(30)
                }
                autoSignExecutions[attempt] = execution
                try? saveAutoSignExecutions()
            }
            if automatically { await notifyAutoSign(course, message: "提交结果未知，打开应用核实签到状态", succeeded: false) }
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
        guard canSign(course, accountGeneration: expectedGeneration) else { return }
        let token = generation
        await refreshCourseIdentityIfNeeded(for: [course])
        guard token == generation, !Task.isCancelled, canSign(course, accountGeneration: expectedGeneration) else { return }
        if effectiveConfirmation(for: course) {
            pendingSignConfirmation = PendingSignConfirmation(course: course, accountGeneration: expectedGeneration ?? generation)
            return
        }
        await sign(course, accountGeneration: expectedGeneration)
    }

    func confirmPendingSign(_ request: PendingSignConfirmation) async {
        if pendingSignConfirmation?.id == request.id { pendingSignConfirmation = nil }
        guard request.accountGeneration == generation,
              canSign(request.course, accountGeneration: request.accountGeneration) else { return }
        await sign(request.course, accountGeneration: request.accountGeneration)
    }

    private func hasLocalSignSuccess(_ course: Course) -> Bool {
        attendanceStates[attendanceKey(course)]?.lastSuccessfulSignAt != nil
    }

    private func canVerifyExisting(_ course: Course) -> Bool {
        guard autoSignRunning, autoSignPausedUntil.map({ autoSignSchoolNow >= $0 }) ?? true,
              let execution = autoSignExecutions[attemptKey(for: course)], execution.submissions > 0,
              ![.signed, .skipped].contains(execution.stage) else { return false }
        let preferences = coursePreferences(for: preferenceID(for: course) ?? "")
        return !preferences.signInDisabled
            && (autoSignOccurrences[attemptKey(for: course)]?.enabled ?? preferences.autoSign.resolve(default: true))
    }

    private var autoSignSchoolNow: Date {
        if let school = autoSignClockSchoolAt, let uptime = autoSignClockUptimeAt {
            return school.addingTimeInterval(max(0, autoSignMonotonicNow() - uptime))
        }
        return attendanceNow().addingTimeInterval(autoSignSchoolOffset)
    }

    private func recordAutoSignClock(_ schoolNow: Date) {
        autoSignSchoolOffset = schoolNow.timeIntervalSince(attendanceNow())
        if !autoSignUncalibratedBoundaries.isEmpty, let index = vault.accounts.firstIndex(where: { $0.id == activeAccountID }) {
            var updated = vault
            func calibrated(_ value: Date?) -> Date? {
                value.map { boundary in
                    guard autoSignUncalibratedBoundaries.contains(boundary) else { return boundary }
                    if let uptime = autoSignActivationUptimes[boundary] {
                        return schoolNow.addingTimeInterval(-max(0, autoSignMonotonicNow() - uptime))
                    }
                    return max(boundary, schoolNow)
                }
            }
            updated.accounts[index].preferences.autoSignRunningSince = calibrated(updated.accounts[index].preferences.autoSignRunningSince)
            updated.accounts[index].preferences.autoSignDefaultSince = calibrated(updated.accounts[index].preferences.autoSignDefaultSince)
            for key in updated.accounts[index].preferences.courses.keys {
                let previous = updated.accounts[index].preferences.courses[key]?.autoSignEnabledSince
                updated.accounts[index].preferences.courses[key]?.autoSignEnabledSince = calibrated(previous)
            }
            for key in updated.accounts[index].preferences.autoSignOccurrences.keys {
                let previous = updated.accounts[index].preferences.autoSignOccurrences[key]?.enabledSince
                updated.accounts[index].preferences.autoSignOccurrences[key]?.enabledSince = calibrated(previous)
            }
            updated.accounts[index].preferences.autoSignSinceUsesSchoolTime = true
            updated.accounts[index].preferences.autoSignPendingClockBoundaries = []
            do {
                try commit(updated)
                autoSignRunningSince = updated.accounts[index].preferences.autoSignRunningSince
                autoSignDefaultSince = updated.accounts[index].preferences.autoSignDefaultSince
                coursePreferences = updated.accounts[index].preferences.courses
                autoSignOccurrences = updated.accounts[index].preferences.autoSignOccurrences
                autoSignUncalibratedBoundaries = []; autoSignActivationUptimes = [:]
            } catch {
                autoSignStoreAvailable = false
                autoSignError = "自动签到已暂停：启用时间校准未能保存：\(error.localizedDescription)"
            }
        }
        autoSignClockWallAt = attendanceNow()
        autoSignClockSchoolAt = schoolNow
        autoSignClockUptimeAt = autoSignMonotonicNow()
    }

    private var autoSignClockNeedsWarm: Bool {
        guard let wall = autoSignClockWallAt, let uptime = autoSignClockUptimeAt else { return true }
        return abs(attendanceNow().timeIntervalSince(wall) - (autoSignMonotonicNow() - uptime)) > 5
    }

    private func warmAutoSignClock(force: Bool = false) {
        guard !isDemo, autoSignRunning, autoSignStoreAvailable, !automaticRefreshPaused,
              autoSignPausedUntil.map({ autoSignSchoolNow >= $0 }) ?? true,
              autoSignClockTask == nil, force || autoSignClockNeedsWarm,
              (courses + semesterSchedules.values.flatMap(\.courses)).contains(where: { course in
                  let preference = coursePreferences(for: preferenceID(for: course) ?? "")
                  let enabled = autoSignOccurrences[attemptKey(for: course)]?.enabled ?? preference.autoSign.resolve(default: true)
                  let key = attemptKey(for: course)
                  if let execution = autoSignExecutions[key] {
                      if [.signed, .skipped, .missed].contains(execution.stage) { return false }
                      let policy = (autoSignOccurrences[key]?.policy ?? .init()).resolve((preference.autoSignRule ?? .init()).resolve(autoSignRule))
                      if execution.stage == .needsAttention && execution.submissions < policy.maxSubmissions && !canVerifyExisting(course) { return false }
                  }
                  guard enabled, !preference.signInDisabled, !hasLocalSignSuccess(course), attendanceStatus(for: course) != .signed, let start = course.startDate, let end = course.endDate else { return false }
                  if autoSignClockSchoolAt == nil, (autoSignExecutions[key]?.submissions ?? 0) > 0 { return true }
                  return autoSignSchoolNow >= start.addingTimeInterval(-25 * 60) && autoSignSchoolNow <= end.addingTimeInterval(10 * 60)
              }) else { return }
        let token = generation
        autoSignClockTask = Task {
            defer { if generation == token { autoSignClockTask = nil } }
            do {
                let schoolNow = try await service.schoolNow()
                guard generation == token, autoSignRunning, !Task.isCancelled else { return }
                recordAutoSignClock(schoolNow)
                autoSignNetworkIssue = false
                if autoSignStoreAvailable { autoSignError = autoSignNotificationIssue }
            } catch {
                guard generation == token, autoSignRunning, !Task.isCancelled else { return }
                autoSignNetworkIssue = true
                autoSignError = autoSignNotificationIssue ?? "自动签到等待校时：\(error.localizedDescription)"
            }
        }
    }

    func foregroundTick() async {
        guard !Task.isCancelled, !isDemo, session != nil, !showLogin, !automaticRefreshPaused,
              !isLoading, signingID == nil, autoSignStoreAvailable, autoSignRunning,
              autoSignPausedUntil.map({ autoSignSchoolNow >= $0 }) ?? true else { return }
        let token = generation
        warmAutoSignClock()
        if let task = autoSignClockTask { await task.value }
        guard generation == token, autoSignRunning, autoSignStoreAvailable else { return }
        let now = autoSignSchoolNow
        let candidates = autoSignPlans.filter {
            guard normalizedDay($0.course.day) == SchoolDate.key(autoSignSchoolNow),
                  !hasLocalSignSuccess($0.course), $0.stage != .signed,
                  $0.stage != .skipped || canVerifyExisting($0.course) else { return false }
            if let execution = autoSignExecutions[$0.key], execution.submissions > 0 {
                let legacy = execution.lastSchoolSubmissionAt == nil
                let due = submissionSchoolTime(execution).addingTimeInterval(Double($0.policy.retryMinutes * 60))
                let atLimit = execution.submissions >= $0.policy.maxSubmissions || legacy || !$0.isParticipating && canVerifyExisting($0.course)
                guard $0.stage != .needsAttention || atLimit && autoSignSchoolNow < $0.course.endDate!
                    && (legacy || !$0.isParticipating || execution.nextSchoolVerificationAt != nil) else { return false }
                let wake = atLimit ? execution.nextSchoolVerificationAt ?? now : due
                return wake <= now
            }
            return $0.stage != .needsAttention && $0.plannedAt <= now
        }
        for plan in candidates {
            guard generation == token, !Task.isCancelled else { return }
            await evaluateAutoSign(plan.course, token: token)
        }
    }

    var autoSignPlans: [AutoSignPlan] {
        guard let id = activeAccountID, !isDemo else { return [] }
        let now = autoSignSchoolNow
        let todayStart = SchoolDate.calendar.startOfDay(for: now)
        let available = courses + semesterSchedules.values.flatMap(\.courses)
        var unique: [String: Course] = [:]
        for course in available {
            guard let start = course.startDate, start >= todayStart,
                  start < now.addingTimeInterval(7 * 86_400) else { continue }
            if unique[attemptKey(for: course)] == nil { unique[attemptKey(for: course)] = course }
        }
        return unique.values.compactMap { course in
            let key = attemptKey(for: course)
            let preferences = coursePreferences(for: preferenceID(for: course) ?? "")
            guard let plan = AutoSignPlanner.plan(account: id, course: course, accountPolicy: autoSignRule,
                                        courseRule: preferences.autoSignRule, occurrence: autoSignOccurrences[key],
                                        running: autoSignRunning && (autoSignPausedUntil.map { autoSignSchoolNow >= $0 } ?? true),
                                        courseEnabled: preferences.autoSign, signDisabled: preferences.signInDisabled,
                                        now: now, execution: autoSignExecutions[key], runningSince: autoSignRunningSince,
                                        defaultSince: autoSignDefaultSince,
                                        courseEnabledSince: preferences.autoSignEnabledSince,
                                        pausedUntil: autoSignPausedUntil) else { return nil }
            let completed = hasLocalSignSuccess(course)
            let boundaryReadOnly = !plan.isParticipating && canVerifyExisting(course)
            let execution = autoSignExecutions[key]
            let schoolNext = execution?.nextSchoolVerificationAt
                ?? execution?.lastSchoolSubmissionAt?.addingTimeInterval(Double(plan.policy.retryMinutes * 60))
                ?? plan.nextAt
            return AutoSignPlan(key: plan.key, course: plan.course, plannedAt: plan.plannedAt, deadline: plan.deadline,
                                policy: plan.policy, source: plan.source, stage: completed ? .signed : boundaryReadOnly ? autoSignExecutions[key]!.stage : plan.stage,
                                reason: completed ? "本机已有成功记录，不再自动提交" : boundaryReadOnly ? "启用时间之后不再补交此课次，继续核实已有提交结果" : plan.reason, nextAt: schoolNext,
                                sources: plan.sources, isParticipating: plan.isParticipating)
        }.sorted { $0.nextAt == $1.nextAt ? $0.key < $1.key : $0.nextAt < $1.nextAt }
    }
    var autoSignRuntimeStatus: String {
        if !autoSignRunning { return "已关闭" }
        if !autoSignStoreAvailable { return "已暂停 · 执行记录不可用" }
        if automaticRefreshPaused || showLogin { return "需要登录" }
        if let until = autoSignPausedUntil, until > autoSignSchoolNow { return "已暂停至明天" }
        if autoSignNetworkIssue { return "等待网络" }
        return "运行中"
    }
    var autoSignSettingsStatus: String {
        if !autoSignRunning { return "已关闭" }
        if !autoSignStoreAvailable || automaticRefreshPaused || showLogin
            || (autoSignPausedUntil.map { $0 > autoSignSchoolNow } ?? false) { return "已暂停" }
        return "运行中"
    }
    var autoSignHistory: [AutoSignExecution] {
        autoSignExecutions.values.filter { $0.hasExecutionActivity && $0.historyDiscarded != true }.sorted {
            let left = $0.events.last?.at ?? $0.startedAt ?? .distantPast
            let right = $1.events.last?.at ?? $1.startedAt ?? .distantPast
            return left == right ? $0.key < $1.key : left > right
        }
    }

    private func saveAutoSignExecutions() throws {
        guard let id = activeAccountID, autoSignStoreAvailable else {
            throw APIError(code: "AUTO_SIGN_STORE", message: "自动签到记录不可用")
        }
        do {
            try autoSignStore.save(accountID: id, executions: autoSignExecutions)
            if recordCloudChanges() { maintainHistoryRetention(recordCleanup: true) }
        }
        catch {
            autoSignStoreAvailable = false
            autoSignError = "自动签到已暂停：记录保存失败：\(error.localizedDescription)"
            throw error
        }
    }

    private func recordAutoSignPlanChanges(before: [String: AutoSignPlan]) {
        guard autoSignStoreAvailable else { return }
        var changed = false
        for plan in autoSignPlans {
            guard var execution = autoSignExecutions[plan.key], execution.hasExecutionActivity,
                  execution.historyDiscarded != true else { continue }
            if let previous = before[plan.key], previous.plannedAt == plan.plannedAt,
               previous.policy == plan.policy, previous.stage == plan.stage, previous.source == plan.source { continue }
            let message = plan.stage == .skipped ? "计划已暂停或跳过：\(plan.reason)"
                : "计划已更新：\(plan.plannedAt.formatted(date: .abbreviated, time: .shortened))；\(plan.source)"
            if execution.events.last?.message == message { continue }
            execution.events.append(AutoSignEvent(at: attendanceNow(), stage: plan.stage, message: message,
                                                  kind: plan.stage == .skipped ? .pause : .planChanged))
            autoSignExecutions[plan.key] = execution
            changed = true
        }
        if changed { try? saveAutoSignExecutions() }
    }

    private func updateAutoSign(_ key: String, stage: AutoSignStage, message: String, nextAt: Date? = nil) {
        guard var execution = autoSignExecutions[key],
              ![.skipped, .signed, .missed, .needsAttention].contains(execution.stage) else { return }
        execution.transition(stage, now: attendanceNow(), message: message, nextAt: nextAt)
        autoSignExecutions[key] = execution
        try? saveAutoSignExecutions()
        if [.missed, .needsAttention].contains(stage), let course = autoSignPlans.first(where: { $0.key == key })?.course {
            let token = generation
            Task { if generation == token { await notifyAutoSign(course, message: message, succeeded: false) } }
        }
    }

    private func continuingAutoSignExecution(_ key: String, token: UUID, allowReadOnlyTerminal: Bool = false) -> AutoSignExecution? {
        guard generation == token, autoSignStoreAvailable, let execution = autoSignExecutions[key],
              ![.skipped, .signed, .submitting].contains(execution.stage),
              allowReadOnlyTerminal || ![.missed, .needsAttention].contains(execution.stage) else { return nil }
        return execution
    }

    private func nextAutoSignVerification(_ key: String) -> Date? {
        guard let execution = autoSignExecutions[key], execution.lastSubmissionAt != nil,
              let plan = autoSignPlans.first(where: { $0.key == key }) else { return nil }
        return execution.submissions >= plan.policy.maxSubmissions ? attendanceNow().addingTimeInterval(30)
            : submissionSchoolTime(execution).addingTimeInterval(Double(plan.policy.retryMinutes * 60) - autoSignSchoolOffset)
    }

    private func submissionSchoolTime(_ execution: AutoSignExecution) -> Date {
        execution.lastSchoolSubmissionAt ?? .distantPast
    }

    private func reserveAutoSignSubmission(_ course: Course, token: UUID, schoolNow: Date) throws {
        guard generation == token else { throw APIError(code: "SIGN_NOT_ALLOWED", message: "账户已切换") }
        recordAutoSignClock(schoolNow)
        guard let plan = autoSignPlans.first(where: { $0.key == attemptKey(for: course) }),
              autoSignStoreAvailable, !hasLocalSignSuccess(course),
              ![.skipped, .missed, .needsAttention, .signed].contains(plan.stage),
              CourseTime.isWithinSignWindow(plan.course, now: schoolNow) else {
            throw APIError(code: "SIGN_NOT_ALLOWED", message: "自动签到计划已失效")
        }
        recordAutoSignClock(schoolNow)
        var execution = autoSignExecutions[plan.key] ?? AutoSignExecution(key: plan.key, now: attendanceNow())
        let due = execution.submissions == 0 ? plan.plannedAt
            : submissionSchoolTime(execution).addingTimeInterval(Double(plan.policy.retryMinutes * 60))
        let deadline = execution.submissions > 0 && plan.policy.missedAction == .manual
            ? due.addingTimeInterval(60) : plan.deadline
        guard schoolNow >= due, schoolNow <= min(deadline, plan.course.endDate!) else {
            throw APIError(code: "SIGN_NOT_ALLOWED", message: "自动签到计划已调整或错过，等待核实")
        }
        guard execution.submissions < plan.policy.maxSubmissions, execution.stage != .submitting,
              execution.submissions == 0 || execution.lastSchoolSubmissionAt != nil && execution.negativeReads >= 2 else {
            throw APIError(code: "SIGN_NOT_ALLOWED", message: "提交次数已耗尽或尚未取得两次未签到证据")
        }
        execution.begin(course: course, now: attendanceNow())
        execution.submissions += 1
        execution.lastSubmissionAt = attendanceNow()
        execution.lastSchoolSubmissionAt = schoolNow
        execution.firstNegativeAt = nil
        execution.firstSchoolNegativeAt = nil
        execution.nextSchoolVerificationAt = nil
        execution.negativeReads = 0
        execution.transition(.submitting, now: attendanceNow(), message: "第 \(execution.submissions) 次提交已发送")
        autoSignExecutions[plan.key] = execution
        try saveAutoSignExecutions()
    }

    private func evaluateAutoSign(_ course: Course, token: UUID) async {
        let schoolNow: Date
        do {
            schoolNow = try await service.schoolNow()
            guard generation == token, autoSignRunning, !Task.isCancelled else { return }
            recordAutoSignClock(schoolNow)
            autoSignNetworkIssue = false
            if autoSignStoreAvailable { autoSignError = autoSignNotificationIssue }
        } catch {
            guard generation == token else { return }
            autoSignNetworkIssue = true
            autoSignError = autoSignNotificationIssue ?? "自动签到等待校时：\(error.localizedDescription)"
            return
        }
        guard let plan = autoSignPlans.first(where: { $0.key == attemptKey(for: course) }),
              plan.isParticipating || canVerifyExisting(course), !hasLocalSignSuccess(course),
              plan.stage != .signed, plan.stage != .skipped || canVerifyExisting(course) else { return }
        let now = attendanceNow()
        var execution = autoSignExecutions[plan.key] ?? AutoSignExecution(key: plan.key, now: now)
        let boundaryReadOnly = !plan.isParticipating && canVerifyExisting(course)
        if execution.stage == .missed && !boundaryReadOnly { return }
        let legacyReceipt = execution.submissions > 0 && execution.lastSchoolSubmissionAt == nil
        let atLimit = execution.submissions >= plan.policy.maxSubmissions || legacyReceipt || boundaryReadOnly
        guard execution.stage != .needsAttention || atLimit else { return }
        let due = legacyReceipt || boundaryReadOnly ? schoolNow : execution.submissions == 0 ? plan.plannedAt
            : submissionSchoolTime(execution).addingTimeInterval(atLimit ? 0 : Double(plan.policy.retryMinutes * 60))
        guard schoolNow >= due else { return }
        if !execution.hasExecutionActivity {
            execution.begin(course: course, now: now)
            autoSignExecutions[plan.key] = execution
            guard (try? saveAutoSignExecutions()) != nil else { return }
        }
        if attendanceStatus(for: course) == .signed {
            updateAutoSign(plan.key, stage: .signed, message: "学校确认已签到")
            return
        }
        if atLimit {
            if schoolNow >= plan.course.endDate! {
                updateAutoSign(plan.key, stage: .needsAttention, message: "课程已结束，未确认签到成功，请手动核实")
                return
            }
            if let date = CourseTime.parse(day: course.day, time: "00:00") { await refresh(on: date) }
            guard let current = continuingAutoSignExecution(plan.key, token: token, allowReadOnlyTerminal: true) else { return }
            let day = normalizedDay(course.day)
            let fresh = autoSignQuerySchoolStartedAt[day].map { legacyReceipt || $0 > submissionSchoolTime(current) } == true
                && autoSignVerifiedQuerySequence[day] == courseRefreshSequences[day]
            if fresh && attendanceStatus(for: course) == .unsigned {
                updateAutoSign(plan.key, stage: .needsAttention, message: legacyReceipt ? "上次提交缺少可靠学校时间，继续核实至下课，不再自动提交" : boundaryReadOnly ? "启用边界之后不再补交，继续核实已有提交结果至下课" : "自动提交次数已耗尽，继续核实至下课，不再自动提交")
            }
            if var latest = autoSignExecutions[plan.key], ![.signed, .skipped].contains(latest.stage) {
                latest.nextSchoolVerificationAt = autoSignSchoolNow.addingTimeInterval(Double(plan.policy.retryMinutes * 60))
                latest.nextAt = latest.nextSchoolVerificationAt!.addingTimeInterval(-autoSignSchoolOffset)
                autoSignExecutions[plan.key] = latest
                try? saveAutoSignExecutions()
            }
            return
        }
        let deadline = min(execution.submissions == 0 || plan.policy.missedAction != .manual
                           ? plan.deadline : due.addingTimeInterval(60), plan.course.endDate!)
        if schoolNow > deadline {
            updateAutoSign(plan.key, stage: execution.submissions == 0 ? .missed : .needsAttention,
                           message: "已错过自动执行时间，请手动处理")
            return
        }
        if execution.submissions > 0 {
            if execution.negativeReads < 2 {
                if let first = execution.firstSchoolNegativeAt, schoolNow.timeIntervalSince(first) < 30 { return }
                guard let date = CourseTime.parse(day: course.day, time: "00:00") else { return }
                await refresh(on: date)
                guard let current = continuingAutoSignExecution(plan.key, token: token) else { return }
                execution = current
                if attendanceStatus(for: course) == .signed { updateAutoSign(plan.key, stage: .signed, message: "学校确认已签到"); return }
                let day = normalizedDay(course.day)
                let observedSchool: Date
                do { observedSchool = try await service.schoolNow() }
                catch { return }
                guard let latest = continuingAutoSignExecution(plan.key, token: token) else { return }
                execution = latest
                recordAutoSignClock(observedSchool)
                guard let startedSchool = autoSignQuerySchoolStartedAt[day],
                      startedSchool > submissionSchoolTime(execution),
                      execution.firstSchoolNegativeAt.map({ startedSchool.timeIntervalSince($0) >= 30 && observedSchool.timeIntervalSince($0) >= 30 }) ?? true,
                      observedSchool >= startedSchool,
                      autoSignVerifiedQuerySequence[day] == courseRefreshSequences[day],
                      let observed = dayVerifiedAt[day],
                      attendanceStatus(for: course) == .unsigned else { return }
                execution.negativeReads += 1
                if execution.firstNegativeAt == nil { execution.firstNegativeAt = observed; execution.firstSchoolNegativeAt = observedSchool }
                execution.events.append(AutoSignEvent(at: attendanceNow(), stage: .checking,
                                                      message: "学校第 \(execution.negativeReads) 次确认仍未签到", kind: .verification))
                autoSignExecutions[plan.key] = execution
                guard (try? saveAutoSignExecutions()) != nil, execution.negativeReads >= 2 else { return }
            }
        } else if !CachePolicy.isFresh(dayVerifiedAt[normalizedDay(course.day)], at: now, lifetime: 60),
                  let date = CourseTime.parse(day: course.day, time: "00:00") { await refresh(on: date) }
        guard continuingAutoSignExecution(plan.key, token: token) != nil,
              !hasLocalSignSuccess(course), attendanceStatus(for: course) == .unsigned else { return }
        await sign(course, accountGeneration: token, automatically: true)
    }

    private func reconcileAutoSignSuccesses(_ courses: [Course]) {
        for course in courses where course.signStatusKnown == true && course.signed {
            let key = attemptKey(for: course)
            guard var execution = autoSignExecutions[key], execution.hasExecutionActivity,
                  ![.signed, .skipped].contains(execution.stage) else { continue }
            execution.transition(.signed, now: attendanceNow(), message: "学校确认已签到")
            autoSignExecutions[key] = execution
            guard (try? saveAutoSignExecutions()) != nil else { return }
            let token = generation
            Task { if generation == token { await notifyAutoSign(course, message: "学校确认已签到", succeeded: true) } }
        }
    }

    private func attemptKey(for course: Course) -> String {
        "\(activeAccountID ?? "demo")|\(normalizedDay(course.day))|\(course.id)"
    }
    private func notifyAutoSign(_ course: Course, message: String, succeeded: Bool) async {
        let token = generation
        let key = attemptKey(for: course)
        let outcome = succeeded ? "signed" : message
        let policy = autoSignPlans.first(where: { $0.key == key })?.policy ?? autoSignRule
        guard policy.notification != .none, !succeeded || policy.notification == .all,
              autoSignNotificationOutcomes[key]?.contains(outcome) != true else { return }
        let status = await notifications.authorizationStatus()
        guard generation == token, status == .authorized || status == .provisional,
              autoSignNotificationOutcomes[key]?.contains(outcome) != true else { return }
        autoSignNotificationOutcomes[key, default: []].insert(outcome)
        let content = UNMutableNotificationContent()
        content.title = (succeeded ? "自动签到成功 · " : "自动签到需关注 · ") + course.name
        content.body = message
        content.sound = .default
        let request = UNNotificationRequest(identifier: "auto-sign-\(UUID())", content: content,
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))
        do { try await notifications.add(request) }
        catch { if generation == token { autoSignNotificationOutcomes[key]?.remove(outcome) } }
    }

    private func signInFeedback() {
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }

    private func savePreferences(autoSign: Bool? = nil, running: Bool? = nil, rule: AutoSignPolicy? = nil,
                                 occurrences: [String: AutoSignOccurrenceOverride]? = nil, pauseUntil: Date? = nil,
                                 clearPause: Bool = false, reminders: Bool? = nil,
                                 confirmation: Bool? = nil, leadMinutes: Int? = nil,
                                 courses: [String: CoursePreferences]? = nil) -> Bool {
        if isDemo {
            if let value = running ?? autoSign {
                if value && !autoSignRunning {
                    autoSignRunningSince = attendanceNow()
                    autoSignDefaultSince = attendanceNow()
                }
                autoSignRunning = value
                autoSignEnabled = value
            }
            if let rule { autoSignRule = rule }
            if let occurrences { autoSignOccurrences = occurrences }
            if let pauseUntil { autoSignPausedUntil = pauseUntil }
            if clearPause { autoSignPausedUntil = nil }
            if let reminders { remindersEnabled = reminders }
            if let confirmation { confirmationEnabled = confirmation }
            if let leadMinutes { reminderLeadMinutes = leadMinutes }
            if let courses { coursePreferences = courses }
            return true
        }
        guard let id = activeAccountID, let index = vault.accounts.firstIndex(where: { $0.id == id }) else { return false }
        let beforeAutoSignPlans = Dictionary(uniqueKeysWithValues: autoSignPlans.map { ($0.key, $0) })
        var updated = vault
        if let rule { updated.accounts[index].preferences.autoSignRule = rule }
        if let occurrences { updated.accounts[index].preferences.autoSignOccurrences = occurrences }
        if let pauseUntil { updated.accounts[index].preferences.autoSignPausedUntil = pauseUntil }
        if clearPause { updated.accounts[index].preferences.autoSignPausedUntil = nil }
        if let reminders { updated.accounts[index].preferences.remindersEnabled = reminders }
        if let confirmation { updated.accounts[index].preferences.confirmationEnabled = confirmation }
        if let leadMinutes { updated.accounts[index].preferences.reminderLeadMinutes = leadMinutes }
        if let courses { updated.accounts[index].preferences.courses = courses }
        let prior = vault.accounts[index].preferences
        // Both compatibility fields mirror the one user-facing switch.
        let singleRunning = running ?? autoSign ?? prior.autoSignIsRunning
        updated.accounts[index].preferences.autoSignRunning = singleRunning
        updated.accounts[index].preferences.autoSignEnabled = singleRunning
        let enabledAt = autoSignSchoolNow
        if autoSignClockWallAt == nil { autoSignUncalibratedBoundaries.insert(enabledAt); autoSignActivationUptimes[enabledAt] = autoSignMonotonicNow() }
        if !prior.autoSignEnabled && updated.accounts[index].preferences.autoSignEnabled {
            updated.accounts[index].preferences.autoSignDefaultSince = enabledAt
        }
        for key in updated.accounts[index].preferences.courses.keys {
            var course = updated.accounts[index].preferences.courses[key]!
            let previous = prior.courses[key] ?? coursePreferences(for: key)
            if course.autoSignEnabledSince == nil { course.autoSignEnabledSince = previous.autoSignEnabledSince }
            let wasEnabled = !previous.signInDisabled && previous.autoSign.resolve(default: true)
            let isEnabled = !course.signInDisabled && course.autoSign.resolve(default: true)
            if !wasEnabled && isEnabled { course.autoSignEnabledSince = enabledAt }
            updated.accounts[index].preferences.courses[key] = course
        }
        // Restoring an inherited course that was disabled also starts a new participation period.
        for (key, previous) in prior.courses where updated.accounts[index].preferences.courses[key] == nil {
            if updated.accounts[index].preferences.courses.keys.contains(where: {
                canonicalCourseID(for: $0) == canonicalCourseID(for: key)
            }) { continue }
            if previous.signInDisabled || !previous.autoSign.resolve(default: true) {
                updated.accounts[index].preferences.courses[key] = CoursePreferences(autoSignEnabledSince: enabledAt)
            }
        }
        for key in updated.accounts[index].preferences.autoSignOccurrences.keys {
            var occurrence = updated.accounts[index].preferences.autoSignOccurrences[key]!
            let previous = prior.autoSignOccurrences[key]
            if occurrence.enabledSince == nil { occurrence.enabledSince = previous?.enabledSince }
            if occurrence.enabled == true && previous?.enabled != true { occurrence.enabledSince = enabledAt }
            if previous?.enabled == false && occurrence.enabled != false { occurrence.enabledSince = enabledAt }
            updated.accounts[index].preferences.autoSignOccurrences[key] = occurrence
        }
        if (!prior.autoSignIsRunning && updated.accounts[index].preferences.autoSignIsRunning)
            || (clearPause && prior.autoSignPausedUntil != nil) {
            updated.accounts[index].preferences.autoSignRunningSince = enabledAt
        }
        updated.accounts[index].preferences.autoSignSinceUsesSchoolTime = autoSignUncalibratedBoundaries.isEmpty
        updated.accounts[index].preferences.autoSignPendingClockBoundaries = autoSignUncalibratedBoundaries.sorted()
        let previouslyEnabled = vault.accounts[index].preferences.autoSignEnabled
            || vault.accounts[index].preferences.courses.values.contains { $0.autoSign == .enabled }
        let nowEnabled = updated.accounts[index].preferences.autoSignEnabled
            || updated.accounts[index].preferences.courses.values.contains { $0.autoSign == .enabled }
        if running != nil || rule != nil || occurrences != nil || pauseUntil != nil || clearPause
            || autoSign.map({ $0 != vault.accounts[index].preferences.autoSignEnabled }) == true
            || (!previouslyEnabled && nowEnabled) {
            updated.accounts[index].preferences.autoSignV2Acknowledged = true
        }
        do {
            try commit(updated)
            autoSignEnabled = updated.accounts[index].preferences.autoSignEnabled
            autoSignRunning = updated.accounts[index].preferences.autoSignIsRunning
            autoSignRunningSince = updated.accounts[index].preferences.autoSignRunningSince
            autoSignDefaultSince = updated.accounts[index].preferences.autoSignDefaultSince
            autoSignRule = updated.accounts[index].preferences.autoSignRule
            autoSignOccurrences = updated.accounts[index].preferences.autoSignOccurrences
            autoSignPausedUntil = updated.accounts[index].preferences.autoSignPausedUntil
            autoSignMigrationPending = updated.accounts[index].preferences.needsAutoSignMigrationNotice
            remindersEnabled = updated.accounts[index].preferences.remindersEnabled
            confirmationEnabled = updated.accounts[index].preferences.confirmationEnabled
            reminderLeadMinutes = updated.accounts[index].preferences.reminderLeadMinutes
            coursePreferences = updated.accounts[index].preferences.courses
            recordAutoSignPlanChanges(before: beforeAutoSignPlans)
            return true
        } catch {
            errorMessage = "偏好未能保存：\(error.localizedDescription)"
            return false
        }
    }

    func setAutoSign(_ enabled: Bool) { setAutoSignRunning(enabled) }
    func setAutoSignRunning(_ enabled: Bool) {
        guard savePreferences(running: enabled) else { return }
        if enabled { warmAutoSignClock(force: true); requestAutoSignNotificationPermission() }
        else { autoSignPermissionTask?.cancel(); autoSignPermissionTask = nil; autoSignPermissionGeneration = UUID() }
    }
    func setAutoSignRule(_ rule: AutoSignPolicy) {
        guard rule.isValid else { errorMessage = "自动签到规则超出允许范围"; return }
        let enablesNotification = autoSignRule.notification == .none && rule.notification != .none
        guard savePreferences(rule: rule) else { return }
        if enablesNotification { requestAutoSignNotificationPermission(force: true) }
    }
    func setAutoSignOccurrence(_ value: AutoSignOccurrenceOverride?, for course: Course) {
        let inherited = (coursePreferences(for: preferenceID(for: course) ?? "").autoSignRule ?? .init()).resolve(autoSignRule)
        if let value {
            let policy = (value.policy ?? .init()).resolve(inherited)
            guard policy.isValid else { errorMessage = "本次自动签到规则超出允许范围"; return }
            let at = value.at ?? course.startDate?.addingTimeInterval(Double(policy.offsetMinutes * 60))
            guard let start = course.startDate, let end = course.endDate, let at,
                  at >= start.addingTimeInterval(-25 * 60), at < end else {
                errorMessage = "本次自动签到时间必须在课前25分钟至下课前，请调整后再保存"
                return
            }
        }
        var values = autoSignOccurrences
        let key = attemptKey(for: course)
        let previousNotification = (values[key]?.policy ?? .init()).resolve(inherited).notification
        if value == nil, values[key]?.enabled == false { values[key] = .init(enabledSince: autoSignSchoolNow) }
        else { values[key] = value }
        guard savePreferences(occurrences: values) else { return }
        if previousNotification == .none && (value?.policy ?? .init()).resolve(inherited).notification != .none {
            requestAutoSignNotificationPermission(force: true)
        }
    }

    private func requestAutoSignNotificationPermission(force: Bool = false) {
        guard !isDemo, force || autoSignRunning,
              autoSignRule.notification != .none || coursePreferences.values.contains(where: { $0.autoSignRule?.notification.map { $0 != .none } ?? false })
                || autoSignOccurrences.values.contains(where: { $0.policy?.notification.map { $0 != .none } ?? false }) else { return }
        guard autoSignPermissionTask == nil else { return }
        notificationSettingsNeeded = false
        let accountToken = generation
        let settingToken = UUID()
        autoSignPermissionGeneration = settingToken
        autoSignPermissionTask = Task {
            defer { if autoSignPermissionGeneration == settingToken { autoSignPermissionTask = nil } }
            let authorization = await notificationAuthorization()
            guard generation == accountToken, autoSignPermissionGeneration == settingToken, !Task.isCancelled else { return }
            if authorization == .allowed {
                if autoSignError == autoSignNotificationIssue { autoSignError = nil }
                if errorMessage == autoSignNotificationIssue { errorMessage = nil }
                autoSignNotificationIssue = nil
                return
            }
            if authorization == .denied {
                var rule = autoSignRule; rule.notification = .none
                var courses = coursePreferences
                for key in courses.keys where courses[key]?.autoSignRule?.notification != nil { courses[key]?.autoSignRule?.notification = AutoSignNotification.none }
                var occurrences = autoSignOccurrences
                for key in occurrences.keys where occurrences[key]?.policy?.notification != nil { occurrences[key]?.policy?.notification = AutoSignNotification.none }
                _ = savePreferences(rule: rule, occurrences: occurrences, courses: courses)
                autoSignNotificationIssue = "系统未允许通知，自动签到结果通知已关闭；可在系统设置中开启后重新选择"
                autoSignError = autoSignNotificationIssue
                errorMessage = autoSignError
                notificationSettingsNeeded = true
            } else {
                autoSignError = "无法检查自动签到通知权限，请稍后重新选择通知设置"
            }
        }
    }

    private func clearCourseReminderNotifications() async {
        let accountToken = generation
        let requestToken = reminderGeneration
        let ids = await notifications.pendingRequestIdentifiers()
        guard generation == accountToken, reminderGeneration == requestToken else { return }
        notifications.remove(ids: ids.filter { !$0.hasPrefix("auto-sign-") })
    }

    func pauseAutoSignUntilTomorrow() {
        let tomorrow = CourseTime.calendar.startOfDay(for: autoSignSchoolNow).addingTimeInterval(86_400)
        _ = savePreferences(pauseUntil: tomorrow)
    }
    func resumeAutoSign() { if savePreferences(clearPause: true) { warmAutoSignClock(force: true) } }
    func acknowledgeAutoSignMigration() {
        guard let id = activeAccountID, let index = vault.accounts.firstIndex(where: { $0.id == id }) else { return }
        var updated = vault
        updated.accounts[index].preferences.autoSignV2Acknowledged = true
        do { try commit(updated); autoSignMigrationPending = false }
        catch { errorMessage = "自动签到提示状态未能保存：\(error.localizedDescription)" }
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
        else { Task { await clearCourseReminderNotifications() } }
    }

    @discardableResult
    func setCoursePreferences(_ preferences: CoursePreferences, for courseId: String,
                              relativeTo previous: CoursePreferences? = nil) async -> Bool {
        let patch = previous.map { CoursePreferencesPatch(previous: $0, proposed: preferences) }
        var preferences = patch?.applying(to: coursePreferences(for: courseId)) ?? preferences
        guard !courseId.isEmpty else { return false }
        if let rule = preferences.autoSignRule, !rule.resolve(autoSignRule).isValid {
            errorMessage = "自动签到规则超出允许范围"
            return false
        }
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
        if let patch { preferences = patch.applying(to: coursePreferences(for: courseId)) }
        if let lead = preferences.reminderLeadMinutes,
           !AccountPreferences.validLeadTimes.contains(lead) { preferences.reminderLeadMinutes = nil }
        let enablesAutoNotification = preferences.autoSignRule?.notification != nil
            && preferences.autoSignRule!.resolve(autoSignRule).notification != .none
            && (coursePreferences(for: courseId).autoSignRule ?? .init()).resolve(autoSignRule).notification == .none
        var updated = coursePreferences
        for alias in updated.keys.filter({ canonicalCourseID(for: $0) == courseId }) { updated.removeValue(forKey: alias) }
        if preferences == CoursePreferences() { updated.removeValue(forKey: courseId) }
        else { updated[courseId] = preferences }
        guard savePreferences(courses: updated) else { return false }
        if enablesAutoNotification { requestAutoSignNotificationPermission(force: true) }
        if preferences.signInDisabled, let pending = pendingSignConfirmation, preferenceID(for: pending.course) == courseId {
            pendingSignConfirmation = nil
        }
        if hasEnabledReminders { await scheduleReminders() }
        else { Task { await clearCourseReminderNotifications() } }
        return true
    }

    func dismissError() {
        errorMessage = nil
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
        #if os(macOS)
        errorMessage = "系统已关闭果壳签到的通知权限，课程提醒设置未更改。请前往系统设置 → 通知 → 果壳签到开启通知。"
        #else
        errorMessage = "系统已关闭果壳签到的通知权限，课程提醒设置未更改。请前往设置 → 果壳签到 → 通知开启权限。"
        #endif
        notificationSettingsNeeded = true
    }

    private var hasEnabledReminders: Bool {
        remindersEnabled || coursePreferences.values.contains { $0.reminders == .enabled }
    }

    private func scheduleReminders() async {
        guard !isDemo, session != nil, !automaticRefreshPaused else { return }
        let accountToken = generation
        let authorization = await notifications.authorizationStatus()
        guard generation == accountToken else { return }
        var allowed = authorization == .authorized || authorization == .provisional
        #if os(iOS)
        allowed = allowed || authorization == .ephemeral
        #endif
        guard allowed else {
            await clearCourseReminderNotifications()
            return
        }
        let requestToken = UUID()
        reminderGeneration = requestToken
        await refreshCourseIdentityIfNeeded(for: courses)
        guard generation == accountToken, reminderGeneration == requestToken, !Task.isCancelled else { return }
        await clearCourseReminderNotifications()
        guard generation == accountToken, reminderGeneration == requestToken, !Task.isCancelled else { return }
        for course in courses.prefix(60) where !course.signed && arrangementFresh(course) && effectiveReminders(for: course) {
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

    func removeAccount(id: String, everywhere: Bool = false) {
        guard canChangeAccount || isApplyingCloudSync else { return }
        do {
            try loadAccounts()
            guard vault.accounts.contains(where: { $0.id == id }) || iCloudPendingAccounts.contains(where: { $0.studentNo == id }) else { return }
            var updated = vault
            updated.remove(id: id)
            // A failed local Keychain transaction must not advertise a successful removal.
            try accountStore.save(updated)
            do {
                if !isApplyingCloudSync {
                    if everywhere { try cloudSync.removeEverywhere(accountID: id) }
                    else { try cloudSync.removeLocally(accountID: id) }
                }
            } catch {
                try accountStore.save(vault)
                throw error
            }
            vault = updated
            updateAccountList()
            iCloudPendingAccounts.removeAll { $0.studentNo == id }
            syncedAutoSignHistory.removeValue(forKey: id)
            for key in defaults.dictionaryRepresentation().keys
                where key.hasPrefix("courses-\(id)-") || key == "semester-schedules-\(id)" || key == "schedule-pending-\(id)" || key == "catalog-\(id)" || key.hasPrefix("catalog-\(id)-") ||
                      key.hasPrefix("attendance-\(id)-") || key == "records-\(id)" || key == "attendance-state-\(id)" {
                defaults.removeObject(forKey: key)
            }
            checkedScheduleDays = checkedScheduleDays.filter { !$0.hasPrefix("\(id)|") }
            autoAttempts = autoAttempts.filter { !$0.hasPrefix("\(id)|") }
            autoSignStore.remove(accountID: id)
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
            invalidatedDays.insert(normalizedDay(course.day))
            refreshSequence += 1
            observeAttendance(course, source: .submission, sequence: refreshSequence)
            saveAttendanceState()
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
            return WidgetCourse(id: course.id, name: course.name, location: location, startTime: start, endTime: end, isCheckedIn: course.signed, attendanceLabel: attendanceLabel(for: course))
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
            projectAttendance(value.preservingIdentity(from: previous["\(normalizedDay(value.day))|\(value.id)"]))
        }
        let merged = courses.filter { !days.contains(normalizedDay($0.day)) } + updated
        if courses != merged {
            let before = Dictionary(uniqueKeysWithValues: autoSignPlans.map { ($0.key, $0) })
            courses = merged
            recordAutoSignPlanChanges(before: before)
        }
    }
    private func saveRecords() {
        guard let session, let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: "records-\(session.studentNo)")
        if recordCloudChanges() { maintainHistoryRetention(recordCleanup: true) }
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
            if catalogIsCached { catalogIsCached = false }
            return
        }
        guard let session else { return }
        let now = Date()
        let semestersAreFresh = CachePolicy.isFresh(semestersUpdatedAt, at: now)
        let catalogIsFresh = CachePolicy.isFresh(catalogUpdatedAt, at: now)
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
        do {
            let semesterValues = try await readSemesters(force: force)
            guard generation == accountToken, !Task.isCancelled else { return }
            let semester = try Self.currentSemester(from: semesterValues)
            selectedSemester = semester
            let directory = try await readDirectory(for: semester, force: force)
            guard generation == accountToken, !Task.isCancelled else { return }
            catalogCourses = directory.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            catalogIsCached = false
            catalogError = nil
            catalogFailureCount = 0
            catalogRetryAfter = nil
            saveCatalogCache(accountId: session.studentNo)
        } catch {
            guard !Task.isCancelled, generation == accountToken else { return }
            if let apiError = error as? APIError, apiError.isSessionExpired {
                markLoginRequired(for: session.studentNo, failedSession: session)
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
            if !force, !invalidatedAttendance.contains(courseId), CachePolicy.isFresh(attendanceUpdatedAt[courseId], at: attendanceNow(), lifetime: 5 * 60) { return }
            let matching = courses.filter { preferenceID(for: $0) == courseId }
            let records = matching.map {
                CourseAttendance(id: "\($0.day)|\($0.id)", courseId: courseId, scheduledCourseId: $0.id,
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
        if !force, !invalidatedAttendance.contains(courseId), CachePolicy.isFresh(attendanceUpdatedAt[courseId], at: attendanceNow(), lifetime: 5 * 60) { return }
        if let read = attendanceTasks[courseId] {
            let token = generation
            await read.task.value
            if generation == token, read.revision != attendanceRevisions[courseId, default: 0] {
                await refreshAttendance(for: courseId, force: force)
            }
            return
        }
        let token = generation
        let revision = attendanceRevisions[courseId, default: 0]
        let task = Task { await self.performAttendanceRefresh(courseId: courseId, session: session, accountToken: token, revision: revision) }
        attendanceTasks[courseId] = (task, revision)
        await task.value
    }

    private func performAttendanceRefresh(courseId: String, session: SchoolSession, accountToken: UUID, revision: Int) async {
        attendanceRefreshing.insert(courseId)
        refreshSequence += 1
        let sequence = refreshSequence
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
            guard attendanceRevisions[courseId, default: 0] == revision else { return }
            for record in summary.records {
                if let course = courses.first(where: { $0.id == record.scheduledCourseId && normalizedDay($0.day) == normalizedDay(record.day) }) {
                    var value = course; value.signed = record.signed; value.signStatusKnown = record.signStatusKnown
                    observeAttendance(value, source: .detail, sequence: sequence)
                }
            }
            courses = courses.map(projectAttendance)
            invalidatedAttendance.remove(courseId)
            saveAttendanceState()
            publishWidget()
            attendanceByCourse[courseId] = summary
            attendanceUpdatedAt[courseId] = attendanceNow()
            attendanceErrors.removeValue(forKey: courseId)
            saveAttendanceCache(accountId: session.studentNo, courseId: courseId, summary: summary)
        } catch {
            guard !Task.isCancelled, generation == accountToken else { return }
            if let apiError = error as? APIError, apiError.isSessionExpired {
                markLoginRequired(for: session.studentNo, failedSession: requestSession)
                requestLogin(for: session.studentNo)
                return
            }
            guard attendanceRevisions[courseId, default: 0] == revision else { return }
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
        if let data = defaults.data(forKey: "catalog-\(accountId)-semesters"),
           let metadata = try? JSONDecoder().decode(SemesterMetadataCache.self, from: data) {
            semesters = metadata.values; semestersUpdatedAt = metadata.updatedAt
        }
        guard let data = defaults.data(forKey: "catalog-\(accountId)"),
              let cache = try? JSONDecoder().decode(CatalogCache.self, from: data), cache.version == 1,
              let semester = cache.semesters.first(where: { $0.id == cache.selectedSemesterId }),
              cache.courses.allSatisfy({ $0.semesterId == semester.id }) else { return }
        if semestersUpdatedAt == nil || cache.semestersUpdatedAt > semestersUpdatedAt! {
            semesters = cache.semesters; semestersUpdatedAt = cache.semestersUpdatedAt
        }
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
        invalidatedAttendance.insert(courseId)
        attendanceRevisions[courseId, default: 0] += 1
        saveAttendanceState()
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

    static var demoCatalogCourses: [CatalogCourse] {
        let term = demoSemester(containing: .now)
        return [
            CatalogCourse(id: "demo-matrix", number: "MATH6001", name: "矩阵分析", teacher: "李明远", classroom: "教学楼 A101", semesterId: term.id, beginDate: term.beginDate, endDate: term.endDate, totalSessions: 16, completedSessions: 3),
            CatalogCourse(id: "demo-ai", number: "CS6002", name: "高级人工智能", teacher: "陈思远", classroom: "教学楼 B203", semesterId: term.id, beginDate: term.beginDate, endDate: term.endDate, totalSessions: 16, completedSessions: 3),
            CatalogCourse(id: "demo-english", number: "ENG6003", name: "学术英语写作", teacher: "王雅文", classroom: nil, semesterId: term.id, beginDate: term.beginDate, endDate: term.endDate, totalSessions: 12, completedSessions: 2)
        ]
    }
}

// Schedule synchronization shares the existing per-day freshness and account-generation guards.
extension AppModel {
    var isScheduleRefreshing: Bool { isSemesterSyncing || isRefreshing(on: selectedDate) }

    private var scheduleSemesters: [SchoolSemester] {
        semesters.isEmpty ? semesterSchedules.values.map(\.semester) : semesters
    }

    var scheduleAvailableSemesters: [SchoolSemester] {
        scheduleSemesters.filter { ScheduleCalendar.dateRange(in: $0) != nil }.sorted { $0.beginDate > $1.beginDate }
    }

    var viewedScheduleSemester: SchoolSemester? {
        let day = SchoolDate.calendar.startOfDay(for: selectedDate)
        let matches = scheduleSemesters.filter { ScheduleCalendar.dateRange(in: $0)?.contains(day) == true }
        return matches.count == 1 ? matches.first : nil
    }

    private var scheduleNavigationRange: ClosedRange<Date>? {
        viewedScheduleSemester.flatMap { ScheduleCalendar.dateRange(in: $0) } ?? scheduleDateRange
    }

    var scheduleDateRange: ClosedRange<Date>? {
        let ranges = scheduleSemesters.compactMap { ScheduleCalendar.dateRange(in: $0) }
        guard let start = ranges.map(\.lowerBound).min(), let end = ranges.map(\.upperBound).max() else { return nil }
        return start...end
    }

    var scheduleWeekNumber: Int? {
        viewedScheduleSemester.flatMap { ScheduleCalendar.weekNumber(on: selectedDate, in: $0) }
    }

    func scheduleDate(selectingSemester id: String) -> Date? {
        guard let semester = scheduleAvailableSemesters.first(where: { $0.id == id }) else { return nil }
        let count = ScheduleCalendar.weeks(in: semester).count
        let week = min(scheduleWeekNumber ?? 1, count)
        return ScheduleCalendar.date(inWeek: week, of: semester, keepingWeekdayOf: selectedDate)
    }

    func canSelectScheduleDate(_ date: Date) -> Bool {
        scheduleDateRange?.contains(SchoolDate.calendar.startOfDay(for: date)) ?? true
    }

    func canSelectVisibleScheduleDate(_ date: Date) -> Bool {
        scheduleNavigationRange?.contains(SchoolDate.calendar.startOfDay(for: date)) ?? true
    }

    func boundedScheduleDate(_ date: Date) -> Date {
        guard let range = scheduleDateRange else { return date }
        let day = SchoolDate.calendar.startOfDay(for: date)
        return min(max(day, range.lowerBound), range.upperBound)
    }

    func adjacentScheduleWeek(_ direction: Int) -> Date? {
        guard let date = SchoolDate.calendar.date(byAdding: .day, value: direction * 7, to: selectedDate) else { return nil }
        let bounded = scheduleNavigationRange.map { min(max(date, $0.lowerBound), $0.upperBound) } ?? date
        return SchoolDate.week(containing: bounded)[0] == SchoolDate.week(containing: selectedDate)[0] ? nil : bounded
    }

    var weekSchedulePresentation: WeekSchedulePresentation {
        let key = "\(SchoolDate.key(SchoolDate.week(containing: selectedDate)[0]))|\(viewedScheduleSemester?.id ?? "unassigned")"
        if let cached = weekPresentations[key] { return cached }
        let bounds = scheduleNavigationRange.map { (SchoolDate.key($0.lowerBound), SchoolDate.key($0.upperBound)) }
        let entries = ScheduleLayout.weekEntries(courses, containing: selectedDate,
                                                semesters: identitySemesters,
                                                includeOutsideWeek: showOutsideWeekCourses, catalog: catalogCourses)
            .filter { entry in
                guard let bounds else { return true }
                return bounds.0 <= entry.displayDay && entry.displayDay <= bounds.1
            }
        let day = SchoolDate.key(selectedDate)
        let term = identitySemesters.first { $0.beginDate <= day && day <= $0.endDate }
        let colorKey = term?.id ?? "unassigned"
        var colors = scheduleColors[colorKey] ?? ScheduleColors()
        colors.register(courses.filter { course in
            guard let term else { return true }
            let day = normalizedDay(course.day)
            return term.beginDate <= day && day <= term.endDate
        })
        scheduleColors[colorKey] = colors
        let value = WeekSchedulePresentation(entries: entries, colors: colors)
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

    var hasWeekSchedule: Bool {
        if isDemo || scheduleUpdatedAt(on: selectedDate) != nil { return true }
        let days = SchoolDate.week(containing: selectedDate).filter { canSelectVisibleScheduleDate($0) }
        return !days.isEmpty && days.allSatisfy { hasSchedule(on: $0) }
    }

    var hasVisibleScheduleErrors: Bool {
        SchoolDate.week(containing: selectedDate).contains {
            canSelectVisibleScheduleDate($0) && scheduleDayErrors[SchoolDate.key($0)] != nil
        }
    }

    var isInitialWeekLoading: Bool {
        !hasWeekSchedule && scheduleSyncError == nil && !hasVisibleScheduleErrors
    }

    func openScheduleDate(_ date: Date) async {
        let token = generation
        if scheduleMode == .week {
            await synchronizeSchedules()
            return
        }
        if let session, !hasSchedule(on: date) {
            if loadCache(for: session, date: date) { courseFreshness[SchoolDate.key(date)] = false }
        }
        await enterDay(date)
        guard generation == token, !Task.isCancelled else { return }
        await synchronizeSchedules()
        guard generation == token, !Task.isCancelled, SchoolDate.key(date) == SchoolDate.key(selectedDate) else { return }
    }

    func refreshSchedule() async {
        if scheduleMode == .week {
            let token = generation
            await synchronizeSchedules(force: true)
            guard generation == token else { return }
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

    func synchronizeSchedules(force: Bool = false, semester requestedSemester: SchoolSemester? = nil) async {
        guard isConnected, !showLogin, !automaticRefreshPaused, !Task.isCancelled else { return }
        if isDemo { populateDemoSemester(containing: requestedSemester.flatMap { ScheduleCalendar.dateRange(in: $0)?.lowerBound } ?? selectedDate); return }
        if let scheduleSyncTask {
            let token = generation
            let previousUpdate = requestedSemester.flatMap { semesterSchedules[$0.id]?.updatedAt }
            await scheduleSyncTask.value
            guard generation == token, !Task.isCancelled else { return }
            if let requestedSemester, let snapshot = semesterSchedules[requestedSemester.id],
               snapshot.updatedAt != previousUpdate, !snapshot.needsRefresh(at: .now) { return }
            // Retain explicit detail-page targets while waiting for an existing batch.
            await synchronizeSchedules(force: requestedSemester != nil && force, semester: requestedSemester)
            return
        }
        if !force, scheduleRetryAfter.map({ $0 > Date() }) == true { return }
        guard let session else { return }
        let token = generation
        let requestedDate = requestedSemester.flatMap { ScheduleCalendar.dateRange(in: $0)?.lowerBound } ?? selectedDate
        if force {
            let day = SchoolDate.key(requestedDate)
            for snapshot in semesterSchedules.values where snapshot.semester.beginDate <= day && day <= snapshot.semester.endDate {
                pendingSemesterRefreshes.insert(snapshot.semester.id)
            }
            savePendingScheduleSync(for: session)
        }
        let task = Task { await self.performScheduleSync(session: session, date: requestedDate, force: force, token: token, requestedSemester: requestedSemester) }
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
                if generation == token { markLoginRequired(for: session.studentNo, failedSession: session); requestLogin(for: session.studentNo) }
                throw error
            }
            do { value = try await operation(renewed) }
            catch let error as APIError where error.isSessionExpired {
                if generation == token { markLoginRequired(for: session.studentNo, failedSession: renewed); requestLogin(for: session.studentNo) }
                throw error
            }
        }
        try Task.checkCancellation()
        guard generation == token, !showLogin, !automaticRefreshPaused else { throw CancellationError() }
        return value
    }

    private func performScheduleSync(session: SchoolSession, date: Date, force: Bool, token: UUID, requestedSemester: SchoolSemester?) async {
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
            var terms = try await readSemesters(force: force)
            if let requestedSemester, !terms.contains(where: { $0.id == requestedSemester.id }) { terms.append(requestedSemester) }
            semesters = terms
            let date = requestedSemester.flatMap { requested in terms.first(where: { $0.id == requested.id }).flatMap { ScheduleCalendar.dateRange(in: $0)?.lowerBound } } ?? boundedScheduleDate(date)
            if requestedSemester == nil, SchoolDate.key(selectedDate) == selectedDay { selectedDate = date }
            let selectedDay = SchoolDate.key(date)
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
        syncingSemesterID = term.id
        defer { if generation == token { syncingSemesterID = nil } }
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
            scheduleWriteSequences[day] = sequence
            if courseFreshness[day] == nil { courseFreshness[day] = false }
            courseUpdates[day] = now
            courseNotices[day] = nil
            scheduleDayErrors[day] = nil
            dayRetryAfter[day] = nil
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
            for value in values { observeAttendance(value, source: .daily, sequence: sequence) }
            saveAttendanceState()
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

    private static func demoSemester(containing date: Date) -> SchoolSemester {
        let calendar = SchoolDate.calendar
        let year = calendar.component(.year, from: date)
        let autumn = calendar.component(.month, from: date) >= 7
        let begin = String(format: "%04d%02d01", year, autumn ? 7 : 1)
        let end = String(format: "%04d%02d%02d", year, autumn ? 12 : 6, autumn ? 31 : 30)
        return SchoolSemester(id: "demo-\(begin)", name: "演示学期", beginDate: begin, endDate: end, isCurrent: true)
    }

    private func populateDemoSemester(containing date: Date) {
        let term = Self.demoSemester(containing: date)
        guard semesterSchedules[term.id] == nil else { return }
        let days = ScheduleCalendar.days(in: term)
        for day in days {
            let key = SchoolDate.key(day)
            if !hasSchedule(on: day) {
                var examples = Self.demoCourses(on: day)
                let week = ScheduleCalendar.weekNumber(on: day, in: term) ?? 1
                // Early sample weeks include gaps and co-teachers without changing today's demo.
                if week <= 4 {
                    if week.isMultiple(of: 2) { examples.removeAll { $0.courseId == "demo-english" } }
                    if let first = examples.first {
                        examples.append(Course(id: "demo-co-teacher", courseId: first.courseId, name: first.name,
                                               teacher: "周明远", classroom: first.classroom, beginTime: first.beginTime,
                                               endTime: first.endTime, day: key))
                    }
                }
                mergeCourses(examples, replacingDays: [key])
                courseUpdates[key] = .now
            }
            checkedScheduleDays.insert("demo|\(key)")
        }
        semesterSchedules[term.id] = SemesterScheduleCache(semester: term, courses: courses.filter {
            term.beginDate <= normalizedDay($0.day) && normalizedDay($0.day) <= term.endDate
        }, updatedAt: .now)
    }
}

extension AppModel {
    func courseScheduleSemester(for course: CatalogCourse) -> SchoolSemester? {
        let term = semesters.first { $0.id == course.semesterId } ?? semesterSchedules[course.semesterId]?.semester
        return term.flatMap { ScheduleCalendar.dateRange(in: $0) == nil ? nil : $0 }
    }

    func courseSchedulePresentation(for course: CatalogCourse) -> CourseSchedulePresentation? {
        guard let semester = courseScheduleSemester(for: course) else { return nil }
        if let cached = courseSchedulePresentations[course] { return cached }
        let directory = courseScheduleDirectories[semester.id]?.courses ?? catalogCourses.filter { $0.semesterId == semester.id }
        let result = CourseSchedulePresentation(course: course, semester: semester, catalog: directory,
                                               semesters: identitySemesters, courses: courses)
        if courseSchedulePresentations.count >= 32 { courseSchedulePresentations.removeAll() }
        courseSchedulePresentations[course] = result
        return result
    }

    func courseScheduleIsComplete(for course: CatalogCourse) -> Bool {
        semesterSchedules[course.semesterId]?.courseIdentityVersion == 1
    }

    /// Loads a course's own semester without changing either tab's navigation selection.
    func loadCourseSchedule(for course: CatalogCourse) async {
        guard isConnected, !showLogin, !Task.isCancelled else { return }
        let id = course.semesterId
        let token = generation
        if let task = courseScheduleTasks[id] { await task.value; return }
        if let snapshot = semesterSchedules[id], !snapshot.needsRefresh(at: .now),
           isDemo || CachePolicy.isFresh(courseScheduleDirectories[id]?.updatedAt, at: .now) {
            // Keep cache hits silent while a tab restores its existing detail view.
            if courseScheduleErrors[id] != nil { courseScheduleErrors[id] = nil }
            courseScheduleRetryAfter[id] = nil
            return
        }
        if courseScheduleRetryAfter[id].map({ $0 > Date() }) == true { return }
        let task = Task { await self.performCourseScheduleLoad(course, token: token) }
        courseScheduleTasks[id] = task
        await task.value
        if generation == token { courseScheduleTasks[id] = nil }
    }

    private func performCourseScheduleLoad(_ course: CatalogCourse, token: UUID) async {
        let id = course.semesterId
        courseScheduleLoading.insert(id)
        courseScheduleErrors[id] = nil
        defer { if generation == token { courseScheduleLoading.remove(id) } }
        do {
            if courseScheduleSemester(for: course) == nil, !isDemo {
                semesters = try await readSemesters(force: true)
            }
            guard let term = courseScheduleSemester(for: course) else {
                throw APIError(code: "COURSE_SCHEDULE_SEMESTER", message: "无法确定这门课所属学期的有效范围。")
            }
            if isDemo {
                populateDemoSemester(containing: ScheduleCalendar.dateRange(in: term)!.lowerBound)
                return
            }
            _ = try await readDirectory(for: term)
            courseSchedulePresentations.removeAll()
            if semesterSchedules[id]?.needsRefresh(at: .now) != false {
                await synchronizeSchedules(semester: term)
                guard generation == token, !Task.isCancelled else { return }
                if semesterSchedules[id]?.needsRefresh(at: .now) != false {
                    throw APIError(code: "COURSE_SCHEDULE_INCOMPLETE", message: scheduleSyncError ?? "排课尚未完整同步，请稍后重试。")
                }
            }
            courseScheduleRetryAfter[id] = nil
        } catch {
            guard generation == token, !(error is CancellationError), !Task.isCancelled else { return }
            courseScheduleErrors[id] = error.localizedDescription
            courseScheduleRetryAfter[id] = Date().addingTimeInterval(60)
        }
    }
}

extension AppModel {
    private func arrangementFresh(_ course: Course) -> Bool {
        if isDemo || courseFreshness[normalizedDay(course.day)] == true { return true }
        let day = normalizedDay(course.day)
        return semesterSchedules.values.contains { !$0.needsRefresh(at: .now) && $0.semester.beginDate <= day && day <= $0.semester.endDate }
    }
    private func attendanceKey(_ course: Course) -> String { "\(normalizedDay(course.day))|\(course.id)" }
    func attendanceStatus(for course: Course) -> AttendanceStatus {
        if isDemo { return course.signed ? .signed : .unsigned }
        return attendanceStates[attendanceKey(course)]?.status ?? (course.signed ? .signed : .unknown)
    }
    func attendanceLabel(for course: Course) -> String {
        let key = attendanceKey(course)
        if attendanceStates[key]?.pendingVerification == true {
            return "已签到 · 待核验"
        }
        switch attendanceStatus(for: course) {
        case .signed: return "已签到"
        case .unsigned: return "未签到"
        case .unknown: return "状态待同步"
        }
    }
    private func projectAttendance(_ course: Course) -> Course {
        guard !isDemo else { return course }
        var value = course
        value.signed = attendanceStatus(for: course) == .signed
        return value
    }
    private func observeAttendance(_ course: Course, source: AttendanceSource, sequence: Int) {
        let key = attendanceKey(course)
        guard attendanceVersions[key, default: 0] < sequence else { return }
        let value: AttendanceStatus = source == .submission ? .signed : course.signStatusKnown == true ? (course.signed ? .signed : .unsigned) : .unknown
        let now = attendanceNow()
        let previous = attendanceStates[key] ?? AttendanceEvidence(observedAt: now)
        let state = previous.observing(value, source: source, now: now)
        attendanceStates[key] = state; attendanceVersions[key] = sequence
    }
    private func loadAttendanceState() {
        guard let id = activeAccountID, let data = defaults.data(forKey: "attendance-state-\(id)"),
              let cache = try? JSONDecoder().decode(AttendanceEvidenceCache.self, from: data), cache.version == 1, cache.accountID == id else { return }
        attendanceStates = cache.states; invalidatedAttendance = cache.invalidatedCourses
    }
    private func saveAttendanceState() {
        guard !isDemo, let id = activeAccountID,
              let data = try? JSONEncoder().encode(AttendanceEvidenceCache(accountID: id, states: attendanceStates, invalidatedCourses: invalidatedAttendance)) else { return }
        defaults.set(data, forKey: "attendance-state-\(id)")
    }
    func enterDay(_ date: Date) async {
        guard !isDemo else { return }
        if courseFreshness[SchoolDate.key(date)] == true, CachePolicy.isFresh(dayVerifiedAt[SchoolDate.key(date)], at: attendanceNow(), lifetime: 30) { return }
        await refresh(on: date)
    }
    private func readSemesters(force: Bool = false) async throws -> [SchoolSemester] {
        if let task = semesterReadTask { return try await task.value }
        if !force, !semesters.isEmpty, CachePolicy.isFresh(semestersUpdatedAt, at: .now) { return semesters }
        let token = generation
        let task = Task { try await self.scheduleRead(token: token) { try await self.service.semesters(session: $0) } }
        semesterReadTask = task
        defer { if generation == token { semesterReadTask = nil } }
        let values = try await task.value
        guard generation == token else { throw CancellationError() }
        semesters = values; semestersUpdatedAt = .now
        if let id = activeAccountID, let data = try? JSONEncoder().encode(SemesterMetadataCache(values: values, updatedAt: semestersUpdatedAt!)) {
            defaults.set(data, forKey: "catalog-\(id)-semesters")
        }
        return values
    }
    private struct SemesterMetadataCache: Codable { let values: [SchoolSemester]; let updatedAt: Date }
    private struct DirectoryCache: Codable { let version: Int; let courses: [CatalogCourse]; let updatedAt: Date }
    private func readDirectory(for term: SchoolSemester, force: Bool = false) async throws -> [CatalogCourse] {
        let id = term.id
        if let task = directoryReadTasks[id] { return try await task.value }
        if courseScheduleDirectories[id] == nil, selectedSemester?.id == id, let updated = catalogUpdatedAt {
            courseScheduleDirectories[id] = (catalogCourses, updated)
        }
        if courseScheduleDirectories[id] == nil, let account = activeAccountID,
           let data = defaults.data(forKey: "catalog-\(account)-directory-\(id)"),
           let stored = try? JSONDecoder().decode(DirectoryCache.self, from: data), stored.version == 1,
           stored.courses.allSatisfy({ $0.semesterId == id }) {
            courseScheduleDirectories[id] = (stored.courses, stored.updatedAt)
        }
        if let cached = courseScheduleDirectories[id] {
            if selectedSemester?.id == id { catalogCourses = cached.courses; catalogUpdatedAt = cached.updatedAt }
            if !force, CachePolicy.isFresh(cached.updatedAt, at: .now) { return cached.courses }
        }
        let token = generation
        let task = Task { try await self.scheduleRead(token: token) { try await self.service.catalogCourses(session: $0, semesterId: id) } }
        directoryReadTasks[id] = task
        defer { if token == generation { directoryReadTasks[id] = nil } }
        let values = try await task.value
        guard token == generation else { throw CancellationError() }
        guard values.allSatisfy({ $0.semesterId == id }) else { throw APIError(code: "CATALOG_SEMESTER", message: "学校返回了其他学期的课程") }
        let now = Date()
        courseScheduleDirectories[id] = (values, now)
        if selectedSemester?.id == id { catalogCourses = values; catalogUpdatedAt = now }
        if let account = activeAccountID, let data = try? JSONEncoder().encode(DirectoryCache(version: 1, courses: values, updatedAt: now)) {
            defaults.set(data, forKey: "catalog-\(account)-directory-\(id)")
        }
        courseSchedulePresentations.removeAll()
        return values
    }
}

// Applying shared preferences is deliberately separate from savePreferences(), whose
// transaction also owns this device's automatic attendance rules and activation clock.
extension AppModel {
    var cloudDeviceID: String { cloudSync.deviceID }

    @discardableResult
    func setHistoryRetention(_ value: HistoryRetentionSettings,
                             relativeTo previous: HistoryRetentionSettings? = nil) -> Bool {
        var next = historyRetention
        if previous == nil || previous?.operations.maxCount != value.operations.maxCount { next.operations.maxCount = value.operations.maxCount }
        if previous == nil || previous?.operations.maxAgeDays != value.operations.maxAgeDays { next.operations.maxAgeDays = value.operations.maxAgeDays }
        if previous == nil || previous?.automatic.maxCount != value.automatic.maxCount { next.automatic.maxCount = value.automatic.maxCount }
        if previous == nil || previous?.automatic.maxAgeDays != value.automatic.maxAgeDays { next.automatic.maxAgeDays = value.automatic.maxAgeDays }
        do {
            let encoded = try next.applicationPreferences()
            if isDemo { historyRetention = next; return true }
            let previousEncoded = try historyRetention.applicationPreferences()
            try loadAccounts()
            for (key, data) in encoded where previousEncoded[key] != data { defaults.set(data, forKey: key) }
            historyRetention = next
            // Capture the rows before cleanup so an immediate return to unlimited
            // retention cannot revive their earlier cloud copies.
            try cloudSync.recordLocalChanges(cloudSnapshot())
            maintainHistoryRetention(recordCleanup: true)
            recordCloudChanges()
            return true
        } catch {
            errorMessage = "无法保存记录保留设置：\(error.localizedDescription)"
            return false
        }
    }

    private func automaticHistoryRows(_ executions: [String: AutoSignExecution], accountID: String) -> [SyncAutoSignHistory] {
        let incarnation = cloudSync.incarnation(for: accountID)
        let local = executions.values.compactMap {
            SyncAutoSignHistory(execution: $0, accountID: accountID, incarnation: incarnation,
                sourceDeviceID: cloudDeviceID, sourceDeviceName: cloudSync.deviceName, revision: 0)
        }
        let discardedKeys = Set(executions.values.filter { $0.historyDiscarded == true }.map(\.key))
        var rows = Dictionary((syncedAutoSignHistory[accountID] ?? []).filter {
            $0.sourceDeviceID != cloudDeviceID || !discardedKeys.contains($0.occurrenceKey)
        }.map { ($0.id, $0) },
            uniquingKeysWith: { a, b in a.revision >= b.revision ? a : b })
        for row in local { rows[row.id] = row }
        return Array(rows.values)
    }

    private func compactAutomaticHistory(_ executions: [String: AutoSignExecution], accountID: String,
                                         deletedIDs: Set<String> = []) throws -> [String: AutoSignExecution] {
        let rows = automaticHistoryRows(executions, accountID: accountID)
        let retained = try historyRetention.automatic.retained(rows, now: attendanceNow(), date: \.updatedAt, id: \.id,
            protected: { ![.signed, .missed, .skipped].contains($0.stage) })
        let retainedIDs = Set(retained.map(\.id)).subtracting(deletedIDs)
        let retiredKeys = Set(rows.filter { $0.sourceDeviceID == cloudDeviceID && !retainedIDs.contains($0.id) }.map(\.occurrenceKey))
        var result = executions
        for key in retiredKeys {
            // Only display content is discarded. Submission evidence remains durable so
            // tightening a history limit cannot make an already handled class run again.
            result[key]?.discardHistory()
        }
        return result
    }

    private func maintainHistoryRetention(deletedHistory: [String: Set<String>] = [:], recordCleanup: Bool = false) {
        guard accountsLoaded, !isDemo else { return }
        guard historyRetention.operations.maxCount != nil || historyRetention.operations.maxAgeDays != nil
            || historyRetention.automatic.maxCount != nil || historyRetention.automatic.maxAgeDays != nil
            || deletedHistory.values.contains(where: { !$0.isEmpty }) else { return }
        do {
            for account in vault.accounts {
                let id = account.id
                let existing: [SyncAttendanceRecord]
                if id == activeAccountID { existing = records }
                else { existing = try defaults.data(forKey: "records-\(id)")
                    .map { try JSONDecoder().decode([SyncAttendanceRecord].self, from: $0) } ?? [] }
                let retained = try historyRetention.operations.retained(existing, now: attendanceNow(), date: \.date, id: { $0.id.uuidString })
                let executions = id == activeAccountID ? autoSignExecutions : try autoSignStore.load(accountID: id)
                let historyRows = automaticHistoryRows(executions, accountID: id)
                let retainedHistory = try historyRetention.automatic.retained(historyRows, now: attendanceNow(),
                    date: \.updatedAt, id: \.id, protected: { ![.signed, .missed, .skipped].contains($0.stage) })
                let keptHistoryIDs = Set(retainedHistory.map(\.id)).subtracting(deletedHistory[id] ?? [])
                if recordCleanup {
                    try cloudSync.recordHistoryCleanup(accountID: id,
                        attendanceIDs: Set(existing.map(\.id)).subtracting(retained.map(\.id)),
                        historyIDs: Set(historyRows.map(\.id)).subtracting(keptHistoryIDs))
                }
                if retained != existing {
                    defaults.set(try JSONEncoder().encode(retained), forKey: "records-\(id)")
                    if id == activeAccountID { records = retained }
                }
                let compacted = try compactAutomaticHistory(executions, accountID: id, deletedIDs: deletedHistory[id] ?? [])
                if compacted != executions {
                    try autoSignStore.save(accountID: id, executions: compacted)
                    if id == activeAccountID { autoSignExecutions = compacted }
                }
                if let remote = syncedAutoSignHistory[id] {
                    syncedAutoSignHistory[id] = remote.filter { keptHistoryIDs.contains($0.id) }
                }
            }
        } catch { errorMessage = "记录保留设置已保存，部分记录尚未清理：\(error.localizedDescription)" }
    }

    func loginUsername(for accountID: String?) -> String {
        guard let accountID else { return "" }
        return accounts.first { $0.id == accountID }?.loginUsername
            ?? iCloudPendingAccounts.first { $0.studentNo == accountID }?.loginUsername ?? accountID
    }

    func setICloudSyncEnabled(_ enabled: Bool) {
        iCloudSyncEnabled = enabled
        defaults.set(enabled, forKey: "iCloudSyncEnabled")
        cloudSync.setEnabled(enabled && !isDemo)
        recordCloudChanges()
        updateCloudStatus()
    }

    func synchronizeICloud() async {
        guard !isDemo else { return }
        retryCloudBootstrapIfNeeded()
        do { try loadAccounts(); recordCloudChanges() }
        catch { iCloudSyncStatus = .failed(error.localizedDescription); return }
        await cloudSync.synchronize(force: true)
        updateCloudStatus()
    }

    func handleICloudRemoteNotification(_ userInfo: [AnyHashable: Any]) async -> CloudSyncRemoteRefreshResult {
        let container = Bundle.main.object(forInfoDictionaryKey: "CloudContainerIdentifier") as? String ?? ""
        guard !isDemo, iCloudSyncEnabled,
              !ProcessInfo.processInfo.arguments.contains("--demo"),
              CloudKitSyncSubscription.matches(userInfo: userInfo, containerIdentifier: container) else { return .noData }
        retryCloudBootstrapIfNeeded()
        // A silent push can launch the process before the root view restores it.
        // Load only the local vault here; normal UI restoration owns school refreshes.
        do { try loadAccounts() }
        catch {
            iCloudSyncStatus = .failed(error.localizedDescription)
            return .failed
        }
        guard recordCloudChanges() else { return .failed }
        let result = await cloudSync.remoteChangesAvailable()
        maintainHistoryRetention(recordCleanup: true)
        updateCloudStatus()
        return result
    }

    func iCloudForegroundTick() async {
        guard !isDemo, accountsLoaded else { return }
        retryCloudBootstrapIfNeeded()
        // Fetch and merge a newer retention choice before applying an older local limit.
        let captured = recordCloudChanges()
        await cloudSync.tick()
        if captured { maintainHistoryRetention(recordCleanup: true) }
        updateCloudStatus()
    }

    private func updateCloudStatus() {
        if cloudSync.status == .ready, let cloudSessionValidationIssue {
            iCloudSyncStatus = .failed(cloudSessionValidationIssue)
        } else {
            iCloudSyncStatus = cloudSync.status == .ready && !iCloudPendingAccounts.isEmpty ? .waitingForCredentials : cloudSync.status
        }
        iCloudLastSyncedAt = cloudSync.lastSuccessfulSync
    }

    private func retryCloudBootstrapIfNeeded() {
        guard iCloudSyncEnabled, cloudSync.requiresBootstrapRetry else { return }
        cloudSync.setEnabled(false)
        cloudSync = CloudSyncEnvironment.make(defaults: defaults, allowLive: true)
        cloudSync.snapshot = { [weak self] in try self?.cloudSnapshot() ?? .init() }
        cloudSync.apply = { [weak self] in try await self?.applyCloudChanges($0) }
        cloudSync.onChange = { [weak self] in self?.updateCloudStatus() }
    }

    @discardableResult
    private func recordCloudChanges(explicitLogin: String? = nil) -> Bool {
        guard accountsLoaded, !isDemo, !isApplyingCloudSync else { return false }
        do {
            try cloudSync.recordLocalChanges(cloudSnapshot(), explicitLogin: explicitLogin)
            return true
        } catch {
            iCloudSyncStatus = .failed(error.localizedDescription)
            return false
        }
    }

    private func cloudSnapshot() throws -> CloudSyncLocalSnapshot {
        guard accountsLoaded, !isDemo else { return .init() }
        var app: [String: Data] = [:]
        for key in SyncPreferenceProjection.applicationKeys where defaults.object(forKey: key) != nil {
            if HistoryRetentionSettings.applicationKeys.contains(key) {
                app[key] = defaults.data(forKey: key)
                continue
            }
            switch key {
            case "appearanceMode", "scheduleViewMode": app[key] = try SyncCodec.encode(defaults.string(forKey: key) ?? "")
            default: app[key] = try SyncCodec.encode(defaults.bool(forKey: key))
            }
        }
        var attendance: [String: [SyncAttendanceRecord]] = [:]
        var executions: [String: [AutoSignExecution]] = [:]
        for account in vault.accounts {
            if account.id == activeAccountID {
                attendance[account.id] = records
                executions[account.id] = Array(autoSignExecutions.values)
            } else {
                attendance[account.id] = try defaults.data(forKey: "records-\(account.id)")
                    .map { try JSONDecoder().decode([SyncAttendanceRecord].self, from: $0) } ?? []
                // Unreadable execution storage never erases previously shared display history.
                executions[account.id] = (try? autoSignStore.load(accountID: account.id)).map { Array($0.values) } ?? []
            }
        }
        return .init(accounts: vault.accounts, applicationPreferences: app, attendance: attendance, executions: executions)
    }

    var displayAutoSignHistory: [SyncAutoSignHistory] {
        guard let id = activeAccountID else { return [] }
        let rows = automaticHistoryRows(autoSignExecutions, accountID: id)
        return (try? historyRetention.automatic.retained(rows, now: attendanceNow(), date: \.updatedAt, id: \.id,
            protected: { ![.signed, .missed, .skipped].contains($0.stage) })) ?? rows
    }

    private func validatedCloudApplicationPreferences(_ fields: [String: Data]) throws -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, data) in fields {
            if HistoryRetentionSettings.applicationKeys.contains(key) {
                _ = try HistoryRetentionSettings.from(applicationPreferences: [key: data])
                result[key] = data
                continue
            }
            switch key {
            case "appearanceMode":
                let value = try SyncCodec.decode(String.self, from: data)
                guard AppAppearance(rawValue: value) != nil else { throw CloudSyncStateError.invalidData }
                result[key] = value
            case "scheduleViewMode":
                let value = try SyncCodec.decode(String.self, from: data)
                guard ScheduleMode(rawValue: value) != nil else { throw CloudSyncStateError.invalidData }
                result[key] = value
            case "accountDetailsHidden", "showOutsideWeekCourses", "update.automaticChecks":
                result[key] = try SyncCodec.decode(Bool.self, from: data)
            default: throw CloudSyncStateError.invalidData
            }
        }
        return result
    }

    private func applyCloudChanges(_ changes: CloudSyncIncoming) async throws {
        guard !isDemo, iCloudSyncEnabled else { throw CancellationError() }
        try loadAccounts()
        let firstAccountRestore = vault.accounts.isEmpty && activeAccountID == nil
            && changes.deletedAccountIDs.isEmpty
        let application = try validatedCloudApplicationPreferences(changes.applicationPreferences)
        let incomingRetention = try HistoryRetentionSettings.from(applicationPreferences:
            historyRetention.applicationPreferences().merging(changes.applicationPreferences) { _, received in received })
        // Validate the entire ordinary-preference projection before changing any local state.
        for change in changes.accounts {
            var preferences = AccountPreferences()
            try SyncPreferenceProjection.applyAccount(change.preferences, to: &preferences)
            for fields in change.courses.values {
                var course = CoursePreferences()
                try SyncPreferenceProjection.applyCourse(fields, to: &course)
            }
        }
        // A tombstone cancels work immediately, including an in-flight account operation.
        isApplyingCloudSync = true
        if cloudAppliedIdentity != cloudSync.state.identity {
            iCloudPendingAccounts = []
            syncedAutoSignHistory = [:]
            cloudVerifiedSessions = []
            cloudAppliedIdentity = cloudSync.state.identity
        }
        for id in changes.deletedAccountIDs {
            cloudDeletedAccounts.insert(id)
            if activeAccountID == id { pendingSignConfirmation = nil }
            removeAccount(id: id)
            if vault.accounts.contains(where: { $0.id == id }) {
                isApplyingCloudSync = false
                throw CloudSyncStateError.unavailable
            }
        }
        isApplyingCloudSync = false

        let token = generation
        var expectedReplica = cloudSync.state
        var accepted: [String: SchoolSession] = [:]
        var acceptedVersions: [String: SyncVersion] = [:]
        var rejected: [String: Set<String>] = [:]
        var validationIssue: String?
        for change in changes.accounts {
            let id = change.profile.studentNo
            let current = vault.accounts.first { $0.id == id }
            // A shared token is tested with a school read. It cannot submit attendance.
            for candidate in change.sessions {
                if current?.session == candidate.session && current?.requiresLogin == false {
                    accepted[id] = candidate.session
                    acceptedVersions[id] = candidate.reference.version
                    break
                }
                if id == activeAccountID && !canChangeAccount { break }
                do {
                    if !cloudVerifiedSessions.contains(candidate.reference.id) {
                        _ = try await service.courses(session: candidate.session, date: attendanceNow())
                        try Task.checkCancellation()
                        guard generation == token, cloudSync.state == expectedReplica, !isDemo, iCloudSyncEnabled else {
                            throw CloudSyncStateError.deferred
                        }
                        cloudVerifiedSessions.insert(candidate.reference.id)
                    }
                    accepted[id] = candidate.session
                    acceptedVersions[id] = candidate.reference.version
                    break
                } catch let error as APIError where error.isSessionExpired {
                    try Task.checkCancellation()
                    guard generation == token, cloudSync.state == expectedReplica else { throw CloudSyncStateError.deferred }
                    try cloudSync.invalidateSession(accountID: id, reference: candidate.reference)
                    rejected[id, default: []].insert(candidate.reference.fingerprint)
                    expectedReplica = cloudSync.state
                } catch {
                    // Network failures are not credential revocations. Preserve the local session.
                    if error is CancellationError || error is CloudSyncStateError { throw error }
                    validationIssue = "登录信息验证暂不可用，将自动重试：\(error.localizedDescription)"
                    break
                }
            }
        }
        try Task.checkCancellation()
        guard generation == token, cloudSync.state == expectedReplica, !isDemo, iCloudSyncEnabled else {
            throw CloudSyncStateError.deferred
        }
        // There are no suspension points inside the local transaction: user edits that
        // happened during validation are either retained above or retried in the next pass.
        isApplyingCloudSync = true
        defer { isApplyingCloudSync = false }
        var updated = vault
        var pending: [SyncAccountProfile] = []
        var mergedRecords: [String: [SyncAttendanceRecord]] = [:]
        var boundaries: [Date] = []
        for change in changes.accounts {
            let id = change.profile.studentNo
            var account = updated.accounts.first { $0.id == id }
            if account == nil, let session = accepted[id] {
                account = StoredAccount(session: session, loginUsername: change.profile.loginUsername,
                    lastUsedAt: .distantPast, preferences: AccountPreferences(autoSignRunning: false, autoSignV2Acknowledged: true))
            }
            guard var account else { pending.append(change.profile); continue }
            if let session = accepted[id], id != activeAccountID || canChangeAccount {
                account.session = session
                account.requiresLogin = false
            } else {
                let fingerprint = try cloudSync.sessionFingerprint(account.session, incarnation: change.profile.incarnation)
                if change.invalidSessionFingerprints.contains(fingerprint) || rejected[id]?.contains(fingerprint) == true { account.requiresLogin = true }
            }
            account.loginUsername = change.profile.loginUsername
            switch change.password {
            case .unchanged: break
            case .clear: account.credentials = nil
            case .value(let value): account.credentials = value
            }
            try SyncPreferenceProjection.applyAccount(change.preferences, to: &account.preferences)
            for (courseID, fields) in change.courses {
                var course = account.preferences.courses[courseID] ?? CoursePreferences()
                let wasDisabled = course.signInDisabled
                try SyncPreferenceProjection.applyCourse(fields, to: &course)
                if wasDisabled && !course.signInDisabled {
                    let boundary = id == activeAccountID ? autoSignSchoolNow : attendanceNow()
                    course.autoSignEnabledSince = boundary
                    if id != activeAccountID || autoSignClockSchoolAt == nil {
                        account.preferences.autoSignPendingClockBoundaries = Array(Set(account.preferences.autoSignPendingClockBoundaries + [boundary])).sorted()
                        if id == activeAccountID { boundaries.append(boundary) }
                    }
                }
                account.preferences.courses[courseID] = course
            }
            updated.upsert(account, makeActive: false)
            let existing: [SyncAttendanceRecord]
            if id == activeAccountID { existing = records }
            else { existing = try defaults.data(forKey: "records-\(id)").map { try JSONDecoder().decode([SyncAttendanceRecord].self, from: $0) } ?? [] }
            var rows = Dictionary(existing.filter { !change.deletedAttendanceIDs.contains($0.id) }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for row in change.attendance { rows[row.id] = row }
            mergedRecords[id] = try incomingRetention.operations.retained(Array(rows.values), now: attendanceNow(),
                date: \.date, id: { $0.id.uuidString })
        }
        if firstAccountRestore, updated.activeAccountID == nil,
           let selected = acceptedVersions.max(by: { $0.value < $1.value })?.key,
           updated.accounts.contains(where: { $0.id == selected }) {
            updated.activeAccountID = selected
        }
        let oldSession = session
        if updated != vault { try accountStore.save(updated); vault = updated; updateAccountList() }
        for (key, value) in application { defaults.set(value, forKey: key) }
        historyRetention = incomingRetention
        if let mode = application["scheduleViewMode"] as? String, let value = ScheduleMode(rawValue: mode) { scheduleMode = value }
        if let value = application["showOutsideWeekCourses"] as? Bool { showOutsideWeekCourses = value }
        iCloudPendingAccounts = pending
        cloudSessionValidationIssue = validationIssue
        for change in changes.accounts {
            let id = change.profile.studentNo
            syncedAutoSignHistory[id] = change.history
            if vault.accounts.contains(where: { $0.id == id }) { cloudDeletedAccounts.remove(id) }
        }
        for (id, rows) in mergedRecords {
            defaults.set(try JSONEncoder().encode(rows), forKey: "records-\(id)")
            if id == activeAccountID { records = rows }
        }
        if let account = vault.accounts.first(where: { $0.id == vault.activeAccountID }) {
            if activeAccountID != account.id || oldSession != account.session {
                activate(account)
                if loginRequest?.accountID == account.id { loginRequest = nil }
            } else {
                remindersEnabled = account.preferences.remindersEnabled
                confirmationEnabled = account.preferences.confirmationEnabled
                reminderLeadMinutes = account.preferences.reminderLeadMinutes
                coursePreferences = account.preferences.courses
                for boundary in boundaries {
                    autoSignUncalibratedBoundaries.insert(boundary)
                    autoSignActivationUptimes[boundary] = autoSignMonotonicNow()
                }
                if account.requiresLogin { automaticRefreshPaused = true; courseFreshness = courseFreshness.mapValues { _ in false } }
                if let confirmation = pendingSignConfirmation, isSignInDisabled(for: confirmation.course) { pendingSignConfirmation = nil }
            }
        }
        syncedPreferencesRevision &+= 1
        maintainHistoryRetention(deletedHistory: Dictionary(changes.accounts.map { ($0.profile.studentNo, $0.deletedHistoryIDs) },
            uniquingKeysWith: { $0.union($1) }))
        // Permission is device-local; scheduling consults authorization and never prompts.
        let reminderToken = generation
        Task { [weak self] in
            guard let self, self.generation == reminderToken else { return }
            if self.hasEnabledReminders { await self.scheduleReminders() }
            else { await self.clearCourseReminderNotifications() }
        }
    }
}
