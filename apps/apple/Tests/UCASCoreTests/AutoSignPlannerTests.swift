import XCTest
@testable import UCASCore

final class AutoSignPlannerTests: XCTestCase {
    private struct PlanCase: Decodable {
        let name: String
        let start: String
        let end: String
        let now: String
        let running: Bool
        let courseEnabled: String
        let courseOffset: Int?
        let occurrenceEnabled: Bool?
        let expectedAt: String
        let expectedStage: String
        let enabledSince: String?
        let expectedParticipating: Bool?
    }

    func testSharedPlanCasesMatchDotNet() throws {
        let location = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../shared/fixtures/auto-sign-plans.json").standardizedFileURL
        let cases = try JSONDecoder().decode([PlanCase].self, from: Data(contentsOf: location))
        for item in cases {
            let course = Course(id: "1234567", name: "示例课程", beginTime: item.start,
                                endTime: item.end, day: "20260916")
            let now = try XCTUnwrap(CourseTime.parse(day: course.day, time: item.now))
            let plan = try XCTUnwrap(AutoSignPlanner.plan(account: "a", course: course, accountPolicy: .init(),
                courseRule: item.courseOffset.map { .init(offsetMinutes: $0) },
                occurrence: item.occurrenceEnabled.map { .init(enabled: $0) },
                running: item.running,
                courseEnabled: PreferenceOverride(rawValue: item.courseEnabled)!, signDisabled: false, now: now,
                runningSince: item.enabledSince.flatMap { CourseTime.parse(day: course.day, time: $0) }))
            let components = CourseTime.calendar.dateComponents([.hour, .minute], from: plan.plannedAt)
            XCTAssertEqual(String(format: "%02d:%02d", components.hour!, components.minute!), item.expectedAt, item.name)
            XCTAssertEqual(plan.stage.rawValue, item.expectedStage, item.name)
            if let expected = item.expectedParticipating { XCTAssertEqual(plan.isParticipating, expected, item.name) }
        }
    }

    func testEnableBoundarySkipsPastPlansButAllowsExactTime() throws {
        let course = Course(id: "1234567", name: "课程", beginTime: "08:30", endTime: "10:00", day: "20260916")
        let at = try XCTUnwrap(CourseTime.parse(day: course.day, time: "08:25"))
        func plan(since: Date) throws -> AutoSignPlan {
            try XCTUnwrap(AutoSignPlanner.plan(account: "a", course: course, accountPolicy: .init(),
                courseRule: nil, occurrence: nil, running: true,
                courseEnabled: .inherit, signDisabled: false, now: at.addingTimeInterval(240), runningSince: since))
        }
        XCTAssertEqual(try plan(since: at.addingTimeInterval(1)).stage, .skipped)
        XCTAssertFalse(try plan(since: at.addingTimeInterval(1)).isParticipating)
        XCTAssertEqual(try plan(since: at).stage, .missed)
        XCTAssertTrue(try plan(since: at).isParticipating)
    }

    func testParticipationBoundaryIncludesCourseRestoreOccurrenceAndPause() throws {
        let course = Course(id: "1234567", name: "课程", beginTime: "08:30", endTime: "10:00", day: "20260916")
        let at = try XCTUnwrap(CourseTime.parse(day: course.day, time: "08:25"))
        for source in 0..<3 {
            let plan = try XCTUnwrap(AutoSignPlanner.plan(account: "a", course: course, accountPolicy: .init(),
                courseRule: nil, occurrence: source == 1 ? .init(enabled: true, enabledSince: at.addingTimeInterval(1)) : nil,
                running: true, courseEnabled: .inherit, signDisabled: false, now: at,
                courseEnabledSince: source == 0 ? at.addingTimeInterval(1) : nil,
                pausedUntil: source == 2 ? at.addingTimeInterval(1) : nil))
            XCTAssertEqual(plan.stage, .skipped)
            XCTAssertFalse(plan.isParticipating)
        }
    }

    func testHistoryEligibilitySeparatesManualTakeoverFromExecution() throws {
        let course = Course(id: "1234567", name: "课程", beginTime: "08:30", endTime: "10:00", day: "20260916")
        let now = try XCTUnwrap(course.startDate)
        var value = AutoSignExecution(key: "a|20260916|1234567", now: now)
        XCTAssertTrue(value.events.isEmpty)
        XCTAssertFalse(value.hasExecutionActivity)
        value.transition(.skipped, now: now, message: "用户已手动接管", kind: .manualTakeover)
        XCTAssertFalse(value.hasExecutionActivity)
        XCTAssertFalse(value.isPurePreview)
        value.begin(course: course, now: now)
        XCTAssertTrue(value.hasExecutionActivity)
        XCTAssertEqual(value.courseName, "课程")
        XCTAssertEqual(value.classStartAt, course.startDate)
        let count = value.events.count
        value.begin(course: course, now: now)
        XCTAssertEqual(value.events.count, count)
    }

    @MainActor
    func testV1MigrationCleansOnlyKnownPreviewAndPreservesEvidence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        var preview = AutoSignExecution(key: "preview", now: now)
        preview.events = [.init(at: now, stage: .planned, message: "计划已生成"),
                          .init(at: now, stage: .skipped, message: "计划已暂停或跳过：自动签到未启用")]
        var missed = AutoSignExecution(key: "missed", now: now)
        missed.events = [.init(at: now, stage: .missed, message: "已错过自动执行时间，请手动处理")]
        var unknown = AutoSignExecution(key: "unknown", now: now)
        unknown.events = [.init(at: now, stage: .planned, message: "旧版未知事件")]
        var evidence = AutoSignExecution(key: "evidence", now: now)
        evidence.submissions = 2; evidence.lastSubmissionAt = now; evidence.negativeReads = 1; evidence.firstNegativeAt = now
        var takeover = AutoSignExecution(key: "takeover", now: now)
        takeover.events = [.init(at: now, stage: .skipped, message: "用户已手动接管")]
        var stageOnly = AutoSignExecution(key: "stageOnly", now: now)
        stageOnly.events = preview.events
        stageOnly.stage = .missed
        let path = directory.appendingPathComponent("61.json")
        let value = AutoSignLedger(accountID: "a", executions: ["preview": preview, "missed": missed,
                                                             "unknown": unknown, "evidence": evidence, "takeover": takeover,
                                                             "stageOnly": stageOnly])
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        legacy["version"] = 1
        try JSONSerialization.data(withJSONObject: legacy).write(to: path)
        let loaded = try FileAutoSignStore(directory: directory).load(accountID: "a")
        XCTAssertNil(loaded["preview"])
        XCTAssertEqual(loaded.count, 5)
        XCTAssertEqual(loaded["evidence"]?.submissions, 2)
        XCTAssertTrue(loaded["missed"]!.hasExecutionActivity)
        XCTAssertTrue(loaded["unknown"]!.hasExecutionActivity)
        XCTAssertFalse(loaded["takeover"]!.hasExecutionActivity)
        XCTAssertTrue(loaded["stageOnly"]!.hasExecutionActivity)
        var oldReal = loaded["stageOnly"]!
        oldReal.begin(course: .init(id: "1234567", name: "课程", beginTime: "08:30", endTime: "10:00", day: "20260916"), now: now)
        XCTAssertNil(oldReal.startedAt, "已有真实旧状态不能补造执行起点")
        let migrated = try JSONDecoder().decode(AutoSignLedger.self, from: Data(contentsOf: path))
        XCTAssertEqual(migrated.version, 2)
        XCTAssertNil(migrated.executions["preview"])
        try FileAutoSignStore(directory: directory).save(accountID: "a", executions: loaded)
        XCTAssertEqual(try FileAutoSignStore(directory: directory).load(accountID: "a")["evidence"]?.submissions, 2,
                       "无事件的旧提交证据也不能在下一次保存时丢失")
    }

    @MainActor
    func testDamagedLedgerIsNotOverwritten() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("61.json")
        let damaged = Data("broken-record".utf8)
        try damaged.write(to: path)
        XCTAssertThrowsError(try FileAutoSignStore(directory: directory).load(accountID: "a"))
        XCTAssertEqual(try Data(contentsOf: path), damaged)
    }

    @MainActor
    func testFailedMigrationWritePreservesOriginalLedger() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let path = directory.appendingPathComponent("61.json")
        let original = Data("{\"version\":1,\"accountID\":\"a\",\"executions\":{}}".utf8)
        try original.write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        XCTAssertThrowsError(try FileAutoSignStore(directory: directory).load(accountID: "a"))
        XCTAssertEqual(try Data(contentsOf: path), original)
    }

    @MainActor
    func testInvalidExecutionStructureIsRejectedBeforeMigrationAndSave() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("61.json")
        let store = FileAutoSignStore(directory: directory)
        for invalid in 0..<6 {
            var execution = AutoSignExecution(key: "task", now: .now)
            switch invalid {
            case 0: execution.submissions = -1
            case 1: execution.submissions = 4; execution.lastSubmissionAt = .now
            case 2: execution.submissions = 1
            case 3: execution.negativeReads = 1
            case 4: execution.negativeReads = 3; execution.firstNegativeAt = .now
            default: execution.lastSubmissionAt = .now
            }
            let value = AutoSignLedger(accountID: "a", executions: ["task": execution])
            var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
            legacy["version"] = 1
            let original = try JSONSerialization.data(withJSONObject: legacy)
            try original.write(to: path)
            XCTAssertThrowsError(try store.load(accountID: "a"))
            XCTAssertEqual(try Data(contentsOf: path), original)
            XCTAssertThrowsError(try store.save(accountID: "a", executions: ["task": execution]))
            XCTAssertEqual(try Data(contentsOf: path), original)
        }
        XCTAssertThrowsError(try store.save(accountID: "a", executions: ["wrong-key": .init(key: "task", now: .now)]))
    }
}
