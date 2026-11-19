import Foundation
import XCTest
@testable import SetlineData

final class WorkoutConvenienceTests: XCTestCase {
    func testOfflineCommandIsIdempotentAfterRelaunchAndCannotOverwritePhoneEdits() async throws {
        try await MainActor.run {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SetlineCompanion-\(UUID())")
            defer { try? FileManager.default.removeItem(at: folder) }
            let files = TrainingFiles(directory: folder)
            let exercise = Exercise(name: "Press")
            let store = try TrainingRepository(files: files, catalog: [exercise])
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let version = try makeRoutine(store, exercise: exercise)
            let session = try store.startSession(versionID: version.id, at: now)
            var watch = WorkoutCompanionOutbox()
            let initial = try store.companionState(at: now)
            watch.observe(initial)
            let first = try XCTUnwrap(initial.workout?.nextSet)
            var actual = WorkoutSetInput(unit: .lb, prescription: first.row.prescription)
            actual.amount = "85"
            actual.reps = "7"
            let command = try XCTUnwrap(watch.enqueue(.completeSet(exerciseID: first.exerciseID, setID: first.id, input: actual)))
            XCTAssertNil(watch.enqueue(.finish(early: true)))
            XCTAssertTrue(store.records.activeSession?.performedSets.isEmpty == true)
            watch = try JSONDecoder().decode(WorkoutCompanionOutbox.self, from: JSONEncoder().encode(watch))
            XCTAssertEqual(watch.pending, command)
            let applied = try store.receiveCompanionCommand(command, at: now.addingTimeInterval(30))
            XCTAssertEqual(applied.outcome, .applied)
            let reopened = try TrainingRepository(files: files, catalog: [exercise])
            let retry = try reopened.receiveCompanionCommand(command, at: now.addingTimeInterval(35))
            XCTAssertEqual(retry.outcome, .alreadyApplied)
            XCTAssertEqual(watch.acknowledge(retry), .alreadyApplied)
            XCTAssertNil(watch.pending)
            watch.observe(initial)
            XCTAssertEqual(watch.state?.cursor, applied.state.cursor)
            XCTAssertEqual(reopened.records.activeSession?.performedSets.map(\.id), [first.id])
            XCTAssertEqual(reopened.records.activeSession?.performedSets.first?.amount, .weight(try XCTUnwrap(Mass(85, unit: .lb))))
            XCTAssertEqual(reopened.records.activeSession?.performedSets.first?.recordedAt, now.addingTimeInterval(30))

            let second = try XCTUnwrap(retry.state.workout?.nextSet)
            let delayed = try XCTUnwrap(watch.enqueue(.completeSet(exerciseID: second.exerciseID, setID: second.id, input: actual)))
            var phoneInput = actual
            phoneInput.reps = "5"
            try reopened.changeWorkout(session.id, .editSet(second.exerciseID, second.id, phoneInput), at: now.addingTimeInterval(40))
            let stale = try reopened.receiveCompanionCommand(delayed, at: now.addingTimeInterval(45))
            XCTAssertEqual(stale.outcome, .outdated)
            XCTAssertEqual(watch.acknowledge(stale), .outdated)
            XCTAssertEqual(stale.state.workout?.nextSet?.row.input, phoneInput)
            let firstAgain = try XCTUnwrap(watch.enqueue(.completeSet(exerciseID: first.exerciseID, setID: first.id, input: actual)))
            XCTAssertEqual(try reopened.receiveCompanionCommand(firstAgain, at: now.addingTimeInterval(50)).outcome, .invalidAction)
        }
    }

    func testTimersPrivacyAndFinishRacesShareAuthoritativeState() async throws {
        try await MainActor.run {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SetlineCompanion-\(UUID())")
            defer { try? FileManager.default.removeItem(at: folder) }
            let exercise = Exercise(name: "Press")
            let store = try TrainingRepository(files: TrainingFiles(directory: folder), catalog: [exercise])
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let version = try makeRoutine(store, exercise: exercise)
            let firstSession = try store.startSession(versionID: version.id, at: now)
            let prepared = try store.companionState(at: now)
            let firstSet = try XCTUnwrap(prepared.workout?.nextSet)
            try store.changeWorkout(firstSession.id, .complete(firstSet.exerciseID, firstSet.id, .kg), at: now)
            try store.changeWorkout(firstSession.id, .sessionNotes("private notes"), at: now)
            let live = try store.companionState(at: now.addingTimeInterval(15))
            let status = try XCTUnwrap(WorkoutLockScreenState(state: live))
            XCTAssertNil(status.routineName)
            XCTAssertNil(status.nextExerciseName)
            XCTAssertNil(status.completedSets)
            XCTAssertFalse(String(decoding: try JSONEncoder().encode(status), as: UTF8.self).contains("private"))
            XCTAssertEqual(WorkoutLockScreenState(state: live, showsDetails: true)?.nextExerciseName, "Press")
            XCTAssertEqual(status.timer?.deadline, now.addingTimeInterval(90))
            let extend = try XCTUnwrap(status.command(for: .extend))
            let extended = try store.receiveCompanionCommand(extend, at: now.addingTimeInterval(15))
            XCTAssertEqual(extended.state.workout?.timer?.deadline, now.addingTimeInterval(105))
            XCTAssertEqual(try store.receiveCompanionCommand(extend, at: now.addingTimeInterval(16)).outcome, .alreadyApplied)
            let staleSkip = try XCTUnwrap(status.command(for: .skip))
            XCTAssertEqual(try store.receiveCompanionCommand(staleSkip, at: now.addingTimeInterval(16)).outcome, .outdated)
            try store.changeWorkout(firstSession.id, .pause, at: now.addingTimeInterval(20))
            let paused = try store.companionState(at: now.addingTimeInterval(50))
            XCTAssertEqual(paused.workout?.timer?.pausedSecondsRemaining, 85)
            XCTAssertNil(WorkoutLockScreenState(state: paused)?.command(for: .restart))

            let premature = WorkoutCompanionCommand(sessionID: firstSession.id, cursor: paused.cursor, action: .finish(early: false))
            XCTAssertEqual(try store.receiveCompanionCommand(premature, at: now.addingTimeInterval(50)).outcome, .invalidAction)
            let early = WorkoutCompanionCommand(sessionID: firstSession.id, cursor: paused.cursor, action: .finish(early: true))
            XCTAssertNil(try store.receiveCompanionCommand(early, at: now.addingTimeInterval(55)).state.workout)
            try store.finishSession(firstSession.id, at: now.addingTimeInterval(60))
            XCTAssertEqual(store.records.sessions.first?.completedAt, now.addingTimeInterval(55))
            XCTAssertEqual(store.records.sessions.first?.endedEarly, true)
            XCTAssertEqual(try store.receiveCompanionCommand(early, at: now.addingTimeInterval(60)).outcome, .alreadyApplied)

            let secondSession = try store.startSession(versionID: version.id, at: now.addingTimeInterval(120))
            let secondState = try store.companionState(at: now.addingTimeInterval(120))
            let finishOnWatch = WorkoutCompanionCommand(sessionID: secondSession.id, cursor: secondState.cursor, action: .finish(early: true))
            try store.finishSession(secondSession.id, at: now.addingTimeInterval(150))
            XCTAssertEqual(try store.receiveCompanionCommand(finishOnWatch, at: now.addingTimeInterval(180)).outcome, .workoutEnded)
            XCTAssertEqual(store.records.sessions.last?.completedAt, now.addingTimeInterval(150))
        }
    }

    func testReminderFollowsReschedulingCompletionSkipAndRotation() async throws {
        try await MainActor.run {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SetlineReminders-\(UUID())")
            defer { try? FileManager.default.removeItem(at: folder) }
            let exercise = Exercise(name: "Press")
            let store = try TrainingRepository(files: TrainingFiles(directory: folder), catalog: [exercise])
            let day = try XCTUnwrap(WorkoutDate("2026-11-18"))
            let now = day.calendarDate.addingTimeInterval(12 * 3600)
            let version = try makeRoutine(store, exercise: exercise)
            try store.assignWeekday(WeekdayAssignment(weekday: day.weekday, versionID: version.id, start: day))
            XCTAssertTrue(WorkoutReminderPlanner.upcoming(in: store.records, preferences: WorkoutReminderPreferences(), now: now, timeZone: .gmt).isEmpty)
            let weekday = WorkoutReminderPreferences(weekdays: true)
            func dates(_ records: TrainingRecords, _ preferences: WorkoutReminderPreferences, at time: Date) -> [WorkoutDate] {
                WorkoutReminderPlanner.upcoming(in: records, preferences: preferences, now: time, timeZone: .gmt).map(\.day)
            }
            XCTAssertEqual(dates(store.records, weekday, at: now), [day, day.offset(7)])
            let original = try XCTUnwrap(store.records.scheduled(on: [day], today: day).first)
            let moved = day.offset(1)
            try store.moveSchedule(original.id, on: day, to: moved, today: day)
            XCTAssertEqual(dates(store.records, weekday, at: now), [moved, day.offset(7)])
            let rescheduled = try XCTUnwrap(store.records.scheduled(on: [moved], today: day).first)
            let session = try store.startScheduled(rescheduled.id, on: moved, at: now, timeZone: .gmt)
            XCTAssertEqual(dates(store.records, weekday, at: now), [day.offset(7)])
            try store.finishSession(session.id, early: true, at: now)
            XCTAssertEqual(dates(store.records, weekday, at: now), [day.offset(7)])

            try store.saveRotation(RoutineRotation(start: day, interval: 1, versionIDs: [version.id]), today: day)
            let rotation = WorkoutReminderPreferences(rotations: true)
            XCTAssertEqual(dates(store.records, rotation, at: now), [day])
            let slot = try XCTUnwrap(store.records.scheduled(on: [day], today: day).first { $0.rotationID != nil })
            try store.skipSchedule(slot.id, on: day, today: day)
            XCTAssertEqual(dates(store.records, rotation, at: now), [moved])
            XCTAssertEqual(dates(store.records, rotation, at: day.offset(2).calendarDate), [day.offset(2)])
        }
    }

    func testReminderUsesLocalDateAndRoutesRejectUnexpectedURLs() throws {
        let sunday = try XCTUnwrap(WorkoutDate("2026-11-01"))
        let zone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let beforeFirstHour = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-01T04:30:00Z"))
        let firstOccurrence = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-01T05:30:00Z"))
        var records = TrainingRecords()
        records.weekdayRules = [WeekdayAssignment(weekday: .sunday, versionID: UUID(), start: sunday)]
        let prefs = WorkoutReminderPreferences(weekdays: true, hour: 1, minute: 30)
        let requests = WorkoutReminderPlanner.upcoming(in: records, preferences: prefs, now: beforeFirstHour, timeZone: zone)
        XCTAssertEqual(requests.first?.day, sunday)
        XCTAssertEqual(requests.first?.fireAt, firstOccurrence)
        XCTAssertEqual(requests.first?.localTime.hour, 1)
        XCTAssertEqual(WorkoutEntryRoute(try XCTUnwrap(requests.first?.route.url)), .scheduled(sunday))
        XCTAssertEqual(WorkoutEntryRoute(WorkoutEntryRoute.active.url), .active)
        for invalid in ["https://workout/active", "setline://workout/active?finish=true", "setline://workout/scheduled/2026-11-31"] {
            XCTAssertNil(WorkoutEntryRoute(try XCTUnwrap(URL(string: invalid))))
        }
    }

    func testBackupRestoreInvalidatesCompanionCommandsWithoutExportingReceipts() async throws {
        try await MainActor.run {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SetlineCompanion-\(UUID())")
            defer { try? FileManager.default.removeItem(at: folder) }
            let exercise = Exercise(name: "Press")
            let store = try TrainingRepository(files: TrainingFiles(directory: folder), catalog: [exercise])
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let version = try makeRoutine(store, exercise: exercise)
            let session = try store.startSession(versionID: version.id, at: now)
            let state = try store.companionState(at: now)
            let first = try XCTUnwrap(state.workout?.nextSet)
            let input = WorkoutSetInput(unit: .kg, prescription: first.row.prescription)
            let logged = WorkoutCompanionCommand(sessionID: session.id, cursor: state.cursor,
                action: .completeSet(exerciseID: first.exerciseID, setID: first.id, input: input))
            let applied = try store.receiveCompanionCommand(logged, at: now)
            XCTAssertEqual(applied.outcome, .applied)
            let next = WorkoutCompanionCommand(sessionID: session.id, cursor: applied.state.cursor, action: .finish(early: true))
            let backup = try SetlineBackup.make(store.records, settings: BackupDisplaySettings(appearance: "dark", opaque: true, unit: .kg),
                options: BackupOptions())
            XCTAssertNil(backup.payload.records.companionCursor)
            XCTAssertNil(backup.payload.records.activeSession?.companionCommands)
            try store.restoreBackup(backup)
            XCTAssertEqual(try store.receiveCompanionCommand(next, at: now).outcome, .outdated)
            XCTAssertEqual(store.records.activeSession?.performedSets.map(\.id), [first.id])
        }
    }

    @MainActor
    private func makeRoutine(_ store: TrainingRepository, exercise: Exercise) throws -> RoutineVersion {
        let row = PlannedExercise(variant: ExerciseVariant(exercise: exercise, equipment: nil,
            measurement: .weightReps(basis: .total, reps: .total)),
            prescription: SetPrescription(sets: 2, reps: RepRange(minimum: 5, maximum: 7),
                target: .weight(try XCTUnwrap(Mass(40)))))
        return try store.saveRoutine(name: "Upper", exercises: [row])
    }
}
