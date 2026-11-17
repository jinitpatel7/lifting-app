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

enum WeightUnit: String, CaseIterable, Identifiable {
    case kg, lb

    var id: Self { self }
    var name: String { self == .kg ? "Kilograms" : "Pounds" }
    var kilogramsPerUnit: Double { self == .kg ? 1 : 0.45359237 }

    func display(_ kilograms: Double, fractionDigits: ClosedRange<Int> = 0...1) -> String {
        (kilograms / kilogramsPerUnit).formatted(.number.precision(.fractionLength(fractionDigits)))
    }

    func kilograms(for input: String) -> Double? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = try? Double(trimmed, format: .number, lenient: false) else { return nil }
        let kilograms = value * kilogramsPerUnit
        guard kilograms.isFinite, kilograms > 0, kilograms <= 700 else { return nil }
        return kilograms
    }
}

enum SampleDate {
    private static var isoStyle: Date.ISO8601FormatStyle {
        Date.ISO8601FormatStyle().year().month().day().dateSeparator(.dash)
    }

    static func label(_ key: String, _ style: Date.FormatStyle) -> String {
        guard let date = try? isoStyle.parse(key) else { return key }
        var utcStyle = style
        utcStyle.timeZone = .gmt
        return date.formatted(utcStyle)
    }
}

struct TrainingState: Codable {
    var bodyweightByDay: [String: Double] = [:]
    var activeRoutineID: String?
}

struct OnDeviceTrainingStore {
    private let fileManager = FileManager.default

    private func fileURL(createDirectory: Bool) throws -> URL {
        let support = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                          appropriateFor: nil, create: createDirectory)
        let folder = support.appendingPathComponent("Setline", isDirectory: true)
        if createDirectory {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return folder.appendingPathComponent("TrainingState-v1.json")
    }

    func load() throws -> TrainingState {
        do {
            return try JSONDecoder().decode(TrainingState.self, from: Data(contentsOf: fileURL(createDirectory: false)))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return TrainingState()
        }
    }

    func save(_ state: TrainingState) throws {
        try JSONEncoder().encode(state).write(to: fileURL(createDirectory: true), options: .atomic)
    }
}

@MainActor
@Observable
final class TrainingModel {
    let sample = SampleData.load()
    private let store = OnDeviceTrainingStore()
    private(set) var state = TrainingState()
    private var storageReadable = true
    var storageError: String?

    init() {
        do {
            state = try store.load()
        } catch {
            storageReadable = false
            storageError = "Setline couldn’t read its local data. Reopen the app to try again."
        }
    }

    var activeRoutine: Routine? { sample?.routine(state.activeRoutineID) }

    func recordBodyweight(_ kilograms: Double, on day: String) -> Bool {
        var next = state
        next.bodyweightByDay[day] = kilograms
        return save(next)
    }

    func startPreview(_ routine: Routine) -> Bool {
        if activeRoutine != nil { return true }
        var next = state
        next.activeRoutineID = routine.id
        return save(next)
    }

    func endPreview() -> Bool {
        var next = state
        next.activeRoutineID = nil
        return save(next)
    }

    private func save(_ next: TrainingState) -> Bool {
        guard storageReadable else {
            storageError = "Setline couldn’t read its local data. Reopen the app to try again."
            return false
        }
        do {
            try store.save(next)
            state = next
            return true
        } catch {
            storageError = "Setline couldn’t save your change on this device. Try again."
            return false
        }
    }
}
