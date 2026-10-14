import XCTest
import Foundation
@testable import UCASCore

final class CloudSyncMergeTests: XCTestCase {
    private func candidate(_ device: String, _ counter: UInt64, _ value: String?,
                           context: [String: UInt64] = [:], baseline: Bool = false) -> SyncCandidate {
        SyncCandidate(version: SyncVersion(deviceID: device, counter: counter,
                                            mutationID: "\(device)-\(counter)", context: context,
                                            isBaseline: baseline), value: value.map { Data($0.utf8) })
    }

    private func register(_ value: SyncCandidate) -> SyncRegister { SyncRegister(candidates: [value]) }

    func testVersionSeparatesCausalityFromDeterministicConcurrentOrdering() throws {
        let a = candidate("A", 1, "a").version
        let b = candidate("B", 50, "b").version
        XCTAssertLessThan(a, b)
        XCTAssertFalse(a.observes(b))
        XCTAssertFalse(b.observes(a))
        let later = candidate("C", 51, "c", context: ["A": 1, "B": 50]).version
        XCTAssertTrue(later.causallyAfter(a))
        XCTAssertTrue(later.causallyAfter(b))
        XCTAssertTrue(later.observes(later))
        XCTAssertFalse(later.causallyAfter(later))
        XCTAssertTrue(candidate("A", 2, "new").version.causallyAfter(a))
        XCTAssertThrowsError(try SyncVersion(deviceID: "A", counter: 2, mutationID: "x", context: ["A": 2]).validate())
        XCTAssertThrowsError(try SyncVersion(deviceID: "", counter: 1, mutationID: "x").validate())
        XCTAssertThrowsError(try SyncVersion(deviceID: "A", counter: 0, mutationID: "x").validate())
        XCTAssertThrowsError(try SyncVersion(deviceID: "A", counter: .max, mutationID: "x").validate())
        XCTAssertThrowsError(try SyncVersion(deviceID: "A", counter: 1, mutationID: "x", context: ["B": .max]).validate())
    }

    func testThreePeerJoinIsAssociativeCommutativeAndIdempotent() throws {
        let values = [
            register(candidate("A", 1, "a")),
            register(candidate("B", 1, "b")),
            register(candidate("C", 2, "c", context: ["A": 1]))
        ]
        let expected = values[0].merged(with: values[1]).merged(with: values[2])
        XCTAssertEqual(expected.candidates.map(\.version.deviceID), ["B", "C"])
        for a in values {
            XCTAssertEqual(a.merged(with: a), a)
            for b in values {
                XCTAssertEqual(a.merged(with: b), b.merged(with: a))
                for c in values {
                    XCTAssertEqual(a.merged(with: b).merged(with: c), a.merged(with: b.merged(with: c)))
                }
            }
        }
        let roundTrip = try SyncCodec.decode(SyncRegister.self, from: SyncCodec.encode(expected))
        XCTAssertEqual(roundTrip, expected)
        XCTAssertEqual(roundTrip.context, ["A": 1, "B": 1, "C": 2])
        XCTAssertEqual(roundTrip.merged(with: values[0]), expected)
    }

    func testContextPreventsADeletedSiblingFromReturningAfterIntermediateMerge() {
        let a = register(candidate("A", 1, "first"))
        let b = register(candidate("B", 2, nil, context: ["A": 1]))
        let c = register(candidate("C", 3, "new", context: b.context))
        let merged = a.merged(with: b).merged(with: c)
        XCTAssertEqual(merged.resolved()?.value, Data("new".utf8))
        XCTAssertEqual(merged.candidates.count, 1)
        XCTAssertEqual(merged.merged(with: a).merged(with: b), merged)
        XCTAssertEqual(merged.context, ["A": 1, "B": 2, "C": 3])
    }

    func testMixedReplicaHistoriesConvergeAcrossEveryGroupingAndDeliveryOrder() {
        let a0 = register(candidate("A", 1, "baseline-a", baseline: true))
        let b0 = register(candidate("B", 1, "baseline-b", baseline: true))
        let c0 = register(candidate("C", 1, "baseline-c", baseline: true))
        let a1 = register(candidate("A", 2, "edit-a", context: a0.context))
        let b1 = register(candidate("B", 2, "edit-b", context: b0.context))
        let firstRead = a1.merged(with: c0)
        let c1 = register(candidate("C", 3, "edit-c", context: firstRead.context))
        let fullRead = b1.merged(with: c1)
        let a2 = register(candidate("A", 4, "edit-a2", context: fullRead.context))
        let deletion = register(candidate("D", 3, nil, context: b1.context))
        let conflict = a2.merged(with: deletion)
        let reenabled = register(candidate("B", 5, "deliberate-reenable", context: conflict.context))
        let states = [SyncRegister(), a0, b0, c0, a1, b1, firstRead, c1, fullRead, a2, deletion, conflict, reenabled]
        for left in states {
            XCTAssertEqual(left.merged(with: left), left)
            for middle in states {
                XCTAssertEqual(left.merged(with: middle), middle.merged(with: left))
                for right in states {
                    let lhs = left.merged(with: middle).merged(with: right)
                    let rhs = left.merged(with: middle.merged(with: right))
                    XCTAssertEqual(lhs, rhs)
                    XCTAssertEqual(lhs.resolved(deleteWins: true), rhs.resolved(deleteWins: true))
                }
            }
        }
        let final = states.reduce(SyncRegister()) { $0.merged(with: $1) }
        XCTAssertEqual(final.resolved(deleteWins: true)?.value, Data("deliberate-reenable".utf8))
        XCTAssertEqual(final.candidates.count, 1)
    }

    func testConcurrentDeletionWinsUntilAUserWriteObservesEverySibling() throws {
        for kind in [SyncRecordKind.account, .password] {
            let forgotten = register(candidate("A", 2, nil))
            let remembered = register(candidate("B", 100, "remembered"))
            let merged = forgotten.merged(with: remembered)
            XCTAssertEqual(merged.candidates.count, 2)
            XCTAssertEqual(merged.resolved()?.value, Data("remembered".utf8))
            let record = SyncRecord(id: "record", kind: kind, accountID: "1001", register: merged)
            XCTAssertNil(record.resolvedCandidate?.value)
            XCTAssertNotNil(record.resolvedCandidate)
            // Observing only the losing remembered write must not bypass a deletion.
            let staleRemember = register(candidate("B", 101, "stale", context: remembered.context))
            XCTAssertNil(merged.merged(with: staleRemember).resolved(deleteWins: true)?.value)
            let explicitRemember = register(candidate("C", 102, "new", context: merged.context))
            let fresh = try record.merged(with: SyncRecord(id: "record", kind: kind, accountID: "1001",
                                                         register: explicitRemember))
            XCTAssertEqual(fresh.resolvedCandidate?.value, Data("new".utf8))
            XCTAssertEqual(fresh.register.candidates.count, 1)
            XCTAssertEqual(try fresh.merged(with: record), fresh)
        }
    }

    func testActualEditsBeatBaselinesRegardlessOfCounterOrDeletion() {
        let baseline = register(candidate("legacy", 900, "old", baseline: true))
        let edit = register(candidate("new", 1, "new"))
        let deletion = register(candidate("other", 2, nil))
        XCTAssertEqual(baseline.merged(with: edit).resolved()?.value, Data("new".utf8))
        XCTAssertEqual(baseline.merged(with: edit), edit.merged(with: baseline))
        let all = baseline.merged(with: edit).merged(with: deletion)
        XCTAssertEqual(all, baseline.merged(with: edit.merged(with: deletion)))
        XCTAssertNil(all.resolved(deleteWins: true)?.value)
        XCTAssertFalse(all.candidates.contains(where: { $0.version.isBaseline }))
        let baselineDelete = register(candidate("legacy-delete", 999, nil, baseline: true))
        XCTAssertEqual(baselineDelete.merged(with: edit).resolved(deleteWins: true)?.value, Data("new".utf8))
        XCTAssertEqual(all.merged(with: baseline), all)
    }

    func testExplicitDeletionDiffersFromEmptyRegisterAndJSONNull() throws {
        let empty = SyncRegister()
        let deletion = register(candidate("A", 1, nil))
        let jsonNull = SyncRegister(candidates: [.init(version: candidate("B", 1, nil).version,
                                                     value: try SyncCodec.encode(Int?.none))])
        XCTAssertNil(empty.resolved())
        XCTAssertNotNil(deletion.resolved())
        XCTAssertNil(deletion.resolved()?.value)
        XCTAssertEqual(jsonNull.resolved()?.value, Data("null".utf8))
        XCTAssertEqual(try SyncCodec.decode(SyncRegister.self, from: SyncCodec.encode(deletion)), deletion)
    }

    func testCodecIsDeterministicAndRejectsNewFormatsIdentityMismatchAndReusedDots() throws {
        let value = candidate("A", 2, "x", context: ["C": 1, "B": 1])
        let first = SyncRecord(id: "opaque", kind: .accountPreference, accountID: "1001", incarnation: "initial:1001",
                               key: "confirmationEnabled", register: register(value))
        let decoded = try SyncCodec.decode(SyncRecord.self, from: SyncCodec.encode(first))
        XCTAssertEqual(first, decoded)
        XCTAssertEqual(try SyncCodec.encode(first), try SyncCodec.encode(decoded))
        let otherKey = SyncRecord(id: "opaque", kind: .accountPreference, accountID: "1001", incarnation: "initial:1001",
                                  key: "remindersEnabled", register: register(value))
        XCTAssertThrowsError(try first.merged(with: otherKey))
        let otherAccount = SyncRecord(id: "opaque", kind: .accountPreference, accountID: "1002", incarnation: "initial:1001",
                                      key: "confirmationEnabled", register: register(value))
        XCTAssertThrowsError(try first.merged(with: otherAccount))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: SyncCodec.encode(first)) as? [String: Any])
        json["formatVersion"] = 2
        XCTAssertThrowsError(try SyncCodec.decode(SyncRecord.self, from: JSONSerialization.data(withJSONObject: json)))
        let reused = SyncCandidate(version: value.version, value: Data("changed".utf8))
        let collision = SyncRecord(id: first.id, kind: first.kind, accountID: first.accountID, incarnation: first.incarnation,
                                   key: first.key, register: register(reused))
        XCTAssertThrowsError(try first.merged(with: collision))
    }

    func testPreferenceProjectionAndPatchesPreserveEveryAutomaticField() throws {
        let now = Date(timeIntervalSince1970: 1234)
        let course = CoursePreferences(confirmation: .enabled, autoSign: .disabled,
            reminders: .enabled, reminderLeadMinutes: 30, signInDisabled: true,
            autoSignRule: .init(offsetMinutes: -10, missedAction: .untilClassEnds, maxSubmissions: 1,
                                retryMinutes: 5, notification: .all), autoSignEnabledSince: now)
        var account = AccountPreferences(autoSignEnabled: true, remindersEnabled: true,
            confirmationEnabled: true, reminderLeadMinutes: 30, courses: ["course": course],
            autoSignRunning: true, autoSignRule: .init(offsetMinutes: -15),
            autoSignOccurrences: ["once": .init(enabled: true, at: now, policy: .init(retryMinutes: 5), enabledSince: now)],
            autoSignPausedUntil: now, autoSignV2Acknowledged: true,
            autoSignRunningSince: now, autoSignDefaultSince: now,
            autoSignSinceUsesSchoolTime: false, autoSignPendingClockBoundaries: [now])
        let original = account
        XCTAssertEqual(Set(try SyncPreferenceProjection.account(account).keys), Set(SyncPreferenceProjection.accountKeys))
        XCTAssertEqual(Set(try SyncPreferenceProjection.course(course).keys), Set(SyncPreferenceProjection.courseKeys))
        XCTAssertEqual(try SyncPreferenceProjection.courses(account)["course"], try SyncPreferenceProjection.course(course))
        XCTAssertEqual(Set(SyncPreferenceProjection.applicationKeys),
                       ["appearanceMode", "accountDetailsHidden", "scheduleViewMode", "showOutsideWeekCourses", "update.automaticChecks",
                        "history.operations.maxCount", "history.operations.maxAgeDays", "history.automatic.maxCount", "history.automatic.maxAgeDays"])
        try SyncPreferenceProjection.applyAccount(SyncPreferenceProjection.account(AccountPreferences()), to: &account)
        var expected = original
        expected.remindersEnabled = false
        expected.confirmationEnabled = false
        expected.reminderLeadMinutes = 10
        XCTAssertEqual(account, expected)
        var changedCourse = course
        try SyncPreferenceProjection.applyCourse(SyncPreferenceProjection.course(CoursePreferences()), to: &changedCourse)
        var expectedCourse = course
        expectedCourse.confirmation = .inherit
        expectedCourse.reminders = .inherit
        expectedCourse.reminderLeadMinutes = nil
        expectedCourse.signInDisabled = false
        XCTAssertEqual(changedCourse, expectedCourse)
        XCTAssertThrowsError(try SyncPreferenceProjection.applyAccount(["autoSignRunning": SyncCodec.encode(false)], to: &account))
        XCTAssertThrowsError(try SyncPreferenceProjection.applyCourse(["autoSign": SyncCodec.encode(PreferenceOverride.enabled)], to: &changedCourse))
        XCTAssertEqual(account, expected)
        XCTAssertEqual(changedCourse, expectedCourse)
    }

    func testInvalidPatchIsAtomicAndIndependentFieldsDoNotOverwriteEachOther() throws {
        var account = AccountPreferences(remindersEnabled: true, confirmationEnabled: false)
        let original = account
        XCTAssertThrowsError(try SyncPreferenceProjection.applyAccount([
            "remindersEnabled": SyncCodec.encode(false), "reminderLeadMinutes": SyncCodec.encode(999)
        ], to: &account))
        XCTAssertEqual(account, original)
        try SyncPreferenceProjection.applyAccount(["confirmationEnabled": SyncCodec.encode(true)], to: &account)
        XCTAssertTrue(account.remindersEnabled)
        XCTAssertTrue(account.confirmationEnabled)
        var course = CoursePreferences(autoSign: .enabled, autoSignEnabledSince: .distantPast)
        let originalCourse = course
        XCTAssertThrowsError(try SyncPreferenceProjection.applyCourse([
            "signInDisabled": SyncCodec.encode(true), "reminderLeadMinutes": SyncCodec.encode(2)
        ], to: &course))
        XCTAssertEqual(course, originalCourse)
    }

    func testAttendanceUUIDAndOldLocalJSONRemainCompatible() throws {
        let id = UUID()
        let record = SyncAttendanceRecord(id: id, courseId: "course", courseName: "name",
                                          date: Date(timeIntervalSince1970: 1234), message: "success", succeeded: true)
        let data = try JSONEncoder().encode([record])
        let restored = try SyncCodec.decode([SyncAttendanceRecord].self, from: data)
        XCTAssertEqual(restored, [record])
        XCTAssertEqual(restored.first?.id, id)
    }

    func testStaleCourseFormAutomaticEditsPreserveSyncedReminderAndCurrentBoundary() {
        let previous = CoursePreferences(reminders: .disabled, reminderLeadMinutes: 5,
                                         autoSignRule: .init(offsetMinutes: -5), autoSignEnabledSince: .distantPast)
        var proposed = previous
        proposed.autoSign = .enabled
        proposed.autoSignRule?.offsetMinutes = -10
        proposed.autoSignEnabledSince = .distantPast
        var latest = previous
        latest.reminders = .enabled
        latest.reminderLeadMinutes = 30
        latest.signInDisabled = true
        latest.autoSignRule?.notification = AutoSignNotification.none
        latest.autoSignEnabledSince = Date(timeIntervalSince1970: 1234)
        let patch = CoursePreferencesPatch(previous: previous, proposed: proposed)
        let result = patch.applying(to: latest)
        XCTAssertFalse(patch.isEmpty)
        XCTAssertEqual(result.autoSign, .enabled)
        XCTAssertEqual(result.autoSignRule?.offsetMinutes, -10)
        XCTAssertEqual(result.autoSignRule?.notification, AutoSignNotification.none)
        XCTAssertEqual(result.reminders, .enabled)
        XCTAssertEqual(result.reminderLeadMinutes, 30)
        XCTAssertTrue(result.signInDisabled)
        XCTAssertEqual(result.autoSignEnabledSince, latest.autoSignEnabledSince)
    }

    func testCoursePatchResetsOnlyEditedOptionalRuleFields() {
        let original = CoursePreferences(autoSignRule: .init(offsetMinutes: -5, maxSubmissions: 2, retryMinutes: 1))
        var proposed = original
        proposed.autoSignRule = nil
        var latest = original
        latest.autoSignRule?.missedAction = .untilClassEnds
        let result = CoursePreferencesPatch(previous: original, proposed: proposed).applying(to: latest)
        XCTAssertEqual(result.autoSignRule, AutoSignPolicyOverride(missedAction: .untilClassEnds))
        XCTAssertNil(CoursePreferencesPatch(previous: original, proposed: proposed).applying(to: original).autoSignRule)
        var partial = original
        partial.autoSignRule?.retryMinutes = nil
        let partialResult = CoursePreferencesPatch(previous: original, proposed: partial).applying(to: latest)
        XCTAssertNil(partialResult.autoSignRule?.retryMinutes)
        XCTAssertEqual(partialResult.autoSignRule?.maxSubmissions, 2)
        XCTAssertEqual(partialResult.autoSignRule?.offsetMinutes, -5)
        XCTAssertEqual(partialResult.autoSignRule?.missedAction, .untilClassEnds)
    }

    func testCoursePatchChangesOnlyEditedOrdinaryFieldsAndNeverRuntimeBoundary() {
        let original = CoursePreferences(confirmation: .disabled, autoSign: .disabled,
                                         reminders: .enabled, reminderLeadMinutes: 10)
        var proposed = original
        proposed.confirmation = .enabled
        proposed.reminderLeadMinutes = nil
        proposed.autoSignEnabledSince = .distantFuture
        var latest = original
        latest.autoSign = .enabled
        latest.reminders = .disabled
        latest.autoSignRule = .init(notification: .all)
        latest.autoSignEnabledSince = Date(timeIntervalSince1970: 4321)
        var expected = latest
        expected.confirmation = .enabled
        expected.reminderLeadMinutes = nil
        XCTAssertEqual(CoursePreferencesPatch(previous: original, proposed: proposed).applying(to: latest), expected)
        var boundaryOnly = original
        boundaryOnly.autoSignEnabledSince = .distantFuture
        let empty = CoursePreferencesPatch(previous: original, proposed: boundaryOnly)
        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(empty.applying(to: latest), latest)
    }

    func testAutomaticHistoryIsDisplayOnlyAndDoesNotExportPreviewsOrTakeover() throws {
        let now = Date(timeIntervalSince1970: 1234)
        let key = "1001|2026-10-14|meeting"
        var execution = AutoSignExecution(key: key, now: now)
        func projection(_ value: AutoSignExecution, device: String = "A", incarnation: String = "first") -> SyncAutoSignHistory? {
            SyncAutoSignHistory(execution: value, accountID: "1001", incarnation: incarnation,
                                sourceDeviceID: device, sourceDeviceName: "Test device", revision: 5)
        }
        XCTAssertNil(projection(execution))
        execution.transition(.planned, now: now, message: "计划已更新", kind: .planChanged)
        XCTAssertNil(projection(execution))
        execution.transition(.skipped, now: now, message: "用户已手动接管", kind: .manualTakeover)
        XCTAssertNil(projection(execution))
        execution.startedAt = now
        execution.courseName = "Test course"
        execution.classStartAt = now.addingTimeInterval(300)
        execution.classEndAt = now.addingTimeInterval(3900)
        execution.submissions = 1
        execution.lastSubmissionAt = now
        execution.lastSchoolSubmissionAt = now
        execution.nextAt = now.addingTimeInterval(60)
        execution.nextSchoolVerificationAt = now.addingTimeInterval(70)
        execution.firstNegativeAt = now
        execution.firstSchoolNegativeAt = now
        execution.negativeReads = 1
        execution.transition(.verifying, now: now, message: "等待核实", kind: .verification)
        let history = try XCTUnwrap(projection(execution))
        XCTAssertNotEqual(history.id, try XCTUnwrap(projection(execution, device: "B")).id)
        XCTAssertNotEqual(history.id, try XCTUnwrap(projection(execution, incarnation: "second")).id)
        XCTAssertEqual(history.events, execution.events)
        XCTAssertEqual(history.submissions, 1)
        XCTAssertEqual(history.occurrenceKey, execution.key)
        let data = try SyncCodec.encode(history)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["key", "nextAt", "nextSchoolVerificationAt", "lastSubmissionAt", "lastSchoolSubmissionAt",
                    "firstNegativeAt", "firstSchoolNegativeAt", "negativeReads", "autoSignRule"] {
            XCTAssertNil(json[key], key)
        }
        XCTAssertThrowsError(try SyncCodec.decode(AutoSignExecution.self, from: data))
        XCTAssertEqual(try SyncCodec.decode(SyncAutoSignHistory.self, from: data), history)
    }
}
