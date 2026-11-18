import Foundation

enum WorkoutSetStatus: String, Codable, Equatable { case pending, skipped, completed }

struct WorkoutSetInput: Codable, Equatable {
    var unit: WeightUnit
    var amount = ""
    var reps = ""
    var rightReps = ""
    var rir = ""
    var rpe = ""
    var failure = false

    init(unit: WeightUnit, prescription: SetPrescription? = nil) {
        self.unit = unit
        if let minimum = prescription?.reps?.minimum { reps = String(minimum); rightReps = reps }
        prefillAmount(prescription?.target)
    }

    init(result: PerformedSet) {
        unit = .kg
        prefillAmount(result.amount)
        switch result.repetitions {
        case .total(let count), .perSide(let count): reps = String(count)
        case .separateSides(let left, let right): reps = String(left); rightReps = String(right)
        case nil: break
        }
        if let value = result.actualRIR { rir = String(value) }
        if let value = result.actualRPE { rpe = String(value) }
        failure = result.effortOutcome == .failure
    }

    private mutating func prefillAmount(_ target: SetAmount?) {
        switch target {
        case .weight(let mass), .addedLoad(let mass), .assistance(let mass):
            amount = String(mass.value(in: unit))
        case .durationSeconds(let seconds): amount = String(seconds)
        case .distanceMeters(let meters): amount = String(meters)
        case .machineSetting(let setting): amount = setting
        case nil: break
        }
    }

    func performedAmount(for measurement: Measurement) throws -> SetAmount? {
        if case .bodyweight = measurement { return nil }
        let label = amount.trimmingCharacters(in: .whitespacesAndNewlines)
        if case .machineSetting = measurement, !label.isEmpty { return .machineSetting(label) }
        guard let value = Double(label.replacingOccurrences(of: ",", with: ".")), value.isFinite, value >= 0 else {
            throw TrainingDataError.invalidRecord("Enter a valid result before completing this set.")
        }
        switch measurement {
        case .weightReps: return Mass(value, unit: unit).map(SetAmount.weight)
        case .addedLoad: return Mass(value, unit: unit).map(SetAmount.addedLoad)
        case .assistance: return Mass(value, unit: unit).map(SetAmount.assistance)
        case .duration: return .durationSeconds(value)
        case .distance: return .distanceMeters(value)
        default: throw TrainingDataError.invalidRecord("Enter a machine setting before completing this set.")
        }
    }

    func repetitions(for measurement: Measurement) throws -> Repetitions? {
        guard let counting = measurement.repCounting else { return nil }
        guard let left = whole(reps) else { throw TrainingDataError.invalidRecord("Enter completed reps.") }
        switch counting {
        case .total: return .total(left)
        case .perSide: return .perSide(left)
        case .separateSides:
            guard let right = whole(rightReps) else { throw TrainingDataError.invalidRecord("Enter reps for both sides.") }
            return .separateSides(left: left, right: right)
        }
    }

    func efforts() throws -> (rir: Int?, rpe: Double?) {
        let reserve = whole(rir)
        let exertion = Double(rpe.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "."))
        guard rir.isEmpty || (reserve.map { $0 >= 0 } == true),
              rpe.isEmpty || (exertion.map { (1...10).contains($0) } == true) else {
            throw TrainingDataError.invalidRecord("Enter a nonnegative whole-number RIR and RPE from 1 to 10.")
        }
        return (reserve, exertion)
    }

    private func whole(_ text: String) -> Int? { Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
}

struct WorkoutSetRow: Codable, Equatable, Identifiable {
    var id = UUID()
    var purpose: SetPurpose
    var prescription: SetPrescription? = nil
    var input: WorkoutSetInput? = nil
    var status: WorkoutSetStatus = .pending
}

struct WorkoutExerciseLog: Codable, Equatable, Identifiable {
    let id: UUID
    var rows: [WorkoutSetRow]
    var notes = ""
    var queued = false
    var queuedAt: Date? = nil

    init(entry: PlannedExercise) throws {
        id = entry.id
        var remaining = 10_000
        func expand(_ blocks: [SetPrescription], purpose: SetPurpose) throws -> [WorkoutSetRow] {
            try blocks.flatMap { block in
                guard block.sets > 0, block.sets <= remaining else {
                    throw TrainingDataError.invalidRecord("This exercise has too many set rows. Reduce its set count before logging.")
                }
                remaining -= block.sets
                return (0..<block.sets).map { _ in WorkoutSetRow(purpose: purpose, prescription: block) }
            }
        }
        let warm = try expand(entry.warmUps ?? [], purpose: .warmUp)
        rows = warm + (try expand(entry.workingSets, purpose: .working))
    }
}

struct WorkoutLog: Codable, Equatable {
    var exercises: [WorkoutExerciseLog]
    var notes = ""

    init(session: WorkoutSession) throws {
        exercises = try session.plan.exercises.map { entry in
            var log = try WorkoutExerciseLog(entry: entry)
            for result in session.performedSets.filter({ $0.plannedExerciseID == entry.id }).sorted(by: { $0.order < $1.order }) {
                let position = result.order - 1
                if log.rows.indices.contains(position) {
                    log.rows[position].id = result.id
                    log.rows[position].status = .completed
                } else {
                    log.rows.append(WorkoutSetRow(id: result.id, purpose: result.purpose ?? .working, status: .completed))
                }
            }
            return log
        }
    }

    func repeated() -> Self {
        var copy = self
        copy.notes = ""
        for index in copy.exercises.indices {
            copy.exercises[index].queued = false
            copy.exercises[index].queuedAt = nil
            copy.exercises[index].notes = ""
            copy.exercises[index].rows = copy.exercises[index].rows.map {
                WorkoutSetRow(purpose: $0.purpose, prescription: $0.prescription)
            }
        }
        return copy
    }
}

enum WorkoutLogChange {
    case sessionNotes(String), exerciseNotes(UUID, String)
    case addExercise(Exercise, Measurement, Equipment?), removeExercise(UUID)
    case moveExercise(UUID, Int), queue(UUID, Bool), skipExercise(UUID), restoreExercise(UUID)
    case addSet(UUID, SetPurpose), removeSet(UUID, UUID), moveSet(UUID, UUID, Int)
    case editSet(UUID, UUID, WorkoutSetInput), complete(UUID, UUID, WeightUnit), setSkipped(UUID, UUID, Bool), undo(UUID, UUID)
}
