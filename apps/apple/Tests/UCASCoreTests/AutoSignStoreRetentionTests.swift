import XCTest
@testable import UCASCore

@MainActor
final class AutoSignStoreRetentionTests: XCTestCase {
    func testLegacyExecutionWithoutHistoryDiscardedFieldRemainsReadable() async throws {
        let json = Data(#"{"key":"legacy","submissions":0,"stage":"planned","negativeReads":0,"message":"等待计划时间","events":[]}"#.utf8)
        let value = try JSONDecoder().decode(AutoSignExecution.self, from: json)
        XCTAssertNil(value.historyDiscarded)
        XCTAssertEqual(value.key, "legacy")
        XCTAssertEqual(value.stage, .planned)
        XCTAssertFalse(value.hasExecutionActivity)
    }

    func testDiscardHistoryPreservesCompleteRuntimeEvidenceAndIsIdempotent() async throws {
        let date = Date(timeIntervalSince1970: 946_684_800)
        var value = evidence(key: "keep-runtime", at: date)
        value.transition(.retryWaiting, now: date, message: "旧的错误详情", nextAt: date.addingTimeInterval(120))
        var expected = value
        expected.courseName = nil
        expected.events = []
        expected.message = "历史已清理"
        expected.historyDiscarded = true

        value.discardHistory()
        XCTAssertEqual(value, expected, "Only display content and its marker may change")
        XCTAssertTrue(value.hasExecutionActivity)
        XCTAssertFalse(value.isPurePreview)
        value.discardHistory()
        XCTAssertEqual(value, expected)
    }

    func testDiscardedExecutionTransitionsWithoutRecreatingDisplayContent() async throws {
        let date = Date(timeIntervalSince1970: 946_684_800)
        var value = evidence(key: "keep-runtime", at: date)
        value.discardHistory()
        let wake = date.addingTimeInterval(240)
        value.transition(.verifying, now: date.addingTimeInterval(120), message: "后续核实详情", nextAt: wake)
        XCTAssertEqual(value.stage, .verifying)
        XCTAssertEqual(value.nextAt, wake)
        XCTAssertEqual(value.submissions, 2)
        XCTAssertEqual(value.negativeReads, 2)
        XCTAssertEqual(value.lastSchoolSubmissionAt, date)
        XCTAssertEqual(value.firstSchoolNegativeAt, date.addingTimeInterval(-30))
        XCTAssertEqual(value.nextSchoolVerificationAt, date.addingTimeInterval(120))
        XCTAssertTrue(value.events.isEmpty)
        XCTAssertNil(value.courseName)
        XCTAssertEqual(value.message, "历史已清理")
        XCTAssertEqual(value.historyDiscarded, true)
        value.transition(.signed, now: wake, message: "核实成功")
        XCTAssertEqual(value.stage, .signed)
        XCTAssertNil(value.nextSchoolVerificationAt)
        XCTAssertTrue(value.events.isEmpty)
        XCTAssertEqual(value.message, "历史已清理")
    }

    func testDiscardMarkerAndSafetyEvidenceSurviveBothStores() async throws {
        let suite = "AutoSignStoreRetentionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        var value = evidence(key: "receipt", at: Date(timeIntervalSince1970: 946_684_800))
        value.discardHistory()
        let stores: [any AutoSignStore] = [UserDefaultsAutoSignStore(defaults: defaults), FileAutoSignStore(directory: directory)]
        for store in stores {
            try store.save(accountID: "account", executions: [value.key: value])
            XCTAssertEqual(try store.load(accountID: "account"), [value.key: value])
        }
    }

    func testUserDefaultsKeepsOldHistoryWithoutAgeOrCountLimit() async throws {
        let suite = "AutoSignStoreRetentionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try assertUnrestrictedHistory(writer: UserDefaultsAutoSignStore(defaults: defaults),
                                      reader: UserDefaultsAutoSignStore(defaults: defaults))
    }

    func testFileStoreKeepsOldHistoryWithoutAgeOrCountLimit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try assertUnrestrictedHistory(writer: FileAutoSignStore(directory: directory),
                                      reader: FileAutoSignStore(directory: directory))
    }

    func testUserDefaultsRetainsOldUnfinishedWorkAndDuplicatePreventionEvidence() async throws {
        let suite = "AutoSignStoreRetentionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try assertExecutionEvidence(writer: UserDefaultsAutoSignStore(defaults: defaults),
                                    reader: UserDefaultsAutoSignStore(defaults: defaults))
    }

    func testFileStoreRetainsOldUnfinishedWorkAndDuplicatePreventionEvidence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try assertExecutionEvidence(writer: FileAutoSignStore(directory: directory),
                                    reader: FileAutoSignStore(directory: directory))
    }

    private func assertUnrestrictedHistory(writer: any AutoSignStore, reader: any AutoSignStore,
                                           file: StaticString = #filePath, line: UInt = #line) throws {
        var executions: [String: AutoSignExecution] = [:]
        let oldDate = Date(timeIntervalSince1970: 946_684_800)
        for index in 0..<150 {
            let date = oldDate.addingTimeInterval(Double(index * 86_400))
            let key = "old-success-\(index)"
            var value = evidence(key: key, at: date)
            value.transition(.signed, now: date.addingTimeInterval(60), message: "已签到")
            executions[key] = value
        }
        try writer.save(accountID: "account", executions: executions)
        XCTAssertEqual(try reader.load(accountID: "account"), executions, file: file, line: line)

        var recent = evidence(key: "recent-success", at: Date(timeIntervalSince1970: 1_800_000_000))
        recent.transition(.signed, now: Date(timeIntervalSince1970: 1_800_000_060), message: "已签到")
        executions[recent.key] = recent
        try writer.save(accountID: "account", executions: executions)
        XCTAssertEqual(try reader.load(accountID: "account"), executions,
                       "Saving new activity must not age out earlier history", file: file, line: line)
    }

    private func assertExecutionEvidence(writer: any AutoSignStore, reader: any AutoSignStore,
                                         file: StaticString = #filePath, line: UInt = #line) throws {
        let oldDate = Date(timeIntervalSince1970: 946_684_800)
        var executions: [String: AutoSignExecution] = [:]
        for stage: AutoSignStage in [.checking, .submitting, .verifying, .retryWaiting, .needsAttention, .signed] {
            var value = evidence(key: stage.rawValue, at: oldDate)
            value.transition(stage, now: oldDate.addingTimeInterval(10), message: stage.rawValue,
                             nextAt: oldDate.addingTimeInterval(120))
            executions[value.key] = value
        }
        var legacy = evidence(key: "legacy-receipt", at: oldDate)
        legacy.events = []
        legacy.startedAt = nil
        legacy.lastSchoolSubmissionAt = nil
        executions[legacy.key] = legacy
        var takeover = AutoSignExecution(key: "manual-takeover", now: oldDate)
        takeover.transition(.skipped, now: oldDate, message: "用户已手动接管", kind: .manualTakeover)
        executions[takeover.key] = takeover

        try writer.save(accountID: "account", executions: executions)
        let restored = try reader.load(accountID: "account")
        XCTAssertEqual(restored, executions,
                       "Submission receipts, retry counters, school-time evidence and cancellations have no age limit",
                       file: file, line: line)
        try writer.save(accountID: "account", executions: restored)
        XCTAssertEqual(try reader.load(accountID: "account"), executions, file: file, line: line)
    }

    private func evidence(key: String, at date: Date) -> AutoSignExecution {
        var value = AutoSignExecution(key: key, now: date)
        value.startedAt = date
        value.courseName = "保留课程"
        value.classStartAt = date.addingTimeInterval(-60)
        value.classEndAt = date.addingTimeInterval(3_600)
        value.submissions = 2
        value.lastSubmissionAt = date
        value.lastSchoolSubmissionAt = date
        value.nextSchoolVerificationAt = date.addingTimeInterval(120)
        value.firstNegativeAt = date.addingTimeInterval(-30)
        value.firstSchoolNegativeAt = date.addingTimeInterval(-30)
        value.negativeReads = 2
        return value
    }
}
