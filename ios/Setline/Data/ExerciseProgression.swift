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
    var topSessions: Int? = nil
    var allowExtraSet: Bool? = nil
    var plateauSessions: Int? = nil
    var volumeCap: Int? = nil

    func validate(for row: PlannedExercise) throws {
        guard row.progressionModes.contains(mode) else { throw TrainingDataError.invalidRecord("Choose a supported progression rule.") }
        if step.map({ !$0.isFinite || $0 <= 0 }) == true {
            throw TrainingDataError.invalidRecord("Enter a positive available increment.")
        }
        if effort == .rir, !(effortLimit.map { $0.isFinite && $0 >= 0 && $0 == $0.rounded() } ?? false) {
            throw TrainingDataError.invalidRecord("Enter a nonnegative minimum RIR.")
        }
        if effort == .rpe, !(effortLimit.map { (1...10).contains($0) } ?? false) {
            throw TrainingDataError.invalidRecord("Enter a maximum RPE from 1 to 10.")
        }
        guard (2...12).contains(topSessions ?? 2), (2...12).contains(plateauSessions ?? 3), (1...30).contains(volumeCap ?? 6) else {
            throw TrainingDataError.invalidRecord("Use 2–12 sessions and a volume cap of 1–30 working sets.")
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
    enum Action: String { case off = "Rule off", learning = "Learning your baseline", hold = "Hold targets", advance = "Progress", adjust = "Step back" }

    let action: Action
    let reason: String
    var sourceID: UUID? = nil
    var sourceDate: WorkoutDate? = nil
    var sourceName: String? = nil
    var evidence: [HistorySet] = []
    var excluded: [HistorySet] = []
    var changes: [Int: SetPrescription] = [:]
    var assessment: [Int: String] = [:]
    var replacements: [Int: [SetPrescription]] = [:]
    var warning: String? = nil
    var fingerprint = ""

    func workingSets(for row: PlannedExercise) -> [SetPrescription] {
        row.workingSets.enumerated().flatMap { index, plan in replacements[index] ?? [changes[index] ?? plan] }
    }
}

enum ProgressionScope: Equatable { case once, routine, dismiss }

struct ProgressionDecision: Codable, Equatable {
    let versionID: UUID
    let rowID: UUID
    let fingerprint: String
    let working: [SetPrescription]?
}

enum ExerciseProgression {
    private struct Observation {
        let session: WorkoutSession
        let rows: [HistorySet]
        let results: [PerformedSet?]
    }

    private struct Slot {
        let index: Int
        let position: Int
        let plan: SetPrescription
    }

    private struct Signature: Encodable {
        let action: String
        let ids: [UUID]
        let results: [[PerformedSet?]]
        let changes: [Int: SetPrescription]
        let replacements: [Int: [SetPrescription]]
    }

    private enum EffortEvidence: Equatable { case hard, room }

    static func suggest(_ row: PlannedExercise, in version: RoutineVersion, records: TrainingRecords) -> ProgressionSuggestion {
        let ordinary = row.workingSets.enumerated().filter { isOrdinary($0.element) }
        let planned = ordinary.flatMap { index, plan in
            (0..<min(max(0, plan.sets), 10_000)).map { Slot(index: index, position: $0, plan: plan) }
        }
        var source: WorkoutSession?
        var evidence: [HistorySet] = [], excluded: [HistorySet] = []
        var observations: [Observation] = []
        var assessment: [Int: String] = [:]
        func answer(_ action: ProgressionSuggestion.Action, _ reason: String, _ changes: [Int: SetPrescription] = [:],
                    replacements: [Int: [SetPrescription]] = [:], warning: String? = nil) -> ProgressionSuggestion {
            let signature = Signature(action: action.rawValue, ids: observations.map { $0.session.id },
                results: observations.map(\.results), changes: changes, replacements: replacements)
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let fingerprint = (try? encoder.encode(signature))?.base64EncodedString() ?? ""
            if !changes.isEmpty, let decision = records.progressionDecisions?.first(where: {
                $0.versionID == version.id && $0.rowID == row.id && $0.fingerprint == fingerprint
            }) {
                return ProgressionSuggestion(action: .hold, reason: decision.working == nil ? "This recommendation was dismissed." :
                    "Queued for the next matching workout.", sourceID: source?.id, sourceDate: source?.localDate, sourceName: source?.plan.name,
                    evidence: evidence, excluded: excluded, assessment: assessment, fingerprint: fingerprint)
            }
            return ProgressionSuggestion(action: action, reason: reason, sourceID: source?.id, sourceDate: source?.localDate,
                sourceName: source?.plan.name, evidence: evidence, excluded: excluded, changes: changes, assessment: assessment,
                replacements: replacements, warning: warning, fingerprint: fingerprint)
        }
        guard !row.progressionModes.isEmpty, records.disabledProgression?.contains(row.variant.key) != true else {
            return answer(.off, "Progression is off for this exercise or needs a named equipment station.")
        }
        guard !planned.isEmpty, planned.count <= 10_000 else {
            return answer(.hold, "There are no usable straight working prescriptions to progress.")
        }
        guard planned.allSatisfy({ $0.plan.reps != nil || $0.plan.target != nil }) else {
            return answer(.hold, "Enter a measurable target for every straight working set before progressing.")
        }
        for session in WorkoutHistory.filtered(records.sessions) where session.completedAt != nil {
            if let source, session.localDate.distance(to: source.localDate) > 90 { break }
            if WorkoutAnalytics.context(session, records: records).kind == .deload { continue }
            let matches = session.plan.exercises.filter { !$0.unlinkedStation && $0.historyVariantKey == row.historyVariantKey }
            let exact = session.routineSnapshot.routineID == version.routineID ? matches.first { $0.id == row.id } : nil
            guard let entry = exact ?? (matches.count == 1 ? matches.first : nil) else { continue }
            let all = session.historyRows(for: entry)
            func included(_ set: HistorySet) -> Bool { set.purpose == .working && set.prescription.map(isOrdinary) == true }
            let rows = all.filter(included)
            if source == nil {
                source = session
                evidence = rows
                excluded = all.filter { !included($0) }
            }
            guard rows.count == planned.count, zip(rows, planned).allSatisfy({ pair in
                pair.0.prescription.map { similar(pair.1.plan, $0) } == true
            }) else { break }
            let results = rows.map { set -> PerformedSet? in
                guard set.status == .completed, let result = set.result, result.purpose != .warmUp, result.amrap != true,
                      (result.structure ?? .straight) == .straight, row.variant.measurement.accepts(result.amount),
                      row.variant.measurement.acceptsPerformed(reps: result.repetitions, rightAmount: result.rightAmount) else { return nil }
                return result
            }
            observations.append(Observation(session: session, rows: rows, results: results))
            if observations.count == 12 { break }
        }
        guard let latest = observations.first else {
            return answer(.learning, "Learning your baseline. Log comparable sessions with this exercise, equipment, and prescription.")
        }
        let availableStep = equipmentIncrement(row, observations: observations)
        let modes = row.progressionModes
        let automatic = availableStep == nil ? modes[0] : (modes.first { $0.isMass } ?? modes[0])
        var rule = records.progressionRule(for: row) ?? ProgressionRule(mode: automatic)
        if rule.step == nil { rule.step = availableStep }
        func complete(_ observation: Observation) -> Bool { observation.results.allSatisfy { $0 != nil } }
        func hard(_ observation: Observation) -> Bool {
            zip(observation.results, planned).contains { result, slot in
                result.map { effortEvidence($0, plan: slot.plan, rule: rule) == .hard } ?? false
            }
        }
        func struggling(_ observation: Observation) -> Bool {
            hard(observation) || zip(observation.results, planned).contains { result, slot in
                result.map { !meets($0, slot.plan, top: false) } ?? false
            }
        }
        for (index, result) in latest.results.enumerated() {
            guard let result else { continue }
            let plan = planned[index].plan
            assessment[latest.rows[index].order] = !meets(result, plan, top: false) ? "Missed target" :
                plan.reps != nil && meets(result, plan, top: true) ? "Reached top of range" : "Met target"
        }
        guard complete(latest) else {
            return answer(.hold, "\(latest.results.compactMap { $0 }.count) of \(planned.count) prescribed working sets have usable completed results. Hold while evidence is incomplete.")
        }
        if struggling(latest) {
            guard observations.count >= 2, complete(observations[1]), struggling(observations[1]) else {
                return answer(.hold, "The latest comparable session missed a target or recorded excessive effort. Hold after one miss.")
            }
            let reduced = changed(ordinary, rule: rule, direction: -1)
            if !reduced.isEmpty {
                return answer(.adjust, "Two consecutive comparable sessions missed a target or recorded excessive effort. Reduce the prescribed demand by one available increment.", reduced)
            }
            if let last = ordinary.last, planned.count > 1 {
                var fewer = last.element
                fewer.sets -= 1
                return answer(.adjust, "Two consecutive comparable sessions missed a target or recorded excessive effort. Remove one straight working set.",
                    [last.offset: fewer], replacements: [last.offset: fewer.sets > 0 ? [fewer] : []])
            }
            return answer(.hold, "Two comparable sessions showed repeated difficulty. Keep the minimum set count and review the target manually.")
        }
        guard observations.filter(complete).count >= 2 else {
            return answer(.learning, "Learning your baseline. Log a second comparable workout with all prescribed working sets.")
        }
        for (index, slot) in planned.enumerated() {
            guard let result = latest.results[index], let range = slot.plan.reps, let reps = actualReps(result),
                  reps >= range.minimum, reps < range.maximum, exactAmount(result, plan: slot.plan) else { continue }
            var prescription = slot.plan
            prescription.sets = 1
            prescription.progressionFloor = slot.plan.progressionFloor ?? range.minimum
            prescription.reps = RepRange(minimum: reps + 1, maximum: range.maximum)
            var before = slot.plan
            before.sets = slot.position
            var after = slot.plan
            after.sets -= slot.position + 1
            return answer(.advance, "Set \(index + 1) met its target and has room in the rep range. Add one rep at the same load.",
                [slot.index: prescription], replacements: [slot.index: [before, prescription, after].filter { $0.sets > 0 }])
        }

        let required = rule.topSessions ?? 2
        let recent = observations.prefix(required)
        let ready = recent.count == required && recent.allSatisfy { observation in
            complete(observation) && !hard(observation) && zip(observation.results, planned).allSatisfy { result, slot in
                result.map { meets($0, slot.plan, top: true) && (!rule.mode.isMass || exactAmount($0, plan: slot.plan)) } ?? false
            }
        }
        if ready, rule.mode != .reps, let step = rule.step {
            let changes = changed(ordinary, rule: rule, direction: 1)
            if !changes.isEmpty {
                let large = changes.keys.contains { index in
                    quantity(row.workingSets[index].target).map { step > abs($0) * 0.1 + 1e-7 } == true
                }
                let description: String = switch rule.mode {
                case .load: "increase load and restart at the low end of the rep range"
                case .assistance: "reduce assistance and restart at the low end of the rep range"
                case .duration: "increase duration"
                case .distance: "increase distance"
                case .reps: "increase reps"
                }
                return answer(.advance, "\(required) comparable sessions reached every target. Use the smallest recorded increment to \(description).", changes,
                    warning: large ? "This increment changes the target by more than 10%. You can hold at the current target." : nil)
            }
        }
        let plateauCount = rule.plateauSessions ?? 3
        let plateau = observations.prefix(plateauCount)
        let volume = row.workingSets.reduce(0) { $0 + min($1.sets, 10_000) }
        let goodRecovery = records.readiness.contains {
            $0.localDate == latest.session.localDate && $0.energy >= 4 && $0.sleepQuality.map { $0 >= 4 } == true && $0.soreness <= 2
        }
        let spareEffort = zip(latest.results, planned).allSatisfy { result, slot in
            result.map { effortEvidence($0, plan: slot.plan, rule: rule) == .room } ?? false
        }
        if rule.allowExtraSet == true, volume < (rule.volumeCap ?? 6), plateau.count == plateauCount,
           plateau.allSatisfy({ complete($0) && !struggling($0) && comparableResults($0.results, latest.results) }),
           spareEffort || goodRecovery, let last = ordinary.last {
            var more = last.element
            more.sets += 1
            let support = spareEffort ? "effort in reserve" : "a supportive readiness check-in"
            return answer(.advance, "Performance held steady for \(plateauCount) comparable sessions with targets met and \(support). Add one working set under the cap.", [last.offset: more])
        }
        if ready, rule.mode != .reps {
            return answer(.hold, rule.step == nil ? "Targets are met. Set an available increment before changing the target." :
                "A full available increment would go outside the supported target range.")
        }
        return answer(.hold, "Hold the current targets. An increase needs \(required) consecutive comparable sessions meeting the required targets.")
    }

    private static func actualReps(_ result: PerformedSet) -> Int? {
        switch result.repetitions {
        case .total(let reps), .perSide(let reps): reps
        case .separateSides(let left, let right): min(left, right)
        case nil: nil
        }
    }

    private static func effortEvidence(_ result: PerformedSet, plan: SetPrescription, rule: ProgressionRule) -> EffortEvidence? {
        if plan.effort == .failure { return nil }
        if rule.effort == .rir, let limit = rule.effortLimit, let rir = result.actualRIR, Double(rir) < limit { return .hard }
        if rule.effort == .rpe, let limit = rule.effortLimit, let rpe = result.actualRPE, rpe > limit { return .hard }
        if rule.effort == .none {
            if let goal = plan.repsInReserve, let actual = result.actualRIR, Double(actual) < Double(goal) - 1 { return .hard }
            if case .rpe(let goal) = plan.effort, let actual = result.actualRPE, actual > goal + 1 { return .hard }
        }
        if result.effortOutcome == .failure || result.actualRIR == 0 || result.actualRPE == 10 { return .hard }
        if result.actualRIR.map({ $0 >= 2 }) == true || result.actualRPE.map({ $0 <= 8 }) == true { return .room }
        return nil
    }

    private static func equipmentIncrement(_ row: PlannedExercise, observations: [Observation]) -> Double? {
        for observation in observations {
            guard let profile = observation.session.workoutLog?.loadProfiles?[row.variant.loggingEquipmentKey] else { continue }
            if let increment = profile.increment, increment.isFinite, increment > 0 { return increment * profile.unit.kilogramsPerUnit }
            if row.variant.usesPlateCalculator, let plate = profile.plates.filter({ $0.count > 0 && $0.weight > 0 }).map(\.weight).min() {
                return 2 * plate * profile.unit.kilogramsPerUnit
            }
        }
        return nil
    }

    private static func similar(_ a: SetPrescription, _ b: SetPrescription) -> Bool {
        a.reps?.maximum == b.reps?.maximum && abs(Double(a.reps?.minimum ?? 0) - Double(b.reps?.minimum ?? 0)) <= 1 &&
            (a.target == b.target || compareAmounts(a.target, b.target, equality: true))
    }

    private static func exactAmount(_ result: PerformedSet, plan: SetPrescription) -> Bool {
        guard let target = plan.target else { return result.amount == nil }
        return compareAmounts(result.amount, target, equality: true) &&
            compareAmounts(result.rightAmount ?? result.amount, target, equality: true)
    }

    private static func comparableResults(_ lhs: [PerformedSet?], _ rhs: [PerformedSet?]) -> Bool {
        zip(lhs, rhs).allSatisfy { left, right in
            left?.repetitions == right?.repetitions &&
                (left?.amount == right?.amount || compareAmounts(left?.amount, right?.amount, equality: true)) &&
                (left?.rightAmount == right?.rightAmount || compareAmounts(left?.rightAmount, right?.rightAmount, equality: true))
        }
    }

    private static func quantity(_ target: SetAmount?) -> Double? {
        switch target {
        case .weight(let mass), .addedLoad(let mass), .assistance(let mass): mass.kilograms
        case .durationSeconds(let value), .distanceMeters(let value): value
        default: nil
        }
    }

    private static func isOrdinary(_ plan: SetPrescription) -> Bool { plan.amrap != true && (plan.structure ?? .straight) == .straight }

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
        guard rule.mode != .reps, let step = rule.step else { return [:] }
        var changes: [Int: SetPrescription] = [:]
        for (index, plan) in entries {
            guard let target = plan.target, let amount = nextAmount(target, by: step * Double(direction)) else { continue }
            var next = plan
            next.target = amount
            if direction > 0, rule.mode.isMass, let reps = plan.reps {
                next.reps = RepRange(minimum: plan.progressionFloor ?? reps.minimum, maximum: reps.maximum)
            }
            if amount != target { changes[index] = next }
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

    mutating func consumeProgression(versionID: UUID, rows: Set<UUID>) {
        guard !rows.isEmpty else { return }
        progressionDecisions?.removeAll { $0.versionID == versionID && rows.contains($0.rowID) }
    }
}

extension WorkoutSession {
    mutating func prepareQueuedProgression(in records: TrainingRecords, schedule: ScheduledWorkout? = nil) throws -> Set<UUID> {
        guard WorkoutAnalytics.context(on: schedule?.localDate ?? localDate, entry: schedule, records: records).kind != .deload else { return [] }
        let version = routineSnapshot
        let queued = (records.progressionDecisions ?? []).filter { $0.versionID == version.id && $0.working != nil }
        var used = Set<UUID>()
        let updated = version.exercises.map { row in
            guard let decision = queued.first(where: { $0.rowID == row.id }),
                  let blocks = decision.working, !blocks.isEmpty else { return row }
            used.insert(row.id)
            return row.replacingWorkingSets(blocks)
        }
        guard !used.isEmpty else { return [] }
        let plan = RoutineVersion(id: version.id, routineID: version.routineID, revision: version.revision,
            createdAt: version.createdAt, name: version.name, exercises: updated, categoryID: version.categoryID, groups: version.groups)
        intendedPlan = plan
        sessionPlan = plan
        let log = try WorkoutLog(session: self)
        workoutLog = log
        rememberScoreSlots(from: log)
        return used
    }
}

extension TrainingRepository {
    func saveProgressionRule(_ rule: ProgressionRule?, versionID: UUID, rowID: UUID) throws {
        let (_, row) = try progressionSlot(versionID, rowID)
        try rule?.validate(for: row)
        var rules = records.progressionRules ?? []
        rules.removeAll { $0.variant == row.variant.key }
        var disabled = records.disabledProgression ?? []
        disabled.removeAll { $0 == row.variant.key }
        if let rule { rules.append(ExerciseProgressionRule(variant: row.variant.key, rule: rule)) }
        else { disabled.append(row.variant.key) }
        try commit {
            $0.progressionRules = rules
            $0.disabledProgression = disabled
        }
    }

    func acceptProgression(_ reviewed: ProgressionSuggestion, versionID: UUID, rowID: UUID,
                           scope: ProgressionScope = .routine, edited: PlannedExercise? = nil) throws {
        let (version, row) = try progressionSlot(versionID, rowID)
        let suggestion = ExerciseProgression.suggest(row, in: version, records: records)
        guard !suggestion.changes.isEmpty, !suggestion.fingerprint.isEmpty, suggestion.fingerprint == reviewed.fingerprint else {
            throw TrainingDataError.conflictingRecord("The suggestion changed. Reopen the review before accepting it.")
        }
        if let edited, edited.id != row.id || edited.historyVariantKey != row.historyVariantKey {
            throw TrainingDataError.invalidRecord("Keep the original exercise and equipment when editing targets.")
        }
        let working = edited?.workingSets ?? suggestion.workingSets(for: row)
        let count = (working + (row.warmUps ?? [])).reduce(0) { $0 + min($1.sets, 10_001) }
        guard count <= 10_000, !working.isEmpty, working.allSatisfy({ $0.isValid(for: row.variant.measurement) }) else {
            throw TrainingDataError.invalidRecord("Keep valid working targets for this exercise.")
        }
        if scope != .routine {
            let decision = ProgressionDecision(versionID: versionID, rowID: rowID, fingerprint: suggestion.fingerprint,
                working: scope == .once ? working : nil)
            try commit {
                $0.consumeProgression(versionID: versionID, rows: [rowID])
                var decisions = $0.progressionDecisions ?? []
                decisions.append(decision)
                $0.progressionDecisions = decisions
            }
            return
        }
        let rows = version.exercises.map { $0.id == rowID ? row.replacingWorkingSets(working) : $0 }
        try saveRoutine(id: version.routineID, name: version.name, exercises: rows, categoryID: version.categoryID,
            groups: version.groups ?? [], expectedVersionID: version.id, preserveCurrentSnapshots: true)
    }

    private func progressionSlot(_ versionID: UUID, _ rowID: UUID) throws -> (RoutineVersion, PlannedExercise) {
        guard let version = records.version(versionID),
              let row = version.exercises.first(where: { $0.id == rowID }) else {
            throw TrainingDataError.conflictingRecord("This routine changed. Reopen the progression review.")
        }
        return (version, row)
    }
}
