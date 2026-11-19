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
            amount: planned.target, recordedAt: finished)
        records.sessions = [WorkoutSession(localDate: date, timeZoneIdentifier: "GMT", startedAt: date.calendarDate,
            scheduleID: nil, routineSnapshot: version, completedAt: finished, performedSets: [first, second])]

        func suggestion() -> ProgressionSuggestion { ExerciseProgression.suggest(row, in: version, records: records) }
        XCTAssertEqual(suggestion().action, .learning)
        records.sessions.append(WorkoutSession(localDate: date.offset(-1), timeZoneIdentifier: "GMT",
            startedAt: date.offset(-1).calendarDate, scheduleID: nil, routineSnapshot: version,
            completedAt: date.offset(-1).calendarDate.addingTimeInterval(60), performedSets: [first, second]))
        XCTAssertTrue(suggestion().reason.contains("Add one rep"))
        records.sessions[0].performedSets[0].repetitions = .separateSides(left: 8, right: 8)
        records.sessions[1].performedSets[0].repetitions = .separateSides(left: 8, right: 8)
        XCTAssertEqual(suggestion().action, .advance)
        XCTAssertEqual(suggestion().changes[0]?.target, .assistance(try XCTUnwrap(Mass(5))))
        XCTAssertNotNil(suggestion().warning)
        records.sessions[0].performedSets[0].actualRIR = 1
        XCTAssertEqual(suggestion().action, .hold)
        XCTAssertTrue(suggestion().reason.contains("excessive effort"))
        records.sessions[0].performedSets[0].actualRIR = 3
        records.progressionRules = [ExerciseProgressionRule(variant: variant.key, rule: ProgressionRule(mode: .assistance, step: 20))]
        XCTAssertTrue(suggestion().reason.contains("full available increment"))

        let changed = PlannedExercise(variant: ExerciseVariant(exercise: exercise, equipment: Equipment(name: "Station B", kind: .machine),
            measurement: variant.measurement), prescription: planned)
        XCTAssertNil(records.progressionRule(for: changed))
        records.progressionRules?.append(ExerciseProgressionRule(variant: changed.variant.key, rule: rule))
        XCTAssertEqual(ExerciseProgression.suggest(changed, in: version, records: records).action, .learning)
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
            var previous = draft
            previous.start = start.addingTimeInterval(-86_400)
            _ = try store.saveHistory(previous, at: now, timeZone: .gmt)
            func suggestion() -> ProgressionSuggestion { ExerciseProgression.suggest(row, in: version, records: store.records) }
            let reviewed = suggestion()
            XCTAssertEqual(reviewed.action, .advance)
            XCTAssertEqual(reviewed.excluded.count, 3)

            var correction = HistoryEditDraft(session: old, day: day, start: start, unit: .kg)
            correction.exercises[0].sets[1].input.reps = "5"
            _ = try store.saveHistory(correction, at: now, timeZone: .gmt)
            XCTAssertThrowsError(try store.acceptProgression(reviewed, versionID: version.id, rowID: row.id))
            XCTAssertEqual(suggestion().action, .hold)
            correction.exercises[0].sets[1].input.reps = "8"
            _ = try store.saveHistory(correction, at: now, timeZone: .gmt)
            let refreshed = suggestion()
            try store.acceptProgression(refreshed, versionID: version.id, rowID: row.id, scope: .once)
            let next = try store.startSession(versionID: version.id, at: now, timeZone: .gmt)
            XCTAssertEqual(next.plan.exercises[0].prescription.target, .weight(try XCTUnwrap(Mass(112.5))))
            XCTAssertEqual(next.routineSnapshot, version)
            XCTAssertTrue(store.records.progressionDecisions?.isEmpty == true)
            try store.finishSession(next.id, early: true, at: now)
            for offset in [1, 2] {
                var normal = draft
                normal.start = start.addingTimeInterval(Double(offset) * 86_400)
                _ = try store.saveHistory(normal, at: normal.start.addingTimeInterval(3600), timeZone: .gmt)
            }
            try store.acceptProgression(suggestion(), versionID: version.id, rowID: row.id)
            let reopened = try TrainingRepository(files: files, catalog: [press])
            let current = try XCTUnwrap(reopened.records.currentRoutines.first)
            XCTAssertEqual(current.revision, 2)
            XCTAssertEqual(current.exercises[0].prescription.target, .weight(try XCTUnwrap(Mass(112.5))))
            XCTAssertEqual(current.exercises[0].warmUps, row.warmUps)
            XCTAssertEqual(current.exercises[0].additionalWorkingSets, row.additionalWorkingSets)
            XCTAssertEqual(reopened.records.schedule.first?.routineVersionID, version.id)
            XCTAssertEqual(reopened.records.sessions.first?.routineSnapshot, version)
            XCTAssertEqual(ExerciseProgression.suggest(current.exercises[0], in: current, records: reopened.records).action, .learning)
        }
    }
}
