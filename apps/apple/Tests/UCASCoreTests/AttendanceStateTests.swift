import XCTest
@testable import UCASCore

final class AttendanceStateTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    func testUnknownRevokesPreviouslyUnsignedPermission() {
        let now = Date()
        let state = AttendanceEvidence(status: .unsigned, source: .daily, observedAt: now)
            .observing(.unknown, source: .daily, now: now)
        XCTAssertEqual(state.status, .unknown)
    }
    func testCorrectionNeedsTwoIndependentSameSourceNegativesWithoutWaiting() {
        var state = AttendanceEvidence(observedAt: now).observing(.signed, source: .submission, now: now)
        state = state.observing(.unsigned, source: .daily, now: now)
        XCTAssertEqual(state.status, .signed); XCTAssertTrue(state.pendingVerification)
        state = state.observing(.unsigned, source: .detail, now: now)
        XCTAssertEqual(state.status, .signed)
        state = state.observing(.unsigned, source: .detail, now: now)
        XCTAssertEqual(state.status, .unsigned); XCTAssertFalse(state.pendingVerification)
        XCTAssertEqual(state.lastSuccessfulSignAt, now)
    }
    func testUnknownAndPositiveBreakNegativeSequence() {
        var state = AttendanceEvidence(status: .signed, source: .daily, observedAt: now)
        state = state.observing(.unsigned, source: .daily, now: now)
        state = state.observing(.unknown, source: .daily, now: now.addingTimeInterval(30))
        XCTAssertNil(state.negativeSource)
        state = state.observing(.unsigned, source: .daily, now: now.addingTimeInterval(60))
        XCTAssertEqual(state.status, .signed)
        state = state.observing(.signed, source: .daily, now: now.addingTimeInterval(90))
        XCTAssertFalse(state.pendingVerification); XCTAssertNil(state.negativeSource)
    }
    func testCacheBoundaryAndFutureTimestamp() {
        XCTAssertTrue(CachePolicy.isFresh(now, at: now.addingTimeInterval(CachePolicy.referenceLifetime - 1)))
        XCTAssertFalse(CachePolicy.isFresh(now, at: now.addingTimeInterval(CachePolicy.referenceLifetime)))
        XCTAssertFalse(CachePolicy.isFresh(now, at: now.addingTimeInterval(-1)))
    }
    func testMissingStatusIsUnknownAndLegacyCourseStillDecodes() throws {
        for status: Any? in [nil, NSNull(), "2", true] {
            var entry: [String: Any] = ["id": "1234567", "courseName": "测试课程"]
            entry["signStatus"] = status
            let course = try XCTUnwrap(ResponseParser.scheduledCourses([entry], day: "20260916").first)
            XCTAssertEqual(course.signStatusKnown, false)
        }
        let data = Data(#"{"id":"1234567","uuid":"","name":"旧缓存","teacher":"","beginTime":"08:30","endTime":"10:10","day":"20260916","signed":false}"#.utf8)
        let legacy = try JSONDecoder().decode(Course.self, from: data)
        XCTAssertNil(legacy.signStatusKnown)
    }
    func testEvidencePersistenceRetainsProtectionAndInvalidation() throws {
        let state = AttendanceEvidence(observedAt: now).observing(.signed, source: .submission, now: now)
        let cache = AttendanceEvidenceCache(accountID: "a", states: ["20260916|1234567": state], invalidatedCourses: ["course-1"])
        let decoded = try JSONDecoder().decode(AttendanceEvidenceCache.self, from: JSONEncoder().encode(cache))
        XCTAssertEqual(decoded.states["20260916|1234567"], state)
        XCTAssertEqual(decoded.invalidatedCourses, ["course-1"])
    }
}
