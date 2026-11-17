import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import UCASCore

private let sessionFixture = #"{"STATUS":"0","result":{"id":"student-id","sessionId":"session-secret","studentNo":"2026123456"}}"#
private let courseFixture = #"{"id":"1234567","uuid":"550e8400-e29b-41d4-a716-446655440000","courseName":"高等数学","teacherName":"张老师","classroomName":" 教一楼002 \n","classBeginTime":"08:00","classEndTime":"09:40","signStatus":"0"}"#
private let testSession = SchoolSession(userId: "student-id", sessionId: "session-secret", studentNo: "2026123456")

final class QingxinServiceTests: XCTestCase {
    func testLoginUsesConfirmedFormAndEscapesReservedCharacters() async throws {
        let transport = FixtureTransport([sessionFixture])
        let service = QingxinService(transport: transport)
        let session = try await service.login(username: " student@ucas.ac.cn ", password: "A+B &=%中文")
        XCTAssertEqual(session, testSession)
        let requests = await transport.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://iclass.ucas.edu.cn:8181/app/user/login.action")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertNil(request.value(forHTTPHeaderField: "sessionId"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "student_5.0.1.2_android_12_20__110000")
        let form = decodeForm(request.httpBody)
        XCTAssertEqual(form["phone"], "student@ucas.ac.cn")
        XCTAssertEqual(form["password"], "A+B &=%中文")
        XCTAssertEqual(form["verificationType"], "1")
        XCTAssertEqual(form["userLevel"], "1")
        XCTAssertEqual(form["verificationUrl"], "http://iclass.ucas.edu.cn:88/ve/webservices/mobileCheck.shtml?method=mobileLogin&username=${0}&password=${1}&lx=${2}")
    }

    func testResumeUsesIdentityOnlyAndIncompleteSessionIsRejected() async throws {
        let transport = FixtureTransport([sessionFixture, #"{"STATUS":0,"result":{"id":"user","sessionId":"token"}}"#])
        let service = QingxinService(transport: transport)
        _ = try await service.resumeSession(identity: "2026123456")
        let requests = await transport.requests
        let form = decodeForm(requests[0].httpBody)
        XCTAssertEqual(form["verificationType"], "2")
        XCTAssertEqual(form["password"], "")
        XCTAssertEqual(form["verificationUrl"], "")
        do {
            _ = try await service.login(username: "user", password: "password")
            XCTFail("Incomplete session was accepted")
        } catch let error as APIError { XCTAssertEqual(error.code, "LOGIN_BAD_RESPONSE") }
    }

    func testLoginRetainsSchoolRealNameSeparatelyFromAccount() async throws {
        let transport = FixtureTransport([#"{"STATUS":"0","result":{"id":"student-id","sessionId":"session-secret","studentNo":"2026123456","realName":"  林清 \n","userName":"2026123456","nickName":"测试昵称"}}"#])
        let session = try await QingxinService(transport: transport).login(username: "student@ucas.ac.cn", password: "password")
        XCTAssertEqual(session.name, "林清")
        XCTAssertEqual(session.studentNo, "2026123456")
    }

    func testMissingOrMalformedRealNameDoesNotBecomeAccountOrNickname() throws {
        for name in ["null", "42", "true", #""   ""#, "{}"] {
            let payload = #"{"STATUS":"0","result":{"id":"student-id","sessionId":"session-secret","studentNo":"2026123456","userName":"2026123456","nickName":"测试昵称","realName":\#(name)}}"#
            XCTAssertNil(try ResponseParser.session(json(payload)).name)
        }
        XCTAssertNil(try ResponseParser.session(json(sessionFixture)).name)
    }

    func testStoredSessionsRemainCompatibleAndPreserveName() throws {
        let legacy = Data(#"{"userId":"student-id","sessionId":"session-secret","studentNo":"2026123456"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(SchoolSession.self, from: legacy), testSession)
        let namedSession = SchoolSession(userId: "student-id", sessionId: "session-secret", studentNo: "2026123456", name: "林清")
        let restored = try JSONDecoder().decode(SchoolSession.self, from: JSONEncoder().encode(namedSession))
        XCTAssertEqual(restored, namedSession)
    }

    func testDailyScheduleUsesSessionHeaderAndShanghaiDate() async throws {
        let transport = FixtureTransport(["{\"STATUS\":0,\"result\":[\(courseFixture)]}"])
        let service = QingxinService(transport: transport)
        let date = try XCTUnwrap(CourseTime.parse(day: "20260915", time: "00:15"))
        let result = try await service.courses(session: testSession, date: date)
        XCTAssertEqual(result.courses.first?.name, "高等数学")
        XCTAssertEqual(result.courses.first?.classroom, "教一楼002")
        XCTAssertFalse(result.fromWeeklyFallback)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "sessionId"), "session-secret")
        XCTAssertEqual(decodeForm(requests[0].httpBody), ["id": "student-id", "dateStr": "20260915"])
    }

    func testWeeklyFallbackSupportsObservedStatusAmbiguityWithValidShape() async throws {
        for status in ["0", "1"] {
            let transport = FixtureTransport([#"{"STATUS":"0","result":[]}"#, "{\"STATUS\":\"\(status)\",\"result\":[{\"dateStr\":\"2026-09-16\",\"schedData\":[\(courseFixture)]}]}"])
            let service = QingxinService(transport: transport)
            let result = try await service.courses(session: testSession, date: sampleCourse().startDate!)
            XCTAssertTrue(result.fromWeeklyFallback)
            XCTAssertEqual(result.courses.first?.day, "20260916")
            XCTAssertEqual(result.courses.first?.classroom, "教一楼002")
            let requests = await transport.requests
            XCTAssertEqual(requests.last?.url?.path, "/app/course/get_stu_course_sched_week.action")
        }
    }

    func testMissingOrMalformedClassroomDoesNotPreventLoadingCourse() throws {
        var entry = try json(courseFixture)
        for value: Any in [NSNull(), "", " \n\t", 42, true, ["name": "教一楼002"], ["教一楼002"]] {
            entry["classroomName"] = value
            let courses = try ResponseParser.scheduledCourses([entry], day: "20260915")
            XCTAssertEqual(courses.count, 1)
            XCTAssertNil(courses.first?.classroom)
            XCTAssertEqual(courses.first?.teacher, "张老师")
        }
        entry.removeValue(forKey: "classroomName")
        XCTAssertNil(try ResponseParser.scheduledCourses([entry], day: "20260915").first?.classroom)
    }

    func testCourseCacheRemainsCompatibleAndPreservesClassroom() throws {
        let legacy = Data(#"{"id":"1234567","uuid":"","name":"高等数学","teacher":"张老师","beginTime":"08:00","endTime":"09:40","day":"20260915","signed":false}"#.utf8)
        let restored = try JSONDecoder().decode(Course.self, from: legacy)
        XCTAssertNil(restored.classroom)
        XCTAssertNil(restored.courseId)
        XCTAssertEqual(restored.name, "高等数学")
        let course = try XCTUnwrap(ResponseParser.scheduledCourses([json(courseFixture)], day: "20260915").first)
        let cached = try JSONDecoder().decode(Course.self, from: JSONEncoder().encode(course))
        XCTAssertEqual(cached, course)
        XCTAssertEqual(cached.classroom, "教一楼002")
    }

    func testSemesterCatalogAndAttendanceRequestsUseObservedContracts() async throws {
        let semesters = #"{"STATUS":"0","result":[{"code":"2026202701","name":"2026-2027秋季学期","beginDate":"2026-08-31","endDate":"2027-01-31","yearStatus":"1"}]}"#
        let catalog = #"{"STATUS":"0","total":1,"result":[{"course_id":"course-a","courseNum":"CS6001","course_name":"高级人工智能","teacher_name":"陈老师","course_address":"教学楼 A101","semesterId":"2026202701","course_beignDate":"2026-08-31","course_endDate":"2027-01-31","jc_num":"16","jc_num_studyed":"3"}]}"#
        let attendance = #"{"STATUS":"0","mySignNum":"1","myNoSignNum":"1","result":[{"id":"record-a","courseId":"course-a","courseSchedId":"1234567","teachTime":"20260920","signStatus":"1","classBeginTime":"2026-09-20 09:20:00","classEndTime":"2026-09-20 12:00:00"},{"id":"record-b","courseId":"course-a","courseSchedId":"1234568","teachTime":"20260927","signStatus":"0","classBeginTime":"2026-09-27 09:20:00","classEndTime":"2026-09-27 12:00:00"}]}"#
        let transport = FixtureTransport([semesters, catalog, attendance])
        let service = QingxinService(transport: transport)

        let terms = try await service.semesters(session: testSession)
        let courses = try await service.catalogCourses(session: testSession, semesterId: terms[0].id)
        let summary = try await service.courseAttendance(session: testSession, courseId: courses[0].id)

        XCTAssertTrue(terms[0].isCurrent)
        XCTAssertEqual(courses[0].number, "CS6001")
        XCTAssertEqual(courses[0].totalSessions, 16)
        XCTAssertEqual(summary.signedCount, 1)
        XCTAssertEqual(summary.unsignedCount, 1)
        XCTAssertEqual(summary.records.map(\.scheduledCourseId), ["1234567", "1234568"])
        let requests = await transport.requests
        XCTAssertEqual(requests.map { $0.url!.path }, [
            "/app/course/get_base_school_year.action",
            "/app/choosecourse/get_myall_course.action",
            "/app/my/get_my_course_sign_detail.action"
        ])
        XCTAssertEqual(URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "1")
        XCTAssertEqual(decodeForm(requests[0].httpBody), ["userId": "student-id", "type": "2"])
        XCTAssertEqual(decodeForm(requests[1].httpBody), ["id": "student-id", "xq_code": "2026202701"])
        XCTAssertEqual(decodeForm(requests[2].httpBody), ["id": "student-id", "courseId": "course-a"])
    }

    func testCatalogRejectsSemesterMismatchAndAttendanceRejectsWrongCourse() throws {
        XCTAssertThrowsError(try ResponseParser.catalogCourses(json(#"{"STATUS":"0","result":[{"course_id":"a","course_name":"课程","semesterId":"other"}]}"#), semesterId: "current"))
        XCTAssertThrowsError(try ResponseParser.courseAttendance(json(#"{"STATUS":"0","result":[{"id":"r","courseId":"other","courseSchedId":"1234567","teachTime":"20260920"}]}"#), courseId: "expected"))
    }

    func testScheduledCourseKeepsStableCourseIdSeparateFromSignId() throws {
        var entry = try json(courseFixture)
        entry["courseId"] = "stable-course"
        let course = try XCTUnwrap(ResponseParser.scheduledCourses([entry], day: "20260915").first)
        XCTAssertEqual(course.id, "1234567")
        XCTAssertEqual(course.courseId, "stable-course")
    }

    func testWeeklyErrorsAndMalformedPayloadsAreNeverAnEmptySchedule() async throws {
        for payload in [#"{"STATUS":"-1","result":[]}"#, #"{"STATUS":"1","ERRCODE":"42","result":[]}"#, #"{"STATUS":"1","ERRMSG":"拒绝访问","result":[]}"#, #"{"STATUS":"1","result":[{"dateStr":"20260915"}]}"#, #"{"STATUS":"1","result":[{"dateStr":"20260230","schedData":[]}]}"#] {
            let transport = FixtureTransport([#"{"STATUS":"0","result":[]}"#, payload])
            do {
                _ = try await QingxinService(transport: transport).courses(session: testSession, date: sampleCourse().startDate!)
                XCTFail("Invalid schedule accepted: \(payload)")
            } catch is APIError { }
        }
    }

    func testExpiredSessionDoesNotFallBackOrResubmit() async throws {
        let transport = FixtureTransport([#"{"STATUS":"1","ERRMSG":"登录已过期，请重新登录"}"#])
        do {
            _ = try await QingxinService(transport: transport).courses(session: testSession)
            XCTFail("Expired session accepted")
        } catch let error as APIError { XCTAssertTrue(error.isSessionExpired) }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testSignRequestUsesSchoolTimeAndStrictSuccess() async throws {
        let transport = FixtureTransport([#"{"STATUS":"0","timestamp":1789430400000}"#, #"{"STATUS":"0","ERRCODE":"0","success":true,"result":{"stuSignStatus":"1","stuSignId":"record"}}"#])
        let service = QingxinService(transport: transport, now: { Date(timeIntervalSince1970: 100) })
        let result = try await service.sign(course: sampleCourse(), session: testSession)
        XCTAssertEqual(result.outcome, .signed)
        XCTAssertEqual(result.stuSignId, "record")
        let requests = await transport.requests
        let request = requests[1]
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "sessionId"), "session-secret")
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value!) }), ["courseSchedId": "1234567", "timestamp": "1789430400000", "id": "student-id"])
    }

    func testUnclearSignReconcilesSuccessWithoutResubmitting() async throws {
        let transport = FixtureTransport([clockFixture, "{}", signState("1")])
        let result = try await retryService(transport).sign(course: sampleCourse(), session: testSession)
        XCTAssertEqual(result.outcome, .signed)
        let requests = await transport.requests
        XCTAssertEqual(requests.filter { $0.url!.path.hasSuffix("stu_scan_sign.action") }.count, 1)
        XCTAssertEqual(requests.count, 3)
    }

    func testUnclearSignRetriesOnlyAfterTwoUnsignedReadsAndUsesNewClock() async throws {
        let transport = FixtureTransport([clockFixture, "{}", signState("0"), signState("0"),
                                          #"{"STATUS":"0","timestamp":1789430405000}"#, signSuccess])
        let counter = await AuthorizationCounter()
        let result = try await retryService(transport).sign(course: sampleCourse(), session: testSession,
                                                            authorizeSubmission: { counter.count += 1 })
        XCTAssertEqual(result.outcome, .signed)
        let requests = await transport.requests
        XCTAssertEqual(requests.map { $0.url!.lastPathComponent }, ["get_timestamp.do", "stu_scan_sign.action",
            "get_stu_course_sched.action", "get_stu_course_sched.action", "get_timestamp.do", "stu_scan_sign.action"])
        XCTAssertTrue(requests.last!.url!.absoluteString.contains("timestamp=1789430405000"))
        let authorizations = await counter.count
        XCTAssertEqual(authorizations, 2)
    }

    func testUnknownOrMissingAttendanceNeverAuthorizesRetry() async throws {
        for state in ["{}", #"{"STATUS":"0","result":[]}"#,
                      #"{"STATUS":"0","result":[{"id":"7654321","signStatus":"0"}]}"#,
                      #"{"STATUS":"0","result":[{"id":"1234567","signStatus":false}]}"#,
                      #"{"STATUS":"0","success":false,"result":[{"id":"1234567","signStatus":"0"}]}"#,
                      #"{"STATUS":"0","result":[{"id":"1234567","signStatus":"0"},{"id":"1234567","signStatus":"1"}]}"#,
                      "bad gateway"] {
            let transport = FixtureTransport([clockFixture, "{}", state])
            let result = try await retryService(transport).sign(course: sampleCourse(), session: testSession)
            XCTAssertEqual(result.outcome, .unknown)
            let requests = await transport.requests
            XCTAssertEqual(requests.count, 3, state)
        }
    }

    func testSecondReadCanConfirmDelayedSuccess() async throws {
        let transport = FixtureTransport([clockFixture, "{}", signState("0"), signState("1")])
        let result = try await retryService(transport).sign(course: sampleCourse(), session: testSession)
        XCTAssertEqual(result.outcome, .signed)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 4)
    }

    func testSubmissionRetryLimitAndScheduledSubmissionBudget() async throws {
        for retry in [true, false] {
            let attempts = retry ? 3 : 1
            let transport = FixtureTransport(Array(repeating: [clockFixture, "{}", signState("0"), signState("0")], count: attempts).flatMap { $0 })
            let result = try await retryService(transport).sign(course: sampleCourse(), session: testSession, retryUnconfirmed: retry)
            XCTAssertEqual(result.outcome, .unknown)
            let requests = await transport.requests
            XCTAssertEqual(requests.filter { $0.url!.path.hasSuffix("stu_scan_sign.action") }.count, attempts)
            XCTAssertEqual(requests.count, retry ? attempts * 4 : 2)
        }
    }

    func testTimestampRejectionForcesCalibrationBeforeRetry() async throws {
        let rejected = #"{"STATUS":"1","ERRCODE":"100","ERRMSG":"时间戳传入异常！"}"#
        XCTAssertEqual(ResponseParser.sign(try json(rejected)).outcome, .timestampRejected)
        let transport = FixtureTransport([clockFixture, rejected, #"{"STATUS":"0","timestamp":1789430405000}"#, signSuccess])
        let result = try await retryService(transport).sign(course: sampleCourse(), session: testSession)
        XCTAssertEqual(result.outcome, .signed)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 4)
        XCTAssertTrue(requests[3].url!.absoluteString.contains("timestamp=1789430405000"))
    }

    func testRetryRechecksAuthorizationAndSchoolSignWindow() async throws {
        let counter = await AuthorizationCounter()
        let transport = FixtureTransport([clockFixture, "{}", signState("0"), signState("0"), clockFixture])
        let result = try await retryService(transport).sign(course: sampleCourse(), session: testSession, authorizeSubmission: {
            counter.count += 1
            if counter.count > 1 { throw APIError(code: "SIGN_NOT_ALLOWED", message: "已停用") }
        })
        XCTAssertEqual(result.outcome, .unknown)
        let requests = await transport.requests
        XCTAssertEqual(requests.filter { $0.url!.path.hasSuffix("stu_scan_sign.action") }.count, 1)
        let ended = FixtureTransport([clockFixture, "{}", signState("0"), signState("0"), #"{"STATUS":"0","timestamp":1789437600000}"#])
        let endedResult = try await retryService(ended).sign(course: sampleCourse(), session: testSession)
        XCTAssertEqual(endedResult.outcome, .unknown)
        let endedRequests = await ended.requests
        XCTAssertEqual(endedRequests.count, 5)
    }

    func testClockTransientFailureRetriesAndDoesNotIncludeBackoffInClockOffset() async throws {
        let clock = TestClock()
        let transport = FixtureTransport(["bad gateway", clockFixture], onResponse: { clock.advance(0.2) })
        let service = QingxinService(transport: transport, now: { clock.date }, retryDelay: { clock.advance($0) })
        let timestamp = try await service.schoolNow()
        XCTAssertEqual(timestamp.timeIntervalSince1970, 1789430400.1, accuracy: 0.001)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
    }

    func testCancellationDuringVerificationNeverResubmits() async throws {
        let transport = FixtureTransport([clockFixture, "{}"])
        let service = QingxinService(transport: transport, retryDelay: { _ in throw CancellationError() })
        do {
            _ = try await service.sign(course: sampleCourse(), session: testSession)
            XCTFail("Cancellation ignored")
        } catch is CancellationError { }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
    }

    func testLostNetworkResponseChecksStateWithoutResubmitting() async throws {
        let transport = FixtureTransport([clockFixture, signState("1")], failures: [2: .networkConnectionLost])
        let result = try await retryService(transport).sign(course: sampleCourse(), session: testSession)
        XCTAssertEqual(result.outcome, .signed)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests.filter { $0.url!.path.hasSuffix("stu_scan_sign.action") }.count, 1)
    }

    func testExplicitRefusalsAndExpiredSessionAreNotRetried() async throws {
        for message in ["未在上课时间", "请使用扫码签到", "用户不存在"] {
            let transport = FixtureTransport([clockFixture, #"{"STATUS":"1","ERRMSG":"\#(message)"}"#])
            let result = try await retryService(transport).sign(course: sampleCourse(), session: testSession)
            XCTAssertEqual(result.outcome, .outsideSignWindow)
            let requests = await transport.requests
            XCTAssertEqual(requests.count, 2)
        }
        let transport = FixtureTransport([clockFixture, #"{"ERRCODE":"401"}"#])
        do {
            _ = try await retryService(transport).sign(course: sampleCourse(), session: testSession)
            XCTFail("Expired session accepted")
        } catch let error as APIError { XCTAssertTrue(error.isSessionExpired) }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
    }

    func testUnclearResponseRetainsSchoolExplanation() throws {
        let result = ResponseParser.sign(try json(#"{"STATUS":"1","ERRMSG":"学校服务繁忙"}"#))
        XCTAssertEqual(result.outcome, .unknown)
        XCTAssertTrue(result.message.contains("学校服务繁忙"))
    }

    func testAmbiguousOrContradictoryResponsesNeverClaimSuccess() throws {
        for payload in [#"{}"#, #"{"STATUS":"0"}"#, #"{"STATUS":"0","result":{"stuSignStatus":"0"}}"#, #"{"STATUS":"1","result":{"stuSignStatus":"1"}}"#, #"{"STATUS":"0","ERRCODE":"5","result":{"stuSignStatus":"1"}}"#, #"{"STATUS":"0","success":false,"result":{"stuSignStatus":"1"}}"#, #"{"STATUS":"0","success":"true","result":{"stuSignStatus":"1"}}"#] {
            XCTAssertEqual(ResponseParser.sign(try json(payload)).outcome, .unknown)
        }
        XCTAssertEqual(ResponseParser.sign(try json(#"{"STATUS":"0","result":{"stuSignStatus":"1","msg":"二维码已过期"}}"#)).outcome, .qrExpired)
        XCTAssertEqual(ResponseParser.sign(try json(#"{"STATUS":"0","result":{"stuSignStatus":"1","msg":"重复签到"}}"#)).outcome, .outsideSignWindow)
        XCTAssertEqual(ResponseParser.sign(try json(#"{"STATUS":"0","result":{"stuSignStatus":1}}"#)).outcome, .signed)
    }

    func testTimestampRejectsStringsBooleansAndSeconds() throws {
        for payload in [#"{"STATUS":"0","timestamp":"1789430400000"}"#, #"{"STATUS":"0","timestamp":true}"#, #"{"STATUS":"0","timestamp":1789430400}"#, #"{"STATUS":"0","timestamp":1789430400000.5}"#, #"{"STATUS":"1","timestamp":1789430400000}"#] {
            XCTAssertThrowsError(try ResponseParser.timestamp(json(payload)))
        }
    }

    func testQRIdentifierCanonicalizationAndNoStudentIdentity() throws {
        let url = try QingxinService.qrURL(identifier: "550e8400-e29b-41d4-a716-446655440000", timestampMs: 1789430400000)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(items.map(\.name), ["timeTableId", "timestamp"])
        XCTAssertEqual(items[0].value, "550E8400E29B41D4A716446655440000")
        for identifier in ["", "123456", "12345678", "<script>", "https://example.com", "550e8400-e29b-41d4-a716-44665544000g"] {
            XCTAssertThrowsError(try QingxinService.qrURL(identifier: identifier, timestampMs: 1))
        }
    }

    func testQRRefreshCapsAtFiveSecondsAndShortensAtThirtySecondBoundary() async throws {
        let clock = TestClock()
        let transport = FixtureTransport([#"{"STATUS":"0","timestamp":1789430400000}"#, #"{"STATUS":"0","timestamp":1789430430000}"#], onResponse: { clock.advance(0.2) })
        let service = QingxinService(transport: transport, now: { clock.date })
        let first = try await service.qr(course: sampleCourse())
        XCTAssertEqual(first.schoolTimestampMs, 1789430400100)
        XCTAssertEqual(first.validityDuration, 5)
        clock.advance(29)
        let nearExpiry = try await service.qr(course: sampleCourse())
        XCTAssertEqual(nearExpiry.validityDuration, 1, accuracy: 0.0001)
        XCTAssertEqual(nearExpiry.schoolTimestampMs, 1789430429100)
        clock.advance(1)
        let renewed = try await service.qr(course: sampleCourse())
        XCTAssertEqual(renewed.validityDuration, 5)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].url?.absoluteString, "https://iclass.ucas.edu.cn:8181/app/common/get_timestamp.do?id=0")
        XCTAssertEqual(requests[0].httpMethod, "POST")
        XCTAssertEqual(first.remainingSeconds(at: first.expiresAt), 0)
    }

    func testClockReversalTriggersNewSchoolSample() async throws {
        let clock = TestClock()
        let transport = FixtureTransport([#"{"STATUS":"0","timestamp":1789430400000}"#, #"{"STATUS":"0","timestamp":1789430405000}"#])
        let service = QingxinService(transport: transport, now: { clock.date })
        _ = try await service.qr(course: sampleCourse())
        clock.advance(-10)
        let renewed = try await service.qr(course: sampleCourse())
        XCTAssertEqual(renewed.schoolTimestampMs, 1789430405000)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
    }

    func testConcurrentQRAndSchoolTimeShareOneClockRequest() async throws {
        let transport = FixtureTransport([#"{"STATUS":"0","timestamp":1789430400000}"#], delayNanoseconds: 10_000_000)
        let service = QingxinService(transport: transport, now: { Date(timeIntervalSince1970: 100) })
        async let first = service.qr(course: sampleCourse())
        async let second = service.schoolNow()
        let (qr, schoolNow) = try await (first, second)
        XCTAssertEqual(qr.schoolTimestampMs, 1789430400000)
        XCTAssertEqual(schoolNow.timeIntervalSince1970, 1789430400)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testHTTPAuthenticationFailureIsActionableAndInvalidJSONIsRejected() async throws {
        for (status, payload, expected) in [(401, "{}", "HTTP_401"), (403, "{}", "HTTP_403"), (502, "bad gateway", "HTTP_502"), (200, "<html>sign in</html>", "BAD_RESPONSE")] {
            let transport = FixtureTransport([payload], status: status)
            do {
                _ = try await QingxinService(transport: transport).login(username: "user", password: "password")
                XCTFail("Bad response accepted")
            } catch let error as APIError { XCTAssertEqual(error.code, expected) }
        }
    }
}

private let clockFixture = #"{"STATUS":"0","timestamp":1789430400000}"#
private let signSuccess = #"{"STATUS":"0","result":{"stuSignStatus":"1"}}"#
private func signState(_ status: String) -> String {
    #"{"STATUS":"0","result":[{"id":"1234567","signStatus":"\#(status)"}]}"#
}
private func retryService(_ transport: FixtureTransport) -> QingxinService {
    QingxinService(transport: transport, now: { Date(timeIntervalSince1970: 100) }, retryDelay: { _ in })
}
@MainActor private final class AuthorizationCounter { var count = 0 }

private actor FixtureTransport: HTTPTransport {
    private var fixtures: [String]
    private let status: Int
    private let onResponse: @Sendable () -> Void
    private let delayNanoseconds: UInt64
    private let failures: [Int: URLError.Code]
    private(set) var requests: [URLRequest] = []

    init(_ fixtures: [String], status: Int = 200, delayNanoseconds: UInt64 = 0, failures: [Int: URLError.Code] = [:], onResponse: @escaping @Sendable () -> Void = {}) {
        self.fixtures = fixtures
        self.status = status
        self.onResponse = onResponse
        self.delayNanoseconds = delayNanoseconds
        self.failures = failures
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if let failure = failures[requests.count] { throw URLError(failure) }
        guard !fixtures.isEmpty else { throw URLError(.badServerResponse) }
        let value = fixtures.removeFirst()
        if delayNanoseconds > 0 { try await Task.sleep(nanoseconds: delayNanoseconds) }
        onResponse()
        return (Data(value.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!)
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 100_000)
    var date: Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; value.addTimeInterval(seconds) }
}

private func decodeForm(_ data: Data?) -> [String: String] {
    guard let data, let text = String(data: data, encoding: .utf8) else { return [:] }
    return Dictionary(uniqueKeysWithValues: text.split(separator: "&").map {
        let pair = $0.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        return (String(pair[0]).removingPercentEncoding!, String(pair[1]).removingPercentEncoding!)
    })
}

private func json(_ value: String) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Data(value.utf8)) as! [String: Any]
}
