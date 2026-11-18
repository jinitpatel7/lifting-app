import Foundation

enum WorkoutEnergyActivity: String, Codable, CaseIterable, Identifiable {
    case variedResistance, vigorousLifting, squatDeadlift

    var id: Self { self }
    var title: String {
        switch self {
        case .variedResistance: "Varied resistance, multiple exercises (8–15 reps)"
        case .vigorousLifting: "Vigorous lifting, powerlifting, or bodybuilding"
        case .squatDeadlift: "Squats and deadlifts, slow or explosive effort"
        }
    }
    var compendium: (code: String, met: Double) {
        switch self {
        case .variedResistance: ("02054", 3.5)
        case .vigorousLifting: ("02050", 6)
        case .squatDeadlift: ("02052", 5)
        }
    }
}

struct WorkoutEnergyInput: Codable, Equatable {
    let activity: WorkoutEnergyActivity
    let minutes: Double

    var isValid: Bool { minutes > 0 && minutes <= 1440 }
}

struct WorkoutEnergyEstimate {
    static let activitySource = URL(string: "https://pacompendium.com/conditioning-exercise/")
    static let methodSource = URL(string: "https://pmc.ncbi.nlm.nih.gov/articles/PMC10818145/")

    let kilocalories: Double
    let bodyweightKg: Double
    let input: WorkoutEnergyInput

    static func calculate(input: WorkoutEnergyInput?, kilograms: Double?) -> Self? {
        guard let input, input.isValid, let kilograms, kilograms.isFinite, kilograms > 0 else { return nil }
        let result = input.activity.compendium.met * (input.minutes / 60) * kilograms
        guard result.isFinite else { return nil }
        return Self(kilocalories: result, bodyweightKg: kilograms, input: input)
    }

    static func workout(_ session: WorkoutSession, records: TrainingRecords) -> Self? {
        guard session.completedAt != nil, !session.performedSets.isEmpty else { return nil }
        return calculate(input: session.energyInput, kilograms: records.bodyweight(on: session.localDate)?.mass.kilograms)
    }
}

extension TrainingRepository {
    func saveWorkoutEnergy(_ input: WorkoutEnergyInput?, sessionID: UUID) throws {
        guard let index = records.sessions.firstIndex(where: { $0.id == sessionID && $0.completedAt != nil && !$0.performedSets.isEmpty }) else {
            throw TrainingDataError.unknownRecord("Choose a finished workout with logged work.")
        }
        guard input?.isValid != false else { throw TrainingDataError.invalidRecord("Enter activity minutes greater than 0 and up to 1,440.") }
        try commit { $0.sessions[index].energyInput = input }
    }
}
