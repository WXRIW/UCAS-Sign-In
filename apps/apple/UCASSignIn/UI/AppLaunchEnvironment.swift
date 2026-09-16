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
        } else if url.path.hasSuffix("get_timestamp.do") {
            payload = ["STATUS": "0", "timestamp": Int64(Date().timeIntervalSince1970 * 1000)]
        } else if url.path.hasSuffix("stu_scan_sign.action") {
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if let id = query.first(where: { $0.name == "id" })?.value { signed.insert(id) }
            payload = ["STATUS": "0", "ERRCODE": "0", "success": true,
                       "result": ["stuSignStatus": "1", "stuSignId": "fixture-record"]]
        } else if url.path.hasSuffix("get_stu_course_sched.action") {
            let id = fields["id"] ?? "fixture-1"
            let index = Int(id.suffix(1)) ?? 1
            payload = ["STATUS": "0", "result": [["id": "100000\(index)",
                        "courseName": ["账户一课程", "账户二课程", "账户三课程"][min(3, max(1, index)) - 1],
                        "teacherName": "示例教师", "classroomName": "示例教室", "classBeginTime": "23:30",
                        "classEndTime": "23:59", "signStatus": signed.contains(id) ? "1" : "0"]]]
        } else {
            throw APIError(code: "FIXTURE_REQUEST", message: "未配置的测试请求")
        }
        return (try JSONSerialization.data(withJSONObject: payload),
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
#endif
