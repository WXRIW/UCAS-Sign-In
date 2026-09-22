import Foundation

/// The only data shared with the widget. Credentials and sign-in tokens stay in the app.
struct WidgetCourse: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var location: String
    var startTime: Date
    var endTime: Date
    var isCheckedIn: Bool
    var attendanceLabel: String? = nil
}

struct WidgetSnapshot: Codable, Equatable {
    var courses: [WidgetCourse]
    var updatedAt: Date

    init(courses: [WidgetCourse], updatedAt: Date = .now) {
        self.courses = courses
        self.updatedAt = updatedAt
    }

    static var empty: WidgetSnapshot { WidgetSnapshot(courses: []) }

    static var preview: WidgetSnapshot {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let day = calendar.startOfDay(for: .now)
        return WidgetSnapshot(courses: [
            WidgetCourse(id: "preview-1", name: "高等人工智能", location: "教室 · 教学楼 B203", startTime: day.addingTimeInterval(9 * 3_600), endTime: day.addingTimeInterval(10.5 * 3_600), isCheckedIn: true),
            WidgetCourse(id: "preview-2", name: "学术英语", location: "教师 · 王雅文", startTime: day.addingTimeInterval(14 * 3_600), endTime: day.addingTimeInterval(15.5 * 3_600), isCheckedIn: false)
        ])
    }
}

enum WidgetSnapshotStore {
    /// Override APP_GROUP_IDENTIFIER for both Xcode targets when using your own team.
    static var appGroupID: String {
        Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String ?? "group.cn.ucas.signin"
    }

    private static let snapshotKey = "today.courseSnapshot.v1"

    static func save(_ snapshot: WidgetSnapshot) {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: snapshotKey)
    }

    static func load() -> WidgetSnapshot {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let data = defaults.data(forKey: snapshotKey),
              let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else {
            return .empty
        }
        return snapshot
    }

    static func clear() {
        UserDefaults(suiteName: appGroupID)?.removeObject(forKey: snapshotKey)
    }
}
