import Foundation
import XCTest
@testable import SetlineData

final class DataPortabilityTests: XCTestCase {
    func testFullRestoreKeepsRelationshipsAndSampleDataSeparate() async throws {
        try await MainActor.run {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SetlineBackup-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let files = TrainingFiles(directory: directory)
            let exercise = Exercise(name: "Dumbbell press", profile: ExerciseProfile(equipmentKind: .dumbbell, setup: "Private setup"))
            let store = try TrainingRepository(files: files, catalog: [exercise])
            let gym = Equipment(name: "Dumbbells", kind: .dumbbell)
            try store.addEquipment(gym)
            let target = try XCTUnwrap(Mass(50, unit: .lb))
            let row = PlannedExercise(variant: ExerciseVariant(exercise: exercise, equipment: gym,
                measurement: .weightReps(basis: .perDumbbell, reps: .separateSides)),
                prescription: SetPrescription(sets: 1, reps: RepRange(minimum: 5, maximum: 7), target: .weight(target)))
            let routine = try store.saveRoutine(name: "Push", exercises: [row])
            let day = try XCTUnwrap(WorkoutDate("2026-11-20"))
            let start = day.calendarDate.addingTimeInterval(12 * 3600)
            let schedule = ScheduledWorkout(localDate: day, routineVersionID: routine.id)
            try store.addScheduledWorkout(schedule)
            let active = try store.startSession(versionID: routine.id, scheduleID: schedule.id, at: start, timeZone: .gmt)
            try store.prepareWorkoutLog(active.id)
            try store.changeWorkout(active.id, .sessionNotes("=Private note"), at: start)
            let set = try XCTUnwrap(store.records.activeSession?.workoutLog?.exercises.first?.rows.first)
            try store.saveSet(PerformedSet(id: set.id, plannedExerciseID: row.id, order: 1, repetitions: .separateSides(left: 6, right: 5),
                amount: .weight(try XCTUnwrap(Mass(22.5))), recordedAt: start.addingTimeInterval(60),
                rightAmount: .weight(try XCTUnwrap(Mass(20)))), in: active.id)
            try store.finishSession(active.id, at: start.addingTimeInterval(90))
            try store.saveBodyweight(try XCTUnwrap(Mass(175, unit: .lb)), on: day)
            try store.linkProgressPhotos(["asset/local"], on: day, sessionID: active.id)
            try files.saveSamplePreview(SamplePreviewState(bodyweightByDay: [day.key: 100], activeRoutineID: "sample"))

            let settings = BackupDisplaySettings(appearance: "dark", opaque: true, unit: .lb)
            let defaultFile = try SetlineBackup.make(store.records, settings: settings, options: BackupOptions())
            XCTAssertTrue(defaultFile.payload.records.photos.isEmpty)
            var included = BackupOptions()
            included.photos = true
            let original = store.records
            let decoded = try SetlineBackup.read(try SetlineBackup.make(original, settings: settings, options: included).data)
            try store.restoreBackup(decoded)
            try store.restoreBackup(decoded)
            let reopened = try TrainingRepository(files: files, catalog: [exercise])
            XCTAssertEqual(reopened.records, original)
            XCTAssertEqual(decoded.payload.settings, settings)
            XCTAssertEqual(reopened.records.sessions.first?.scheduleID, schedule.id)
            XCTAssertEqual(reopened.records.bodyweight(on: day)?.mass.value(in: .lb), 175)
            XCTAssertEqual(try files.loadSamplePreview().activeRoutineID, "sample")
            XCTAssertTrue(TrainingCSV.workouts(original, options: ShareOptions(notes: true)).contains("'=Private note"))
            XCTAssertFalse(TrainingCSV.workouts(original, options: ShareOptions()).contains("Private note"))

            let redacted = try SetlineBackup.make(original, settings: settings,
                options: BackupOptions(notes: false, bodyweight: false, readiness: false, forecasts: false, photos: false))
            XCTAssertFalse(String(decoding: try redacted.data, as: UTF8.self).contains("Private"))
            XCTAssertTrue(redacted.payload.records.bodyweightEntries.isEmpty)
            XCTAssertNil(redacted.payload.records.sessions.first?.performanceForecasts)
            var duplicate = original
            duplicate.sessions += original.sessions
            XCTAssertThrowsError(try SetlineBackup.validate(duplicate))
            XCTAssertThrowsError(try SetlineBackup.read(Data("{broken".utf8)))
        }
    }

    func testPortableRoutineKeepsTypedTargetsAndRejectsAnEquivalentSecondImport() throws {
        let exercise = Exercise(name: "Press", profile: ExerciseProfile(equipmentKind: .dumbbell, setup: "Private setup"))
        let equipment = Equipment(name: "Dumbbell rack", kind: .dumbbell)
        let amount = try XCTUnwrap(Mass(50, unit: .lb))
        let row = PlannedExercise(variant: ExerciseVariant(exercise: exercise, equipment: equipment,
            measurement: .weightReps(basis: .perDumbbell, reps: .perSide)), prescription: SetPrescription(sets: 3,
                reps: RepRange(minimum: 5, maximum: 7), target: .weight(amount), repsInReserve: 2))
        let version = RoutineVersion(routineID: UUID(), revision: 1, createdAt: Date(), name: "Strength", exercises: [row])
        let data = try RoutineExchange(version, notes: false).data
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("Private setup"))
        let file = try RoutineExchange.read(data)
        var contents = TrainingRecords()
        XCTAssertTrue(try file.insert(into: &contents, catalog: []))
        XCTAssertFalse(try file.insert(into: &contents, catalog: []))
        let imported = try XCTUnwrap(contents.currentRoutines.first?.exercises.first)
        XCTAssertNotEqual(imported.id, row.id)
        XCTAssertEqual(imported.prescription.target, .weight(amount))
        XCTAssertEqual(imported.variant.measurement, row.variant.measurement)
        XCTAssertEqual(imported.prescription.repsInReserve, 2)
    }
}
