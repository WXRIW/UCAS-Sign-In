import XCTest
@testable import UCASCore

final class ScheduleCacheTests: XCTestCase {
    func testColorCollisionsProbeEverySlotBeforeReusingColors() {
        let courses = (0..<200).map { index in
            Course(id: "\(index)", courseNumber: "COLOR\(index)", name: "课程\(index)",
                   beginTime: "08:00", endTime: "09:00", day: "20260921")
        }
        let collisions = Array(courses.filter { CourseIdentity.colorIndex(for: $0, paletteSize: 7) == 6 }.prefix(15))
        XCTAssertEqual(collisions.count, 15)
        var palette = ScheduleColors()
        palette.register(Array(collisions.prefix(7)))
        let first = collisions.prefix(7).map { palette.index(for: $0) }
        XCTAssertEqual(Set(first).count, 7)
        palette.register(collisions)
        XCTAssertEqual(collisions.prefix(7).map { palette.index(for: $0) }, first)
        let usage = Dictionary(grouping: collisions, by: { palette.index(for: $0) }).mapValues(\.count)
        XCTAssertEqual(usage.values.sorted(), [2, 2, 2, 2, 2, 2, 3])
        var reordered = ScheduleColors()
        reordered.register(Array(collisions.prefix(7).reversed()))
        XCTAssertEqual(collisions.prefix(7).map { reordered.index(for: $0) }, first)
        let sameCourse = Course(id: "new-meeting", courseNumber: collisions[0].courseNumber, name: "另一教师",
                                beginTime: "10:00", endTime: "11:00", day: "20260928")
        palette.register([sameCourse])
        XCTAssertEqual(palette.index(for: sameCourse), first[0])
    }

    func testSemesterWeekLayoutPerformance() {
        let start = date("20260907")
        let courses = (0..<140).flatMap { offset in
            (1...6).map { teacher in
                joint(teacher, day: CourseTime.dayKey(CourseTime.calendar.date(byAdding: .day, value: offset, to: start)!))
            }
        }
        let begin = Date()
        let entries = ScheduleLayout.weekEntries(courses, containing: date("20260921"), semesters: [term],
                                                 includeOutsideWeek: true, catalog: [jointCatalog])
        _ = WeekSchedulePresentation(entries: entries)
        let elapsed = Date().timeIntervalSince(begin)
        XCTAssertLessThan(elapsed, 0.25, "Large cached semesters must not block every frame for half a second")
        XCTAssertEqual(entries.count, 42)
    }

    func testCourseColorDoesNotDependOnTeacherMeetingWeekOrResponseOrder() {
        let first = joint(1)
        let otherWeek = joint(3, day: "20261005")
        XCTAssertEqual(CourseIdentity.colorIndex(for: first, paletteSize: 7),
                       CourseIdentity.colorIndex(for: otherWeek, paletteSize: 7))
        let oldCache = joint(2, number: nil)
        let oldOtherWeek = joint(4, day: "20261005", number: nil)
        XCTAssertEqual(CourseIdentity.colorIndex(for: oldCache, paletteSize: 7),
                       CourseIdentity.colorIndex(for: oldOtherWeek, paletteSize: 7))
        let entries = ScheduleLayout.weekEntries([joint(3), joint(2), joint(1)], containing: date("20260921"),
            semesters: [term], includeOutsideWeek: false, catalog: [jointCatalog])
        XCTAssertEqual(Set(entries.map { CourseIdentity.colorIndex(for: $0.course, paletteSize: 7) }).count, 1)
    }

    private var jointCatalog: CatalogCourse {
        CatalogCourse(id: "canonical", number: "JOINT101", name: "联合课程", teacher: "教师甲,教师乙,教师丙",
                      classroom: "B203", semesterId: "term", beginDate: "20260831", endDate: "20270131")
    }

    private func joint(_ teacher: Int, day: String = "20260921", room: String = "B203", number: String? = "JOINT101") -> Course {
        Course(id: "123456\(teacher)", courseId: "teaching-\(teacher)", courseNumber: number, teacherId: "teacher-\(teacher)",
               name: "联合课程", teacher: "教师\(teacher)", classroom: room, beginTime: "08:00", endTime: "09:40", day: day)
    }

    func testCourseNumberParsesFromScheduleAndIgnoresIncorrectSemesterField() throws {
        let values = try ResponseParser.scheduledCourses([["id": "1234567", "courseId": "teacher-specific",
            "courseNum": "JOINT101", "teacherId": "t1", "courseName": "联合课程", "semesterId": "wrong-old-term",
            "classBeginTime": "08:00", "classEndTime": "09:40"]], day: "20260921")
        let course = try XCTUnwrap(values.first)
        XCTAssertEqual(course.courseNumber, "JOINT101")
        XCTAssertEqual(course.teacherId, "t1")
        XCTAssertEqual(CourseIdentity.catalogCourse(for: course, catalog: [jointCatalog], semesters: [term])?.id, "canonical")
        XCTAssertEqual(course.courseId, "teacher-specific")
        XCTAssertEqual(course.qrIdentifier, "1234567")
    }

    func testNumberAssociationRejectsAmbiguousOrOutOfTermMatches() {
        let duplicate = CatalogCourse(id: "another-class", number: "JOINT101", name: "联合课程", teacher: "其他教师",
                                      classroom: "C301", semesterId: "term", beginDate: "20260831", endDate: "20270131")
        XCTAssertNil(CourseIdentity.catalogCourse(for: joint(1), catalog: [jointCatalog, duplicate], semesters: [term]))
        XCTAssertNil(CourseIdentity.catalogCourse(for: joint(1, day: "20270201"), catalog: [jointCatalog], semesters: [term]))
        XCTAssertNil(CourseIdentity.catalogCourse(for: joint(1, number: nil), catalog: [jointCatalog], semesters: [term]))
        XCTAssertNil(CourseIdentity.catalogCourse(for: joint(1), catalog: [jointCatalog], semesters: []))
    }

    func testCoTeachersShareDisplayGroupButKeepEveryMeetingAndSignIdentifier() throws {
        let courses = (1...3).map { joint($0) }
        let entries = ScheduleLayout.weekEntries(courses, containing: date("20260921"), semesters: [term],
                                                includeOutsideWeek: false, catalog: [jointCatalog])
        let block = try XCTUnwrap(ScheduleLayout.weekBlocks(entries).first)
        XCTAssertEqual(block.groups.count, 1)
        XCTAssertEqual(block.groups[0].teachers.count, 3)
        XCTAssertEqual(Set(block.entries.map(\.course.qrIdentifier)), Set(courses.map(\.qrIdentifier)))
        XCTAssertEqual(Set(block.entries.map(\.course)), Set(courses))
        let differentRoom = ScheduleLayout.weekEntries([joint(1), joint(2, room: "C301")], containing: date("20260921"),
            semesters: [term], includeOutsideWeek: false, catalog: [jointCatalog])
        XCTAssertEqual(ScheduleLayout.weekBlocks(differentRoom)[0].groups.count, 2)
        let unresolved = ScheduleLayout.weekEntries(courses, containing: date("20260921"), semesters: [term], includeOutsideWeek: false)
        XCTAssertEqual(ScheduleLayout.weekBlocks(unresolved)[0].groups.count, 3)
    }

    func testOutsideWeekCoTeachersAreRetainedAndCurrentMeetingSuppressesWholePreview() {
        let previous = (1...3).flatMap { [joint($0, day: "20260914"), joint($0, day: "20260907")] }
        let previews = ScheduleLayout.weekEntries(previous, containing: date("20260921"), semesters: [term],
            includeOutsideWeek: true, catalog: [jointCatalog])
        XCTAssertEqual(previews.count, 3)
        XCTAssertEqual(ScheduleLayout.weekBlocks(previews)[0].groups.count, 1)
        let withActual = ScheduleLayout.weekEntries(previous + [joint(1)], containing: date("20260921"), semesters: [term],
            includeOutsideWeek: true, catalog: [jointCatalog])
        XCTAssertEqual(withActual.count, 1)
        XCTAssertFalse(withActual[0].isOutsideWeek)
    }

    func testLegacyCacheReadsAndRequiresIdentityUpgradeWithoutChangingTimestamp() throws {
        let course = joint(1)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(course)) as? [String: Any])
        json.removeValue(forKey: "courseNumber"); json.removeValue(forKey: "teacherId")
        let legacy = try JSONDecoder().decode(Course.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.courseNumber)
        XCTAssertEqual(legacy.id, course.id)
        let now = date("20260921")
        let cache = SemesterScheduleCache(semester: term, courses: [legacy], updatedAt: now)
        var snapshot = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(cache)) as? [String: Any])
        snapshot.removeValue(forKey: "courseIdentityVersion")
        let decoded = try JSONDecoder().decode(SemesterScheduleCache.self, from: JSONSerialization.data(withJSONObject: snapshot))
        XCTAssertTrue(decoded.needsRefresh(at: now))
        XCTAssertEqual(decoded.updatedAt, now)
        let hydrated = legacy.preservingIdentity(from: course)
        XCTAssertEqual(hydrated.courseNumber, course.courseNumber)
        XCTAssertEqual(hydrated.qrIdentifier, legacy.qrIdentifier)
        XCTAssertNil(legacy.preservingIdentity(from: joint(1, day: "20260914")).courseNumber)
    }
    private func date(_ day: String, _ time: String = "00:00") -> Date { CourseTime.parse(day: day, time: time)! }
    private let term = SchoolSemester(id: "term", name: "测试学期", beginDate: "20260831", endDate: "20270131", isCurrent: true)

    func testSevenDayExpiryIncludesExactBoundaryAndClockRollback() {
        let now = date("20260921")
        let cache = SemesterScheduleCache(semester: term, courses: [], updatedAt: now)
        XCTAssertFalse(cache.needsRefresh(at: now.addingTimeInterval(604799)))
        XCTAssertTrue(cache.needsRefresh(at: now.addingTimeInterval(604800)))
        XCTAssertTrue(cache.needsRefresh(at: now.addingTimeInterval(-1)))
    }

    func testWeekUsesMondayAndShanghaiAcrossYearBoundary() {
        let week = ScheduleCalendar.week(containing: date("20270103", "23:59"))
        XCTAssertEqual(week.map(CourseTime.dayKey), ["20261228", "20261229", "20261230", "20261231", "20270101", "20270102", "20270103"])
        XCTAssertEqual(ScheduleCalendar.week(containing: date("20270104"))[0], date("20270104"))
    }

    func testSemesterIncludesBothEndpointsAndRejectsInvalidRange() {
        let days = ScheduleCalendar.days(in: term)
        XCTAssertEqual(days.first, date("20260831"))
        XCTAssertEqual(days.last, date("20270131"))
        XCTAssertEqual(days.count, 154)
        XCTAssertTrue(ScheduleCalendar.days(in: SchoolSemester(id: "x", name: "x", beginDate: "20270102", endDate: "20260101", isCurrent: false)).isEmpty)
    }

    func testArrangementComparisonNormalizesAndExcludesAttendance() {
        let a = Course(id: "1", courseId: "stable", name: "课程 A", teacher: "教师", classroom: " A101 ", beginTime: "8:00", endTime: "09:00", day: "20260921")
        let b = Course(id: "1", courseId: "stable", name: " 课程  A ", teacher: "教师", classroom: "A101", beginTime: "08:00:00", endTime: "09:00:00", day: "2026-09-21", signed: true)
        let other = sampleCourse(id: "2")
        XCTAssertTrue(ScheduleCalendar.sameArrangements([a, other], [other, b]))
        XCTAssertFalse(ScheduleCalendar.sameArrangements([a], []))
        let moved = Course(id: "1", courseId: "stable", name: "课程 A", teacher: "教师", classroom: "A102", beginTime: "08:00", endTime: "09:00", day: "20260921")
        XCTAssertFalse(ScheduleCalendar.sameArrangements([a], [moved]))
    }

    func testOverlapsAreTransitiveButTouchingCoursesRemainSeparate() {
        let courses = [sampleCourse(id: "1", begin: "08:00", end: "09:00"),
                       sampleCourse(id: "2", begin: "08:30", end: "10:00"),
                       sampleCourse(id: "3", begin: "09:30", end: "11:00"),
                       sampleCourse(id: "4", begin: "11:00", end: "12:00")]
        let blocks = ScheduleLayout.blocks(courses.reversed())
        XCTAssertEqual(blocks.map { $0.courses.count }, [3, 1])
        XCTAssertEqual(blocks[0].end, courses[2].endDate)
    }

    func testInvalidTimesAreExcludedAndHoursExpand() {
        let invalid = sampleCourse(begin: "12:00", end: "11:00")
        XCTAssertFalse(ScheduleLayout.isTimed(invalid))
        XCTAssertTrue(ScheduleLayout.blocks([invalid]).isEmpty)
        XCTAssertEqual(ScheduleLayout.hours([sampleCourse(begin: "06:30", end: "23:30")]), 6...24)
        XCTAssertEqual(ScheduleLayout.hours([]), 8...22)
    }

    func testWeeklyParserPreservesEmptyDatesAndDoesNotInventCoverage() throws {
        let payload = Data(#"{"STATUS":"1","result":[{"dateStr":"2026-09-21","schedData":[]},{"dateStr":"2026-09-22","schedData":[{"id":"1234567","courseName":"课程","classBeginTime":"08:00","classEndTime":"09:00"}]}]}"#.utf8)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let week = try ResponseParser.weeklySchedule(json)
        XCTAssertEqual(week.coveredDays, ["20260921", "20260922"])
        XCTAssertEqual(week.courses.count, 1)
        XCTAssertFalse(week.coveredDays.contains("20260923"))
    }

    func testDuplicateWeeklyDatesAreRejected() throws {
        let payload = Data(#"{"STATUS":"0","result":[{"dateStr":"20260921","schedData":[]},{"dateStr":"20260921","schedData":[]}]}"#.utf8)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        XCTAssertThrowsError(try ResponseParser.weeklySchedule(json))
    }

    private func meeting(_ day: String, id: String = "meeting", courseID: String? = "stable",
                         begin: String = "08:00", end: String = "09:00", room: String = "A101") -> Course {
        Course(id: id, courseId: courseID, name: "课程", teacher: "教师", classroom: room,
               beginTime: begin, endTime: end, day: day, signed: true)
    }

    func testOutsideWeekDefaultsToOnlyActualMeetingsAndNeedsKnownSemester() {
        let actual = meeting("20260921"), other = meeting("20260914", id: "other")
        let hidden = ScheduleLayout.weekEntries([actual, other], containing: date("20260921"),
                                               semesters: [term], includeOutsideWeek: false)
        XCTAssertEqual(hidden.map(\.course), [actual])
        XCTAssertFalse(hidden[0].isOutsideWeek)
        XCTAssertTrue(ScheduleLayout.weekEntries([other], containing: date("20260921"),
                                                 semesters: [], includeOutsideWeek: true).isEmpty)
    }

    func testOutsideWeekDeduplicatesSlotsAndPrefersNearestMeetingWithoutChangingOriginal() throws {
        let near = meeting("20260914", id: "near", begin: "8:00", room: "新教室")
        let far = meeting("20260907", id: "far", begin: "08:00:00")
        let future = meeting("20260928", id: "future")
        let entries = ScheduleLayout.weekEntries([far, future, near], containing: date("20260921"),
                                                semesters: [term], includeOutsideWeek: true)
        let preview = try XCTUnwrap(entries.first)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(preview.displayDay, "20260921")
        XCTAssertEqual(preview.course, near)
        XCTAssertTrue(preview.course.signed)
        XCTAssertTrue(preview.isOutsideWeek)
        XCTAssertEqual(preview.positionedCourse.startDate, date("20260921", "08:00"))
        XCTAssertFalse(preview.positionedCourse.signed)
        XCTAssertEqual(ScheduleLayout.weekEntries([near, far, future], containing: date("20260921"),
                                                  semesters: [term], includeOutsideWeek: true).map(\.id), entries.map(\.id))
    }

    func testCurrentMeetingSuppressesOtherWeeksEvenWhenClassroomChanges() {
        let actual = meeting("20260921", id: "actual", room: "B202")
        let entries = ScheduleLayout.weekEntries([meeting("20260914"), actual], containing: date("20260921"),
                                                semesters: [term], includeOutsideWeek: true)
        XCTAssertEqual(entries.map(\.course), [actual])
        XCTAssertFalse(entries[0].isOutsideWeek)
    }

    func testOutsideWeekNormalizesFullTimestampAndFallbackIdentity() throws {
        let dated = meeting("20260914", courseID: nil, begin: "2026-09-14T00:00:00Z", end: "2026-09-14T01:00:00Z")
        let repeated = meeting("20260907", id: "repeat", courseID: nil)
        let entries = ScheduleLayout.weekEntries([dated, repeated], containing: date("20260921"), semesters: [term], includeOutsideWeek: true)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(try XCTUnwrap(entries.first).positionedCourse.startDate, date("20260921", "08:00"))
        XCTAssertEqual(entries.first?.course, dated)
    }

    func testOutsideWeekUsesWeekdayAndSemesterBoundariesAcrossYear() {
        let nextTerm = SchoolSemester(id: "next", name: "next", beginDate: "20270201", endDate: "20270630", isCurrent: false)
        let entries = ScheduleLayout.weekEntries([meeting("20270104"), meeting("20260824", id: "old"),
                                                  meeting("20270201", id: "next", courseID: "different"),
                                                  meeting("20261229", id: "tuesday", courseID: "tuesday")],
                                                containing: date("20270103"), semesters: [term, nextTerm], includeOutsideWeek: true)
        XCTAssertEqual(entries.map(\.displayDay), ["20261228", "20261229"])
        XCTAssertEqual(entries.map(\.course.id), ["meeting", "tuesday"])
        XCTAssertTrue(ScheduleLayout.weekEntries([meeting("20260907")], containing: date("20260831"),
            semesters: [SchoolSemester(id: "midweek", name: "midweek", beginDate: "20260901", endDate: "20270131", isCurrent: true)],
            includeOutsideWeek: true).isEmpty)
    }

    func testOutsideWeekRetainsDistinctTimeSlotsAndOriginalCoursesInOverlap() throws {
        let actual = meeting("20260921", id: "actual", begin: "08:30", end: "09:30")
        let other = meeting("20260914", id: "preview", courseID: "different")
        let later = meeting("20260914", id: "later", courseID: "different", begin: "11:00", end: "12:00")
        let invalid = meeting("20260915", id: "invalid", begin: "待确认")
        let entries = ScheduleLayout.weekEntries([other, actual, later, invalid], containing: date("20260921"),
                                                semesters: [term], includeOutsideWeek: true)
        XCTAssertEqual(entries.count, 4)
        let blocks = ScheduleLayout.weekBlocks(entries)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(Set(blocks[0].entries.map(\.course)), Set([actual, other]))
        XCTAssertFalse(blocks[0].isOutsideWeek)
        XCTAssertTrue(blocks[1].isOutsideWeek)
        XCTAssertEqual(blocks[1].entries.first?.course, later)
        XCTAssertFalse(ScheduleLayout.isTimed(try XCTUnwrap(entries.last).positionedCourse))
    }
}
