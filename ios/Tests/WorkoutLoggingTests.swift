import Foundation
import XCTest
@testable import SetlineData

final class WorkoutLoggingTests: XCTestCase {
    func testScheduledLoggingRestoresPartialWorkAndPreservesVersions() async throws {
        try await MainActor.run {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SetlineLogTests-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let files = TrainingFiles(directory: directory)
            let press = Exercise(name: "Press")
            let row = Exercise(name: "Row")
            let store = try TrainingRepository(files: files, catalog: [press, row])
            let date = Date(timeIntervalSince1970: 1_800_000_000)
            let measurement = Measurement.weightReps(basis: .total, reps: .total)
            let block = SetPrescription(sets: 3, reps: RepRange(minimum: 6, maximum: 8), target: .weight(try XCTUnwrap(Mass(80))), repsInReserve: 2)
            let first = PlannedExercise(variant: ExerciseVariant(exercise: press, equipment: nil, measurement: measurement), prescription: block)
            let second = PlannedExercise(variant: ExerciseVariant(exercise: row, equipment: nil, measurement: measurement), prescription: block)
            let version = try store.saveRoutine(name: "Upper A", exercises: [first, second], at: date)
            let scheduled = ScheduledWorkout(localDate: WorkoutDate(date, timeZone: .gmt), routineVersionID: version.id)
            try store.addScheduledWorkout(scheduled)
            let session = try store.startSession(versionID: version.id, scheduleID: scheduled.id, at: date, timeZone: .gmt)
            try store.prepareWorkoutLog(session.id)
            let log = try XCTUnwrap(store.records.activeSession?.workoutLog)
            let set = log.exercises[0].rows[0]
            let skipped = log.exercises[0].rows[1]
            XCTAssertEqual(store.records.activeSession?.performedSets.count, 0)
            var input = WorkoutSetInput(unit: .kg, prescription: set.prescription)
            input.amount = "82.5"
            input.reps = "7"
            input.rir = "1"
            input.rpe = "9"
            try store.changeWorkout(session.id, .editSet(first.id, set.id, input), at: date)
            try store.changeWorkout(session.id, .sessionNotes("Paused on presses"), at: date)
            try store.changeWorkout(session.id, .exerciseNotes(first.id, "Even tempo"), at: date)
            try store.changeWorkout(session.id, .queue(second.id, true), at: date)

            let reopened = try TrainingRepository(files: files, catalog: [press, row])
            XCTAssertEqual(reopened.records.activeSession?.workoutLog?.exercises[0].rows[0].input, input)
            XCTAssertTrue(reopened.records.activeSession?.workoutLog?.exercises[1].queued == true)
            XCTAssertTrue(reopened.records.activeSession?.performedSets.isEmpty == true)
            try reopened.changeWorkout(session.id, .complete(first.id, set.id, .kg), at: date)
            let completed = try XCTUnwrap(reopened.records.activeSession?.performedSets.first)
            XCTAssertEqual(completed.actualRIR, 1)
            XCTAssertEqual(completed.actualRPE, 9)
            XCTAssertEqual(completed.repetitions, .total(7))
            try reopened.changeWorkout(session.id, .undo(first.id, set.id), at: date)
            XCTAssertTrue(reopened.records.activeSession?.performedSets.isEmpty == true)
            try reopened.changeWorkout(session.id, .complete(first.id, set.id, .kg), at: date)
            try reopened.changeWorkout(session.id, .setSkipped(first.id, skipped.id, true), at: date)
            try reopened.changeWorkout(session.id, .moveExercise(second.id, -1), at: date)
            XCTAssertEqual(reopened.records.currentRoutines, [version])
            let new = try reopened.updateRoutineFromWorkout(session.id, at: date)
            XCTAssertEqual(new.exercises.map(\.id), [second.id, first.id])
            XCTAssertEqual(new.exercises[1].prescription.reps?.minimum, 7)
            XCTAssertEqual(reopened.records.versions(for: version.routineID), [new, version])
            try reopened.finishSession(session.id, early: true, at: date)
            let finished = try XCTUnwrap(reopened.records.sessions.first)
            XCTAssertEqual(finished.routineSnapshot, version)
            XCTAssertEqual(finished.scheduleID, scheduled.id)
            XCTAssertEqual(finished.endedEarly, true)
            XCTAssertEqual(finished.workoutLog?.exercises[1].rows.map(\.status), [.completed, .skipped, .pending])
            XCTAssertEqual(finished.workoutLog?.notes, "Paused on presses")
            XCTAssertEqual(finished.performedSets.count, 1)
            let repeatSession = try reopened.repeatSession(session.id, at: date, timeZone: .gmt)
            XCTAssertEqual(repeatSession.referenceSessionID, session.id)
            XCTAssertTrue(repeatSession.performedSets.isEmpty)
            XCTAssertEqual(repeatSession.workoutLog?.exercises[1].rows.map(\.status), [.pending, .pending, .pending])
            XCTAssertEqual(reopened.records.sessions.first, finished)
        }
    }

    func testEmptyWorkoutOnlyCompletesValidMeasurements() async throws {
        try await MainActor.run {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SetlineEmptyTests-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let exercise = Exercise(name: "Carry")
            let store = try TrainingRepository(files: TrainingFiles(directory: directory), catalog: [exercise])
            let date = Date(timeIntervalSince1970: 1_800_000_000)
            let session = try store.startEmptySession(at: date, timeZone: .gmt)
            try store.changeWorkout(session.id, .addExercise(exercise, .distance, nil), at: date)
            let item = try XCTUnwrap(store.records.activeSession?.workoutLog?.exercises.first)
            let set = item.rows[0]
            XCTAssertThrowsError(try store.changeWorkout(session.id, .complete(item.id, set.id, .lb), at: date))
            var input = WorkoutSetInput(unit: .lb)
            input.amount = "200"
            try store.changeWorkout(session.id, .editSet(item.id, set.id, input), at: date)
            try store.changeWorkout(session.id, .complete(item.id, set.id, .lb), at: date)
            try store.finishSession(session.id, at: date)
            XCTAssertEqual(store.records.sessions.first?.performedSets.first?.amount, .distanceMeters(200))
            XCTAssertNil(store.records.sessions.first?.endedEarly)
        }
    }

    func testPausedSupersetKeepsTimestampsAndSeparatesMeasuredRestFromEdits() async throws {
        try await MainActor.run {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SetlineTimerTests-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let files = TrainingFiles(directory: directory)
            let exercises = [Exercise(name: "Press"), Exercise(name: "Row")]
            let store = try TrainingRepository(files: files, catalog: exercises)
            let date = Date(timeIntervalSince1970: 1_800_000_000)
            let firstBlock = SetPrescription(sets: 2, reps: RepRange(minimum: 6, maximum: 8), target: .weight(try XCTUnwrap(Mass(40))))
            let plan = exercises.map {
                PlannedExercise(variant: ExerciseVariant(exercise: $0, equipment: nil, measurement: .weightReps(basis: .total, reps: .perSide)), prescription: firstBlock)
            }
            let group = RoutineGroup(kind: .superset, exerciseIDs: plan.map(\.id), rounds: 2, restBetweenExercises: 20, restBetweenRounds: 75)
            let version = try store.saveRoutine(name: "Upper", exercises: plan, groups: [group], at: date)
            let session = try store.startSession(versionID: version.id, at: date)
            try store.prepareWorkoutLog(session.id)
            let rows = try XCTUnwrap(store.records.activeSession?.workoutLog?.exercises)
            let first = rows[0].rows[0]
            let second = rows[1].rows[0]
            var input = WorkoutSetInput(unit: .kg, prescription: first.prescription)
            input.reps = "7"
            input.rightReps = "5"
            input.separateSides = true
            input.rightAmount = "35"
            try store.changeWorkout(session.id, .editSet(rows[0].id, first.id, input), at: date)
            try store.changeWorkout(session.id, .trackRest(true), at: date)
            try store.changeWorkout(session.id, .complete(rows[0].id, first.id, .kg), at: date.addingTimeInterval(5))
            try store.changeWorkout(session.id, .pause, at: date.addingTimeInterval(15))
            let reopened = try TrainingRepository(files: files, catalog: exercises)
            let paused = try XCTUnwrap(reopened.records.activeSession)
            let later = date.addingTimeInterval(300)
            let times = paused.workoutTimes(at: later, clock: paused.workoutLog?.clock)
            XCTAssertEqual(times.active, 15)
            XCTAssertEqual(times.paused, 285)
            XCTAssertEqual(paused.workoutLog?.rest?.remaining(active: times.active), 10)
            XCTAssertEqual(paused.workoutLog?.rest?.startedAt, date.addingTimeInterval(5))
            XCTAssertThrowsError(try reopened.changeWorkout(session.id, .complete(rows[1].id, second.id, .kg), at: later))
            try reopened.changeWorkout(session.id, .resume, at: later)
            try reopened.changeWorkout(session.id, .editRest(first.id, "22"), at: later)
            try reopened.changeWorkout(session.id, .complete(rows[1].id, second.id, .kg), at: later.addingTimeInterval(10))
            let active = try XCTUnwrap(reopened.records.activeSession)
            XCTAssertEqual(active.workoutLog?.rest?.targetSeconds, 75)
            let result = try XCTUnwrap(active.performedSets.first)
            XCTAssertEqual(result.repetitions, .separateSides(left: 7, right: 5))
            XCTAssertEqual(result.rightAmount, .weight(try XCTUnwrap(Mass(35))))
            XCTAssertEqual(result.actualRest?.measuredSeconds, 20)
            XCTAssertEqual(result.actualRest?.editedSeconds, 22)
            try reopened.changeWorkout(session.id, .removeExercise(rows[0].id), at: later.addingTimeInterval(11))
            try reopened.changeWorkout(session.id, .undoLast, at: later.addingTimeInterval(12))
            XCTAssertEqual(reopened.records.activeSession?.performedSets, active.performedSets)
        }
    }

    func testPlateCalculatorHonorsAvailablePairs() throws {
        let plates = try WorkoutLoadProfile.parsePlates("20x1, 5x1, 2.5x1")
        let profile = WorkoutLoadProfile(unit: .kg, bar: 20, plates: plates)
        let options = try XCTUnwrap(profile.options(for: 65))
        XCTAssertEqual(options.plates, [20, 2.5])
        XCTAssertEqual(options.lower, 60)
        XCTAssertEqual(options.upper, 70)
        XCTAssertNil(try profile.options(for: 40)?.plates)
        XCTAssertThrowsError(try WorkoutLoadProfile.parsePlates("5x31"))
    }
}
