import Foundation
import Observation

struct SampleData: Decodable {
    let today: String
    let week: [ScheduleDay]
    let routines: [Routine]
    let history: [SessionSummary]
    let benchTrend: [ProgressPoint]

    static func load() -> Self? {
        guard let url = Bundle.main.url(forResource: "SampleData", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    func routine(_ id: String?) -> Routine? {
        routines.first { $0.id == id }
    }
}

struct ScheduleDay: Decodable, Identifiable {
    var id: String { date }
    let date: String
    let routineID: String?
}

struct Routine: Decodable, Identifiable {
    let id: String
    let name: String
    let focus: String
    let minutes: Int
    let primaryMuscles: String
    let secondaryMuscles: String
    let exercises: [ExercisePrescription]
}

struct ExercisePrescription: Decodable, Identifiable {
    let id: String
    let name: String
    let muscles: String
    let symbol: String
    let sets: Int
    let reps: String
    let rir: Int
    let restSeconds: Int
    let previous: PreviousSet?
    let image: String?

    var prescription: String { "\(sets) × \(reps) reps" }
    var rest: String {
        let minutes = restSeconds / 60
        let seconds = restSeconds % 60
        return [minutes > 0 ? "\(minutes) min" : nil, seconds > 0 ? "\(seconds) sec" : nil]
            .compactMap { $0 }.joined(separator: " ")
    }
}

struct PreviousSet: Decodable {
    let weightKg: Double
    let reps: Int
}

struct SessionSummary: Decodable, Identifiable {
    let id: String
    let date: String
    let routineID: String
    let minutes: Int
    let sets: Int
}

struct ProgressPoint: Decodable, Identifiable {
    var id: String { date }
    let date: String
    let weightKg: Double
}

enum SampleDate {
    static func label(_ key: String, _ style: Date.FormatStyle) -> String {
        WorkoutDate(key)?.formatted(style) ?? key
    }
}

@MainActor
@Observable
final class TrainingModel {
    let sample = SampleData.load()
    let catalogEntries = CatalogExercise.load()
    private let files = try? TrainingFiles.applicationSupport()
    private(set) var records = TrainingRecords()
    private(set) var preview = SamplePreviewState()
    private var repository: TrainingRepository?
    private var userLoadError: String?
    private var sampleLoadError: String?
    var storageError: String?

    init() {
        guard let files else {
            userLoadError = "Setline couldn’t find its local storage."
            sampleLoadError = userLoadError
            storageError = userLoadError
            return
        }
        do {
            let repository = try TrainingRepository(files: files, catalog: catalog)
            self.repository = repository
            records = repository.records
        } catch {
            userLoadError = (error as? TrainingDataError)?.localizedDescription
                ?? "Setline couldn’t read its local data. Reopen the app to try again."
            storageError = userLoadError
        }
        do {
            preview = try files.loadSamplePreview()
        } catch {
            sampleLoadError = "Setline couldn’t read the saved sample preview."
        }
    }

    var activeRoutine: Routine? { sample?.routine(preview.activeRoutineID) }
    var catalog: [Exercise] { catalogEntries.map(\.exercise) }
    var library: [Exercise] { catalog + records.exercises }

    func sampleInvolvement(_ routine: Routine) -> MuscleInvolvement {
        let sampleIDs = Set(routine.exercises.map(\.id))
        return MuscleInvolvement(catalogEntries.filter { entry in
            entry.sampleID.map(sampleIDs.contains) ?? false
        }.compactMap { $0.exercise.profile })
    }

    func saveExercise(_ exercise: Exercise, editing: Bool) -> Bool {
        updateUserData { repository in
            if editing { try repository.editExercise(exercise) }
            else { try repository.addExercise(exercise) }
        }
    }

    func exercisePreference(_ id: UUID) -> ExercisePreference {
        records.exercisePreferences?[id.uuidString] ?? ExercisePreference()
    }

    func saveExercisePreference(_ preference: ExercisePreference, id: UUID) -> Bool {
        updateUserData { try $0.setExercisePreference(preference, for: id) }
    }

    func bodyweight(on day: String, sampleMode: Bool) -> Double? {
        if sampleMode { return preview.bodyweightByDay[day] }
        return WorkoutDate(day).flatMap { records.bodyweight(on: $0)?.mass.kilograms }
    }

    func recordBodyweight(_ kilograms: Double, on day: String, sampleMode: Bool) -> Bool {
        guard let date = WorkoutDate(day), let mass = Mass(kilograms), kilograms > 0 else { return false }
        if sampleMode {
            var next = preview
            next.bodyweightByDay[day] = kilograms
            return savePreview(next)
        }
        return updateUserData { try $0.saveBodyweight(mass, on: date) }
    }

    func startPreview(_ routine: Routine) -> Bool {
        if activeRoutine != nil { return true }
        var next = preview
        next.activeRoutineID = routine.id
        return savePreview(next)
    }

    func endPreview() -> Bool {
        var next = preview
        next.activeRoutineID = nil
        return savePreview(next)
    }

    func startSession(versionID: UUID, scheduleID: UUID?) -> Bool {
        if records.activeSession != nil { return true }
        return updateUserData { _ = try $0.startSession(versionID: versionID, scheduleID: scheduleID) }
    }

    func finishSession(_ id: UUID, early: Bool = false) -> Bool {
        updateUserData { try $0.finishSession(id, early: early) }
    }

    func startEmptyWorkout() -> Bool {
        if records.activeSession != nil { return true }
        return updateUserData { _ = try $0.startEmptySession() }
    }

    func scheduleWorkout(versionID: UUID, date: Date) -> Bool {
        updateUserData { try $0.addScheduledWorkout(ScheduledWorkout(localDate: WorkoutDate(date), routineVersionID: versionID)) }
    }

    func prepareWorkoutLog(_ id: UUID) {
        _ = updateUserData { try $0.prepareWorkoutLog(id) }
    }

    func logChange(_ id: UUID, _ change: WorkoutLogChange) {
        _ = updateUserData { try $0.changeWorkout(id, change) }
    }

    func updateRoutineFromWorkout(_ id: UUID) -> Bool {
        updateUserData { _ = try $0.updateRoutineFromWorkout(id) }
    }

    func saveRoutine(id: UUID, name: String, exercises: [PlannedExercise], categoryID: UUID?, groups: [RoutineGroup],
                     expectedVersionID: UUID?) -> Bool {
        updateUserData { repository in
            _ = try repository.saveRoutine(id: id, name: name, exercises: exercises, categoryID: categoryID,
                                           groups: groups, expectedVersionID: expectedVersionID)
        }
    }

    func addRoutineCategory(_ category: RoutineCategory) -> Bool {
        updateUserData { try $0.addRoutineCategory(category) }
    }

    func addEquipment(_ equipment: Equipment) -> Bool {
        updateUserData { try $0.addEquipment(equipment) }
    }

    func duplicateRoutine(_ versionID: UUID) -> Bool {
        updateUserData { _ = try $0.duplicateRoutine(versionID: versionID) }
    }

    func repeatWorkout(_ id: UUID) -> Bool {
        updateUserData { _ = try $0.repeatSession(id) }
    }

    func editSessionPlan(_ id: UUID, name: String, exercises: [PlannedExercise], groups: [RoutineGroup]) -> Bool {
        updateUserData { try $0.editSessionPlan(id, name: name, exercises: exercises, groups: groups) }
    }

    func updateUserData(_ update: (TrainingRepository) throws -> Void) -> Bool {
        guard let repository else {
            storageError = userLoadError
            return false
        }
        do {
            try update(repository)
            records = repository.records
            storageError = nil
            return true
        } catch {
            storageError = (error as? TrainingDataError)?.localizedDescription
                ?? "Setline couldn’t save your change on this device. Try again."
            return false
        }
    }

    private func savePreview(_ next: SamplePreviewState) -> Bool {
        guard let files, sampleLoadError == nil else {
            storageError = sampleLoadError
            return false
        }
        do {
            try files.saveSamplePreview(next)
            preview = next
            storageError = nil
            return true
        } catch {
            storageError = "Setline couldn’t save the sample preview. Try again."
            return false
        }
    }
}
