import SwiftUI
import UserNotifications
import WidgetKit

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
    @Published var showLogin = false
    @Published var notice: String?
    @Published var errorMessage: String?
    @Published var lastUpdated: Date?
    @Published private var courseUpdates: [String: Date] = [:]
    @Published private var courseNotices: [String: String] = [:]
    @Published private var courseFreshness: [String: Bool] = [:]
    @Published var records: [AttendanceRecord] = []
    @Published var remindersEnabled = UserDefaults.standard.bool(forKey: "remindersEnabled")
    @Published var autoSignEnabled = UserDefaults.standard.bool(forKey: "autoSignEnabled")
    let service: QingxinService
    #if os(macOS)
    private let keychain = KeychainStore(service: "\(Bundle.main.bundleIdentifier ?? "cn.ucas.signin.mac").credentials")
    #else
    private let keychain = KeychainStore()
    #endif
    private var generation = UUID()
    private var refreshSequence = 0
    private var courseRefreshSequences: [String: Int] = [:]
    private var reminderGeneration = UUID()
    private var todayIsFresh: Bool { courseFreshness[SchoolDate.key(.now)] == true }
    private var autoAttempts: Set<String> = []
    private var restored = false
    private var automaticRefreshPaused = false

    init(service: QingxinService = QingxinService()) {
        self.service = service
    }

    var isCached: Bool { isCached(on: selectedDate) }
    var isLoading: Bool { isAuthenticating || !refreshTasks.isEmpty }
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
    func canSign(_ course: Course) -> Bool {
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

    func restore() async {
        guard !restored else { return }
        restored = true
        if ProcessInfo.processInfo.arguments.contains("--demo") { enterDemo(); return }
        do {
            session = try keychain.loadSession()
            if session != nil { loadRecords(); await refresh() }
        } catch { errorMessage = "无法读取本机登录信息，请重新登录。" }
    }

    func login(username: String, password: String, remember: Bool) async -> Bool {
        guard !isLoading else { return false }
        let token = generation
        isAuthenticating = true
        defer { if generation == token { isAuthenticating = false } }
        do {
            let result = try await service.login(username: username, password: password)
            guard generation == token else { return false }
            try keychain.save(session: result)
            if remember { try keychain.save(credentials: StoredCredentials(username: username, password: password)) }
            else { try keychain.clearCredentials() }
            generation = UUID()
            cancelRefreshes()
            reminderGeneration = UUID()
            signingID = nil
            courseFreshness.removeAll()
            automaticRefreshPaused = false
            UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
            WidgetSnapshotStore.clear()
            WidgetCenter.shared.reloadAllTimelines()
            session = result
            isDemo = false
            courses = []
            autoAttempts.removeAll()
            records = []
            selectedDate = .now
            loadRecords()
            showLogin = false
            isAuthenticating = false
            await refresh()
            return true
        } catch {
            if generation == token { errorMessage = error.localizedDescription }
            return false
        }
    }

    func savedCredentials() -> StoredCredentials? { try? keychain.loadCredentials() }

    func enterDemo() {
        generation = UUID()
        cancelRefreshes()
        reminderGeneration = UUID()
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        WidgetSnapshotStore.clear()
        WidgetCenter.shared.reloadAllTimelines()
        isAuthenticating = false
        signingID = nil
        session = nil
        isDemo = true
        selectedDate = .now
        courses = Self.demoCourses(on: selectedDate)
        records = []
        lastUpdated = .now
        courseUpdates[SchoolDate.key(selectedDate)] = lastUpdated
        courseFreshness.removeAll()
        notice = nil
        showLogin = false
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
        do {
            let result = try await service.courses(session: session, date: date)
            guard !Task.isCancelled, generation == accountToken else { return }
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
            guard !Task.isCancelled, generation == accountToken else { return }
            if error is CancellationError { return }
            if let apiError = error as? APIError, apiError.isSessionExpired {
                automaticRefreshPaused = true
                errorMessage = "登录已过期，请重新登录学校账号。"
                showLogin = true
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

    func sign(_ course: Course) async {
        guard canSign(course) else { return }
        let token = generation
        autoAttempts.insert("\(course.day)-\(course.id)")
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
        guard let session else { showLogin = true; return }
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
            if let error = error as? APIError, error.isSessionExpired { showLogin = true }
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
        let key = "\(course.day)-\(course.id)"
        guard autoAttempts.insert(key).inserted else { return }
        await sign(course)
    }

    private func signInFeedback() {
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }

    func setAutoSign(_ enabled: Bool) {
        autoSignEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "autoSignEnabled")
    }

    func setReminders(_ enabled: Bool) async {
        let token = generation
        reminderGeneration = UUID()
        let settingToken = reminderGeneration
        if enabled {
            do {
                let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                guard generation == token, reminderGeneration == settingToken else { return }
                remindersEnabled = allowed
                if !allowed {
                    #if os(macOS)
                    errorMessage = "通知尚未开启。请前往系统设置 → 通知 → 果壳签到，允许课程提醒。"
                    #else
                    errorMessage = "通知尚未开启。可前往设置 → 果壳签到 → 通知，允许课程提醒。"
                    #endif
                }
            } catch { remindersEnabled = false; errorMessage = error.localizedDescription }
        } else { remindersEnabled = false }
        UserDefaults.standard.set(remindersEnabled, forKey: "remindersEnabled")
        if remindersEnabled { await scheduleReminders() }
        else { UNUserNotificationCenter.current().removeAllPendingNotificationRequests() }
    }

    private func scheduleReminders() async {
        guard !isDemo, session != nil else { return }
        let accountToken = generation
        let requestToken = UUID()
        reminderGeneration = requestToken
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        for course in courses.prefix(60) where !course.signed {
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
                try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
                guard generation == accountToken, reminderGeneration == requestToken, remindersEnabled else {
                    center.removePendingNotificationRequests(withIdentifiers: [identifier])
                    return
                }
            }
            catch {
                notice = "部分课程提醒未能保存，请重新开启提醒。"
                courseNotices[normalizedDay(course.day)] = notice
            }
        }
    }

    func logout() {
        if !isDemo {
            do { try keychain.clear() }
            catch { errorMessage = "本机凭据未能清除，请重试退出。"; return }
            for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("courses-") || key.hasPrefix("records-") {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        generation = UUID()
        cancelRefreshes()
        reminderGeneration = UUID()
        courseFreshness.removeAll()
        automaticRefreshPaused = false
        session = nil; isDemo = false; courses = []; records = []
        isAuthenticating = false; signingID = nil; lastUpdated = nil; notice = nil
        autoAttempts.removeAll()
        setAutoSign(false)
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        WidgetSnapshotStore.save(WidgetSnapshot(courses: []))
        WidgetCenter.shared.reloadAllTimelines()
        Task { await service.clearClock() }
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
        WidgetSnapshotStore.save(WidgetSnapshot(courses: values))
        WidgetCenter.shared.reloadAllTimelines()
    }
    private func saveCache(for session: SchoolSession, date: Date) {
        let datedCourses = courses.filter { normalizedDay($0.day) == SchoolDate.key(date) }
        guard let data = try? JSONEncoder().encode(CachedCourses(courses: datedCourses, updatedAt: lastUpdated(on: date) ?? .now)) else { return }
        UserDefaults.standard.set(data, forKey: "courses-\(session.studentNo)-\(SchoolDate.key(date))")
    }
    private func loadCache(for session: SchoolSession, date: Date) -> Bool {
        guard let data = UserDefaults.standard.data(forKey: "courses-\(session.studentNo)-\(SchoolDate.key(date))"),
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
        UserDefaults.standard.set(data, forKey: "records-\(session.studentNo)")
    }
    private func loadRecords() {
        guard let session, let data = UserDefaults.standard.data(forKey: "records-\(session.studentNo)"),
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
