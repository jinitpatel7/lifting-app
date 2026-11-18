import Foundation

enum WeightUnit: String, Codable, CaseIterable, Identifiable {
    case kg, lb

    var id: Self { self }
    var name: String { self == .kg ? "Kilograms" : "Pounds" }
    var kilogramsPerUnit: Double { self == .kg ? 1 : 0.45359237 }

    func display(_ kilograms: Double, fractionDigits: ClosedRange<Int> = 0...1) -> String {
        (kilograms / kilogramsPerUnit).formatted(.number.precision(.fractionLength(fractionDigits)))
    }

    func kilograms(for input: String) -> Double? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = try? Double(trimmed, format: .number, lenient: false), value > 0 else { return nil }
        return Mass(value, unit: self)?.kilograms
    }
}

struct Mass: Codable, Hashable {
    let kilograms: Double

    init?(_ value: Double, unit: WeightUnit = .kg) {
        let kilograms = value * unit.kilogramsPerUnit
        guard kilograms.isFinite, kilograms >= 0 else { return nil }
        self.kilograms = kilograms
    }

    func value(in unit: WeightUnit) -> Double { kilograms / unit.kilogramsPerUnit }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let mass = Mass(try container.decode(Double.self)) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid mass in kilograms")
        }
        self = mass
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(kilograms)
    }
}

struct WorkoutDate: Codable, Hashable, Comparable {
    let key: String

    static let format = Date.ISO8601FormatStyle(timeZone: .gmt)
        .year().month().day().dateSeparator(.dash)

    init?(_ key: String) {
        guard let date = try? Self.format.parse(key), Self.format.format(date) == key else { return nil }
        self.key = key
    }

    init(_ date: Date, timeZone: TimeZone = .current) {
        var format = Self.format
        format.timeZone = timeZone
        key = format.format(date)
    }

    func formatted(_ style: Date.FormatStyle) -> String {
        guard let date = try? Self.format.parse(key) else { return key }
        var style = style
        style.timeZone = .gmt
        return date.formatted(style)
    }

    static func week(containing day: WorkoutDate) -> [WorkoutDate] {
        guard let date = try? format.parse(day.key) else { return [] }
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .gmt
        guard let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start else { return [] }
        return (0..<7).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: start).map { WorkoutDate($0, timeZone: .gmt) }
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.key < rhs.key }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let day = WorkoutDate(try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid local workout date")
        }
        self = day
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(key)
    }
}

enum EquipmentKind: String, Codable, CaseIterable, Hashable {
    case barbell, dumbbell, cable, machine, kettlebell, band, other
}

struct Equipment: Codable, Equatable, Identifiable {
    var id = UUID()
    let name: String
    let kind: EquipmentKind
    var createdAt = Date()
}

struct Exercise: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var createdAt = Date()
    var profile: ExerciseProfile? = nil
    var updatedAt: Date? = nil
}

enum LoadBasis: String, Codable, Hashable {
    case total, perDumbbell
}

enum RepCounting: String, Codable, Hashable {
    case total, perSide, separateSides
}

enum Repetitions: Codable, Equatable {
    case total(Int)
    case perSide(Int)
    case separateSides(left: Int, right: Int)

    func matches(_ counting: RepCounting) -> Bool {
        switch (self, counting) {
        case (.total(let count), .total), (.perSide(let count), .perSide): count > 0
        case (.separateSides(let left, let right), .separateSides): left >= 0 && right >= 0 && (left > 0 || right > 0)
        default: false
        }
    }
}

enum SetAmount: Codable, Equatable {
    case weight(Mass)
    case addedLoad(Mass)
    case assistance(Mass)
    case durationSeconds(Double)
    case distanceMeters(Double)
    case machineSetting(String)
}

enum Measurement: Codable, Hashable {
    case weightReps(basis: LoadBasis, reps: RepCounting)
    case bodyweight(reps: RepCounting)
    case addedLoad(reps: RepCounting)
    case assistance(reps: RepCounting)
    case duration
    case distance
    case machineSetting(reps: RepCounting)

    var repCounting: RepCounting? {
        switch self {
        case .weightReps(_, let reps), .bodyweight(let reps), .addedLoad(let reps),
             .assistance(let reps), .machineSetting(let reps): reps
        case .duration, .distance: nil
        }
    }

    func supports(_ equipment: Equipment?) -> Bool {
        switch self {
        case .weightReps(.perDumbbell, _): equipment?.kind == .dumbbell
        case .machineSetting: equipment != nil
        default: true
        }
    }

    func accepts(_ amount: SetAmount?) -> Bool {
        switch (self, amount) {
        case (.bodyweight, nil), (.weightReps, .weight), (.addedLoad, .addedLoad), (.assistance, .assistance): true
        case (.duration, .durationSeconds(let seconds)): seconds.isFinite && seconds > 0
        case (.distance, .distanceMeters(let meters)): meters.isFinite && meters > 0
        case (.machineSetting, .machineSetting(let setting)): !setting.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default: false
        }
    }

    func accepts(_ repetitions: Repetitions?) -> Bool {
        guard let repCounting else { return repetitions == nil }
        return repetitions?.matches(repCounting) == true
    }
}

struct ExerciseVariant: Codable, Equatable {
    let exercise: Exercise
    let equipment: Equipment?
    let measurement: Measurement

    var key: ExerciseVariantKey {
        ExerciseVariantKey(exerciseID: exercise.id, equipmentID: equipment?.id, measurement: measurement)
    }
}

struct ExerciseVariantKey: Codable, Hashable {
    let exerciseID: UUID
    let equipmentID: UUID?
    let measurement: Measurement
}

struct RepRange: Codable, Equatable {
    let minimum: Int
    let maximum: Int

    var isValid: Bool { minimum > 0 && maximum >= minimum }
    var label: String { minimum == maximum ? "\(minimum)" : "\(minimum)–\(maximum)" }
}

struct SetPrescription: Codable, Equatable {
    var sets: Int
    var reps: RepRange? = nil
    var target: SetAmount? = nil
    var repsInReserve: Int? = nil
    var restSeconds: Int? = nil
    var structure: SetStructure? = nil
    var amrap: Bool? = nil
    var effort: EffortTarget? = nil

    func isValid(for measurement: Measurement, allowsUntargetedReps: Bool = false) -> Bool {
        sets > 0 && (repsInReserve ?? 0) >= 0 && (restSeconds ?? 0) >= 0
            && (effort?.isValid ?? true) && (effort == nil || repsInReserve == nil)
            && (measurement.repCounting == nil ? reps == nil && amrap != true : (reps?.isValid ?? (amrap == true || allowsUntargetedReps)))
            && (target == nil || measurement.accepts(target))
    }
}

struct PlannedExercise: Codable, Equatable, Identifiable {
    var id = UUID()
    let variant: ExerciseVariant
    let prescription: SetPrescription
    var warmUps: [SetPrescription]? = nil
    var additionalWorkingSets: [SetPrescription]? = nil

    var workingSets: [SetPrescription] { [prescription] + (additionalWorkingSets ?? []) }
    var allPrescriptions: [SetPrescription] { (warmUps ?? []) + workingSets }
}

struct RoutineRecord: Codable, Equatable, Identifiable {
    let id: UUID
    let createdAt: Date
    var currentVersionID: UUID
}

struct RoutineVersion: Codable, Equatable, Identifiable {
    var id = UUID()
    let routineID: UUID
    let revision: Int
    let createdAt: Date
    let name: String
    let exercises: [PlannedExercise]
    var categoryID: UUID? = nil
    var groups: [RoutineGroup]? = nil
}

struct PerformedSet: Codable, Equatable, Identifiable {
    var id = UUID()
    let plannedExerciseID: UUID
    var order: Int
    var repetitions: Repetitions? = nil
    var amount: SetAmount? = nil
    var recordedAt = Date()
    var effortOutcome: EffortOutcome? = nil
    var purpose: SetPurpose? = nil
    var structure: SetStructure? = nil
    var amrap: Bool? = nil
    var actualRIR: Int? = nil
    var actualRPE: Double? = nil
    var rightAmount: SetAmount? = nil
    var actualRest: ActualWorkoutRest? = nil
}

struct WorkoutSession: Codable, Equatable, Identifiable {
    var id = UUID()
    let localDate: WorkoutDate
    let timeZoneIdentifier: String
    let startedAt: Date
    let scheduleID: UUID?
    let routineSnapshot: RoutineVersion
    var completedAt: Date? = nil
    var performedSets: [PerformedSet] = []
    var sessionPlan: RoutineVersion? = nil
    var referenceSessionID: UUID? = nil
    var workoutLog: WorkoutLog? = nil
    var endedEarly: Bool? = nil
    var routineUpdateBaseID: UUID? = nil
    var manualDurationKnown: Bool? = nil
    var performanceForecasts: [PerformanceForecast]? = nil
    var forecastEvidenceAt: Date? = nil
    var forecastPerformedSlots: Set<UUID>? = nil

    var plan: RoutineVersion { sessionPlan ?? routineSnapshot }
}

struct ScheduledWorkout: Codable, Equatable, Identifiable {
    var id = UUID()
    var localDate: WorkoutDate
    let routineVersionID: UUID
    var programBlockID: UUID? = nil
    var createdAt = Date()
    var sourceKey: String? = nil
    var rotationID: UUID? = nil
    var movedFrom: [WorkoutDate]? = nil
    var skippedOn: WorkoutDate? = nil
}

struct ProgramBlock: Codable, Equatable, Identifiable {
    var id = UUID()
    let name: String
    let firstDay: WorkoutDate
    let lastDay: WorkoutDate
    var createdAt = Date()
    var weeks: [Int: ProgramWeek]? = nil
}

struct BodyweightEntry: Codable, Equatable, Identifiable {
    var id = UUID()
    let localDate: WorkoutDate
    let createdAt: Date
    var updatedAt: Date
    var mass: Mass
}

struct ReadinessCheckIn: Codable, Equatable, Identifiable {
    var id = UUID()
    let localDate: WorkoutDate
    let energy: Int
    let soreness: Int
    var sleepMinutes: Int? = nil
    var recordedAt = Date()
    var sleepQuality: Int? = nil
    var motivation: Int? = nil
}

enum PhotoLocation: Codable, Equatable {
    case photoLibrary(localIdentifier: String)
    case appFile(relativePath: String)

    var isValid: Bool {
        switch self {
        case .photoLibrary(let identifier):
            return !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !identifier.contains("://")
        case .appFile(let path):
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            return !path.contains("\\") && !path.contains(":") && !path.contains("\0")
                && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
        }
    }
}

enum PhotoSubject: Codable, Equatable {
    case exercise(UUID), session(UUID), bodyweight(UUID)
}

struct DevicePhotoReference: Codable, Equatable, Identifiable {
    var id = UUID()
    let location: PhotoLocation
    var subject: PhotoSubject? = nil
    var createdAt = Date()
    var localDate: WorkoutDate? = nil
}

struct FuturePrediction: Codable, Equatable, Identifiable {
    var id = UUID()
    let variant: ExerciseVariantKey
    let sourceSessionIDs: [UUID]
    var amount: SetAmount? = nil
    var reps: RepRange? = nil
    var createdAt = Date()
}
