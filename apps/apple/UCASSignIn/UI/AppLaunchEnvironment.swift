import SwiftUI
#if DEBUG
import UserNotifications
#endif

@MainActor
enum AppLaunchEnvironment {
    static var isUnitTestHost: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
        #else
        false
        #endif
    }

    static var defaults: UserDefaults {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--account-fixtures") {
            return UserDefaults(suiteName: "\(Bundle.main.bundleIdentifier ?? "ucas").account-fixtures")!
        }
        #endif
        return .standard
    }

    static func makeModel() -> AppModel {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--account-fixtures") {
            let preferences = defaults
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("--fixture-reset") || !arguments.contains("--fixture-persist") {
                preferences.removePersistentDomain(forName: "\(Bundle.main.bundleIdentifier ?? "ucas").account-fixtures")
            }
            return AppModel(service: QingxinService(transport: AccountFixtureTransport()),
                            accountStore: FixtureAccountStore(defaults: preferences), defaults: preferences,
                            notifications: FixtureNotifications(), widgets: FixtureWidgets())
        }
        #endif
        return AppModel()
    }
}

#if DEBUG
/// Deterministic UI tests exercise real account flows without accessing live services.
@MainActor
private final class FixtureAccountStore: AccountStore {
    private let defaults: UserDefaults
    init(defaults: UserDefaults) { self.defaults = defaults }
    func load() throws -> AccountVault {
        if let data = defaults.data(forKey: "fixture.accounts") {
            return try JSONDecoder().decode(AccountVault.self, from: data)
        }
        let a = StoredAccount(session: SchoolSession(userId: "fixture-1", sessionId: "fixture-session-1",
                                                     studentNo: "2026000001", name: "林清"))
        let b = StoredAccount(session: SchoolSession(userId: "fixture-2", sessionId: "fixture-session-2",
                                                     studentNo: "2026000002", name: "周宁"),
                              lastUsedAt: Date().addingTimeInterval(-60))
        let vault = AccountVault(accounts: [a, b], activeAccountID: a.id)
        try save(vault)
        return vault
    }
    func save(_ vault: AccountVault) throws {
        defaults.set(try JSONEncoder().encode(vault), forKey: "fixture.accounts")
    }
}

private struct FixtureNotifications: NotificationClient {
    func authorizationStatus() async -> UNAuthorizationStatus { .authorized }
    func requestAuthorization() async throws -> Bool { true }
    func add(_ request: UNNotificationRequest) async throws { }
    func removeAll() { }
    func remove(ids: [String]) { }
}

private struct FixtureWidgets: WidgetClient {
    func save(_ snapshot: WidgetSnapshot) { }
    func clear() { }
}

private actor AccountFixtureTransport: HTTPTransport {
    private var signed: Set<String> = []
    private var catalogRequests = 0
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        var form = URLComponents()
        form.percentEncodedQuery = request.httpBody.flatMap { String(data: $0, encoding: .utf8) }
        let fields = Dictionary((form.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
        let payload: [String: Any]
        if url.path.hasSuffix("login.action") {
            let username = fields["phone"] ?? ""
            let numbers = ["2026000001", "2026000002", "2026000003"]
            guard let index = numbers.firstIndex(of: username), fields["password"] != "wrong" else {
                throw APIError(code: "LOGIN_FAILED", message: "测试账号或密码不正确")
            }
            payload = ["STATUS": "0", "result": ["id": "fixture-\(index + 1)",
                        "sessionId": "fixture-session-\(index + 1)", "studentNo": username,
                        "realName": ["林清", "周宁", "顾言"][index]]]
        } else if url.path.hasSuffix("get_base_school_year.action") {
            let year = SchoolDate.calendar.component(.year, from: .now)
            let slow = ProcessInfo.processInfo.arguments.contains("--slow-schedule-fixture")
            let week = SchoolDate.week(containing: .now)
            payload = ["STATUS": "0", "result": [["code": "fixture-semester", "name": "测试学期",
                       "beginDate": slow ? SchoolDate.key(week[0]) : "\(year)-01-01",
                       "endDate": slow ? SchoolDate.key(week[6]) : "\(year)-12-31", "yearStatus": "1"]]]
        } else if url.path.hasSuffix("get_myall_course.action") {
            if ProcessInfo.processInfo.arguments.contains("--co-teacher-fixture") {
                let result: [String: Any] = ["STATUS": "0", "result": [[
                    "course_id": "joint-course", "course_name": "联合课程", "courseNum": "CS6001",
                    "teacher_name": "教师一,教师二,教师三", "classroomName": "B203",
                    "semesterId": "fixture-semester"]]]
                return (try JSONSerialization.data(withJSONObject: result),
                        HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            catalogRequests += 1
            if catalogRequests > 1 {
                // Exercise the real loading path, with both fast and slow responses.
                try await Task.sleep(for: .milliseconds(catalogRequests.isMultiple(of: 2) ? 80 : 900))
            }
            payload = ["STATUS": "0", "result": (1...18).map { index in
                ["course_id": "fixture-course-\(index)", "course_name": "测试课程\(index)",
                 "courseNum": "TEST00\(index)", "teacher_name": "示例教师",
                 "semesterId": "fixture-semester"]
            }]
        } else if url.path.hasSuffix("get_my_course_sign_detail.action"),
                  ProcessInfo.processInfo.arguments.contains("--co-teacher-fixture"), fields["courseId"] == "joint-course" {
            payload = ["STATUS": "0", "mySignNum": "0", "myNoSignNum": "1", "result": [[
                "id": "joint-attendance", "courseId": "joint-course", "courseSchedId": "2345671",
                "teachTime": SchoolDate.key(SchoolDate.week(containing: .now)[0]),
                "classBeginTime": "08:00", "classEndTime": "09:40", "signStatus": "0"]]]
        } else if url.path.hasSuffix("get_timestamp.do") {
            payload = ["STATUS": "0", "timestamp": Int64(Date().timeIntervalSince1970 * 1000)]
        } else if url.path.hasSuffix("stu_scan_sign.action") {
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if let id = query.first(where: { $0.name == "id" })?.value { signed.insert(id) }
            payload = ["STATUS": "0", "ERRCODE": "0", "success": true,
                       "result": ["stuSignStatus": "1", "stuSignId": "fixture-record"]]
        } else if url.path.hasSuffix("get_stu_course_sched_week.action") {
            if ProcessInfo.processInfo.arguments.contains("--slow-schedule-fixture") {
                try await Task.sleep(for: .seconds(12))
            }
            if ProcessInfo.processInfo.arguments.contains("--failed-schedule-fixture") {
                throw APIError(code: "FIXTURE_SCHEDULE", message: "测试同步失败")
            }
            let date = CourseTime.parse(day: fields["dateStr"] ?? "", time: "00:00") ?? .now
            let id = fields["id"] ?? "fixture-1"
            let index = min(3, max(1, Int(id.suffix(1)) ?? 1))
            payload = ["STATUS": "0", "result": SchoolDate.week(containing: date).map { date in
                ["dateStr": SchoolDate.key(date), "schedData": scheduleCourses(on: date, accountID: id, index: index)] as [String: Any]
            }]
        } else if url.path.hasSuffix("get_stu_course_sched.action") {
            let id = fields["id"] ?? "fixture-1"
            let index = min(3, max(1, Int(id.suffix(1)) ?? 1))
            let date = CourseTime.parse(day: fields["dateStr"] ?? "", time: "00:00") ?? .now
            payload = ["STATUS": "0", "result": scheduleCourses(on: date, accountID: id, index: index)]
        } else {
            throw APIError(code: "FIXTURE_REQUEST", message: "未配置的测试请求")
        }
        return (try JSONSerialization.data(withJSONObject: payload),
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    private func scheduleCourses(on date: Date, accountID: String, index: Int) -> [[String: Any]] {
        var courses: [[String: Any]] = [["id": "100000\(index)",
            "courseName": ["账户一课程", "账户二课程", "账户三课程"][index - 1],
            "teacherName": "示例教师", "classroomName": "示例教室", "classBeginTime": "23:30",
            "classEndTime": "23:59", "signStatus": signed.contains(accountID) ? "1" : "0"]]
        let previousMonday = SchoolDate.calendar.date(byAdding: .day, value: -7, to: SchoolDate.week(containing: .now)[0])!
        if ProcessInfo.processInfo.arguments.contains("--outside-week-fixture"),
           SchoolDate.key(date) == SchoolDate.key(previousMonday) {
            courses.append(["id": "7654321", "courseId": "outside-week", "courseName": "非本周示例课程",
                            "teacherName": "示例教师", "classroomName": "教学楼 A101", "classBeginTime": "08:00",
                            "classEndTime": "09:40", "signStatus": "0"])
        }
        if ProcessInfo.processInfo.arguments.contains("--co-teacher-fixture"),
           SchoolDate.key(date) == SchoolDate.key(SchoolDate.week(containing: .now)[0]) {
            courses += (1...3).map { teacher in
                ["id": "234567\(teacher)", "courseId": teacher == 1 ? "joint-course" : "joint-teaching-\(teacher)",
                 "courseNum": "CS6001", "teacherId": "teacher-\(teacher)", "semesterId": "incorrect-term",
                 "courseName": "联合课程：研究生心理健康教育指导", "teacherName": ["教师一", "教师二", "教师三"][teacher - 1],
                 "classroomName": "B203", "classBeginTime": "08:00", "classEndTime": "09:40", "signStatus": "0"]
            }
        }
        return courses
    }
}
#endif
