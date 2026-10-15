import XCTest
@testable import UCASSignInMac

final class WidgetScheduleTests: XCTestCase {
    func testMediumCoursesAdvanceAfterEachCourseEnds() {
        let courses = [
            course("first", start: "08:00", end: "09:00"),
            course("second", start: "10:00", end: "11:00"),
            course("third", start: "13:00", end: "14:00"),
            course("fourth", start: "15:00", end: "16:00")
        ]
        let snapshot = WidgetSnapshot(courses: courses.reversed())

        XCTAssertEqual(WidgetSchedule(snapshot: snapshot, at: date("07:00")).visibleCourses(limit: 2).map(\.id), ["first", "second"])
        XCTAssertEqual(WidgetSchedule(snapshot: snapshot, at: date("09:00")).visibleCourses(limit: 2).map(\.id), ["second", "third"])
        XCTAssertEqual(WidgetSchedule(snapshot: snapshot, at: date("11:00")).visibleCourses(limit: 2).map(\.id), ["third", "fourth"])
        XCTAssertEqual(WidgetSchedule(snapshot: snapshot, at: date("11:00")).visibleCourses(limit: 1).map(\.id), ["third"])
    }

    func testCourseRemainsVisibleUntilItsExactEnd() {
        let first = course("first", start: "08:00", end: "09:00")
        let second = course("second", start: "10:00", end: "11:00")
        let snapshot = WidgetSnapshot(courses: [first, second])

        XCTAssertEqual(WidgetSchedule(snapshot: snapshot, at: first.endTime.addingTimeInterval(-1)).remainingCourses.map(\.id), ["first", "second"])
        XCTAssertEqual(WidgetSchedule(snapshot: snapshot, at: first.endTime).remainingCourses.map(\.id), ["second"])
    }

    func testEndedOverlappingCourseDoesNotOccupyVisibleCapacity() {
        let snapshot = WidgetSnapshot(courses: [
            course("long", start: "08:00", end: "12:00"),
            course("short", start: "09:00", end: "10:00"),
            course("next", start: "13:00", end: "14:00")
        ])

        let schedule = WidgetSchedule(snapshot: snapshot, at: date("10:30"))

        XCTAssertEqual(schedule.visibleCourses(limit: 2).map(\.id), ["long", "next"])
    }

    func testTodayUsesShanghaiDayRatherThanUTCDate() {
        let snapshot = WidgetSnapshot(courses: [
            course("yesterday", start: "23:00", end: "23:30", day: "2026-10-14"),
            course("early", start: "00:15", end: "01:00"),
            course("later", start: "23:00", end: "23:30"),
            course("tomorrow", start: "00:15", end: "01:00", day: "2026-10-16")
        ])
        let now = ISO8601DateFormatter().date(from: "2026-10-14T16:00:00Z")!

        let schedule = WidgetSchedule(snapshot: snapshot, at: now)

        XCTAssertEqual(schedule.todayCourses.map(\.id), ["early", "later"])
        XCTAssertEqual(schedule.remainingCourses.map(\.id), ["early", "later"])
        XCTAssertEqual(schedule.nextMidnight, date("00:00", day: "2026-10-16"))
    }

    func testCheckInStateDoesNotChangeCourseSelection() {
        let snapshot = WidgetSnapshot(courses: [
            course("ended", start: "08:00", end: "09:00"),
            course("signed", start: "10:00", end: "11:00", isCheckedIn: true),
            course("upcoming", start: "13:00", end: "14:00")
        ])

        let schedule = WidgetSchedule(snapshot: snapshot, at: date("10:30"))

        XCTAssertEqual(schedule.visibleCourses(limit: 2).map(\.id), ["signed", "upcoming"])
    }

    func testFinishedDayRetainsLastCoursesUpToCapacity() {
        let courses = (0..<10).map { index in
            course("course-\(index)", start: String(format: "%02d:00", index + 8), end: String(format: "%02d:30", index + 8))
        }
        let schedule = WidgetSchedule(snapshot: WidgetSnapshot(courses: courses.reversed()), at: date("20:00"))

        XCTAssertTrue(schedule.remainingCourses.isEmpty)
        for capacity in [1, 2, 4, 8] {
            XCTAssertEqual(schedule.visibleCourses(limit: capacity).map(\.id), Array(courses.suffix(capacity)).map(\.id))
        }
        XCTAssertEqual(schedule.visibleCourses(limit: 20), courses)
    }

    func testSingleRemainingCourseDoesNotBackfillCompletedCourses() {
        let snapshot = WidgetSnapshot(courses: [
            course("ended", start: "08:00", end: "09:00"),
            course("last", start: "10:00", end: "11:00")
        ])

        let schedule = WidgetSchedule(snapshot: snapshot, at: date("10:00"))

        XCTAssertEqual(schedule.visibleCourses(limit: 8).map(\.id), ["last"])
    }

    func testEmptySnapshotAndNonpositiveCapacityHaveNoVisibleCourses() {
        let empty = WidgetSchedule(snapshot: .empty, at: date("08:00"))
        let populated = WidgetSchedule(snapshot: WidgetSnapshot(courses: [course("course", start: "10:00", end: "11:00")]), at: date("08:00"))

        XCTAssertTrue(empty.todayCourses.isEmpty)
        XCTAssertTrue(empty.remainingCourses.isEmpty)
        XCTAssertTrue(empty.visibleCourses(limit: 2).isEmpty)
        XCTAssertTrue(populated.visibleCourses(limit: 0).isEmpty)
        XCTAssertTrue(populated.visibleCourses(limit: -1).isEmpty)
    }

    func testEqualStartTimesSortByEndThenStableID() {
        let courses = [
            course("c", start: "10:00", end: "12:00"),
            course("b", start: "10:00", end: "11:00"),
            course("a", start: "10:00", end: "11:00"),
            course("early", start: "09:00", end: "12:00")
        ]

        for input in [courses, Array(courses.reversed())] {
            let schedule = WidgetSchedule(snapshot: WidgetSnapshot(courses: input), at: date("08:00"))
            XCTAssertEqual(schedule.todayCourses.map(\.id), ["early", "a", "b", "c"])
        }
    }

    func testTimelineContainsOnlyFutureUniqueEndsAndNextMidnight() {
        let now = date("10:00")
        let snapshot = WidgetSnapshot(courses: [
            course("past", start: "08:00", end: "09:00"),
            course("ends-now", start: "09:00", end: "10:00"),
            course("second", start: "12:00", end: "13:00"),
            course("first", start: "10:00", end: "11:00"),
            course("same-end", start: "10:30", end: "11:00"),
            course("midnight", start: "23:00", end: "00:00", endDay: "2026-10-16"),
            course("overnight", start: "23:30", end: "01:00", endDay: "2026-10-16"),
            course("tomorrow", start: "08:00", end: "09:00", day: "2026-10-16")
        ])

        let schedule = WidgetSchedule(snapshot: snapshot, at: now)

        XCTAssertEqual(schedule.timelineDates, [now, date("11:00"), date("13:00"), date("00:00", day: "2026-10-16")])
        XCTAssertEqual(schedule.timelineDates.last, schedule.nextMidnight)
    }

    func testEmptyTimelineStillClearsAtMidnight() {
        let now = date("23:59")
        let snapshot = WidgetSnapshot(courses: [course("last", start: "20:00", end: "21:00")])
        let schedule = WidgetSchedule(snapshot: snapshot, at: now)

        XCTAssertEqual(schedule.timelineDates, [now, date("00:00", day: "2026-10-16")])
        XCTAssertTrue(WidgetSchedule(snapshot: snapshot, at: schedule.nextMidnight).visibleCourses(limit: 8).isEmpty)
        XCTAssertEqual(WidgetSchedule(snapshot: .empty, at: now).timelineDates, schedule.timelineDates)
    }

    private func course(_ id: String, start: String, end: String, day: String = "2026-10-15", endDay: String? = nil, isCheckedIn: Bool = false) -> WidgetCourse {
        WidgetCourse(id: id, name: id, location: "教室 · A102", startTime: date(start, day: day), endTime: date(end, day: endDay ?? day), isCheckedIn: isCheckedIn)
    }

    private func date(_ time: String, day: String = "2026-10-15") -> Date {
        ISO8601DateFormatter().date(from: "\(day)T\(time):00+08:00")!
    }
}
