import Foundation
import XCTest
@testable import SetlineData

final class ExerciseLibraryTests: XCTestCase {
    func testRenameKeepsSnapshotAndPreferenceAndNewVariantGetsOwnKey() async throws {
        try await MainActor.run {
            let files = TrainingFiles(directory: FileManager.default.temporaryDirectory.appendingPathComponent("SetlineLibraryTests-\(UUID())"))
            defer { try? FileManager.default.removeItem(at: files.directory) }
            let repository = try TrainingRepository(files: files)
            let moment = Date(timeIntervalSince1970: 1_800_000_000)
            let machine = Equipment(name: "Press station A", kind: .machine, createdAt: moment)
            let original = Exercise(name: "Seated Press", createdAt: moment,
                profile: ExerciseProfile(pattern: .horizontalPush, equipmentKind: .machine, variation: "Press station A",
                                         primary: [.chest], secondary: [.triceps], machineSetup: MachineSetup(seat: "007")))
            try repository.addEquipment(machine)
            try repository.addExercise(original)
            try repository.setExercisePreference(ExercisePreference(favorite: true), for: original.id)
            let measurement = Measurement.machineSetting(reps: .total)
            let variant = ExerciseVariant(exercise: original, equipment: machine, measurement: measurement)
            let entry = PlannedExercise(variant: variant, prescription: SetPrescription(sets: 3,
                reps: RepRange(minimum: 8, maximum: 10), target: .machineSetting("007")))
            let version = try repository.saveRoutine(name: "Press session", exercises: [entry], at: moment)
            let session = try repository.startSession(versionID: version.id, at: moment, timeZone: .gmt)
            try repository.finishSession(session.id, at: moment)

            var renamed = original
            renamed.name = "Renamed Seated Press"
            renamed.profile?.machineSetup.seat = "008"
            try repository.editExercise(renamed, at: moment.addingTimeInterval(60))
            var other = renamed
            other.profile?.variation = "Press station B"
            XCTAssertThrowsError(try repository.editExercise(other))
            other.id = UUID()
            try repository.addExercise(other)

            let reopened = try TrainingRepository(files: files)
            XCTAssertEqual(reopened.records.exercises.first?.name, renamed.name)
            XCTAssertEqual(reopened.records.exercisePreferences?[original.id.uuidString]?.favorite, true)
            XCTAssertEqual(reopened.records.sessions.first?.routineSnapshot.exercises.first?.variant.exercise, original)
            let next = try reopened.saveRoutine(id: version.routineID, name: version.name, exercises: [entry], at: moment.addingTimeInterval(120))
            XCTAssertEqual(next.exercises.first?.variant.exercise.name, renamed.name)
            XCTAssertEqual(next.exercises.first?.variant.key, variant.key)
            XCTAssertNotEqual(ExerciseVariant(exercise: other, equipment: machine, measurement: measurement).key, variant.key)
            XCTAssertEqual(try TrainingRepository(files: files).records.sessions.first?.routineSnapshot, version)
        }
    }

    func testLibraryFiltersAndSubstitutions() throws {
        let press = Exercise(name: "Bench Press", profile: ExerciseProfile(pattern: .horizontalPush, equipmentKind: .barbell, primary: [.chest]))
        let dumbbell = Exercise(name: "Dumbbell Press", profile: ExerciseProfile(pattern: .horizontalPush, equipmentKind: .dumbbell, primary: [.chest]))
        let pushUp = Exercise(name: "Push-Up", profile: ExerciseProfile(pattern: .horizontalPush, primary: [.chest]))
        let exercises = [press, dumbbell, pushUp]
        let query = ExerciseLibraryQuery(name: "PRESS", muscle: .chest, equipment: .equipment(.dumbbell), pattern: .horizontalPush)
        XCTAssertEqual(query.results(catalog: exercises, custom: [], preferences: [:]), [dumbbell])
        XCTAssertTrue(query.results(catalog: [], custom: [], preferences: [:]).isEmpty)
        let preferences = [pushUp.id.uuidString: ExercisePreference(excluded: true)]
        XCTAssertEqual(ExerciseLibraryQuery.substitutions(for: press, in: exercises,
            available: [.bodyweight, .equipment(.dumbbell)], preferences: preferences), [dumbbell])
        XCTAssertEqual(MuscleInvolvement([try XCTUnwrap(press.profile), ExerciseProfile(secondary: [.chest, .triceps])]).secondary, [.triceps])
        let legacy = Data(#"{"id":"10000000-0000-4000-8000-000000000077","name":"Legacy Row","createdAt":0}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(Exercise.self, from: legacy).profile)
    }
}
