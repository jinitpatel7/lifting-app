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
}
