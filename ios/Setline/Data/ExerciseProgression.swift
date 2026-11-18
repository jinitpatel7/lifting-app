import Foundation

enum ProgressionMode: String, Codable, CaseIterable, Identifiable {
    case reps = "Reps", load = "Load", duration = "Duration", distance = "Distance", assistance = "Reduced assistance"
    var id: Self { self }
    var isMass: Bool { self == .load || self == .assistance }
}

struct ProgressionRule: Codable, Equatable {
    enum Threshold: String, Codable, CaseIterable { case top = "Top of each rep range", minimum = "Minimum of each rep range" }
    enum Miss: String, Codable, CaseIterable { case hold = "Hold targets", stepBack = "Step back one increment" }
    enum Effort: String, Codable, CaseIterable { case none = "Off", rir = "Minimum RIR", rpe = "Maximum RPE" }

    var mode: ProgressionMode
    var threshold: Threshold = .top
    var miss: Miss = .hold
    var step: Double? = nil
    var effort: Effort = .none
    var effortLimit: Double? = nil

    func validate(for row: PlannedExercise) throws {
        guard row.progressionModes.contains(mode) else { throw TrainingDataError.invalidRecord("Choose a supported progression rule.") }
        if mode != .reps, !(step.map { $0.isFinite && $0 > 0 } ?? false) {
            throw TrainingDataError.invalidRecord("Enter a positive available increment.")
        }
        if effort == .rir, !(effortLimit.map { $0.isFinite && $0 >= 0 && $0 == $0.rounded() } ?? false) {
            throw TrainingDataError.invalidRecord("Enter a nonnegative minimum RIR.")
        }
        if effort == .rpe, !(effortLimit.map { (1...10).contains($0) } ?? false) {
            throw TrainingDataError.invalidRecord("Enter a maximum RPE from 1 to 10.")
        }
    }
}

struct ExerciseProgressionRule: Codable, Equatable {
    let variant: ExerciseVariantKey
    let rule: ProgressionRule
}

extension PlannedExercise {
    var progressionModes: [ProgressionMode] {
        guard !unlinkedStation else { return [] }
        return switch variant.measurement {
        case .weightReps, .addedLoad: [.reps, .load]
        case .assistance: [.reps, .assistance]
        case .duration: [.duration]
        case .distance: [.distance]
        case .bodyweight, .machineSetting: [.reps]
        }
    }

    func replacingWorkingSets(_ blocks: [SetPrescription]) -> Self {
        PlannedExercise(id: id, variant: variant, prescription: blocks[0], warmUps: warmUps,
            additionalWorkingSets: additionalWorkingSets != nil || blocks.count > 1 ? Array(blocks.dropFirst()) : nil)
    }
}

struct ProgressionSuggestion {
    enum Action: String { case off = "Rule off", hold = "Hold targets", advance = "Progress", adjust = "Step back" }

    let action: Action
    let reason: String
    var sourceID: UUID? = nil
    var sourceDate: WorkoutDate? = nil
    var sourceName: String? = nil
    var evidence: [HistorySet] = []
    var excluded: [HistorySet] = []
    var changes: [Int: SetPrescription] = [:]
    var assessment: [Int: String] = [:]
}

enum ExerciseProgression {
    static func suggest(_ row: PlannedExercise, in version: RoutineVersion, records: TrainingRecords) -> ProgressionSuggestion {
        let ordinary = row.workingSets.enumerated().filter { isOrdinary($0.element) }
        var source: WorkoutSession?
        var evidence: [HistorySet] = [], excluded: [HistorySet] = []
        var assessment: [Int: String] = [:]
        func answer(_ action: ProgressionSuggestion.Action, _ reason: String, _ changes: [Int: SetPrescription] = [:]) -> ProgressionSuggestion {
            ProgressionSuggestion(action: action, reason: reason, sourceID: source?.id, sourceDate: source?.localDate,
                sourceName: source?.plan.name, evidence: evidence, excluded: excluded, changes: changes, assessment: assessment)
        }
        guard let rule = records.progressionRule(for: row), (try? rule.validate(for: row)) != nil else {
            return answer(.off, "Choose a rule for this exercise and equipment.")
        }
        guard !ordinary.isEmpty else { return answer(.hold, "There are no straight working prescriptions to progress.") }
        guard ordinary.allSatisfy({ rule.mode == .reps ? $0.element.reps != nil : $0.element.target != nil }) else {
            return answer(.hold, "Enter a planned target for every straight working block in this routine.")
        }
        for session in WorkoutHistory.filtered(records.sessions) where session.completedAt != nil {
            let matches = session.plan.exercises.filter { !$0.unlinkedStation && $0.historyVariantKey == row.historyVariantKey }
            let sameRoutine = session.routineSnapshot.routineID == version.routineID
            let exact = sameRoutine ? matches.first { $0.id == row.id } : nil
            if sameRoutine, exact == nil, session.routineSnapshot.exercises.contains(where: { $0.id == row.id && $0.historyVariantKey == row.historyVariantKey }) {
                source = session
                return answer(.hold, "The last workout removed this exercise slot or changed its equipment or measurement. Log the current prescription first.")
            }
            guard let entry = exact ?? (matches.count == 1 ? matches.first : nil) else { continue }
            source = session
            let rows = session.historyRows(for: entry)
            func included(_ set: HistorySet) -> Bool { set.purpose == .working && set.prescription.map(isOrdinary) == true }
            evidence = rows.filter(included)
            excluded = rows.filter { !included($0) }
            if WorkoutAnalytics.context(session, records: records).kind == .deload {
                return answer(.hold, "The latest matching workout was a planned deload. Log a regular workout before progressing.")
            }
            break
        }
        guard source != nil else { return answer(.hold, "Log a finished workout with the same exercise, equipment, and measurement.") }
        let count = ordinary.reduce(0) { min($0 + min($1.element.sets, 10_001), 10_001) }
        guard count == evidence.count, count <= 10_000 else {
            return answer(.hold, "The last workout used a different number of straight working sets. Log the current prescription first.")
        }
        let planned = ordinary.flatMap { Array(repeating: $0, count: $0.element.sets) }
        guard zip(planned, evidence).allSatisfy({ pair in
            pair.1.prescription.map { sameTargets(pair.0.element, $0) } == true
        }) else { return answer(.hold, "The last workout used different targets. Log the current prescription first.") }
        let usable = evidence.enumerated().compactMap { index, set -> PerformedSet? in
            guard set.status == .completed, let result = set.result, result.amrap != true,
                  result.purpose != .warmUp, (result.structure ?? .straight) == .straight,
                  row.variant.measurement.accepts(result.amount),
                  row.variant.measurement.acceptsPerformed(reps: result.repetitions, rightAmount: result.rightAmount) else { return nil }
            let plan = planned[index].element
            assessment[set.order] = !meets(result, plan, top: false) ? "Missed target" :
                plan.reps == nil ? "Met target amount" : meets(result, plan, top: true) ? "Reached top of range" : "Met minimum"
            return result
        }
        guard usable.count == count else {
            return answer(.hold, "\(usable.count) of \(count) prescribed straight working sets have usable completed results. Finish all of them to assess a change.")
        }
        let missed = zip(usable, planned).filter { !meets($0.0, $0.1.element, top: false) }
        if !missed.isEmpty {
            let indices = Set(missed.map { $0.1.offset })
            let changes = rule.miss == .stepBack ? changed(ordinary.filter { indices.contains($0.offset) }, rule: rule, direction: -1) : [:]
            let detail = changes.isEmpty ? "Keep the current targets." : "Your rule steps back one increment for the affected blocks."
            return answer(changes.isEmpty ? .hold : .adjust, "\(missed.count) of \(count) sets missed a planned minimum or amount. \(detail)", changes)
        }
        let top = rule.mode != .reps && rule.threshold == .top && planned.contains { $0.element.reps != nil }
        let passing = zip(usable, planned).filter { meets($0.0, $0.1.element, top: top) }.count
        guard passing == count else {
            return answer(.hold, "\(passing) of \(count) sets reached the top of their rep range at the planned target. Keep the current targets.")
        }
        var effortNote = ""
        if rule.effort != .none, let limit = rule.effortLimit {
            let readings = usable.compactMap { rule.effort == .rir ? $0.actualRIR.map { Double($0) } : $0.actualRPE }
            let label = rule.effort == .rir ? "RIR" : "RPE"
            if readings.count == count {
                guard readings.allSatisfy({ rule.effort == .rir ? $0 >= limit : $0 <= limit }) else {
                    let criterion = rule.effort == .rir ? "at least \(limit.formatted()) RIR" : "at most \(limit.formatted()) RPE"
                    return answer(.hold, "The sets met the performance targets, but at least one recorded \(label) missed the effort criterion of \(criterion).")
                }
                effortNote = " All \(count) \(label) readings also met your rule."
            } else { effortNote = " Effort was left out because only \(readings.count) of \(count) sets recorded \(label)." }
        }
        let changes = changed(ordinary, rule: rule, direction: 1)
        if changes.isEmpty {
            let note = rule.mode == .reps ? "The rep minimum is already at the top of the prescribed range." : "A full available increment would go outside the supported target range."
            return answer(.hold, note + effortNote)
        }
        let criteria = top ? "the top of their rep ranges at the planned target" : "their planned targets"
        return answer(.advance, "All \(count) straight working sets reached \(criteria)." + effortNote, changes)
    }

    private static func isOrdinary(_ plan: SetPrescription) -> Bool { plan.amrap != true && (plan.structure ?? .straight) == .straight }

    private static func sameTargets(_ a: SetPrescription, _ b: SetPrescription) -> Bool {
        a.reps == b.reps && (a.target == b.target || compareAmounts(a.target, b.target, equality: true))
    }

    private static func meets(_ result: PerformedSet, _ plan: SetPrescription, top: Bool) -> Bool {
        if let range = plan.reps {
            let required = top ? range.maximum : range.minimum
            switch result.repetitions {
            case .total(let count), .perSide(let count): if count < required { return false }
            case .separateSides(let left, let right): if min(left, right) < required { return false }
            case nil: return false
            }
        }
        guard let target = plan.target else { return true }
        return compareAmounts(result.amount, target) && compareAmounts(result.rightAmount ?? result.amount, target)
    }

    private static func compareAmounts(_ actual: SetAmount?, _ target: SetAmount?, equality: Bool = false) -> Bool {
        func reaches(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-7 || (!equality && a > b) }
        switch (actual, target) {
        case (.weight(let a), .weight(let b)), (.addedLoad(let a), .addedLoad(let b)): reaches(a.kilograms, b.kilograms)
        case (.assistance(let a), .assistance(let b)): reaches(b.kilograms, a.kilograms)
        case (.durationSeconds(let a), .durationSeconds(let b)), (.distanceMeters(let a), .distanceMeters(let b)): reaches(a, b)
        case (.machineSetting(let a), .machineSetting(let b)): a == b
        default: false
        }
    }

    private static func changed(_ entries: [(offset: Int, element: SetPrescription)], rule: ProgressionRule,
                                direction: Int) -> [Int: SetPrescription] {
        var changes: [Int: SetPrescription] = [:]
        for (index, plan) in entries {
            var next = plan
            if rule.mode == .reps, let range = plan.reps {
                let minimum = direction == 1 && range.minimum >= range.maximum ? range.minimum : max(1, range.minimum + direction)
                next.reps = RepRange(minimum: minimum, maximum: range.maximum)
            } else if let step = rule.step, let target = plan.target {
                next.target = nextAmount(target, by: step * Double(direction)) ?? target
            }
            if !sameTargets(plan, next) { changes[index] = next }
        }
        return changes
    }

    private static func nextAmount(_ target: SetAmount, by step: Double) -> SetAmount? {
        func mass(_ candidate: Double) -> Mass? { Mass(abs(candidate) < 1e-7 ? 0 : candidate) }
        func positive(_ value: Double) -> Double? { value.isFinite && value > 1e-7 ? value : nil }
        switch target {
        case .weight(let value): return mass(value.kilograms + step).map(SetAmount.weight)
        case .addedLoad(let value): return mass(value.kilograms + step).map(SetAmount.addedLoad)
        case .assistance(let value): return mass(value.kilograms - step).map(SetAmount.assistance)
        case .durationSeconds(let value): return positive(value + step).map(SetAmount.durationSeconds)
        case .distanceMeters(let value): return positive(value + step).map(SetAmount.distanceMeters)
        case .machineSetting: return nil
        }
    }
}

extension TrainingRecords {
    func progressionRule(for row: PlannedExercise) -> ProgressionRule? {
        progressionRules?.first { $0.variant == row.variant.key }?.rule
    }
}

extension TrainingRepository {
    func saveProgressionRule(_ rule: ProgressionRule?, versionID: UUID, rowID: UUID) throws {
        let (_, row) = try progressionSlot(versionID, rowID)
        try rule?.validate(for: row)
        var rules = records.progressionRules ?? []
        rules.removeAll { $0.variant == row.variant.key }
        if let rule { rules.append(ExerciseProgressionRule(variant: row.variant.key, rule: rule)) }
        try commit { $0.progressionRules = rules }
    }

    func acceptProgression(_ reviewed: ProgressionSuggestion, versionID: UUID, rowID: UUID) throws {
        let (version, row) = try progressionSlot(versionID, rowID)
        let suggestion = ExerciseProgression.suggest(row, in: version, records: records)
        guard !suggestion.changes.isEmpty, suggestion.matchesReview(reviewed) else {
            throw TrainingDataError.conflictingRecord("The suggestion changed. Reopen the review before accepting it.")
        }
        let working = row.workingSets.enumerated().map { suggestion.changes[$0.offset] ?? $0.element }
        let rows = version.exercises.map { $0.id == rowID ? row.replacingWorkingSets(working) : $0 }
        try saveRoutine(id: version.routineID, name: version.name, exercises: rows, categoryID: version.categoryID,
            groups: version.groups ?? [], expectedVersionID: version.id, preserveCurrentSnapshots: true)
    }

    private func progressionSlot(_ versionID: UUID, _ rowID: UUID) throws -> (RoutineVersion, PlannedExercise) {
        guard let version = records.currentRoutines.first(where: { $0.id == versionID }),
              let row = version.exercises.first(where: { $0.id == rowID }) else {
            throw TrainingDataError.conflictingRecord("This routine changed. Reopen the progression review.")
        }
        return (version, row)
    }
}

private extension ProgressionSuggestion {
    func matchesReview(_ other: Self) -> Bool {
        // Older sessions reconstruct row IDs while decoding their historical prescriptions.
        action == other.action && reason == other.reason && sourceID == other.sourceID && changes == other.changes && assessment == other.assessment &&
            evidence.map(\.result) == other.evidence.map(\.result) && excluded.map(\.result) == other.excluded.map(\.result)
    }
}
