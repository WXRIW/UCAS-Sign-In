import XCTest
@testable import UCASCore

final class CourseTimeTests: XCTestCase {
    func testSchoolTimeFormatsAndExplicitTimeZones() throws {
        let expected = try XCTUnwrap(CourseTime.parse(day: "20260915", time: "08:00"))
        for value in ["8:00", "08:00:00", "08：00", "800", "0800", "080000", "2026-09-15 08:00:00", "2026-09-15T08:00:00.123", "2026-09-15T08:00:00+08:00", "2026-09-15T00:00:00Z"] {
            XCTAssertEqual(CourseTime.parse(day: "2026/09/15", time: value), expected, value)
        }
        XCTAssertEqual(CourseTime.dayKey(expected), "20260915")
        XCTAssertEqual(CourseTime.display("2026-09-15 8:00:00"), "08:00")
    }

    func testInvalidDatesDoNotRollForwardOrFallBackToToday() {
        for (day, time) in [("20260229", "08:00"), ("20261301", "08:00"), ("20260915", "24:00"), ("20260915", "08:60"), ("20260915", "08:00:99"), ("", "08:00"), ("garbage", "08:00"), ("20260915", ""), ("20260915", "08:00+99:99")] {
            XCTAssertNil(CourseTime.parse(day: day, time: time), "\(day) \(time)")
        }
        XCTAssertNotNil(CourseTime.parse(day: "20240229", time: "08:00"))
        XCTAssertEqual(CourseTime.display(""), "—")
    }

    func testSignWindowIsInclusiveAtLeadAndExclusiveAtEnd() throws {
        let course = sampleCourse()
        let begin = try XCTUnwrap(course.startDate), end = try XCTUnwrap(course.endDate)
        XCTAssertFalse(CourseTime.isWithinSignWindow(course, now: begin.addingTimeInterval(-1501)))
        XCTAssertTrue(CourseTime.isWithinSignWindow(course, now: begin.addingTimeInterval(-1500)))
        XCTAssertTrue(CourseTime.isWithinSignWindow(course, now: end.addingTimeInterval(-1)))
        XCTAssertFalse(CourseTime.isWithinSignWindow(course, now: end))
        XCTAssertFalse(CourseTime.isInProgress(course, now: begin.addingTimeInterval(-1)))
        XCTAssertTrue(CourseTime.isInProgress(course, now: begin))
    }

    func testCurrentNextSkipsConsecutiveSameNameAndOtherDays() throws {
        let courses = [sampleCourse(), sampleCourse(id: "1234568", begin: "10:00", end: "11:40"), sampleCourse(id: "1234569", name: "大学英语", begin: "14:00", end: "15:40"), sampleCourse(id: "1234570", name: "昨日课程", begin: "09:00", end: "11:40", day: "20260914")]
        let now = try XCTUnwrap(CourseTime.parse(day: "20260915", time: "08:30"))
        let selected = CourseTime.currentAndNext(courses.reversed(), now: now)
        XCTAssertEqual(selected.current?.id, "1234567")
        XCTAssertEqual(selected.next?.id, "1234569")
        let before = CourseTime.currentAndNext(courses, now: now.addingTimeInterval(-3600))
        XCTAssertNil(before.current)
        XCTAssertEqual(before.next?.id, "1234567")
        let tomorrow = CourseTime.currentAndNext(courses, now: now.addingTimeInterval(86400))
        XCTAssertNil(tomorrow.current)
        XCTAssertNil(tomorrow.next)
    }

    func testInvalidOrReversedCourseIntervalNeverEnablesSigning() {
        let course = sampleCourse(begin: "10:00", end: "09:00")
        XCTAssertFalse(CourseTime.isWithinSignWindow(course, now: course.startDate!))
        XCTAssertFalse(CourseTime.isInProgress(course, now: course.startDate!))
    }
}

func sampleCourse(id: String = "1234567", name: String = "高等数学", begin: String = "08:00", end: String = "09:40", day: String = "20260915") -> Course {
    Course(id: id, uuid: "550e8400-e29b-41d4-a716-446655440000", name: name, teacher: "张老师", beginTime: begin, endTime: end, day: day)
}
