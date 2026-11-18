import Foundation
import XCTest
@testable import SetlineData

final class RoutinePlanningTests: XCTestCase {
    func testRoutineVersionDuplicateAndRepeatKeepSeparateSnapshots() async throws {
        try await MainActor.run {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SetlineRoutineTests-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let files = TrainingFiles(directory: directory)
            let exercise = Exercise(name: "Press")
            let other = Exercise(name: "Row")
            let store = try TrainingRepository(files: files, catalog: [exercise, other])
            let time = Date(timeIntervalSince1970: 1_800_000_000)
            let category = RoutineCategory(name: "Upper body")
            try store.addRoutineCategory(category)
            let range = RepRange(minimum: 6, maximum: 8)
            let warm = SetPrescription(sets: 1, reps: range, target: .weight(try XCTUnwrap(Mass(20))))
            let work = SetPrescription(sets: 3, reps: range, restSeconds: 90, structure: .dropSet, amrap: true, effort: .failure)
            let second = SetPrescription(sets: 1, amrap: true, effort: .rpe(9.5))
            let measurement = Measurement.weightReps(basis: .total, reps: .total)
            let press = PlannedExercise(variant: ExerciseVariant(exercise: exercise, equipment: nil, measurement: measurement),
                                       prescription: work, warmUps: [warm], additionalWorkingSets: [second])
            let row = PlannedExercise(variant: ExerciseVariant(exercise: other, equipment: nil, measurement: measurement), prescription: work)
            let group = RoutineGroup(kind: .superset, exerciseIDs: [press.id, row.id], rounds: 3, restBetweenRounds: 90)
            let first = try store.saveRoutine(name: "Upper A", exercises: [press, row], categoryID: category.id, groups: [group], at: time)
            let active = try store.startSession(versionID: first.id, at: time, timeZone: .gmt)
            let set = PerformedSet(plannedExerciseID: press.id, order: 1, repetitions: .total(8), amount: .weight(try XCTUnwrap(Mass(60))),
                                   recordedAt: time, effortOutcome: .failure, purpose: .working, structure: .dropSet, amrap: true)
            try store.saveSet(set, in: active.id)
            let reordered = try store.saveRoutine(id: first.routineID, name: "Upper A revised", exercises: [row, press],
                                                  categoryID: category.id, groups: [group], expectedVersionID: first.id, at: time)
            XCTAssertEqual(reordered.groups?.first?.exerciseIDs, [row.id, press.id])
            XCTAssertEqual(store.records.versions(for: first.routineID), [reordered, first])
            XCTAssertEqual(store.records.activeSession?.plan, first)

            let duplicate = try store.duplicateRoutine(versionID: reordered.id, at: time)
            XCTAssertNotEqual(duplicate.routineID, first.routineID)
            XCTAssertEqual(duplicate.revision, 1)
            XCTAssertEqual(duplicate.exercises.map(\.variant), reordered.exercises.map(\.variant))
            XCTAssertNotEqual(duplicate.exercises.map(\.id), reordered.exercises.map(\.id))
            XCTAssertEqual(duplicate.groups?.first?.exerciseIDs, duplicate.exercises.map(\.id))

            XCTAssertThrowsError(try store.editSessionPlan(active.id, name: "Incomplete", exercises: [row]))
            try store.editSessionPlan(active.id, name: "Workout only", exercises: [row, press], groups: [group])
            try store.finishSession(active.id, at: time)
            let completed = try XCTUnwrap(store.records.sessions.first)
            XCTAssertEqual(completed.routineSnapshot, first)
            XCTAssertEqual(completed.plan.name, "Workout only")
            let repeated = try store.repeatSession(active.id, at: time, timeZone: .gmt)
            XCTAssertEqual(repeated.routineSnapshot, completed.plan)
            XCTAssertEqual(repeated.referenceSessionID, active.id)
            XCTAssertEqual(repeated.performedSets, [])
            let reopened = try TrainingRepository(files: files, catalog: [exercise, other])
            XCTAssertEqual(reopened.records.sessions.first?.performedSets, [set])
            XCTAssertEqual(reopened.records.versions(for: first.routineID), [reordered, first])
        }
    }

    func testInvalidGroupsAndMeasurementTargets() throws {
        let exercise = Exercise(name: "Timed carry")
        let entry = PlannedExercise(variant: ExerciseVariant(exercise: exercise, equipment: nil, measurement: .duration),
                                    prescription: SetPrescription(sets: 2, target: .durationSeconds(35), effort: .rpe(7)))
        var second = entry
        second.id = UUID()
        var third = entry
        third.id = UUID()
        let group = RoutineGroup(kind: .superset, exerciseIDs: [entry.id, third.id], rounds: 2)
        XCTAssertThrowsError(try RoutineGroup.normalized([group], exercises: [entry, second, third]))
        XCTAssertTrue(entry.prescription.isValid(for: .duration))
        XCTAssertFalse(entry.prescription.isValid(for: .distance))
        XCTAssertFalse(SetPrescription(sets: 1, effort: .rpe(11)).isValid(for: .duration))
    }
}
