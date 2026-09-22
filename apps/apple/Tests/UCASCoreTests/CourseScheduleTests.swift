import XCTest
@testable import UCASCore

final class CourseScheduleTests: XCTestCase {
    private let term = SchoolSemester(id: "term", name: "跨年学期", beginDate: "20261230", endDate: "20270119", isCurrent: true)
    private let course = CatalogCourse(id: "catalog", number: "CS1", name: "课程", teacher: "教师", classroom: "B203", semesterId: "term", beginDate: "", endDate: "")

    private func meeting(_ id: String, day: String = "20261230", room: String? = "B203", start: String = "13:30", end: String = "16:10", teacher: String = "甲老师", number: String? = "CS1", courseID: String = "teacher-course") -> Course {
        Course(id: id, courseId: courseID, courseNumber: number, name: "课程", teacher: teacher,
               classroom: room, beginTime: start, endTime: end, day: day)
    }
    private func presentation(_ values: [Course], catalog: [CatalogCourse]? = nil) -> CourseSchedulePresentation {
        CourseSchedulePresentation(course: course, semester: term, catalog: catalog ?? [course], semesters: [term], courses: values)
    }

    func testPartialCrossYearWeeksAndDiscontinuousSummary() {
        let result = presentation([meeting("3", day: "20270113"), meeting("1"), meeting("last", day: "20270119")])
        XCTAssertEqual(result.meetings.map(\.week), [1, 3, 4])
        XCTAssertEqual(result.meetings.map(\.weekday), [3, 3, 2])
        XCTAssertEqual(result.summaries.first(where: { $0.weekday == 3 })?.weekText, "第 1、3 周")
        XCTAssertEqual(CourseSchedulePresentation.weekText([10, 3, 2, 1, 2, 8]), "第 1–3、8、10 周")
    }

    func testCoTeachersMergeButDifferentRoomsAndTimesDoNot() {
        let result = presentation([meeting("a"), meeting("b", teacher: "乙老师"), meeting("c", room: "B204"),
                                   meeting("d", start: "18:30", end: "20:00")])
        XCTAssertEqual(result.meetings.count, 3)
        let merged = result.meetings.first { $0.courses.count == 2 }
        XCTAssertEqual(merged?.teachers, ["乙老师", "甲老师"].sorted())
        XCTAssertEqual(Set(merged?.courses.map(\.id) ?? []), ["a", "b"])
        XCTAssertEqual(result.summaries.count, 3)
    }

    func testUnknownRoomsAndInvalidTimesRemainSeparateAndVisible() {
        let result = presentation([meeting("a", room: nil), meeting("b", room: nil),
                                   meeting("bad", start: "待定", end: ""), meeting("reverse", start: "16:00", end: "14:00")])
        XCTAssertEqual(result.meetings.count, 4)
        XCTAssertEqual(result.meetings.filter { !$0.hasValidTime }.count, 2)
        XCTAssertTrue(result.summaries.contains { $0.time.contains("待定") && $0.time.contains("时间待确认") })
    }

    func testAssociationRejectsAmbiguityAndDoesNotMatchNamesOrOtherTerms() {
        let duplicate = CatalogCourse(id: "duplicate", number: "CS1", name: "课程", teacher: "", classroom: nil, semesterId: "term", beginDate: "", endDate: "")
        XCTAssertNotNil(presentation([meeting("a")], catalog: [course, duplicate]).associationIssue)
        let result = presentation([meeting("outside", day: "20261229"), meeting("wrong", number: "CS2"),
                                   meeting("name-only", number: nil), meeting("id", number: nil, courseID: "catalog")])
        XCTAssertNil(result.associationIssue)
        XCTAssertEqual(result.meetings.flatMap(\.courses).map(\.id), ["id"])
    }

    func testOrderingAndAttendanceDoNotChangeArrangements() {
        let first = meeting("first")
        let second = meeting("second", day: "20270106")
        var signed = first
        signed.signed = true
        let lhs = presentation([first, second])
        let rhs = presentation([second, signed])
        XCTAssertEqual(lhs.meetings.map(\.id), rhs.meetings.map(\.id))
        XCTAssertEqual(lhs.summaries.map(\.weekText), rhs.summaries.map(\.weekText))
    }

    func testProgressUsesEndTimeAndMergedArrangements() {
        var signedFuture = meeting("future", day: "20270106")
        signedFuture.signed = true
        let result = presentation([meeting("a"), meeting("b", teacher: "乙老师"),
                                   meeting("later", start: "18:30", end: "20:00"), signedFuture])
        let end = CourseTime.parse(day: "20261230", time: "16:10")!
        XCTAssertEqual(result.progress(at: end.addingTimeInterval(-1)).ended, 0)
        let progress = result.progress(at: end)
        XCTAssertEqual(progress.total, 3)
        XCTAssertEqual(progress.ended, 1)
        XCTAssertEqual(progress.unknownTime, 0)
        XCTAssertEqual(progress.fraction, 1.0 / 3.0)
        XCTAssertEqual(result.progress(at: .distantFuture).ended, 3)
    }

    func testProgressDoesNotGuessInvalidTimesAndHandlesEmptySchedule() {
        let result = presentation([meeting("bad", start: "待定", end: ""),
                                   meeting("reverse", start: "16:00", end: "14:00"), meeting("valid")])
        let progress = result.progress(at: .distantFuture)
        XCTAssertEqual(progress.total, 3)
        XCTAssertEqual(progress.ended, 1)
        XCTAssertEqual(progress.unknownTime, 2)
        let empty = presentation([]).progress(at: .distantFuture)
        XCTAssertEqual(empty.total, 0)
        XCTAssertEqual(empty.ended, 0)
        XCTAssertEqual(empty.fraction, 0)
    }
}
