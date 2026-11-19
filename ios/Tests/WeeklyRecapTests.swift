import Foundation
import XCTest
@testable import SetlineData

final class WeeklyRecapTests: XCTestCase {
    func testRecapReflectsCorrectedHistoryAndPreservesForecastAndCalorieInputs() async throws {
        try await MainActor.run {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SetlineRecap-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let files = TrainingFiles(directory: directory)
            let profile = ExerciseProfile(pattern: .horizontalPush, equipmentKind: .barbell, primary: [.chest],
                secondary: [.triceps, .chest], setup: "", cues: "")
            let lift = Exercise(name: "Bench press", profile: profile)
            let store = try TrainingRepository(files: files, catalog: [lift])
            let row = PlannedExercise(variant: ExerciseVariant(exercise: lift, equipment: nil, measurement: .weightReps(basis: .total, reps: .total)),
                prescription: SetPrescription(sets: 1, reps: RepRange(minimum: 5, maximum: 5), target: .weight(try XCTUnwrap(Mass(80)))),
                warmUps: [SetPrescription(sets: 1, reps: RepRange(minimum: 5, maximum: 5), target: .weight(try XCTUnwrap(Mass(30))))])
            let version = try store.saveRoutine(name: "Strength", exercises: [row])
            let day = try XCTUnwrap(WorkoutDate("2026-11-20"))
            func finish(_ date: WorkoutDate, load: Double?, early: Bool = false) throws -> WorkoutSession {
                let when = date.calendarDate.addingTimeInterval(12 * 3600)
                let slot = ScheduledWorkout(localDate: date, routineVersionID: version.id)
                try store.addScheduledWorkout(slot)
                let active = try store.startSession(versionID: version.id, scheduleID: slot.id, at: when, timeZone: .gmt)
                try store.saveSet(PerformedSet(plannedExerciseID: row.id, order: 1, repetitions: .total(5),
                    amount: .weight(try XCTUnwrap(Mass(30))), recordedAt: when.addingTimeInterval(60), purpose: .warmUp), in: active.id)
                if let load {
                    try store.saveSet(PerformedSet(plannedExerciseID: row.id, order: 2, repetitions: .total(5),
                        amount: .weight(try XCTUnwrap(Mass(load))), recordedAt: when.addingTimeInterval(120), purpose: .working), in: active.id)
                }
                try store.finishSession(active.id, early: early, at: when.addingTimeInterval(1800))
                return try XCTUnwrap(store.records.sessions.last)
            }

            _ = try finish(day.offset(-10), load: 80)
            let current = try finish(day.offset(-3), load: 90)
            _ = try finish(day.offset(-2), load: nil, early: true)
            let block = ProgramBlock(name: "Base phase", firstDay: day, lastDay: day.offset(13), weeks: [0: ProgramWeek(kind: .deload)])
            try store.addProgramBlock(block)
            try store.addScheduledWorkout(ScheduledWorkout(localDate: day.offset(1), routineVersionID: version.id, programBlockID: block.id))
            try store.saveWorkoutEnergy(WorkoutEnergyInput(activity: .variedResistance, minutes: 30), sessionID: current.id)
            XCTAssertNil(WorkoutEnergyEstimate.workout(try XCTUnwrap(store.records.sessions.first { $0.id == current.id }), records: store.records))
            try store.saveBodyweight(try XCTUnwrap(Mass(82)), on: day.offset(-5))
            try store.saveBodyweight(try XCTUnwrap(Mass(80)), on: day.offset(-3))
            try store.saveBodyweight(try XCTUnwrap(Mass(78)), on: day)

            let before = WeeklyRecap.make(store.records, anchor: day, today: day)
            XCTAssertEqual(before.sessions.planned, 3)
            XCTAssertEqual(before.sessions.scheduled, 1)
            XCTAssertEqual(before.sessions.incomplete, 1)
            XCTAssertEqual(before.sessions.deload, 1)
            XCTAssertEqual(before.deloads, [block.name])
            XCTAssertEqual(before.training.muscles[.chest]?.direct.warmUp, 2)
            XCTAssertEqual(before.training.muscles[.chest]?.direct.working, 1)
            XCTAssertEqual(before.training.muscles[.triceps]?.indirect.working, 1)
            XCTAssertEqual(before.training.totals[.volume], 450)
            XCTAssertEqual(before.personalRecords.first?.effort?.load, 90)
            XCTAssertEqual(before.weight.latest?.smoothedKilograms, 80)
            XCTAssertEqual(before.energy.total, 140)
            XCTAssertEqual(before.next?.plan.id, version.id)

            let original = try XCTUnwrap(store.records.sessions.first { $0.id == current.id })
            var correction = HistoryEditDraft(session: original, day: current.localDate, start: current.startedAt, unit: .kg)
            correction.exercises[0].sets[1].input.amount = "75"
            _ = try store.saveHistory(correction, at: day.calendarDate, timeZone: .gmt)
            let reopened = try TrainingRepository(files: files, catalog: [lift])
            XCTAssertEqual(reopened.records.sessions.first { $0.id == current.id }?.performanceForecasts, current.performanceForecasts)
            let after = WeeklyRecap.make(reopened.records, anchor: day, today: day)
            XCTAssertEqual(after.training.totals[.volume], 375)
            XCTAssertTrue(after.personalRecords.isEmpty)
            XCTAssertEqual(after.changes.first?.previous.values[.weight], 80)
            XCTAssertEqual(after.changes.first?.current.values[.weight], 75)
            XCTAssertEqual(after.energy.total, 140)
        }
    }

    func testEnergyAndProductionScoreRequireDifferentInputs() throws {
        let input = WorkoutEnergyInput(activity: .vigorousLifting, minutes: 30)
        XCTAssertEqual(WorkoutEnergyEstimate.calculate(input: input, kilograms: 80)?.kilocalories, 240)
        XCTAssertNil(WorkoutEnergyEstimate.calculate(input: input, kilograms: nil))
        XCTAssertNil(WorkoutEnergyEstimate.calculate(input: nil, kilograms: 80))
        XCTAssertNil(WorkoutEnergyEstimate.calculate(input: WorkoutEnergyInput(activity: .vigorousLifting, minutes: 0), kilograms: 80))

        let day = try XCTUnwrap(WorkoutDate("2026-11-20"))
        let output = DailyWorkoutScore.assessment(on: day, records: TrainingRecords(), today: day)
        guard case .unavailable(let reason) = output.availability else { return XCTFail("An empty day should have no score") }
        XCTAssertTrue(reason.contains("Finish a planned workout"))
        XCTAssertTrue(output.components.isEmpty)
    }

    func testWorkoutScoreUsesPrescribedSlotsAndRecalculatesCorrections() throws {
        let day = try XCTUnwrap(WorkoutDate("2026-11-20"))
        let planned = SetPrescription(sets: 2, reps: RepRange(minimum: 5, maximum: 8),
            target: .assistance(try XCTUnwrap(Mass(20))), repsInReserve: 3)
        let entry = PlannedExercise(variant: ExerciseVariant(exercise: Exercise(name: "Pull-up"), equipment: nil,
            measurement: .assistance(reps: .perSide)), prescription: planned)
        let version = RoutineVersion(routineID: UUID(), revision: 1, createdAt: day.calendarDate, name: "Pull", exercises: [entry])
        var session = WorkoutSession(localDate: day, timeZoneIdentifier: "GMT", startedAt: day.calendarDate,
            scheduleID: nil, routineSnapshot: version, completedAt: day.calendarDate.addingTimeInterval(60))
        var log = try WorkoutLog(session: session)
        session.rememberScoreSlots(from: log)
        let first = log.exercises[0].rows[0].id
        log.exercises[0].rows[0].status = .completed
        log.exercises[0].rows[1].status = .skipped
        let extra = WorkoutSetRow(purpose: .working, prescription: planned, status: .completed)
        log.exercises[0].rows.insert(extra, at: 0)
        session.workoutLog = log
        session.performedSets = [
            PerformedSet(id: first, plannedExerciseID: entry.id, order: 2, repetitions: .perSide(7),
                amount: planned.target, actualRIR: 1),
            PerformedSet(id: extra.id, plannedExerciseID: entry.id, order: 1, repetitions: .perSide(20),
                amount: planned.target, actualRIR: 3),
        ]
        let initial = PrescribedWorkoutScore.assessment(session)
        guard case .available(let score) = initial.availability else { return XCTFail("Expected a score") }
        XCTAssertEqual(score, 65)
        XCTAssertTrue(initial.components[0].detail.contains("1 of 2"))
        session.performedSets[0].amount = .assistance(try XCTUnwrap(Mass(40)))
        session.performedSets[0].actualRIR = nil
        let corrected = PrescribedWorkoutScore.assessment(session)
        guard case .available(let updated) = corrected.availability else { return XCTFail("Expected an updated score") }
        XCTAssertEqual(updated, 50)
        XCTAssertNil(corrected.components[2].points)
    }
}
