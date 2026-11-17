import Foundation
import XCTest
@testable import SetlineData

final class TrainingRepositoryTests: XCTestCase {
    func testRelaunchKeepsSessionSnapshotAndIncrementalSets() async throws {
        try await MainActor.run {
            let files = temporaryFiles()
            defer { try? FileManager.default.removeItem(at: files.directory) }
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let repository = try TrainingRepository(files: files)
            let exercise = Exercise(name: "Dumbbell Press", createdAt: now)
            let equipment = Equipment(name: "Dumbbell pair", kind: .dumbbell, createdAt: now)
            try repository.addExercise(exercise)
            try repository.addEquipment(equipment)
            let variant = ExerciseVariant(exercise: exercise, equipment: equipment,
                                          measurement: .weightReps(basis: .perDumbbell, reps: .perSide))
            let entry = PlannedExercise(variant: variant, prescription: SetPrescription(
                sets: 3, reps: RepRange(minimum: 8, maximum: 10), target: .weight(try XCTUnwrap(Mass(20)))))
            let initial = try repository.saveRoutine(name: "Press day", exercises: [entry], at: now)
            let timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
            let localDate = WorkoutDate(now, timeZone: timeZone)
            let block = ProgramBlock(name: "Volume", firstDay: localDate, lastDay: localDate, createdAt: now)
            try repository.addProgramBlock(block)
            let scheduled = ScheduledWorkout(localDate: localDate, routineVersionID: initial.id, programBlockID: block.id, createdAt: now)
            try repository.addScheduledWorkout(scheduled)
            let session = try repository.startSession(versionID: initial.id, scheduleID: scheduled.id, at: now, timeZone: timeZone)
            let load = try XCTUnwrap(Mass(45, unit: .lb))
            let performed = PerformedSet(plannedExerciseID: entry.id, order: 1, repetitions: .perSide(9),
                                         amount: .weight(load), recordedAt: now.addingTimeInterval(120))
            var mismatched = performed
            mismatched.amount = .machineSetting("45")
            XCTAssertThrowsError(try repository.saveSet(mismatched, in: session.id))
            XCTAssertTrue(repository.records.activeSession?.performedSets.isEmpty == true)
            try repository.saveSet(performed, in: session.id)
            try repository.saveSet(performed, in: session.id)

            let reopened = try TrainingRepository(files: files)
            XCTAssertEqual(reopened.records.activeSession?.id, session.id)
            XCTAssertEqual(reopened.records.activeSession?.performedSets, [performed])
            XCTAssertEqual(reopened.records.activeSession?.localDate, localDate)
            XCTAssertEqual(reopened.records.activeSession?.timeZoneIdentifier, timeZone.identifier)
            XCTAssertThrowsError(try reopened.startSession(versionID: initial.id))

            let revisedEntry = PlannedExercise(id: entry.id, variant: variant, prescription: SetPrescription(
                sets: 4, reps: RepRange(minimum: 6, maximum: 6)))
            let revised = try reopened.saveRoutine(id: initial.routineID, name: "Heavy press", exercises: [revisedEntry], at: now)
            XCTAssertNotEqual(revised.id, initial.id)
            XCTAssertEqual(revised.revision, 2)
            try reopened.finishSession(session.id, at: now.addingTimeInterval(240))
            let prediction = FuturePrediction(variant: variant.key, sourceSessionIDs: [session.id], amount: .weight(load), createdAt: now)
            try reopened.addPrediction(prediction)

            let final = try TrainingRepository(files: files).records
            XCTAssertNil(final.activeSession)
            XCTAssertEqual(final.currentRoutines, [revised])
            XCTAssertEqual(final.schedule.first?.routineVersionID, initial.id)
            XCTAssertEqual(final.sessions.first?.routineSnapshot, initial)
            XCTAssertEqual(final.sessions.first?.performedSets, [performed])
            XCTAssertEqual(final.predictions, [prediction])
        }
    }

    func testWeightsDatesAndDistinctMeasurements() throws {
        let load = try XCTUnwrap(Mass(100, unit: .lb))
        XCTAssertEqual(load.kilograms, 45.359237, accuracy: 0.000001)
        XCTAssertEqual(load.value(in: .lb), 100, accuracy: 0.000001)
        XCTAssertNil(Mass(.infinity))
        XCTAssertNil(Mass(-1))
        XCTAssertNil(WorkoutDate("2026-02-30"))
        let midnight = Date(timeIntervalSince1970: 1_767_225_600)
        let timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: -5 * 3600))
        XCTAssertEqual(WorkoutDate(midnight, timeZone: .gmt).key, "2026-01-01")
        XCTAssertEqual(WorkoutDate(midnight, timeZone: timeZone).key, "2025-12-31")
        XCTAssertEqual(WorkoutDate.week(containing: WorkoutDate(midnight, timeZone: timeZone)).count, 7)

        let pulley = Equipment(name: "North cable", kind: .cable)
        let otherPulley = Equipment(name: "South cable", kind: .cable)
        let exercise = Exercise(name: "Pulldown")
        let settings = Measurement.machineSetting(reps: .total)
        let weight = Measurement.weightReps(basis: .total, reps: .total)
        func variant(_ equipment: Equipment, _ measurement: Measurement) -> ExerciseVariantKey {
            ExerciseVariant(exercise: exercise, equipment: equipment, measurement: measurement).key
        }
        XCTAssertNotEqual(variant(pulley, settings), variant(otherPulley, settings))
        XCTAssertNotEqual(variant(pulley, settings), variant(pulley, weight))
        XCTAssertTrue(settings.accepts(SetAmount.machineSetting("007")))
        XCTAssertFalse(settings.accepts(SetAmount.weight(load)))
        XCTAssertFalse(weight.accepts(SetAmount.machineSetting("007")))
        XCTAssertFalse(Measurement.weightReps(basis: .perDumbbell, reps: .total).supports(pulley))
        XCTAssertTrue(Measurement.assistance(reps: .total).accepts(SetAmount.assistance(load)))
        XCTAssertFalse(Measurement.assistance(reps: .total).accepts(SetAmount.addedLoad(load)))
        XCTAssertFalse(RepCounting.perSide == .separateSides)
        XCTAssertTrue(Repetitions.separateSides(left: 8, right: 7).matches(.separateSides))
        XCTAssertFalse(Repetitions.total(15).matches(.separateSides))
    }

    func testMigrationKeepsUserEntriesAndSeparatesThePreview() async throws {
        try await MainActor.run {
            let files = temporaryFiles()
            defer { try? FileManager.default.removeItem(at: files.directory) }
            try FileManager.default.createDirectory(at: files.directory, withIntermediateDirectories: true)
            let legacyURL = files.directory.appendingPathComponent(TrainingFiles.legacyFilename)
            let legacy = Data(#"{"bodyweightByDay":{"2026-11-17":82.4},"activeRoutineID":"upper-a"}"#.utf8)
            try legacy.write(to: legacyURL)
            let first = try TrainingRepository(files: files)
            let date = try XCTUnwrap(WorkoutDate("2026-11-17"))
            let migrated = try XCTUnwrap(first.records.bodyweight(on: date))
            XCTAssertEqual(migrated.mass.kilograms, 82.4)
            XCTAssertTrue(first.records.routines.isEmpty)
            XCTAssertTrue(first.records.sessions.isEmpty)
            XCTAssertTrue(first.records.predictions.isEmpty)
            XCTAssertEqual(try files.loadSamplePreview().activeRoutineID, "upper-a")
            XCTAssertTrue(try files.loadSamplePreview().bodyweightByDay.isEmpty)

            try files.saveSamplePreview(SamplePreviewState(bodyweightByDay: [date.key: 65], activeRoutineID: "lower-a"))
            XCTAssertEqual(try TrainingRepository(files: files).records.bodyweight(on: date), migrated)
            try first.saveBodyweight(try XCTUnwrap(Mass(180, unit: .lb)), on: date)
            let edited = try XCTUnwrap(TrainingRepository(files: files).records.bodyweight(on: date))
            XCTAssertEqual(edited.id, migrated.id)
            XCTAssertEqual(edited.mass.value(in: .lb), 180, accuracy: 0.000001)
            XCTAssertEqual(try files.loadSamplePreview().bodyweightByDay[date.key], 65)
            XCTAssertEqual(try Data(contentsOf: legacyURL), legacy)
        }
    }

    func testFailedWritesPreserveCommittedStateAndUnknownSchemas() async throws {
        try await MainActor.run {
            let files = temporaryFiles()
            defer { try? FileManager.default.removeItem(at: files.directory) }
            let repository = try TrainingRepository(files: files)
            try Data().write(to: files.directory)
            let date = try XCTUnwrap(WorkoutDate("2026-11-17"))
            let mass = try XCTUnwrap(Mass(82))
            XCTAssertThrowsError(try repository.saveBodyweight(mass, on: date))
            XCTAssertTrue(repository.records.bodyweightEntries.isEmpty)

            try FileManager.default.removeItem(at: files.directory)
            try FileManager.default.createDirectory(at: files.directory, withIntermediateDirectories: true)
            let userURL = files.directory.appendingPathComponent(TrainingFiles.userFilename)
            let future = Data(#"{"schemaVersion":999,"records":{}}"#.utf8)
            try future.write(to: userURL)
            XCTAssertThrowsError(try TrainingRepository(files: files)) { error in
                XCTAssertEqual(error as? TrainingDataError, .unsupportedSchema(999))
            }
            XCTAssertEqual(try Data(contentsOf: userURL), future)
        }
    }

    func testDeviceReferencesAndReadinessRoundTrip() async throws {
        try await MainActor.run {
            let files = temporaryFiles()
            defer { try? FileManager.default.removeItem(at: files.directory) }
            let repository = try TrainingRepository(files: files)
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let date = WorkoutDate(now, timeZone: .gmt)
            let exercise = Exercise(name: "Squat", createdAt: now)
            try repository.addExercise(exercise)
            let photo = DevicePhotoReference(location: .photoLibrary(localIdentifier: "3A5B2C/L0/001"),
                                             subject: .exercise(exercise.id), createdAt: now)
            try repository.addPhotoReference(photo)
            XCTAssertThrowsError(try repository.addPhotoReference(DevicePhotoReference(location: .appFile(relativePath: "../photo.jpg"))))
            XCTAssertThrowsError(try repository.addPhotoReference(DevicePhotoReference(location: .photoLibrary(localIdentifier: "https://example.com/photo.jpg"))))
            let checkIn = ReadinessCheckIn(localDate: date, energy: 4, soreness: 2, sleepMinutes: 465, recordedAt: now)
            try repository.addReadinessCheckIn(checkIn)
            let loaded = try TrainingRepository(files: files).records
            XCTAssertEqual(loaded.photos, [photo])
            XCTAssertEqual(loaded.readiness, [checkIn])
        }
    }

    private func temporaryFiles() -> TrainingFiles {
        TrainingFiles(directory: FileManager.default.temporaryDirectory.appendingPathComponent("SetlineTests-\(UUID())"))
    }
}
