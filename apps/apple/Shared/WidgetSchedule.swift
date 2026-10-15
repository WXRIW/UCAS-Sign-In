import Foundation

/// Selects courses and transition times from the widget's local snapshot.
struct WidgetSchedule {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }()

    let date: Date
    let todayCourses: [WidgetCourse]

    init(snapshot: WidgetSnapshot, at date: Date) {
        self.date = date
        todayCourses = snapshot.courses
            .filter { Self.calendar.isDate($0.startTime, inSameDayAs: date) }
            .sorted {
                if $0.startTime != $1.startTime { return $0.startTime < $1.startTime }
                if $0.endTime != $1.endTime { return $0.endTime < $1.endTime }
                return $0.id < $1.id
            }
    }

    var remainingCourses: [WidgetCourse] {
        todayCourses.filter { $0.endTime > date }
    }

    func visibleCourses(limit: Int) -> [WidgetCourse] {
        guard limit > 0 else { return [] }
        let remaining = remainingCourses
        return remaining.isEmpty
            ? Array(todayCourses.suffix(limit))
            : Array(remaining.prefix(limit))
    }

    var nextMidnight: Date {
        Self.calendar.date(byAdding: .day, value: 1, to: Self.calendar.startOfDay(for: date))!
    }

    var timelineDates: [Date] {
        let midnight = nextMidnight
        let courseEnds = todayCourses.map(\.endTime).filter { $0 > date && $0 < midnight }
        return [date] + Set(courseEnds).sorted() + [midnight]
    }
}
