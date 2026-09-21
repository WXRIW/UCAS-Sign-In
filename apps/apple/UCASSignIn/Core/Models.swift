import Foundation

public struct SchoolSession: Codable, Hashable, Sendable {
    public let userId: String
    public let sessionId: String
    public let studentNo: String
    public let name: String?

    public init(userId: String, sessionId: String, studentNo: String, name: String? = nil) {
        self.userId = userId
        self.sessionId = sessionId
        self.studentNo = studentNo
        self.name = name
    }
}

public struct Course: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    /// School teaching-record ID; co-teachers may have different IDs for one catalog course.
    public let courseId: String?
    public let courseNumber: String?
    public let teacherId: String?
    public let uuid: String
    public let name: String
    public let teacher: String
    public let classroom: String?
    public let beginTime: String
    public let endTime: String
    public let day: String
    public var signed: Bool

    public init(id: String, courseId: String? = nil, courseNumber: String? = nil, teacherId: String? = nil, uuid: String = "", name: String, teacher: String = "", classroom: String? = nil, beginTime: String, endTime: String, day: String, signed: Bool = false) {
        self.id = id
        self.courseId = courseId?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.courseNumber = courseNumber?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.teacherId = teacherId?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.uuid = uuid
        self.name = name
        self.teacher = teacher
        let classroom = classroom?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.classroom = classroom?.isEmpty == false ? classroom : nil
        self.beginTime = beginTime
        self.endTime = endTime
        self.day = day
        self.signed = signed
    }

    public var startDate: Date? { CourseTime.parse(day: day, time: beginTime) }
    public var endDate: Date? { CourseTime.parse(day: day, time: endTime) }
    public var timeRange: String { "\(CourseTime.display(beginTime))–\(CourseTime.display(endTime))" }
    public var qrIdentifier: String { id.range(of: "^[0-9]{7}$", options: .regularExpression) != nil ? id : uuid }

    public func preservingIdentity(from previous: Course?) -> Course {
        guard let previous, previous.id == id,
              CourseTime.normalizeDay(previous.day) == CourseTime.normalizeDay(day) else { return self }
        return Course(id: id, courseId: courseId ?? previous.courseId, courseNumber: courseNumber ?? previous.courseNumber,
                      teacherId: teacherId ?? previous.teacherId, uuid: uuid, name: name, teacher: teacher,
                      classroom: classroom, beginTime: beginTime, endTime: endTime, day: day, signed: signed)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

public struct SchoolSemester: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let beginDate: String
    public let endDate: String
    public let isCurrent: Bool

    public init(id: String, name: String, beginDate: String, endDate: String, isCurrent: Bool) {
        self.id = id
        self.name = name
        self.beginDate = beginDate
        self.endDate = endDate
        self.isCurrent = isCurrent
    }
}

public struct CatalogCourse: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let number: String
    public let name: String
    public let teacher: String
    public let classroom: String?
    public let semesterId: String
    public let beginDate: String
    public let endDate: String
    public let totalSessions: Int?
    public let completedSessions: Int?

    public init(id: String, number: String, name: String, teacher: String, classroom: String?, semesterId: String,
                beginDate: String, endDate: String, totalSessions: Int? = nil, completedSessions: Int? = nil) {
        self.id = id
        self.number = number
        self.name = name
        self.teacher = teacher
        self.classroom = classroom?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.semesterId = semesterId
        self.beginDate = beginDate
        self.endDate = endDate
        self.totalSessions = totalSessions
        self.completedSessions = completedSessions
    }
}

public struct CourseAttendance: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let courseId: String
    public let scheduledCourseId: String
    public let day: String
    public let beginTime: String
    public let endTime: String
    public let signed: Bool

    public init(id: String, courseId: String, scheduledCourseId: String, day: String,
                beginTime: String, endTime: String, signed: Bool) {
        self.id = id
        self.courseId = courseId
        self.scheduledCourseId = scheduledCourseId
        self.day = day
        self.beginTime = beginTime
        self.endTime = endTime
        self.signed = signed
    }
}

public struct CourseAttendanceSummary: Codable, Equatable, Sendable {
    public let signedCount: Int
    public let unsignedCount: Int
    public let records: [CourseAttendance]

    public init(signedCount: Int, unsignedCount: Int, records: [CourseAttendance]) {
        self.signedCount = signedCount
        self.unsignedCount = unsignedCount
        self.records = records
    }
}

public struct CourseQueryResult: Codable, Sendable {
    public let courses: [Course]
    public let fromWeeklyFallback: Bool
    public let message: String
    public let fromCache: Bool

    public init(courses: [Course], fromWeeklyFallback: Bool = false, message: String, fromCache: Bool = false) {
        self.courses = courses
        self.fromWeeklyFallback = fromWeeklyFallback
        self.message = message
        self.fromCache = fromCache
    }
}

public enum SignOutcome: String, Codable, Sendable {
    case signed, qrExpired, outsideSignWindow, unknown
}

public struct SignResult: Sendable {
    public let outcome: SignOutcome
    public let message: String
    public let status: String
    public let errCode: String
    public let stuSignId: String
}

public struct QRSnapshot: Sendable {
    public let url: URL
    public let schoolTimestampMs: Int64
    public let expiresAt: Date
    public let validityDuration: TimeInterval

    public init(url: URL, schoolTimestampMs: Int64, expiresAt: Date, validityDuration: TimeInterval) {
        self.url = url
        self.schoolTimestampMs = schoolTimestampMs
        self.expiresAt = expiresAt
        self.validityDuration = validityDuration
    }

    public func remainingSeconds(at date: Date = Date()) -> TimeInterval {
        max(0, min(validityDuration, expiresAt.timeIntervalSince(date)))
    }
}

public struct APIError: LocalizedError, Sendable, Equatable {
    public let code: String
    public let message: String
    public var errorDescription: String? { message }
    public var isSessionExpired: Bool { ["HTTP_401", "HTTP_403", "LOGIN_EXPIRED"].contains(code) }

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}
