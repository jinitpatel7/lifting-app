import Foundation

enum SetStructure: String, Codable, CaseIterable, Identifiable, Hashable {
    case straight = "Straight", dropSet = "Drop set", restPause = "Rest-pause"
    var id: Self { self }
}

enum EffortTarget: Codable, Equatable {
    case rpe(Double)
    case failure

    var isValid: Bool {
        if case .rpe(let value) = self { return (1...10).contains(value) }
        return true
    }
}

enum EffortOutcome: String, Codable, Equatable {
    case stopped, failure
}

enum SetPurpose: String, Codable, Equatable {
    case warmUp, working
}

struct RoutineCategory: Codable, Equatable, Identifiable {
    var id = UUID()
    let name: String
}

struct RoutineGroup: Codable, Equatable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Identifiable, Equatable {
        case superset = "Superset", circuit = "Circuit"
        var id: Self { self }
    }

    var id = UUID()
    var kind: Kind
    var exerciseIDs: [UUID]
    var rounds: Int
    var restBetweenExercises: Int = 0
    var restBetweenRounds: Int = 0

    var summary: String {
        "\(kind.rawValue) · \(rounds) rounds · \(restBetweenExercises)s between exercises · \(restBetweenRounds)s between rounds"
    }

    static func normalized(_ groups: [Self], exercises: [PlannedExercise]) throws -> [Self] {
        guard Set(groups.map(\.id)).count == groups.count, Set(exercises.map(\.id)).count == exercises.count else {
            throw TrainingDataError.invalidRecord("Each group needs its own ID.")
        }
        let positions = Dictionary(uniqueKeysWithValues: exercises.enumerated().map { ($0.element.id, $0.offset) })
        var occupied = Set<UUID>()
        return try groups.map { group in
            guard group.rounds > 0, group.restBetweenExercises >= 0, group.restBetweenRounds >= 0 else {
                throw TrainingDataError.invalidRecord("A group needs at least one round and nonnegative rest periods.")
            }
            let members = Set(group.exerciseIDs)
            let indexes = members.compactMap { positions[$0] }.sorted()
            guard members.count == group.exerciseIDs.count, members.count >= 2,
                  group.kind != .superset || members.count == 2,
                  indexes.count == members.count, let first = indexes.first, let last = indexes.last,
                  last - first + 1 == indexes.count, occupied.isDisjoint(with: members) else {
                throw TrainingDataError.invalidRecord("Choose two adjacent exercises for a superset or two or more for a circuit. Each exercise can belong to one group.")
            }
            occupied.formUnion(members)
            var normalized = group
            normalized.exerciseIDs = indexes.map { exercises[$0].id }
            return normalized
        }
    }
}
