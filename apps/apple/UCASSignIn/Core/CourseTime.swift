import Foundation

/// School schedules always use China Standard Time, independently of the device's zone.
public enum CourseTime {
    public static let timeZone = TimeZone(identifier: "Asia/Shanghai")!
    public static let signWindowLead: TimeInterval = 25 * 60

    public static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    public static func dayKey(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d", parts.year!, parts.month!, parts.day!)
    }

    public static func normalizeDay(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = "^(\\d{4})[-/]?(\\d{2})[-/]?(\\d{2})(?:[T ].*)?$"
        guard let parts = captures(pattern, value), let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              let date = validatedDate(year: year, month: month, day: day, hour: 0, minute: 0, second: 0, zone: timeZone) else { return nil }
        return dayKey(date)
    }

    public static func parse(day: String, time: String) -> Date? {
        let raw = time.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "：", with: ":").replacingOccurrences(of: "．", with: ".")
        guard !raw.isEmpty else { return nil }
        var dayPart = day
        var timePart = raw
        if let parts = captures("^(\\d{4}[-/]\\d{2}[-/]\\d{2})[T ]+(.+)$", raw) {
            dayPart = parts[0]
            timePart = parts[1]
        }
        guard let normalized = normalizeDay(dayPart) else { return nil }
        let digits = Array(normalized)
        let year = Int(String(digits[0..<4]))!
        let month = Int(String(digits[4..<6]))!
        let dateDay = Int(String(digits[6..<8]))!
        var zone = timeZone
        if let suffix = captures("^(.*?)(Z|[+-]\\d{2}:?\\d{2})$", timePart) {
            timePart = suffix[0]
            if suffix[1] == "Z" {
                zone = TimeZone(secondsFromGMT: 0)!
            } else {
                let offset = suffix[1].replacingOccurrences(of: ":", with: "")
                let chars = Array(offset)
                guard let hours = Int(String(chars[1...2])), let minutes = Int(String(chars[3...4])), hours <= 23, minutes < 60 else { return nil }
                zone = TimeZone(secondsFromGMT: (hours * 3600 + minutes * 60) * (chars[0] == "-" ? -1 : 1)) ?? timeZone
            }
        }
        let clock: [String]
        if let parts = captures("^(\\d{1,2}):(\\d{2})(?::(\\d{2}))?(?:\\.\\d+)?$", timePart) {
            clock = parts
        } else if timePart.range(of: "^\\d{3,4}$", options: .regularExpression) != nil {
            let padded = String(repeating: "0", count: 4 - timePart.count) + timePart
            clock = [String(padded.prefix(2)), String(padded.suffix(2)), "0"]
        } else if timePart.range(of: "^\\d{6}$", options: .regularExpression) != nil {
            clock = [String(timePart.prefix(2)), String(timePart.dropFirst(2).prefix(2)), String(timePart.suffix(2))]
        } else { return nil }
        guard let hour = Int(clock[0]), let minute = Int(clock[1]) else { return nil }
        let second = Int(clock[2]) ?? 0
        return validatedDate(year: year, month: month, day: dateDay, hour: hour, minute: minute, second: second, zone: zone)
    }

    public static func display(_ raw: String) -> String {
        guard let value = parse(day: "20000101", time: raw) else { return "—" }
        let parts = calendar.dateComponents([.hour, .minute], from: value)
        return String(format: "%02d:%02d", parts.hour!, parts.minute!)
    }

    public static func isWithinSignWindow(_ course: Course, now: Date = Date()) -> Bool {
        guard let begin = course.startDate, let end = course.endDate, end > begin else { return false }
        return now >= begin.addingTimeInterval(-signWindowLead) && now < end
    }

    public static func isInProgress(_ course: Course, now: Date = Date()) -> Bool {
        guard let begin = course.startDate, let end = course.endDate, end > begin else { return false }
        return now >= begin && now < end
    }

    public static func currentAndNext(_ courses: [Course], now: Date = Date()) -> (current: Course?, next: Course?) {
        let today = dayKey(now)
        let sorted = courses.filter { normalizeDay($0.day) == today && $0.startDate != nil }.sorted {
            if $0.startDate == $1.startDate { return ($0.endDate ?? .distantFuture) < ($1.endDate ?? .distantFuture) }
            return $0.startDate! < $1.startDate!
        }
        let current = sorted.first { isWithinSignWindow($0, now: now) }
        let next = sorted.first { course in
            guard let begin = course.startDate else { return false }
            if let current, let currentBegin = current.startDate {
                return course.id != current.id && course.name.trimmingCharacters(in: .whitespacesAndNewlines) != current.name.trimmingCharacters(in: .whitespacesAndNewlines) && begin > currentBegin
            }
            return begin > now
        }
        return (current, next)
    }

    private static func validatedDate(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int, zone: TimeZone) -> Date? {
        guard (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day), (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second) else { return nil }
        var cal = calendar
        cal.timeZone = zone
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard let date = cal.date(from: components) else { return nil }
        let actual = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard actual.year == year, actual.month == month, actual.day == day, actual.hour == hour, actual.minute == minute, actual.second == second else { return nil }
        return date
    }

    private static func captures(_ pattern: String, _ value: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        return (1..<match.numberOfRanges).map { index in
            guard let range = Range(match.range(at: index), in: value) else { return "" }
            return String(value[range])
        }
    }
}
