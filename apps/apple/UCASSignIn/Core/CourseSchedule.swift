import Foundation

public struct CourseScheduleMeeting: Identifiable, Sendable {
    public let id: String
    public let courses: [Course]
    public let day: Date
    public let week: Int
    public let weekday: Int // Monday = 1
    public let start: Date?
    public let end: Date?
    public let classroom: String?
    public let teachers: [String]
    public var hasValidTime: Bool { start != nil && end != nil }
    public let timeText: String

    public func hasEnded(at now: Date) -> Bool {
        guard hasValidTime, let end else { return false }
        return end <= now
    }
}

public struct CourseScheduleProgress: Equatable, Sendable {
    public let total: Int
    public let ended: Int
    public let unknownTime: Int
    public var fraction: Double { total == 0 ? 0 : Double(ended) / Double(total) }
}

public struct CourseScheduleSummary: Identifiable, Sendable {
    public let id: String
    public let weeks: [Int]
    public let weekday: Int
    public let time: String
    public let classroom: String?
    public var weekText: String { CourseSchedulePresentation.weekText(weeks) }
}

/// Read-only projection of actual arrangements, never attendance records or weekly previews.
public struct CourseSchedulePresentation: Sendable {
    public let meetings: [CourseScheduleMeeting]
    public let summaries: [CourseScheduleSummary]
    public let associationIssue: String?

    /// Count merged arrangements, independently of attendance or the current teaching week.
    public func progress(at now: Date) -> CourseScheduleProgress {
        CourseScheduleProgress(total: meetings.count, ended: meetings.filter { $0.hasEnded(at: now) }.count,
                               unknownTime: meetings.filter { !$0.hasValidTime }.count)
    }

    public init(course: CatalogCourse, semester: SchoolSemester, catalog: [CatalogCourse],
                semesters: [SchoolSemester], courses: [Course]) {
        let directory = catalog.filter { $0.semesterId == semester.id }
        let number = course.number.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = directory.filter { number.isEmpty ? (!$0.id.isEmpty && $0.id == course.id) : $0.number.trimmingCharacters(in: .whitespacesAndNewlines) == number }
        guard matches.count == 1, let target = matches.first else {
            meetings = []; summaries = []
            associationIssue = "暂时无法可靠关联这门课的排课信息。"
            return
        }
        associationIssue = nil
        let values = courses.filter {
            CourseIdentity.catalogCourse(for: $0, catalog: directory, semesters: semesters)?.id == target.id
        }.sorted { ($0.day, $0.beginTime, $0.id) < ($1.day, $1.beginTime, $1.id) }
        var groups: [[String]: [Course]] = [:]
        for value in values {
            guard let day = CourseTime.normalizeDay(value.day),
                  let date = CourseTime.parse(day: day, time: "00:00"),
                  ScheduleCalendar.weekNumber(on: date, in: semester) != nil else { continue }
            let room = Self.clean(value.classroom ?? "")
            let interval = Self.interval(value)
            let key: [String]
            if let (start, end) = interval, !room.isEmpty {
                key = [day, String(start.timeIntervalSince1970), String(end.timeIntervalSince1970), room]
            } else { key = [day, value.id, value.uuid] }
            groups[key, default: []].append(value)
        }
        meetings = groups.values.map { values in
            let first = values[0]
            let day = CourseTime.parse(day: first.day, time: "00:00")!
            let interval = Self.interval(first)
            let room = Self.clean(first.classroom ?? "")
            return CourseScheduleMeeting(id: values.map { "\($0.day)|\($0.id)|\($0.uuid)" }.sorted().joined(separator: ","),
                courses: values, day: day, week: ScheduleCalendar.weekNumber(on: day, in: semester)!,
                weekday: (CourseTime.calendar.component(.weekday, from: day) + 5) % 7 + 1,
                start: interval?.0, end: interval?.1, classroom: room.isEmpty ? nil : room,
                teachers: Array(Set(values.map { Self.clean($0.teacher) }.filter { !$0.isEmpty })).sorted(),
                timeText: Self.timeText(first, interval: interval))
        }.sorted {
            if $0.day != $1.day { return $0.day < $1.day }
            if $0.start != $1.start { return ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture) }
            return $0.id < $1.id
        }
        var summaryGroups: [[String]: [CourseScheduleMeeting]] = [:]
        for value in meetings {
            let key = [String(value.weekday), value.timeText, value.classroom ?? "", value.hasValidTime ? "valid" : value.id]
            summaryGroups[key, default: []].append(value)
        }
        summaries = summaryGroups.map { key, values in
            let value = values[0]
            return CourseScheduleSummary(id: key.joined(separator: "|"), weeks: Array(Set(values.map(\.week))).sorted(),
                weekday: value.weekday, time: value.timeText + (value.hasValidTime ? "" : "（时间待确认）"), classroom: value.classroom)
        }.sorted { ($0.weekday, $0.time, $0.id) < ($1.weekday, $1.time, $1.id) }
    }

    public static func weekText(_ weeks: [Int]) -> String {
        let weeks = Array(Set(weeks)).sorted()
        var spans: [String] = []
        var index = 0
        while index < weeks.count {
            let first = weeks[index]
            var last = first
            index += 1
            while index < weeks.count && weeks[index] == last + 1 { last = weeks[index]; index += 1 }
            spans.append(first == last ? "\(first)" : "\(first)–\(last)")
        }
        return "第 \(spans.joined(separator: "、")) 周"
    }

    private static func timeText(_ course: Course, interval: (Date, Date)?) -> String {
        guard let interval else {
            return "\(course.beginTime.isEmpty ? "暂未提供" : course.beginTime)–\(course.endTime.isEmpty ? "暂未提供" : course.endTime)"
        }
        func clock(_ date: Date) -> String {
            let parts = CourseTime.calendar.dateComponents([.hour, .minute], from: date)
            return String(format: "%02d:%02d", parts.hour!, parts.minute!)
        }
        return "\(clock(interval.0))–\(clock(interval.1))"
    }

    private static func clean(_ value: String) -> String { value.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
    private static func interval(_ course: Course) -> (Date, Date)? {
        guard let start = course.startDate, let end = course.endDate, start < end,
              CourseTime.dayKey(start) == CourseTime.normalizeDay(course.day),
              CourseTime.dayKey(end) == CourseTime.normalizeDay(course.day) else { return nil }
        return (start, end)
    }
}
