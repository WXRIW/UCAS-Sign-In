import Foundation
import XCTest
@testable import UCASCore

final class HistoryRetentionTests: XCTestCase {
    private struct Row {
        let id: String
        let date: Date
        var active = false
    }
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testDefaultKeepsEveryEntryRegardlessOfCountOrAge() throws {
        let rows = (0..<150).map { Row(id: String($0), date: now.addingTimeInterval(-Double(120 + $0) * 86_400)) }
        let retained = try HistoryRetentionPolicy().retained(rows, now: now, date: { $0.date }, id: { $0.id })
        XCTAssertEqual(retained.count, 150)
        let fields = try HistoryRetentionSettings().applicationPreferences()
        XCTAssertEqual(Set(fields.keys), Set(HistoryRetentionSettings.applicationKeys))
        XCTAssertTrue(fields.values.allSatisfy { $0 == Data("null".utf8) })
        XCTAssertEqual(try HistoryRetentionSettings.from(applicationPreferences: [:]), HistoryRetentionSettings())
    }

    func testCustomAgeThenCountHasStableTieOrderingAndInclusiveCutoff() throws {
        let rows = [Row(id: "old", date: now.addingTimeInterval(-4 * 86_400)),
                    Row(id: "b", date: now), Row(id: "a", date: now),
                    Row(id: "boundary", date: now.addingTimeInterval(-3 * 86_400))]
        let policy = HistoryRetentionPolicy(maxCount: 2, maxAgeDays: 3)
        XCTAssertEqual(try policy.retained(rows, now: now, date: { $0.date }, id: { $0.id }).map(\.id), ["a", "b"])
        XCTAssertEqual(try HistoryRetentionPolicy(maxAgeDays: 3).retained(rows, now: now,
            date: { $0.date }, id: { $0.id }).map(\.id), ["a", "b", "boundary"])
        let settings = HistoryRetentionSettings(operations: .init(maxCount: 237), automatic: .init(maxAgeDays: 184))
        XCTAssertEqual(try HistoryRetentionSettings.from(applicationPreferences: settings.applicationPreferences()), settings)
    }

    func testProtectedInProgressRowsSurviveBothLimits() throws {
        let rows = [Row(id: "new", date: now), Row(id: "old-active", date: now.addingTimeInterval(-100 * 86_400), active: true),
                    Row(id: "old-terminal", date: now.addingTimeInterval(-100 * 86_400))]
        let retained = try HistoryRetentionPolicy(maxCount: 1, maxAgeDays: 1).retained(rows, now: now,
            date: { $0.date }, id: { $0.id }, protected: { $0.active })
        XCTAssertEqual(retained.map(\.id), ["new", "old-active"])
    }

    func testInvalidLimitsCannotTriggerRetention() throws {
        for invalid in [0, -1] {
            XCTAssertThrowsError(try HistoryRetentionPolicy(maxCount: invalid).retained([Row(id: "one", date: now)],
                now: now, date: { $0.date }, id: { $0.id }))
            XCTAssertThrowsError(try HistoryRetentionSettings.from(applicationPreferences: [
                "history.automatic.maxAgeDays": SyncCodec.encode(invalid)]))
        }
        XCTAssertThrowsError(try HistoryRetentionSettings.from(applicationPreferences: [
            "history.operations.maxCount": Data("true".utf8)]))
        XCTAssertThrowsError(try HistoryRetentionSettings.from(applicationPreferences: [
            "history.operations.maxCount": Data("2.5".utf8)]))
    }

    func testClearedExecutionEvidenceIsNotExportedAsDisplayHistory() {
        var execution = AutoSignExecution(key: "example", now: now)
        execution.startedAt = now
        execution.submissions = 1
        execution.transition(.signed, now: now, message: "done")
        execution.discardHistory()
        XCTAssertTrue(execution.hasExecutionActivity)
        XCTAssertNil(SyncAutoSignHistory(execution: execution, accountID: "1001", incarnation: "incarnation",
            sourceDeviceID: "device", sourceDeviceName: "Test", revision: 1))
    }
}
