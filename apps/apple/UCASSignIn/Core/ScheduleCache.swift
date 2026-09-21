import Foundation

public enum ScheduleMode: String, Sendable {
    case day, week
}

/// An omitted date is unknown, rather than an empty day.
public struct WeeklySchedule: Sendable {
    public let courses: [Course]
    public let coveredDays: Set<String>
}

public struct SemesterScheduleCache: Codable, Sendable {
    public let semester: SchoolSemester
    public let courses: [Course]
    public let updatedAt: Date
    public let courseIdentityVersion: Int?

    public init(semester: SchoolSemester, courses: [Course], updatedAt: Date) {
        self.semester = semester
        self.courses = courses
        self.updatedAt = updatedAt
        self.courseIdentityVersion = 1
    }

    public func needsRefresh(at date: Date) -> Bool {
        courseIdentityVersion != 1 || date.timeIntervalSince(updatedAt) >= 7 * 24 * 60 * 60 || updatedAt > date
    }
}

public enum CourseIdentity {
    public static func colorKey(for course: Course) -> String {
        course.courseNumber ?? course.name.split(whereSeparator: \.isWhitespace).joined()
    }
    /// Color follows the course number, never a meeting/teacher ID or response order.
    /// A normalized title is a visual-only fallback, not an identity association.
    public static func colorIndex(for course: Course, paletteSize: Int) -> Int {
        guard paletteSize > 0 else { return 0 }
        let key = colorKey(for: course)
        let hash = key.utf8.reduce(0) { ($0 * 31 + Int($1)) % 65521 }
        return hash % paletteSize
    }
    /// The schedule API's semesterId can be stale. Only authoritative semester date ranges scope a match.
    public static func semester(for course: Course, semesters: [SchoolSemester]) -> SchoolSemester? {
        guard let day = CourseTime.normalizeDay(course.day) else { return nil }
        let matches = semesters.filter { $0.beginDate <= day && day <= $0.endDate }
        guard Set(matches.map(\.id)).count == 1 else { return nil }
        return matches.first
    }

    public static func catalogCourse(for course: Course, catalog: [CatalogCourse], semesters: [SchoolSemester]) -> CatalogCourse? {
        guard let semester = semester(for: course, semesters: semesters) else { return nil }
        let directory = catalog.filter { $0.semesterId == semester.id }
        let matches: [CatalogCourse]
        if let number = course.courseNumber {
            matches = directory.filter { $0.number.trimmingCharacters(in: .whitespacesAndNewlines) == number }
        } else if let id = course.courseId {
            matches = directory.filter { $0.id == id }
        } else { return nil }
        return matches.count == 1 ? matches[0] : nil
    }
}

/// Linear probing uses every color once before starting the next round.
/// Register the whole semester, not just the visible week, to keep colors stable.
public struct ScheduleColors: Sendable {
    public static let count = 7
    private var assignments: [String: Int] = [:]

    public init() {}

    public mutating func register(_ courses: [Course]) {
        let keys = Set(courses.map(CourseIdentity.colorKey)).sorted()
        var usage = Array(repeating: 0, count: Self.count)
        for index in assignments.values { usage[index] += 1 }
        for key in keys where assignments[key] == nil {
            let start = key.utf8.reduce(0) { ($0 * 31 + Int($1)) % 65521 } % Self.count
            let round = usage.min()!
            let index = (0..<Self.count).map { (start + $0) % Self.count }.first { usage[$0] == round }!
            assignments[key] = index
            usage[index] += 1
        }
    }

    public func index(for course: Course) -> Int {
        assignments[CourseIdentity.colorKey(for: course)] ?? CourseIdentity.colorIndex(for: course, paletteSize: Self.count)
    }
}

public enum ScheduleCalendar {
    public static func week(containing date: Date) -> [Date] {
        var calendar = CourseTime.calendar
        calendar.firstWeekday = 2
        let start = calendar.dateInterval(of: .weekOfYear, for: date)!.start
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    public static func dateRange(in semester: SchoolSemester) -> ClosedRange<Date>? {
        guard let start = CourseTime.parse(day: semester.beginDate, time: "00:00"),
              let end = CourseTime.parse(day: semester.endDate, time: "00:00"), start <= end else { return nil }
        let count = CourseTime.calendar.dateComponents([.day], from: start, to: end).day ?? -1
        guard count >= 0, count <= 366 else { return nil }
        return start...end
    }

    public static func days(in semester: SchoolSemester) -> [Date] {
        guard let range = dateRange(in: semester) else { return [] }
        let count = CourseTime.calendar.dateComponents([.day], from: range.lowerBound, to: range.upperBound).day ?? 0
        return (0...count).compactMap { CourseTime.calendar.date(byAdding: .day, value: $0, to: range.lowerBound) }
    }

    /// The week containing the semester's first day is week 1, with Monday starting each week.
    public static func weekNumber(on date: Date, in semester: SchoolSemester) -> Int? {
        guard let range = dateRange(in: semester), range.contains(CourseTime.calendar.startOfDay(for: date)) else { return nil }
        let days = CourseTime.calendar.dateComponents([.day], from: week(containing: range.lowerBound)[0],
                                                      to: week(containing: date)[0]).day ?? 0
        return days / 7 + 1
    }

    public static func weeks(in semester: SchoolSemester) -> [ClosedRange<Date>] {
        guard let range = dateRange(in: semester), let count = weekNumber(on: range.upperBound, in: semester) else { return [] }
        let firstMonday = week(containing: range.lowerBound)[0]
        return (0..<count).compactMap { index in
            guard let start = CourseTime.calendar.date(byAdding: .day, value: index * 7, to: firstMonday),
                  let end = CourseTime.calendar.date(byAdding: .day, value: 6, to: start) else { return nil }
            return max(start, range.lowerBound)...min(end, range.upperBound)
        }
    }

    public static func date(inWeek number: Int, of semester: SchoolSemester, keepingWeekdayOf date: Date) -> Date? {
        let ranges = weeks(in: semester)
        guard number > 0, number <= ranges.count else { return nil }
        let range = ranges[number - 1]
        let offset = (CourseTime.calendar.component(.weekday, from: date) + 5) % 7
        guard let target = CourseTime.calendar.date(byAdding: .day, value: offset, to: week(containing: range.lowerBound)[0]) else { return nil }
        return min(max(target, range.lowerBound), range.upperBound)
    }

    /// Compare arrangements, excluding attendance state and transport ordering.
    public static func sameArrangements(_ lhs: [Course], _ rhs: [Course]) -> Bool {
        func signature(_ course: Course) -> [String] {
            func clean(_ text: String) -> String {
                text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            }
            func time(_ raw: String) -> String {
                CourseTime.parse(day: course.day, time: raw).map { String($0.timeIntervalSince1970) } ?? clean(raw)
            }
            return [course.id, course.courseId ?? "", course.courseNumber ?? "", course.teacherId ?? "", course.uuid, CourseTime.normalizeDay(course.day) ?? course.day,
                    clean(course.name), clean(course.teacher), clean(course.classroom ?? ""),
                    time(course.beginTime), time(course.endTime)]
        }
        return lhs.map(signature).sorted { $0.lexicographicallyPrecedes($1) }
            == rhs.map(signature).sorted { $0.lexicographicallyPrecedes($1) }
    }
}

public struct ScheduleBlock {
    public let courses: [Course]
    public let start: Date
    public let end: Date
}

/// A display-only placement. Navigation and attendance must use the original course.
public struct WeekScheduleEntry: Identifiable {
    public let course: Course
    public let displayDay: String
    public let catalogCourseId: String?
    public init(course: Course, displayDay: String, catalogCourseId: String? = nil) {
        self.course = course
        self.displayDay = displayDay
        self.catalogCourseId = catalogCourseId
    }
    public var isOutsideWeek: Bool { CourseTime.normalizeDay(course.day) != displayDay }
    public var id: String { "\(displayDay)|\(course.day)|\(course.id)" }

    public var positionedCourse: Course {
        func clock(_ raw: String) -> String {
            guard let date = CourseTime.parse(day: course.day, time: raw),
                  CourseTime.dayKey(date) == CourseTime.normalizeDay(course.day) else { return raw }
            let parts = CourseTime.calendar.dateComponents([.hour, .minute, .second], from: date)
            return String(format: "%02d:%02d:%02d", parts.hour!, parts.minute!, parts.second!)
        }
        return Course(id: id, courseId: course.courseId, courseNumber: course.courseNumber, teacherId: course.teacherId,
                      name: course.name, teacher: course.teacher,
                      classroom: course.classroom, beginTime: clock(course.beginTime), endTime: clock(course.endTime), day: displayDay)
    }
}

public struct WeekScheduleGroup: Identifiable {
    public let entries: [WeekScheduleEntry]
    public var id: String { entries.map(\.id).joined(separator: ",") }
    public var isOutsideWeek: Bool { entries.allSatisfy(\.isOutsideWeek) }
    public var course: Course { entries[0].course }
    public var teachers: [String] {
        Array(Set(entries.map { $0.course.teacher.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
    }
}

public struct WeekScheduleBlock: Identifiable {
    public let entries: [WeekScheduleEntry]
    public let start: Date
    public let end: Date
    public var id: String { entries.map(\.id).joined(separator: ",") }
    public var isOutsideWeek: Bool { entries.allSatisfy(\.isOutsideWeek) }
    public let groups: [WeekScheduleGroup]

    public init(entries: [WeekScheduleEntry], start: Date, end: Date) {
        self.entries = entries
        self.start = start
        self.end = end
        self.groups = Self.group(entries)
    }

    private static func group(_ entries: [WeekScheduleEntry]) -> [WeekScheduleGroup] {
        var keys: [[String]] = []
        var grouped: [[WeekScheduleEntry]] = []
        for entry in entries {
            let positioned = entry.positionedCourse
            let key: [String]
            if let catalogID = entry.catalogCourseId, let room = entry.course.classroom,
               let start = positioned.startDate, let end = positioned.endDate {
                key = [catalogID, entry.displayDay, String(start.timeIntervalSince1970), String(end.timeIntervalSince1970),
                       room.split(whereSeparator: \.isWhitespace).joined(separator: " "), String(entry.isOutsideWeek)]
            } else { key = [entry.id] }
            if let index = keys.firstIndex(of: key) { grouped[index].append(entry) }
            else { keys.append(key); grouped.append([entry]) }
        }
        return grouped.map { WeekScheduleGroup(entries: $0) }
    }
}

/// Immutable drawing data, reused across progress, selection and attendance UI updates.
public final class WeekSchedulePresentation {
    public let colors: ScheduleColors
    public let entries: [WeekScheduleEntry]
    public let hours: ClosedRange<Int>
    public let blocksByDay: [String: [WeekScheduleBlock]]
    public let untimedByDay: [String: [WeekScheduleEntry]]

    public init(entries: [WeekScheduleEntry], colors: ScheduleColors? = nil) {
        var palette = colors ?? ScheduleColors()
        palette.register(entries.map(\.course))
        self.colors = palette
        self.entries = entries
        let positioned = entries.map(\.positionedCourse)
        hours = ScheduleLayout.hours(positioned)
        let days = Dictionary(grouping: entries, by: \.displayDay)
        blocksByDay = days.mapValues(ScheduleLayout.weekBlocks)
        untimedByDay = days.mapValues { $0.filter { !ScheduleLayout.isTimed($0.positionedCourse) } }
    }
}

public enum ScheduleLayout {
    public static func weekEntries(_ courses: [Course], containing date: Date,
                                   semesters: [SchoolSemester], includeOutsideWeek: Bool,
                                   catalog: [CatalogCourse] = []) -> [WeekScheduleEntry] {
        let days = ScheduleCalendar.week(containing: date)
        let weekKeys = Set(days.map(CourseTime.dayKey))
        func entry(_ course: Course, _ day: String) -> WeekScheduleEntry {
            WeekScheduleEntry(course: course, displayDay: day,
                              catalogCourseId: CourseIdentity.catalogCourse(for: course, catalog: catalog, semesters: semesters)?.id)
        }
        if !includeOutsideWeek {
            return courses.compactMap { course in
                guard let day = CourseTime.normalizeDay(course.day), weekKeys.contains(day) else { return nil }
                return entry(course, day)
            }
        }
        let datedCourses = courses.compactMap { course -> (course: Course, day: String, date: Date)? in
            guard let day = CourseTime.normalizeDay(course.day),
                  let date = CourseTime.parse(day: day, time: "00:00") else { return nil }
            return (course, day, date)
        }
        func clean(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        func slot(_ course: Course, includeTeacher: Bool) -> [String] {
            func time(_ value: String) -> String {
                guard let date = CourseTime.parse(day: course.day, time: value),
                      let day = CourseTime.parse(day: course.day, time: "00:00") else { return clean(value) }
                return String(date.timeIntervalSince(day))
            }
            let canonical = CourseIdentity.catalogCourse(for: course, catalog: catalog, semesters: semesters)?.id
            let identity = (canonical ?? course.courseId).map { ["id", $0] } ?? ["name", clean(course.name)]
            let teacher = includeTeacher || canonical == nil ? [course.teacherId ?? clean(course.teacher)] : []
            return identity + teacher + [time(course.beginTime), time(course.endTime)]
        }
        return days.flatMap { day -> [WeekScheduleEntry] in
            let key = CourseTime.dayKey(day)
            let actual = datedCourses.filter { $0.day == key }.map(\.course)
            var result = actual.map { entry($0, key) }
            let terms = semesters.filter { $0.beginDate <= key && key <= $0.endDate }
            guard !terms.isEmpty else { return result }
            let currentSlots = Set(actual.map { slot($0, includeTeacher: false) })
            var seen = Set<[String]>()
            // Use the nearest real meeting as the representative of a recurring slot.
            let candidates = datedCourses.filter { source in
                !weekKeys.contains(source.day)
                    && CourseTime.calendar.component(.weekday, from: source.date) == CourseTime.calendar.component(.weekday, from: day)
                    && terms.contains { $0.beginDate <= source.day && source.day <= $0.endDate }
            }.sorted {
                let lhs = abs($0.date.timeIntervalSince(day)), rhs = abs($1.date.timeIntervalSince(day))
                if lhs != rhs { return lhs < rhs }
                if $0.day != $1.day { return $0.day < $1.day }
                return $0.course.id < $1.course.id
            }
            for source in candidates where !currentSlots.contains(slot(source.course, includeTeacher: false))
                && seen.insert(slot(source.course, includeTeacher: true)).inserted {
                result.append(entry(source.course, key))
            }
            return result
        }
    }

    public static func weekBlocks(_ entries: [WeekScheduleEntry]) -> [WeekScheduleBlock] {
        let originals = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return blocks(entries.map(\.positionedCourse)).map { block in
            WeekScheduleBlock(entries: block.courses.compactMap { originals[$0.id] }, start: block.start, end: block.end)
        }
    }

    public static func isTimed(_ course: Course) -> Bool {
        guard let start = course.startDate, let end = course.endDate,
              let day = CourseTime.parse(day: course.day, time: "00:00"),
              let next = CourseTime.calendar.date(byAdding: .day, value: 1, to: day) else { return false }
        return start >= day && end <= next && end > start
    }

    public static func blocks(_ courses: [Course]) -> [ScheduleBlock] {
        let sorted = courses.filter(isTimed).sorted {
            if $0.startDate == $1.startDate { return $0.id < $1.id }
            return $0.startDate! < $1.startDate!
        }
        var result: [ScheduleBlock] = []
        for course in sorted {
            if let last = result.last, course.startDate! < last.end {
                result[result.count - 1] = ScheduleBlock(courses: last.courses + [course], start: last.start,
                                                       end: max(last.end, course.endDate!))
            } else {
                result.append(ScheduleBlock(courses: [course], start: course.startDate!, end: course.endDate!))
            }
        }
        return result
    }

    public static func hours(_ courses: [Course]) -> ClosedRange<Int> {
        var first = 8, last = 22
        for course in courses where isTimed(course) {
            let day = CourseTime.parse(day: course.day, time: "00:00")!
            first = min(first, Int(floor(course.startDate!.timeIntervalSince(day) / 3600)))
            last = max(last, Int(ceil(course.endDate!.timeIntervalSince(day) / 3600)))
        }
        return max(0, first)...min(24, last)
    }
}
