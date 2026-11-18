import Foundation

enum MuscleGroup: String, Codable, CaseIterable, Identifiable {
    case chest, shoulders, biceps, triceps, forearms, core, traps, lats, lowerBack
    case glutes, quads, hamstrings, calves, shins, adductors

    var id: Self { self }
    var label: String {
        switch self {
        case .lowerBack: "Lower back"
        case .quads: "Quadriceps"
        case .core: "Abdominals"
        case .traps: "Upper back"
        case .adductors: "Inner thighs"
        default: rawValue.capitalized
        }
    }
}

enum MovementPattern: String, Codable, CaseIterable, Identifiable {
    case horizontalPush, verticalPush, horizontalPull, verticalPull, squat, hinge
    case elbowFlexion, elbowExtension, kneeFlexion, ankleExtension, carry, core, other

    var id: Self { self }
    var label: String {
        switch self {
        case .horizontalPush: "Horizontal push"
        case .verticalPush: "Vertical push"
        case .horizontalPull: "Horizontal pull"
        case .verticalPull: "Vertical pull"
        case .elbowFlexion: "Elbow flexion"
        case .elbowExtension: "Elbow extension"
        case .kneeFlexion: "Knee flexion"
        case .ankleExtension: "Ankle extension"
        default: rawValue.capitalized
        }
    }
}

struct CatalogExercise: Decodable {
    let id: UUID
    let sampleID: String?
    let name: String
    let equipment: EquipmentKind?
    let pattern: MovementPattern
    let variation: String?
    let primary: [MuscleGroup]
    let secondary: [MuscleGroup]
    let setup: String
    let cues: String
    let machineSetup: MachineSetup?
    let demonstration: ExerciseDemonstration?

    var exercise: Exercise {
        Exercise(id: id, name: name, createdAt: Date(timeIntervalSince1970: 0),
                 profile: ExerciseProfile(pattern: pattern, equipmentKind: equipment, variation: variation ?? "",
                                          primary: primary, secondary: secondary, setup: setup, cues: cues,
                                          machineSetup: machineSetup ?? MachineSetup(), demonstration: demonstration))
    }

    static func load(from bundle: Bundle = .main) -> [Self] {
        guard let url = bundle.url(forResource: "ExerciseCatalog", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Self].self, from: data)) ?? []
    }
}

enum LibraryEquipment: Hashable, Identifiable {
    case bodyweight, equipment(EquipmentKind)

    static var choices: [Self] { [.bodyweight] + EquipmentKind.allCases.map { .equipment($0) } }
    var kind: EquipmentKind? { if case .equipment(let kind) = self { kind } else { nil } }
    var id: String { kind?.rawValue ?? "bodyweight" }
    var label: String { id.capitalized }

    init(_ kind: EquipmentKind?) { self = kind.map(Self.equipment) ?? .bodyweight }
}

struct MachineSetup: Codable, Equatable {
    var seat: String = ""
    var attachment: String = ""
    var incline: String = ""
    var handle: String = ""

    var fields: [(String, String)] {
        [("Seat position", seat), ("Attachment", attachment), ("Incline", incline), ("Handle", handle)]
            .filter { !$0.1.isEmpty }
    }
}

struct ExerciseDemonstration: Codable, Equatable {
    enum Kind: String, Codable { case image, video }
    let kind: Kind
    let resource: String

    var isBundleResource: Bool {
        let parts = resource.split(separator: ".", omittingEmptySubsequences: false)
        let extensions: Set<String> = kind == .image ? ["png", "jpg", "jpeg", "webp"] : ["mp4", "mov"]
        return parts.count == 2 && !parts[0].isEmpty && extensions.contains(String(parts[1]).lowercased())
            && parts[0].allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}

struct ExerciseProfile: Codable, Equatable {
    var pattern: MovementPattern = .other
    var equipmentKind: EquipmentKind? = nil
    var variation: String = ""
    var primary: [MuscleGroup] = []
    var secondary: [MuscleGroup] = []
    var setup: String = ""
    var cues: String = ""
    var machineSetup: MachineSetup = MachineSetup()
    var demonstration: ExerciseDemonstration? = nil

    var muscles: Set<MuscleGroup> { Set(primary + secondary) }
}

struct ExercisePreference: Codable, Equatable {
    var favorite = false
    var excluded = false
}

enum ExerciseCollection: String, CaseIterable, Identifiable {
    case all = "All", favorites = "Favorites", custom = "Custom", excluded = "Excluded"
    var id: Self { self }
}

struct ExerciseLibraryQuery {
    var name = ""
    var muscle: MuscleGroup? = nil
    var equipment: LibraryEquipment? = nil
    var pattern: MovementPattern? = nil
    var collection: ExerciseCollection = .all

    func results(catalog: [Exercise], custom: [Exercise], preferences: [String: ExercisePreference]) -> [Exercise] {
        let customIDs = Set(custom.map(\.id))
        let keyword = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return (catalog + custom).filter { exercise in
            let preference = preferences[exercise.id.uuidString] ?? ExercisePreference()
            let visible = collection == .excluded ? preference.excluded : !preference.excluded
            return visible
                && (collection != .favorites || preference.favorite)
                && (collection != .custom || customIDs.contains(exercise.id))
                && (keyword.isEmpty || exercise.name.localizedStandardContains(keyword))
                && (muscle.map { exercise.profile?.muscles.contains($0) == true } ?? true)
                && (equipment == nil || exercise.profile.map { LibraryEquipment($0.equipmentKind) } == equipment)
                && (pattern == nil || exercise.profile?.pattern == pattern)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func substitutions(for source: Exercise, in exercises: [Exercise], available: Set<LibraryEquipment>,
                              preferences: [String: ExercisePreference]) -> [Exercise] {
        guard let profile = source.profile, !profile.muscles.isEmpty else { return [] }
        return exercises.filter { exercise in
            guard exercise.id != source.id, preferences[exercise.id.uuidString]?.excluded != true,
                  let candidate = exercise.profile, available.contains(LibraryEquipment(candidate.equipmentKind)) else { return false }
            return !profile.muscles.isDisjoint(with: candidate.muscles)
        }.sorted { lhs, rhs in
            let left = Set(lhs.profile?.primary ?? []).intersection(profile.primary).count
            let right = Set(rhs.profile?.primary ?? []).intersection(profile.primary).count
            if left != right { return left > right }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}

struct MuscleInvolvement {
    var primary: Set<MuscleGroup> = []
    var secondary: Set<MuscleGroup> = []

    init(_ profiles: [ExerciseProfile]) {
        primary = Set(profiles.flatMap(\.primary))
        secondary = Set(profiles.flatMap(\.secondary)).subtracting(primary)
    }

    var isEmpty: Bool { primary.isEmpty && secondary.isEmpty }
}
