import Foundation
import CoreFoundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public final class URLSessionTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session { self.session = session } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 20
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            self.session = URLSession(configuration: configuration, delegate: SchoolRedirectPolicy(), delegateQueue: nil)
        }
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw APIError(code: "HTTP_BAD_RESPONSE", message: "学校网络响应异常，请稍后重试")
        }
        return (data, response)
    }
}

/// Never forward a session header or login POST to a different host or to plain HTTP.
private final class SchoolRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let original = task.originalRequest?.url
        let destination = request.url
        let allowed = destination?.scheme == "https" && destination?.host == original?.host && destination?.port == original?.port
        completionHandler(allowed ? request : nil)
    }
}

/// Native implementation of the endpoints documented by the upstream Android client.
/// Credentials and session headers are only sent to the school's HTTPS host.
public actor QingxinService {
    public static let baseURL = URL(string: "https://iclass.ucas.edu.cn:8181/app/")!
    public static let timeSyncTTL: TimeInterval = 30
    public static let qrRefreshInterval: TimeInterval = 5
    private static let userAgent = "student_5.0.1.2_android_12_20_100000000000000_110000"
    private static let loginUserAgent = "student_5.0.1.2_android_12_20__110000"
    private static let verificationURL = "http://iclass.ucas.edu.cn:88/ve/webservices/mobileCheck.shtml?method=mobileLogin&username=${0}&password=${1}&lx=${2}"
    private let transport: any HTTPTransport
    private let now: @Sendable () -> Date
    private var sample: ClockSample?
    private var pendingSync: Task<ClockSample, Error>?
    private var clockGeneration = 0

    public init(transport: any HTTPTransport = URLSessionTransport(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport
        self.now = now
    }

    public func login(username: String, password: String) async throws -> SchoolSession {
        let identity = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identity.isEmpty, !password.isEmpty else {
            throw APIError(code: "LOGIN_INPUT_INVALID", message: "请输入学号或 SEP 邮箱和密码")
        }
        let json = try await execute(path: "user/login.action", fields: [
            ("phone", identity), ("password", password), ("verificationType", "1"),
            ("verificationUrl", Self.verificationURL), ("userLevel", "1")
        ], login: true)
        return try ResponseParser.session(json)
    }

    public func resumeSession(identity: String) async throws -> SchoolSession {
        let identity = identity.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identity.isEmpty else { throw APIError(code: "LOGIN_EXPIRED", message: "登录已失效，请重新登录") }
        let json = try await execute(path: "user/login.action", fields: [
            ("phone", identity), ("password", ""), ("verificationType", "2"),
            ("verificationUrl", ""), ("userLevel", "1")
        ], login: true)
        return try ResponseParser.session(json)
    }

    public func courses(session: SchoolSession, date: Date = Date()) async throws -> CourseQueryResult {
        let day = CourseTime.dayKey(date)
        let fields = [("id", session.userId), ("dateStr", day)]
        let daily = try await execute(path: "course/get_stu_course_sched.action", session: session, fields: fields)
        try ResponseParser.rejectSessionError(daily)
        if ResponseParser.scalar(daily["STATUS"]) == "0" {
            if let entries = daily["result"] as? [[String: Any]] {
                let courses = try ResponseParser.scheduledCourses(entries, day: day)
                if !courses.isEmpty {
                    return CourseQueryResult(courses: courses, message: "已更新当天课程")
                }
            }
        }
        let weekly = try await execute(path: "course/get_stu_course_sched_week.action", session: session, fields: fields)
        return try ResponseParser.week(weekly, day: day)
    }

    public func weeklySchedule(session: SchoolSession, date: Date) async throws -> WeeklySchedule {
        let json = try await execute(path: "course/get_stu_course_sched_week.action", session: session,
                                     fields: [("id", session.userId), ("dateStr", CourseTime.dayKey(date))])
        return try ResponseParser.weeklySchedule(json)
    }

    /// Unlike the legacy fallback, this never infers an empty day from an omitted weekly entry.
    public func dailySchedule(session: SchoolSession, date: Date) async throws -> [Course] {
        let day = CourseTime.dayKey(date)
        let json = try await execute(path: "course/get_stu_course_sched.action", session: session,
                                     fields: [("id", session.userId), ("dateStr", day)])
        try ResponseParser.rejectSessionError(json)
        if ResponseParser.scalar(json["STATUS"]) == "0",
           let entries = json["result"] as? [[String: Any]],
           ["", "0"].contains(ResponseParser.scalar(json["ERRCODE"])),
           ResponseParser.scalar(json["ERRMSG"]).isEmpty {
            return try ResponseParser.scheduledCourses(entries, day: day)
        }
        let week = try await weeklySchedule(session: session, date: date)
        guard week.coveredDays.contains(day) else {
            throw APIError(code: "SCHEDULE_INCOMPLETE", message: "学校未返回 \(day) 的课程，请重试")
        }
        return week.courses.filter { CourseTime.normalizeDay($0.day) == day }
    }

    public func semesters(session: SchoolSession) async throws -> [SchoolSemester] {
        let json = try await execute(path: "course/get_base_school_year.action", session: session,
                                     fields: [("userId", session.userId), ("type", "2")])
        return try ResponseParser.semesters(json)
    }

    public func catalogCourses(session: SchoolSession, semesterId: String) async throws -> [CatalogCourse] {
        let json = try await execute(path: "choosecourse/get_myall_course.action", session: session,
                                     fields: [("id", session.userId), ("xq_code", semesterId)],
                                     query: [URLQueryItem(name: "user_type", value: "1")])
        return try ResponseParser.catalogCourses(json, semesterId: semesterId)
    }

    public func courseAttendance(session: SchoolSession, courseId: String) async throws -> CourseAttendanceSummary {
        let json = try await execute(path: "my/get_my_course_sign_detail.action", session: session,
                                     fields: [("id", session.userId), ("courseId", courseId)])
        return try ResponseParser.courseAttendance(json, courseId: courseId)
    }

    /// A sign-in is never retried automatically: an ambiguous network response may already have committed.
    public func sign(course: Course, session: SchoolSession,
                     authorizeSubmission: @MainActor @Sendable () throws -> Void = {}) async throws -> SignResult {
        guard course.id.range(of: "^[0-9]{7}$", options: .regularExpression) != nil else {
            throw APIError(code: "COURSE_ID_INVALID", message: "课程缺少有效的 7 位签到 ID，请刷新课表")
        }
        let reading = try await synchronizedReading()
        try await authorizeSubmission()
        let json = try await execute(path: "course/stu_scan_sign.action", session: session, query: [
            URLQueryItem(name: "courseSchedId", value: course.id),
            URLQueryItem(name: "timestamp", value: String(reading.timestamp)),
            URLQueryItem(name: "id", value: session.userId)
        ], timeout: 10)
        try ResponseParser.rejectSessionError(json)
        return ResponseParser.sign(json)
    }

    public func qr(course: Course) async throws -> QRSnapshot {
        try await qr(identifier: course.qrIdentifier)
    }

    public func schoolNow() async throws -> Date {
        let reading = try await synchronizedReading()
        return Date(timeIntervalSince1970: Double(reading.timestamp) / 1000)
    }

    public func qr(identifier: String) async throws -> QRSnapshot {
        // Reject invalid IDs before attempting a network request.
        _ = try Self.qrURL(identifier: identifier, timestampMs: 0)
        let reading = try await synchronizedReading()
        let duration = min(Self.qrRefreshInterval, Self.timeSyncTTL - reading.age)
        guard duration > 0 else { throw APIError(code: "TIME_SYNC_EXPIRED", message: "学校校时已过期，请重试") }
        return QRSnapshot(url: try Self.qrURL(identifier: identifier, timestampMs: reading.timestamp), schoolTimestampMs: reading.timestamp, expiresAt: reading.localNow.addingTimeInterval(duration), validityDuration: duration)
    }

    public func clearClock() {
        clockGeneration += 1
        pendingSync?.cancel()
        pendingSync = nil
        sample = nil
    }

    public static func qrURL(identifier: String, timestampMs: Int64) throws -> URL {
        let identifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let compact = identifier.replacingOccurrences(of: "-", with: "")
        let key: String
        let value: String
        if identifier.range(of: "^[0-9]{7}$", options: .regularExpression) != nil {
            key = "courseSchedId"
            value = identifier
        } else if compact.range(of: "^[0-9a-fA-F]{32}$", options: .regularExpression) != nil {
            key = "timeTableId"
            value = compact.uppercased()
        } else {
            throw APIError(code: "COURSE_ID_INVALID", message: "请输入 7 位课程 ID 或 32 位 UUID")
        }
        var components = URLComponents(url: baseURL.appendingPathComponent("course/stu_scan_sign.action"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: key, value: value), URLQueryItem(name: "timestamp", value: String(timestampMs))]
        return components.url!
    }

    private struct ClockSample: Sendable {
        let schoolAtReceive: Int64
        let receivedAt: Date
    }

    private func synchronizedReading() async throws -> (timestamp: Int64, age: TimeInterval, localNow: Date) {
        let initialNow = now()
        if let sample {
            let age = initialNow.timeIntervalSince(sample.receivedAt)
            if age >= 0 && age < Self.timeSyncTTL {
                return (sample.schoolAtReceive + Int64(age * 1000), age, initialNow)
            }
        }
        let generation = clockGeneration
        let task: Task<ClockSample, Error>
        if let pendingSync { task = pendingSync } else {
            task = Task {
                let startedAt = self.now()
                let json = try await self.execute(path: "common/get_timestamp.do", fields: [], query: [URLQueryItem(name: "id", value: "0")], timeout: 6)
                let timestamp = try ResponseParser.timestamp(json)
                let receivedAt = self.now()
                let roundTrip = receivedAt.timeIntervalSince(startedAt)
                guard roundTrip >= 0 && roundTrip < Self.timeSyncTTL else {
                    throw APIError(code: "TIME_SYNC_EXPIRED", message: "学校校时已过期，请重试")
                }
                return ClockSample(schoolAtReceive: timestamp + Int64(roundTrip * 500), receivedAt: receivedAt)
            }
            pendingSync = task
        }
        do {
            let received = try await task.value
            try Task.checkCancellation()
            guard generation == clockGeneration else { throw CancellationError() }
            sample = received
            pendingSync = nil
            let localNow = now()
            let age = localNow.timeIntervalSince(received.receivedAt)
            guard age >= 0 && age < Self.timeSyncTTL else {
                throw APIError(code: "TIME_SYNC_EXPIRED", message: "学校校时已过期，请重试")
            }
            return (received.schoolAtReceive + Int64(age * 1000), age, localNow)
        } catch {
            if generation == clockGeneration { pendingSync = nil }
            throw error
        }
    }

    private func execute(path: String, session: SchoolSession? = nil, fields: [(String, String)]? = nil, query: [URLQueryItem] = [], login: Bool = false, timeout: TimeInterval = 15) async throws -> [String: Any] {
        var components = URLComponents(url: Self.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue(login ? Self.loginUserAgent : Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let session {
            guard !session.sessionId.isEmpty && !session.userId.isEmpty else {
                throw APIError(code: "LOGIN_EXPIRED", message: "登录已失效，请重新登录")
            }
            request.setValue(session.sessionId, forHTTPHeaderField: "sessionId")
        }
        if let fields {
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
            request.httpBody = fields.map { key, value in
                "\(key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\(value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
            }.joined(separator: "&").data(using: .utf8)
        } else { request.httpMethod = "GET" }
        let data: Data
        let response: HTTPURLResponse
        do { (data, response) = try await transport.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch let error as APIError { throw error }
        catch { throw APIError(code: "NETWORK_UNAVAILABLE", message: "暂时无法连接学校服务，请检查网络后重试") }
        guard (200...299).contains(response.statusCode) else {
            let message = [401, 403].contains(response.statusCode) ? "登录已失效，请重新登录" : "学校服务请求失败（\(response.statusCode)）"
            throw APIError(code: "HTTP_\(response.statusCode)", message: message)
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw APIError(code: "BAD_RESPONSE", message: "学校返回的数据无法读取，请稍后重试")
        }
        return json
    }
}

enum ResponseParser {
    static func scalar(_ value: Any?) -> String {
        if let value = value as? String { return value.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() { return value.stringValue }
        return ""
    }

    static func session(_ json: [String: Any]) throws -> SchoolSession {
        guard scalar(json["STATUS"]) == "0" else { throw APIError(code: "LOGIN_REJECTED", message: "账户验证失败，请检查学号或 SEP 邮箱及密码") }
        guard let result = json["result"] as? [String: Any] else { throw APIError(code: "LOGIN_BAD_RESPONSE", message: "学校登录返回不完整") }
        let id = scalar(result["id"]), sessionId = scalar(result["sessionId"]), studentNo = scalar(result["studentNo"])
        guard !id.isEmpty, !sessionId.isEmpty, !studentNo.isEmpty else { throw APIError(code: "LOGIN_BAD_RESPONSE", message: "学校登录未返回完整身份，请重试") }
        // iCLASS uses realName for the student's name; userName is the login account.
        let name = (result["realName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return SchoolSession(userId: id, sessionId: sessionId, studentNo: studentNo, name: name?.isEmpty == false ? name : nil)
    }

    static func semesters(_ json: [String: Any]) throws -> [SchoolSemester] {
        try rejectSessionError(json)
        guard scalar(json["STATUS"]) == "0", let entries = json["result"] as? [[String: Any]] else {
            throw APIError(code: "SEMESTER_REJECTED", message: "学校暂未返回可用学期，请稍后重试")
        }
        let values = try entries.map { entry -> SchoolSemester in
            let code = scalar(entry["code"]), name = scalar(entry["name"])
            guard !code.isEmpty, !name.isEmpty,
                  let begin = CourseTime.normalizeDay(scalar(entry["beginDate"])),
                  let end = CourseTime.normalizeDay(scalar(entry["endDate"])) else {
                throw APIError(code: "SEMESTER_BAD_RESPONSE", message: "学校学期数据不完整，请稍后重试")
            }
            return SchoolSemester(id: code, name: name, beginDate: begin, endDate: end,
                                  isCurrent: scalar(entry["yearStatus"]) == "1")
        }
        guard !values.isEmpty else {
            throw APIError(code: "SEMESTER_EMPTY", message: "学校暂未返回可用学期，请稍后重试")
        }
        return values
    }

    static func catalogCourses(_ json: [String: Any], semesterId: String) throws -> [CatalogCourse] {
        try rejectSessionError(json)
        guard scalar(json["STATUS"]) == "0", let entries = json["result"] as? [[String: Any]] else {
            throw APIError(code: "COURSE_CATALOG_REJECTED", message: "学校暂未返回课程目录，请稍后重试")
        }
        return try entries.map { entry -> CatalogCourse in
            let id = scalar(entry["course_id"]), name = scalar(entry["course_name"])
            guard !id.isEmpty, !name.isEmpty else {
                throw APIError(code: "COURSE_CATALOG_BAD_RESPONSE", message: "学校课程目录数据不完整，请稍后重试")
            }
            let returnedSemester = scalar(entry["semesterId"])
            guard returnedSemester.isEmpty || returnedSemester == semesterId else {
                throw APIError(code: "COURSE_CATALOG_SEMESTER_MISMATCH", message: "学校返回了其他学期的课程，请重新刷新")
            }
            return CatalogCourse(
                id: id, number: scalar(entry["courseNum"]), name: name,
                teacher: scalar(entry["teacher_name"]), classroom: scalar(entry["course_address"]),
                semesterId: semesterId,
                beginDate: CourseTime.normalizeDay(scalar(entry["course_beignDate"])) ?? "",
                endDate: CourseTime.normalizeDay(scalar(entry["course_endDate"])) ?? "",
                totalSessions: Int(scalar(entry["jc_num"])),
                completedSessions: Int(scalar(entry["jc_num_studyed"]))
            )
        }
    }

    static func courseAttendance(_ json: [String: Any], courseId: String) throws -> CourseAttendanceSummary {
        try rejectSessionError(json)
        guard scalar(json["STATUS"]) == "0", let entries = json["result"] as? [[String: Any]] else {
            throw APIError(code: "ATTENDANCE_REJECTED", message: "学校暂未返回课程考勤，请稍后重试")
        }
        let records = try entries.map { entry -> CourseAttendance in
            let id = scalar(entry["id"]), returnedCourseId = scalar(entry["courseId"])
            let scheduledId = scalar(entry["courseSchedId"])
            guard !id.isEmpty, returnedCourseId == courseId, !scheduledId.isEmpty,
                  let day = CourseTime.normalizeDay(scalar(entry["teachTime"])) else {
                throw APIError(code: "ATTENDANCE_BAD_RESPONSE", message: "学校课程考勤数据不完整，请稍后重试")
            }
            return CourseAttendance(id: id, courseId: returnedCourseId, scheduledCourseId: scheduledId,
                                    day: day, beginTime: scalar(entry["classBeginTime"]),
                                    endTime: scalar(entry["classEndTime"]),
                                    signed: scalar(entry["signStatus"]) == "1", signStatusKnown: ["0", "1"].contains(scalar(entry["signStatus"])))
        }
        return CourseAttendanceSummary(signedCount: Int(scalar(json["mySignNum"])) ?? records.filter(\.signed).count,
                                       unsignedCount: Int(scalar(json["myNoSignNum"])) ?? records.filter { !$0.signed && $0.signStatusKnown == true }.count,
                                       records: records)
    }

    static func timestamp(_ json: [String: Any]) throws -> Int64 {
        guard scalar(json["STATUS"]) == "0", let number = json["timestamp"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { throw badTimestamp }
        let value = number.doubleValue
        guard value.isFinite, value.rounded() == value, value >= 1_000_000_000_000, value <= 8_640_000_000_000_000 else { throw badTimestamp }
        return number.int64Value
    }

    private static var badTimestamp: APIError { APIError(code: "TIME_SYNC_BAD_RESPONSE", message: "学校校时数据异常，请重试") }

    static func rejectSessionError(_ json: [String: Any]) throws {
        let code = scalar(json["ERRCODE"])
        let nested = json["result"] as? [String: Any] ?? [:]
        let message = scalar(json["ERRMSG"]) + scalar(json["message"]) + scalar(json["msg"]) + scalar(nested["msg"])
        if ["401", "403", "LOGIN_EXPIRED", "SESSION_EXPIRED"].contains(code) || matches("未登录|尚未登录|重新登录|登录.*(失效|过期)|session.*(expired|invalid)", message) {
            throw APIError(code: "LOGIN_EXPIRED", message: "登录已失效，请重新登录")
        }
    }

    static func scheduledCourses(_ entries: [[String: Any]], day: String) throws -> [Course] {
        var result: [Course] = []
        var seen = Set<String>()
        for entry in entries {
            let id = scalar(entry["id"]), uuid = scalar(entry["uuid"])
            guard !id.isEmpty else { throw APIError(code: "SCHEDULE_BAD_RESPONSE", message: "课表缺少课程 ID，请稍后重新查询") }
            if !seen.insert(id).inserted { continue }
            let name = scalar(entry["courseName"])
            let classroom = entry["classroomName"] as? String
            result.append(Course(id: id, courseId: scalar(entry["courseId"]),
                                 courseNumber: scalar(entry["courseNum"]), teacherId: scalar(entry["teacherId"]), uuid: uuid,
                                 name: name.isEmpty ? "未命名课程" : name,
                                 teacher: scalar(entry["teacherName"]), classroom: classroom,
                                 beginTime: scalar(entry["classBeginTime"]), endTime: scalar(entry["classEndTime"]),
                                 day: day, signed: scalar(entry["signStatus"]) == "1", signStatusKnown: ["0", "1"].contains(scalar(entry["signStatus"]))))
        }
        return result.sorted { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }
    }

    static func week(_ json: [String: Any], day: String) throws -> CourseQueryResult {
        let all = try weeklySchedule(json).courses
        let today = all.filter { $0.day == day }
        if !today.isEmpty { return CourseQueryResult(courses: today, message: "已从周课表更新当天课程") }
        if !all.isEmpty { return CourseQueryResult(courses: all, fromWeeklyFallback: true, message: "当天没有课程，已显示本周课程") }
        return CourseQueryResult(courses: [], message: "当天及本周暂无课程")
    }

    static func weeklySchedule(_ json: [String: Any]) throws -> WeeklySchedule {
        try rejectSessionError(json)
        let status = scalar(json["STATUS"]), error = scalar(json["ERRCODE"])
        // Upstream's weekly STATUS branch differs from its daily endpoint and has no server fixture.
        // Compatibility is limited to 0/1, with a complete schedule shape and no explicit error.
        guard ["0", "1"].contains(status), (error.isEmpty || error == "0"), scalar(json["ERRMSG"]).isEmpty,
              let days = json["result"] as? [[String: Any]] else {
            throw APIError(code: "SCHEDULE_REJECTED", message: "学校暂未返回可用课表，请重新查询")
        }
        if let success = json["success"] {
            guard let value = success as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID(), value.boolValue else {
                throw APIError(code: "SCHEDULE_REJECTED", message: "学校暂未返回可用课表，请重新查询")
            }
        }
        var all: [Course] = []
        var coveredDays = Set<String>()
        for entry in days {
            guard let date = CourseTime.normalizeDay(scalar(entry["dateStr"])), let entries = entry["schedData"] as? [[String: Any]] else {
                throw APIError(code: "SCHEDULE_BAD_RESPONSE", message: "学校周课表数据不完整，请重新查询")
            }
            all += try scheduledCourses(entries, day: date)
            guard coveredDays.insert(date).inserted else {
                throw APIError(code: "SCHEDULE_BAD_RESPONSE", message: "学校周课表包含重复日期，请重新查询")
            }
        }
        return WeeklySchedule(courses: all.sorted { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }, coveredDays: coveredDays)
    }

    static func sign(_ json: [String: Any]) -> SignResult {
        let result = json["result"] as? [String: Any] ?? [:]
        let status = scalar(json["STATUS"]), errCode = String(scalar(json["ERRCODE"]).prefix(64))
        let message = [result["msg"], json["ERRMSG"], json["msg"], json["message"]].map(scalar).first { !$0.isEmpty } ?? ""
        let expired = matches("(二维码|签到码).*(失效|过期)|timestamp.*(invalid|expired)", message)
        let outside = matches("未在上课时间|不在.*签到时间|不是上课时间|未选.*课|不属于.*课|已签到|重复签到", message)
        let explicitlySuccessful: Bool
        if let flag = json["success"] {
            if let number = flag as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { explicitlySuccessful = number.boolValue }
            else { explicitlySuccessful = false }
        } else { explicitlySuccessful = true }
        let outcome: SignOutcome
        let display: String
        if expired {
            outcome = .qrExpired
            display = "学校提示签到码已失效，请刷新后重试"
        } else if status == "0", (errCode.isEmpty || errCode == "0"), scalar(result["stuSignStatus"]) == "1", explicitlySuccessful, !outside {
            outcome = .signed
            display = "签到成功"
        } else if outside {
            outcome = .outsideSignWindow
            if message.contains("已签到") || message.contains("重复签到") { display = "学校提示已签到，请刷新课程状态" }
            else if message.contains("未选") || message.contains("不属于") { display = "学校提示当前身份未选此课程" }
            else { display = "学校未完成签到，请确认上课时间和课程状态" }
        } else {
            outcome = .unknown
            display = "学校未明确确认签到完成，请刷新课程状态后再决定是否重试"
        }
        return SignResult(outcome: outcome, message: display, status: status, errCode: errCode, stuSignId: scalar(result["stuSignId"]))
    }

    private static func matches(_ pattern: String, _ value: String) -> Bool {
        value.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
