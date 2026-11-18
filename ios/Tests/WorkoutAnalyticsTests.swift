import Foundation
import XCTest
@testable import SetlineData

final class WorkoutAnalyticsTests: XCTestCase {
    private func date(_ day: Int) throws -> WorkoutDate {
        try XCTUnwrap(WorkoutDate(String(format: "2026-11-%02d", day)))
    }

    private func entry(_ exercise: Exercise, equipment: Equipment? = nil, counting: RepCounting = .total,
                       basis: LoadBasis = .total) -> PlannedExercise {
        let plan = SetPrescription(sets: 3, reps: RepRange(minimum: 5, maximum: 5))
        return PlannedExercise(variant: ExerciseVariant(exercise: exercise, equipment: equipment, measurement: .weightReps(basis: basis, reps: counting)),
            prescription: plan, warmUps: [SetPrescription(sets: 1, reps: RepRange(minimum: 5, maximum: 5))])
    }

    private func lift(_ row: PlannedExercise, _ load: Double, _ reps: Repetitions, order: Int = 1,
                      purpose: SetPurpose = .working, right: Double? = nil) throws -> PerformedSet {
        PerformedSet(plannedExerciseID: row.id, order: order, repetitions: reps,
            amount: .weight(try XCTUnwrap(Mass(load))), purpose: purpose, rightAmount: right.flatMap { Mass($0) }.map(SetAmount.weight))
    }

    private func session(_ date: WorkoutDate, _ version: RoutineVersion, sets: [PerformedSet], scheduleID: UUID? = nil) -> WorkoutSession {
        WorkoutSession(localDate: date, timeZoneIdentifier: "GMT", startedAt: date.calendarDate, scheduleID: scheduleID,
            routineSnapshot: version, completedAt: date.calendarDate.addingTimeInterval(1800), performedSets: sets)
    }

    func testVolumeRecordsAndWeeklyMusclesUseActualSetsAndSeparateWarmups() throws {
        let exercise = Exercise(name: "Bench Press", profile: ExerciseProfile(equipmentKind: .barbell,
            primary: [.chest], secondary: [.chest, .triceps]))
        let row = entry(exercise)
        let version = RoutineVersion(routineID: UUID(), revision: 1, createdAt: Date(), name: "Upper", exercises: [row])
        let day = try date(18)
        let scheduled = ScheduledWorkout(localDate: day, routineVersionID: version.id)
        let sets = try [lift(row, 40, .total(10), purpose: .warmUp), lift(row, 100, .total(5), order: 2),
                        lift(row, 80, .total(8), order: 3)]
        let record = session(day, version, sets: sets, scheduleID: scheduled.id)
        var records = TrainingRecords()
        records.sessions = [record]
        records.schedule = [scheduled]
        records.routineVersions = [version]
        let working = try XCTUnwrap(WorkoutAnalytics.exercises(records, filter: .init(), purpose: .working, settings: .init()).first)
        let point = try XCTUnwrap(working.points.first)
        XCTAssertEqual(point.values[.volume], 1140)
        XCTAssertEqual(point.values[.reps], 13)
        XCTAssertEqual(try XCTUnwrap(point.values[.estimate]), 116.666666, accuracy: 0.00001)
        XCTAssertEqual(working.records.heaviest?.load, 100)
        XCTAssertEqual(working.records.byReps.first(where: { $0.reps == 8 })?.load, 80)
        let warmUp = try XCTUnwrap(WorkoutAnalytics.exercises(records, filter: .init(), purpose: .warmUp, settings: .init()).first)
        XCTAssertEqual(warmUp.points.first?.values[.volume], 400)
        XCTAssertNil(warmUp.points.first?.values[.estimate])
        let report = WorkoutAnalytics.weekly(records, anchor: day, filter: .init(), today: day)
        XCTAssertEqual(report.planned.working, 3)
        XCTAssertEqual(report.performed.working, 2)
        XCTAssertEqual(report.performed.warmUp, 1)
        XCTAssertEqual(report.muscles[.chest]?.direct.working, 2)
        XCTAssertEqual(report.muscles[.chest]?.indirect.working, 0)
        XCTAssertEqual(report.muscles[.triceps]?.indirect.warmUp, 1)
    }

    func testUnilateralRecordsAndMachineIsolation() throws {
        let exercise = Exercise(name: "Row", profile: ExerciseProfile(equipmentKind: .dumbbell))
        let unilateral = entry(exercise, counting: .perSide, basis: .perDumbbell)
        let different = try lift(unilateral, 20, .separateSides(left: 8, right: 10), right: 15)
        XCTAssertEqual(WorkoutHistory.volume(different, exercise: unilateral), 310)
        XCTAssertNil(WorkoutAnalytics.estimatedMax(different, row: unilateral))
        let bilateral = entry(exercise, basis: .perDumbbell)
        XCTAssertEqual(WorkoutHistory.volume(try lift(bilateral, 20, .total(8)), exercise: bilateral), 320)
        let machineA = entry(exercise, equipment: Equipment(name: "Machine A", kind: .machine))
        let machineB = entry(exercise, equipment: Equipment(name: "Machine B", kind: .machine))
        let first = RoutineVersion(routineID: UUID(), revision: 1, createdAt: Date(), name: "Row", exercises: [machineA])
        let second = RoutineVersion(routineID: first.routineID, revision: 2, createdAt: Date(), name: "Row", exercises: [machineB])
        let a = session(try date(1), first, sets: [try lift(machineA, 65, .total(5))])
        let b = session(try date(3), second, sets: [try lift(machineB, 85, .total(5))])
        var records = TrainingRecords()
        records.sessions = [b, a]
        let results = WorkoutAnalytics.exercises(records, filter: .init(), purpose: .working, settings: .init())
        XCTAssertEqual(results.count, 2)
        let changed = try XCTUnwrap(results.first { $0.row.variant.equipment?.id == machineB.variant.equipment?.id })
        XCTAssertTrue(changed.points[0].events.contains("Equipment changed"))
        XCTAssertNil(changed.points[0].values[.estimate])
        let scope = HistoryScope(exerciseID: exercise.id, label: exercise.name)
        XCTAssertNil(WorkoutHistory.compare(b, a, scope: scope).volumeChange)
        XCTAssertNil(WorkoutHistory.metrics(b).volume)
    }

    func testPlateauIgnoresPlannedDeloadAndResetsAfterBreak() throws {
        let exercise = Exercise(name: "Bench Press", profile: ExerciseProfile(equipmentKind: .barbell))
        let row = entry(exercise)
        let v = RoutineVersion(routineID: UUID(), revision: 1, createdAt: Date(), name: "Upper", exercises: [row])
        var records = TrainingRecords()
        let block = ProgramBlock(name: "Strength", firstDay: try date(1), lastDay: try date(23),
            weeks: [1: ProgramWeek(kind: .deload)])
        records.programBlocks = [block]
        records.sessions = try [1, 3, 5, 7].map { session(try date($0), v, sets: [try lift(row, 100, .total(5))]) }
        XCTAssertEqual(WorkoutAnalytics.exercises(records, filter: .init(), purpose: .working, settings: .init()).first?.plateau,
            .flag(change: 0, count: 4))
        records.sessions.append(session(try date(8), v, sets: [try lift(row, 70, .total(5))]))
        XCTAssertEqual(WorkoutAnalytics.exercises(records, filter: .init(), purpose: .working, settings: .init()).first?.plateau, .deload)
        records.sessions.append(session(try date(24), v, sets: [try lift(row, 100, .total(5))]))
        let latest = try XCTUnwrap(WorkoutAnalytics.exercises(records, filter: .init(), purpose: .working, settings: .init()).first)
        XCTAssertNil(latest.plateau)
        XCTAssertTrue(latest.points.last?.events.contains("Training break · 16 days between logs") == true)
    }
}
