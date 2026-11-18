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
    var separateSides: Bool? = nil
    var rightAmount: String? = nil

    init(unit: WeightUnit, prescription: SetPrescription? = nil) {
        self.unit = unit
        if let minimum = prescription?.reps?.minimum { reps = String(minimum); rightReps = reps }
        prefillAmount(prescription?.target)
    }

    init(result: PerformedSet) {
        self.init(result: result, unit: .kg)
    }

    init(result: PerformedSet, unit: WeightUnit) {
        self.unit = unit
        prefillAmount(result.amount)
        switch result.repetitions {
        case .total(let count), .perSide(let count): reps = String(count)
        case .separateSides(let left, let right): reps = String(left); rightReps = String(right)
        case nil: break
        }
        if let value = result.actualRIR { rir = String(value) }
        if let value = result.actualRPE { rpe = String(value) }
        failure = result.effortOutcome == .failure
        if case .separateSides = result.repetitions { separateSides = true }
        if let right = result.rightAmount {
            separateSides = true
            var input = WorkoutSetInput(unit: unit)
            input.prefillAmount(right)
            rightAmount = input.amount
        }
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
        case .perSide where separateSides != true: return .perSide(left)
        case .perSide, .separateSides:
            guard let right = whole(rightReps) else { throw TrainingDataError.invalidRecord("Enter reps for both sides.") }
            return .separateSides(left: left, right: right)
        }
    }

    func performedRightAmount(for measurement: Measurement, reps: Repetitions?) throws -> SetAmount? {
        let splitQuantity = measurement.repCounting == nil && separateSides == true
        if !splitQuantity {
            guard case .separateSides = reps, let rightAmount, !rightAmount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        }
        var right = self
        right.amount = rightAmount ?? ""
        return try right.performedAmount(for: measurement)
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
    var clock: WorkoutClock? = nil
    var rest: WorkoutRest? = nil
    var trackRest: Bool? = nil
    var loadProfiles: [String: WorkoutLoadProfile]? = nil
    var undo: WorkoutUndo? = nil

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
        copy.clock = nil
        copy.rest = nil
        copy.undo = nil
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
    case pause, resume, trackRest(Bool), extendRest, restartRest, skipRest, editRest(UUID, String), undoLast
    case loadProfile(String, WorkoutLoadProfile)

    var undoLabel: String? {
        switch self {
        case .complete: "set completion"
        case .removeSet: "set deletion"
        case .removeExercise: "exercise deletion"
        case .setSkipped(_, _, true), .skipExercise: "skip"
        case .moveSet, .moveExercise: "reorder"
        case .skipRest: "rest skip"
        default: nil
        }
    }
}

struct WorkoutClock: Codable, Equatable {
    var pausedAt: Date?
    var pausedSeconds: TimeInterval = 0
}

struct WorkoutRest: Codable, Equatable {
    let setID: UUID
    let startedAt: Date
    let startedActive: TimeInterval
    var countdownStartedAt: Date
    var countdownActive: TimeInterval
    let targetSeconds: Int
    let rule: String
    var extensionSeconds: TimeInterval = 0

    func remaining(active: TimeInterval) -> Int {
        let seconds = ceil(max(0, Double(targetSeconds) + extensionSeconds - (active - countdownActive)))
        return seconds < Double(Int.max) ? Int(seconds) : Int.max
    }
}

struct ActualWorkoutRest: Codable, Equatable {
    var measuredSeconds: Int? = nil
    var editedSeconds: Int? = nil
    var startedAt: Date? = nil
    var endedAt: Date? = nil
    var reason: String? = nil
}

struct WorkoutUndo: Codable, Equatable {
    let label: String
    let exercises: [WorkoutExerciseLog]
    let results: [PerformedSet]
    let plan: RoutineVersion?
    let rest: WorkoutRest?
}

extension WorkoutSession {
    func workoutTimes(at date: Date, clock: WorkoutClock?) -> (elapsed: TimeInterval, paused: TimeInterval, active: TimeInterval) {
        let end = completedAt ?? date
        let elapsed = max(0, end.timeIntervalSince(startedAt))
        let paused = min(elapsed, (clock?.pausedSeconds ?? 0) + (clock?.pausedAt.map { max(0, end.timeIntervalSince($0)) } ?? 0))
        return (elapsed, paused, elapsed - paused)
    }
}

struct WorkoutSequenceItem {
    let exerciseID: UUID
    let row: WorkoutSetRow
    var group: RoutineGroup? = nil
    var round: Int? = nil
}

extension WorkoutLog {
    func sequence(groups: [RoutineGroup]) -> [WorkoutSequenceItem] {
        var result: [WorkoutSequenceItem] = []
        var grouped = Set<UUID>()
        let available = Dictionary(uniqueKeysWithValues: exercises.filter { !$0.queued }.map { ($0.id, $0) })
        for exercise in exercises where !grouped.contains(exercise.id) {
            guard let group = groups.first(where: { $0.exerciseIDs.contains(exercise.id) }) else {
                if !exercise.queued { result += exercise.rows.map { WorkoutSequenceItem(exerciseID: exercise.id, row: $0) } }
                continue
            }
            grouped.formUnion(group.exerciseIDs)
            let members = group.exerciseIDs.compactMap { available[$0] }
            let work = members.map { $0.rows.filter { $0.purpose == .working } }
            let rounds = min(group.rounds, work.map(\.count).max() ?? 0)
            for member in members {
                result += member.rows.filter { $0.purpose == .warmUp }.map { WorkoutSequenceItem(exerciseID: member.id, row: $0) }
            }
            for round in 0..<rounds {
                for (index, member) in members.enumerated() where work[index].indices.contains(round) {
                    result.append(WorkoutSequenceItem(exerciseID: member.id, row: work[index][round], group: group, round: round))
                }
            }
            for (index, member) in members.enumerated() {
                result += work[index].dropFirst(rounds).map { WorkoutSequenceItem(exerciseID: member.id, row: $0) }
            }
        }
        return result
    }

    mutating func openRest(for row: WorkoutSetRow, groups: [RoutineGroup], at date: Date, active: TimeInterval) {
        let order = sequence(groups: groups)
        var seconds = row.prescription?.restSeconds ?? 90
        var rule = row.prescription?.restSeconds == nil ? "Default rest" : "Set rest"
        if let source = order.first(where: { $0.row.id == row.id }), let group = source.group,
           let next = order.first(where: { $0.row.status == .pending }), next.group?.id == group.id {
            let sameRound = next.round == source.round
            seconds = sameRound ? group.restBetweenExercises : group.restBetweenRounds
            rule = sameRound ? "Between exercises" : "Between rounds"
        }
        rest = WorkoutRest(setID: row.id, startedAt: date, startedActive: active, countdownStartedAt: date,
                           countdownActive: active, targetSeconds: seconds, rule: rule)
    }

    mutating func closeRest(results: inout [PerformedSet], at date: Date, active: TimeInterval, reason: String) {
        guard let rest else { return }
        if trackRest == true, let index = results.firstIndex(where: { $0.id == rest.setID }) {
            let edited = results[index].actualRest?.editedSeconds
            results[index].actualRest = ActualWorkoutRest(measuredSeconds: Int(max(0, active - rest.startedActive)), editedSeconds: edited,
                startedAt: rest.startedAt, endedAt: date, reason: reason)
        }
        self.rest = nil
    }
}

struct WorkoutLoadProfile: Codable, Equatable {
    struct Plate: Codable, Equatable {
        let weight: Double
        let count: Int
    }

    let unit: WeightUnit
    var bar: Double? = nil
    var plates: [Plate] = []
    var increment: Double? = nil

    struct Options {
        let plates: [Double]?
        let lower: Double?
        let upper: Double?
    }

    func options(for target: Double) throws -> Options? {
        guard let bar, (0...1_000_000).contains(bar), (0...1_000_000).contains(target) else { return nil }
        var combinations = [0: [Double]()]
        for plate in plates {
            var next: [Int: [Double]] = [:]
            for (total, values) in combinations {
                for count in 0...plate.count {
                    let load = total + count * Int((plate.weight * 1000).rounded())
                    if next[load].map({ $0.count > values.count + count }) ?? true {
                        next[load] = values + Array(repeating: plate.weight, count: count)
                    }
                    guard next.count <= 25_000 else { throw TrainingDataError.invalidRecord("Use fewer plate sizes or pairs in this calculation.") }
                }
            }
            combinations = next
        }
        let base = Int((bar * 1000).rounded())
        let requested = Int((target * 1000).rounded())
        let totals = combinations.keys.map { base + 2 * $0 }.sorted()
        let exact = totals.contains(requested) ? combinations[(requested - base) / 2]?.sorted(by: >) : nil
        return Options(plates: exact, lower: totals.last(where: { $0 < requested }).map { Double($0) / 1000 },
                       upper: totals.first(where: { $0 > requested }).map { Double($0) / 1000 })
    }

    static func parsePlates(_ text: String) throws -> [Plate] {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
        let entries = text.split(separator: ",", omittingEmptySubsequences: false)
        guard entries.count <= 12 else { throw TrainingDataError.invalidRecord("Enter up to 12 plate sizes.") }
        return try entries.map { entry in
            let parts = entry.lowercased().split(whereSeparator: { $0 == "x" || $0 == "×" || $0 == ":" })
            guard parts.count == 2, let weight = Double(parts[0].trimmingCharacters(in: .whitespaces)),
                  weight > 0, weight <= 1000, let count = Int(parts[1].trimmingCharacters(in: .whitespaces)), (1...30).contains(count),
                  abs(weight * 1000 - (weight * 1000).rounded()) < 0.00001 else {
                throw TrainingDataError.invalidRecord("Enter plate weight × pairs, for example 20x2, 5x1. Use at most 30 pairs per size.")
            }
            return Plate(weight: weight, count: count)
        }
    }
}

extension ExerciseVariant {
    var loggingEquipmentKind: EquipmentKind? { equipment?.kind ?? exercise.profile?.equipmentKind }
    var loggingEquipmentKey: String { equipment?.id.uuidString ?? exercise.id.uuidString }
    var usesPlateCalculator: Bool {
        if case .weightReps(.total, _) = measurement { return loggingEquipmentKind == .barbell }
        return false
    }
}

extension Measurement {
    func acceptsPerformed(reps: Repetitions?, rightAmount: SetAmount?) -> Bool {
        let separateReps = reps?.matches(.separateSides) == true
        guard accepts(reps) || (repCounting == .perSide && separateReps) else { return false }
        return rightAmount == nil || ((repCounting == nil || separateReps) && accepts(rightAmount))
    }
}
