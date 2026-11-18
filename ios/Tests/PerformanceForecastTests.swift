import Foundation
import XCTest
@testable import SetlineData

final class PerformanceForecastTests: XCTestCase {
    func testCutoffDeloadEquipmentAndLongBreakUseOnlyComparableResults() throws {
        let lift = Exercise(name: "Press")
        let equipment = Equipment(name: "Station A", kind: .machine)
        let variant = ExerciseVariant(exercise: lift, equipment: equipment, measurement: .weightReps(basis: .total, reps: .total))
        let target = SetAmount.weight(try XCTUnwrap(Mass(100)))
        let row = PlannedExercise(variant: variant, prescription: SetPrescription(sets: 1, reps: RepRange(minimum: 6, maximum: 10), target: target))
        let day = try XCTUnwrap(WorkoutDate("2026-11-18"))
        let start = day.calendarDate.addingTimeInterval(12 * 3600)
        let version = RoutineVersion(routineID: UUID(), revision: 1, createdAt: start, name: "Press day", exercises: [row])
        func workout(_ offset: Int, reps: Int) -> WorkoutSession {
            let date = day.offset(offset)
            let began = date.calendarDate.addingTimeInterval(12 * 3600)
            let end = began.addingTimeInterval(120)
            return WorkoutSession(localDate: date, timeZoneIdentifier: "GMT", startedAt: began, scheduleID: nil, routineSnapshot: version,
                completedAt: end, performedSets: [PerformedSet(plannedExerciseID: row.id, order: 1, repetitions: .total(reps), amount: target,
                    recordedAt: began.addingTimeInterval(60), purpose: .working)], forecastEvidenceAt: end)
        }

        var records = TrainingRecords()
        records.sessions = [workout(-13, reps: 8), workout(-11, reps: 9), workout(-9, reps: 8), workout(-7, reps: 9), workout(-5, reps: 8), workout(-3, reps: 40)]
        let deloadDay = day.offset(-2)
        let block = ProgramBlock(name: "Deload", firstDay: deloadDay, lastDay: day.offset(-1), weeks: [0: ProgramWeek(kind: .deload)])
        records.programBlocks = [block]
        records.sessions.append(workout(-1, reps: 4))
        var backfill = workout(-4, reps: 60)
        backfill.forecastEvidenceAt = start.addingTimeInterval(1)
        records.sessions.append(backfill)
        records.sessions.append(workout(0, reps: 70))

        let forecast = ExerciseForecasts.make(for: row, in: version, records: records, at: start, day: day, deload: false)
        XCTAssertEqual(forecast.status, .ready)
        XCTAssertEqual(forecast.sources.count, 5)
        XCTAssertEqual(forecast.ranges[.reps]?.center, 8)
        XCTAssertEqual(forecast.previous?.values[.reps], 40)
        XCTAssertTrue(forecast.notes.contains { $0.contains("outside the recent range") })
        XCTAssertTrue(forecast.notes.contains { $0.contains("deloads") })
        XCTAssertEqual(ExerciseForecasts.make(for: row, in: version, records: records, at: start, day: day, deload: true).status, .paused)
        let later = ExerciseForecasts.make(for: row, in: version, records: records, at: start, day: day.offset(30), deload: false)
        XCTAssertGreaterThan(try XCTUnwrap(later.ranges[.weight]?.high), try XCTUnwrap(forecast.ranges[.weight]?.high))
        XCTAssertEqual(ExerciseForecasts.make(for: row, in: version, records: records, at: start, day: day.offset(140), deload: false).status, .learning)
        let switched = PlannedExercise(id: row.id, variant: ExerciseVariant(exercise: lift, equipment: Equipment(name: "Station B", kind: .machine),
            measurement: variant.measurement), prescription: row.prescription)
        let incompatible = ExerciseForecasts.make(for: switched, in: version, records: records, at: start, day: day, deload: false)
        XCTAssertEqual(incompatible.status, .learning)
        XCTAssertTrue(incompatible.notes.contains { $0.contains("different equipment") })
    }

    func testStoredModelAndBenchmarkSurviveHistoryCorrection() async throws {
        try await MainActor.run {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SetlineForecast-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let files = TrainingFiles(directory: directory)
            let exercise = Exercise(name: "Bench press")
            let store = try TrainingRepository(files: files, catalog: [exercise])
            let target = SetAmount.weight(try XCTUnwrap(Mass(100)))
            let row = PlannedExercise(variant: ExerciseVariant(exercise: exercise, equipment: nil, measurement: .weightReps(basis: .total, reps: .total)),
                prescription: SetPrescription(sets: 1, reps: RepRange(minimum: 6, maximum: 10), target: target))
            let routine = try store.saveRoutine(name: "Bench day", exercises: [row])
            let day = try XCTUnwrap(WorkoutDate("2026-11-18"))
            let start = day.calendarDate.addingTimeInterval(12 * 3600)
            for (offset, reps) in [(-14, 8), (-7, 10), (-3, 12), (0, 9)] {
                let begins = day.offset(offset).calendarDate.addingTimeInterval(12 * 3600)
                let session = try store.startSession(versionID: routine.id, at: begins, timeZone: .gmt)
                try store.saveSet(PerformedSet(plannedExerciseID: row.id, order: 1, repetitions: .total(reps), amount: target,
                    recordedAt: begins.addingTimeInterval(60)), in: session.id)
                try store.finishSession(session.id, at: begins.addingTimeInterval(120))
            }
            let restarted = try TrainingRepository(files: files, catalog: [exercise])
            let saved = try XCTUnwrap(restarted.records.sessions.last?.performanceForecasts?.first)
            XCTAssertEqual(saved.issuedAt, start)
            XCTAssertEqual(saved.status, .ready)
            XCTAssertEqual(saved.ranges[.reps]?.center, 10)
            XCTAssertEqual(saved.previous?.values[.reps], 12)
            let score = try XCTUnwrap(ExerciseForecasts.scores(restarted.records).first)
            XCTAssertEqual(score.count, 1)
            XCTAssertEqual(score.metrics[.reps]?.forecastError, 1)
            XCTAssertEqual(score.metrics[.reps]?.previousError, 3)

            let earlier = restarted.records.sessions[2]
            var correction = HistoryEditDraft(session: earlier, day: earlier.localDate, start: earlier.startedAt, unit: .kg)
            correction.exercises[0].sets[0].input.reps = "15"
            let correctedAt = start.addingTimeInterval(3600)
            _ = try restarted.saveHistory(correction, at: correctedAt, timeZone: .gmt)
            XCTAssertEqual(restarted.records.sessions.last?.performanceForecasts, [saved])
            XCTAssertEqual(ExerciseForecasts.scores(restarted.records).first?.metrics[.reps]?.previousError, 3)
            let oldCutoff = ExerciseForecasts.make(for: row, in: routine, records: restarted.records, at: start, day: day, deload: false)
            XCTAssertFalse(oldCutoff.sources.contains { $0.id == earlier.id })
            let future = ExerciseForecasts.make(for: row, in: routine, records: restarted.records, at: correctedAt.addingTimeInterval(60), day: day, deload: false)
            XCTAssertTrue(future.sources.contains { $0.id == earlier.id })
            XCTAssertEqual(restarted.records.currentRoutines.first?.id, routine.id)
        }
    }
}
