import Foundation
import XCTest
@testable import SetlineData

final class SchedulePlanningTests: XCTestCase {
    func testTrainingWeekUsesLocalCalendarDays() throws {
        let date = try XCTUnwrap(WorkoutDate("2026-11-01"))
        let week = ScheduleSettings(weekStart: .thursday, mode: .week).dates(around: date)
        XCTAssertEqual(week.map(\.key), ["2026-10-29", "2026-10-30", "2026-10-31", "2026-11-01", "2026-11-02", "2026-11-03", "2026-11-04"])
        XCTAssertEqual(ScheduleSettings(mode: .rolling).dates(around: date).first, date)
        XCTAssertEqual(date.distance(to: date.offset(2)), 2)
    }

    func testRotationMovesWithoutAdvancingUntilActualCompletion() async throws {
        try await MainActor.run {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SetlineSchedule-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let files = TrainingFiles(directory: directory)
            let anchor = try XCTUnwrap(WorkoutDate("2026-11-18"))
            let upper = Exercise(name: "Press", profile: ExerciseProfile(primary: [.chest]))
            let lower = Exercise(name: "Squat", profile: ExerciseProfile(primary: [.quads], secondary: [.core]))
            let store = try TrainingRepository(files: files, catalog: [upper, lower])
            @MainActor func routine(_ exercise: Exercise) throws -> RoutineVersion {
                let row = PlannedExercise(variant: ExerciseVariant(exercise: exercise, equipment: nil, measurement: .bodyweight(reps: .total)),
                    prescription: SetPrescription(sets: 1, reps: RepRange(minimum: 5, maximum: 5)))
                return try store.saveRoutine(name: exercise.name, exercises: [row])
            }
            let first = try routine(upper)
            let second = try routine(lower)
            try store.saveRotation(RoutineRotation(start: anchor, interval: 1, versionIDs: [first.id, second.id]), today: anchor)
            let tomorrow = anchor.offset(1)
            let visible = store.records.scheduled(on: [anchor, tomorrow, tomorrow.offset(1)], today: tomorrow)
            XCTAssertEqual(visible.map(\.status), [.missed, .planned])
            XCTAssertEqual(visible.map(\.versionID), [first.id, first.id])
            XCTAssertThrowsError(try store.skipSchedule(visible[0].id, on: anchor, today: tomorrow))
            try store.skipSchedule(visible[1].id, on: tomorrow, today: tomorrow)
            let projected = try XCTUnwrap(store.records.scheduled(on: [tomorrow.offset(1)], today: tomorrow).first)
            XCTAssertEqual(projected.versionID, second.id)
            let movedDate = anchor.offset(4)
            try store.moveSchedule(projected.id, on: projected.date, to: movedDate, today: tomorrow)
            let reopened = try TrainingRepository(files: files, catalog: [upper, lower])
            let moved = try XCTUnwrap(reopened.records.scheduled(on: [movedDate], today: movedDate).first)
            XCTAssertEqual(moved.status, .rescheduled)
            let start = movedDate.calendarDate.addingTimeInterval(12 * 3600)
            let session = try reopened.startScheduled(moved.id, on: movedDate, at: start, timeZone: .gmt)
            XCTAssertTrue(reopened.records.recentMuscles(asOf: movedDate).isEmpty)
            try reopened.prepareWorkoutLog(session.id)
            let exercise = try XCTUnwrap(reopened.records.activeSession?.workoutLog?.exercises.first)
            try reopened.changeWorkout(session.id, .complete(exercise.id, exercise.rows[0].id, .kg), at: start)
            try reopened.finishSession(session.id, early: true, at: start.addingTimeInterval(1))
            XCTAssertEqual(reopened.records.scheduled(on: [movedDate, movedDate.offset(1)], today: movedDate).map(\.versionID), [second.id, first.id])
            XCTAssertEqual(reopened.records.recentMuscles(asOf: movedDate.offset(1))[.quads]?.days, 1)
            XCTAssertNil(reopened.records.recentMuscles(asOf: movedDate)[.chest])
        }
    }

    func testDeloadAndReadinessPersistWithPinnedPrescription() async throws {
        try await MainActor.run {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SetlineProgram-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let files = TrainingFiles(directory: directory)
            let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-19T03:30:00Z"))
            let zone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
            let day = WorkoutDate(date, timeZone: zone)
            XCTAssertEqual(day.key, "2026-11-18")
            let exercise = Exercise(name: "Press")
            let store = try TrainingRepository(files: files, catalog: [exercise])
            let row = PlannedExercise(variant: ExerciseVariant(exercise: exercise, equipment: nil, measurement: .bodyweight(reps: .total)),
                prescription: SetPrescription(sets: 1, reps: RepRange(minimum: 3, maximum: 3)))
            let version = try store.saveRoutine(name: "Deload", exercises: [row])
            let block = ProgramBlock(name: "Strength", firstDay: day.offset(-7), lastDay: day.offset(6))
            try store.addProgramBlock(block)
            try store.setProgramWeek(blockID: block.id, index: 1, week: ProgramWeek(kind: .deload, notes: "Reduce reps"))
            try store.addScheduledWorkout(ScheduledWorkout(localDate: day, routineVersionID: version.id, programBlockID: block.id))
            try store.saveReadiness(on: day, soreness: 4, sleep: 2, energy: 1, motivation: 3, at: date, timeZone: zone)
            let reopened = try TrainingRepository(files: files, catalog: [exercise])
            XCTAssertEqual(reopened.records.programBlocks[0].weeks?[1]?.kind, .deload)
            XCTAssertEqual(reopened.records.readiness[0].sleepQuality, 2)
            let entry = try XCTUnwrap(reopened.records.scheduled(on: [day], today: day).first)
            let session = try reopened.startScheduled(entry.id, on: day, at: date, timeZone: zone)
            XCTAssertEqual(session.routineSnapshot.id, version.id)
            XCTAssertEqual(session.plan.exercises[0].prescription.reps?.minimum, 3)
        }
    }
}
