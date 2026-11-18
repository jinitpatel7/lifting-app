import Foundation
import XCTest
@testable import SetlineData

final class WorkoutHistoryTests: XCTestCase {
    func testMissedWorkoutAndCorrectionRefreshDerivedResults() async throws {
        try await MainActor.run {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SetlineHistory-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let files = TrainingFiles(directory: directory)
            let press = Exercise(name: "Bench Press")
            let store = try TrainingRepository(files: files, catalog: [press])
            let entry = PlannedExercise(variant: ExerciseVariant(exercise: press, equipment: nil, measurement: .weightReps(basis: .total, reps: .total)),
                prescription: SetPrescription(sets: 1, reps: RepRange(minimum: 5, maximum: 5), target: .weight(try XCTUnwrap(Mass(70)))))
            let version = try store.saveRoutine(name: "Press Day", exercises: [entry])
            let day = try XCTUnwrap(WorkoutDate("2026-11-08"))
            let start = day.calendarDate.addingTimeInterval(12 * 3600)
            let now = start.addingTimeInterval(24 * 3600)
            var draft = HistoryEditDraft(template: version, day: day, start: start, unit: .kg)
            draft.minutes = "40"
            draft.notes = "From notebook"
            XCTAssertThrowsError(try store.saveHistory(draft, at: now, timeZone: .gmt))
            XCTAssertTrue(draft.exercises[0].sets[0].input.amount.isEmpty)
            draft.exercises[0].sets[0].row.status = .completed
            draft.exercises[0].sets[0].input.amount = "84"
            draft.exercises[0].sets[0].input.reps = "5"
            let id = try store.saveHistory(draft, at: now, timeZone: .gmt)
            let original = try XCTUnwrap(store.records.sessions.first)
            XCTAssertEqual(original.id, id)
            XCTAssertEqual(original.historyStatus, .completed)
            XCTAssertEqual(WorkoutHistory.metrics(original).duration, 2400)
            XCTAssertEqual(WorkoutHistory.metrics(original).volume, 420)
            try store.addPrediction(FuturePrediction(variant: entry.variant.key, sourceSessionIDs: [id], amount: .weight(try XCTUnwrap(Mass(85)))))
            var edit = HistoryEditDraft(session: original, day: day, start: start, unit: .kg)
            edit.exercises[0].sets[0].input.amount = "80"
            try store.saveHistory(edit, at: now, timeZone: .gmt)
            let reopened = try TrainingRepository(files: files, catalog: [press])
            let corrected = try XCTUnwrap(reopened.records.sessions.first)
            XCTAssertEqual(corrected.routineSnapshot, version)
            XCTAssertEqual(corrected.performedSets.first?.id, original.performedSets.first?.id)
            XCTAssertEqual(corrected.localDate, day)
            XCTAssertEqual(corrected.workoutLog?.notes, "From notebook")
            XCTAssertEqual(WorkoutHistory.metrics(corrected).volume, 400)
            let trend = WorkoutAnalytics.exercises(reopened.records, filter: HistoryFilter(), purpose: .working, settings: AnalyticsSettings())
            XCTAssertEqual(trend.first?.records.heaviest?.load, 80)
            XCTAssertTrue(reopened.records.predictions.isEmpty)
            XCTAssertTrue(WorkoutHistory.filtered(reopened.records.sessions, by: HistoryFilter(from: day.offset(1))).isEmpty)
        }
    }

    func testRoutineComparisonFlagsDifferentOrderAndEquipment() throws {
        let day = try XCTUnwrap(WorkoutDate("2026-11-08"))
        let start = day.calendarDate
        let routine = UUID()
        let press = Exercise(name: "Press"), row = Exercise(name: "Row")
        let firstBar = Equipment(name: "Station A", kind: .machine), secondBar = Equipment(name: "Station B", kind: .machine)
        let measurement = Measurement.weightReps(basis: .total, reps: .total)
        let prescription = SetPrescription(sets: 1, reps: RepRange(minimum: 5, maximum: 5))
        let first = PlannedExercise(variant: ExerciseVariant(exercise: press, equipment: firstBar, measurement: measurement), prescription: prescription)
        let second = PlannedExercise(variant: ExerciseVariant(exercise: row, equipment: nil, measurement: measurement), prescription: prescription)
        let changed = PlannedExercise(id: first.id, variant: ExerciseVariant(exercise: press, equipment: secondBar, measurement: measurement), prescription: prescription)
        func make(_ entries: [PlannedExercise], revision: Int, rowLoad: Double) throws -> WorkoutSession {
            let version = RoutineVersion(routineID: routine, revision: revision, createdAt: start, name: "Upper", exercises: entries)
            let performed = try entries.map { entry in
                PerformedSet(plannedExerciseID: entry.id, order: 1, repetitions: .total(5),
                    amount: .weight(try XCTUnwrap(Mass(entry.id == second.id ? rowLoad : 75))), recordedAt: start)
            }
            return WorkoutSession(localDate: day, timeZoneIdentifier: "GMT", startedAt: start, scheduleID: nil, routineSnapshot: version,
                completedAt: start, performedSets: performed)
        }
        let original = try make([first, second], revision: 1, rowLoad: 50)
        let updated = try make([second, changed], revision: 2, rowLoad: 55)
        let scope = try XCTUnwrap(WorkoutHistory.scopes(updated, original).first)
        let result = WorkoutHistory.compare(updated, original, scope: scope)
        XCTAssertTrue(result.orderChanged)
        XCTAssertTrue(result.equipmentChanged)
        XCTAssertEqual(result.volumeChange, 25)
        XCTAssertNil(WorkoutHistory.compare(updated, original, scope: HistoryScope(exerciseID: press.id, label: press.name)).volumeChange)
    }
}
