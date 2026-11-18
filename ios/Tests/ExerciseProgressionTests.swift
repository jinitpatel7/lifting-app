import Foundation
import XCTest
@testable import SetlineData

final class ExerciseProgressionTests: XCTestCase {
    func testConservativeRepCriteriaAndCoarseAssistanceWithUnilateralResults() throws {
        let machine = Equipment(name: "Assisted station A", kind: .machine)
        let exercise = Exercise(name: "Assisted pull-up")
        let variant = ExerciseVariant(exercise: exercise, equipment: machine, measurement: .assistance(reps: .perSide))
        let planned = SetPrescription(sets: 2, reps: RepRange(minimum: 6, maximum: 8), target: .assistance(try XCTUnwrap(Mass(15))))
        let row = PlannedExercise(variant: variant, prescription: planned)
        let date = try XCTUnwrap(WorkoutDate("2026-11-18"))
        let version = RoutineVersion(routineID: UUID(), revision: 1, createdAt: date.calendarDate, name: "Pull", exercises: [row])
        let rule = ProgressionRule(mode: .assistance, step: 10, effort: .rir, effortLimit: 2)
        var records = TrainingRecords()
        records.progressionRules = [ExerciseProgressionRule(variant: variant.key, rule: rule)]
        let finished = date.calendarDate.addingTimeInterval(60)
        let first = PerformedSet(plannedExerciseID: row.id, order: 1, repetitions: .separateSides(left: 8, right: 7),
            amount: planned.target, recordedAt: finished)
        let second = PerformedSet(plannedExerciseID: row.id, order: 2, repetitions: .perSide(8),
            amount: planned.target, recordedAt: finished, actualRIR: 1)
        records.sessions = [WorkoutSession(localDate: date, timeZoneIdentifier: "GMT", startedAt: date.calendarDate,
            scheduleID: nil, routineSnapshot: version, completedAt: finished, performedSets: [first, second])]

        func suggestion() -> ProgressionSuggestion { ExerciseProgression.suggest(row, in: version, records: records) }
        XCTAssertEqual(suggestion().action, .hold)
        XCTAssertTrue(suggestion().reason.contains("1 of 2"))
        records.sessions[0].performedSets[0].repetitions = .separateSides(left: 8, right: 8)
        XCTAssertEqual(suggestion().action, .advance)
        XCTAssertTrue(suggestion().reason.contains("only 1 of 2"))
        XCTAssertEqual(suggestion().changes[0]?.target, .assistance(try XCTUnwrap(Mass(5))))
        records.sessions[0].performedSets[0].actualRIR = 2
        XCTAssertEqual(suggestion().action, .hold)
        XCTAssertTrue(suggestion().reason.contains("recorded RIR missed"))
        records.sessions[0].performedSets[1].actualRIR = 3
        records.progressionRules = [ExerciseProgressionRule(variant: variant.key, rule: ProgressionRule(mode: .assistance, step: 20))]
        XCTAssertTrue(suggestion().reason.contains("full available increment"))

        let changed = PlannedExercise(variant: ExerciseVariant(exercise: exercise, equipment: Equipment(name: "Station B", kind: .machine),
            measurement: variant.measurement), prescription: planned)
        XCTAssertNil(records.progressionRule(for: changed))
        records.progressionRules?.append(ExerciseProgressionRule(variant: changed.variant.key, rule: rule))
        XCTAssertTrue(ExerciseProgression.suggest(changed, in: version, records: records).reason.contains("same exercise, equipment, and measurement"))
    }

    func testHistoryEditsRefreshTheSuggestionAndAcceptancePreservesScheduleAndHistory() async throws {
        try await MainActor.run {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SetlineProgression-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let files = TrainingFiles(directory: directory)
            let press = Exercise(name: "Bench Press")
            let store = try TrainingRepository(files: files, catalog: [press])
            let range = RepRange(minimum: 6, maximum: 8)
            let target = SetAmount.weight(try XCTUnwrap(Mass(100)))
            let row = PlannedExercise(variant: ExerciseVariant(exercise: press, equipment: nil, measurement: .weightReps(basis: .total, reps: .total)),
                prescription: SetPrescription(sets: 2, reps: range, target: target),
                warmUps: [SetPrescription(sets: 1, reps: range)],
                additionalWorkingSets: [SetPrescription(sets: 1, reps: range, amrap: true), SetPrescription(sets: 1, reps: range, structure: .dropSet)])
            let version = try store.saveRoutine(name: "Bench day", exercises: [row])
            let day = try XCTUnwrap(WorkoutDate("2026-11-18"))
            try store.addScheduledWorkout(ScheduledWorkout(localDate: day.offset(3), routineVersionID: version.id))
            try store.saveProgressionRule(ProgressionRule(mode: .load, miss: .stepBack, step: 12.5), versionID: version.id, rowID: row.id)
            let start = day.calendarDate.addingTimeInterval(12 * 3600)
            let now = start.addingTimeInterval(3600)
            var draft = HistoryEditDraft(template: version, day: day, start: start, unit: .kg)
            for index in 1...2 {
                draft.exercises[0].sets[index].row.status = .completed
                draft.exercises[0].sets[index].input.amount = "100"
                draft.exercises[0].sets[index].input.reps = "8"
            }
            _ = try store.saveHistory(draft, at: now, timeZone: .gmt)
            let old = try XCTUnwrap(store.records.sessions.first)
            func suggestion() -> ProgressionSuggestion { ExerciseProgression.suggest(row, in: version, records: store.records) }
            let reviewed = suggestion()
            XCTAssertEqual(reviewed.action, .advance)
            XCTAssertEqual(reviewed.excluded.count, 3)

            var correction = HistoryEditDraft(session: old, day: day, start: start, unit: .kg)
            correction.exercises[0].sets[1].input.reps = "5"
            _ = try store.saveHistory(correction, at: now, timeZone: .gmt)
            XCTAssertThrowsError(try store.acceptProgression(reviewed, versionID: version.id, rowID: row.id))
            let adjusted = suggestion()
            XCTAssertEqual(adjusted.action, .adjust)
            try store.acceptProgression(adjusted, versionID: version.id, rowID: row.id)
            let reopened = try TrainingRepository(files: files, catalog: [press])
            let current = try XCTUnwrap(reopened.records.currentRoutines.first)
            XCTAssertEqual(current.revision, 2)
            XCTAssertEqual(current.exercises[0].prescription.target, .weight(try XCTUnwrap(Mass(87.5))))
            XCTAssertEqual(current.exercises[0].warmUps, row.warmUps)
            XCTAssertEqual(current.exercises[0].additionalWorkingSets, row.additionalWorkingSets)
            XCTAssertEqual(reopened.records.schedule.first?.routineVersionID, version.id)
            XCTAssertEqual(reopened.records.sessions.first?.routineSnapshot, version)
            XCTAssertTrue(ExerciseProgression.suggest(current.exercises[0], in: current, records: reopened.records).reason.contains("different targets"))
        }
    }
}
