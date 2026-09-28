import Foundation

/// A display-only copy of courses. Sessions and credentials never leave iPhone.
struct WatchCourse: Codable, Identifiable, Equatable {
    let id: String
    let day: String
    let name: String
    let time: String
    let location: String
    let teacher: String?
    let startAt: Date?
    let attendance: String
    let isSigned: Bool
    let canSign: Bool
}

struct WatchDay: Codable, Identifiable, Equatable {
    let id: String
    let date: Date
    let courses: [WatchCourse]
    let updatedAt: Date?
}

struct WatchRecord: Codable, Identifiable, Equatable {
    let id: String
    let courseName: String
    let date: Date
    let message: String
    let succeeded: Bool
}

struct WatchSnapshot: Codable, Equatable {
    let accountGeneration: String
    let accountName: String
    let message: String?
    let courses: [WatchCourse]
    let updatedAt: Date
    let week: [WatchDay]?
    let recentRecords: [WatchRecord]?
    let studentNo: String?
}

struct WatchResponse: Codable {
    let snapshot: WatchSnapshot
    let message: String?
}
