import Foundation

struct WorkoutScoreWeights: Codable, Equatable {
    var completion: Double = 60
    var targets: Double = 25
    var effort: Double = 15

    var valid: Bool {
        let weights = [completion, targets, effort]
        return weights.allSatisfy { (0...100).contains($0) } && weights.contains { $0 > 0 }
    }
}

struct WorkoutScoreContext {
    let date: WorkoutDate
    let sessions: [WorkoutSession]
    let schedule: [ScheduleOccurrence]
    var weights = WorkoutScoreWeights()
}

struct WorkoutScoreAssessment {
    enum Availability { case unavailable(reason: String), available(score: Int) }

    struct Component: Identifiable {
        let name: String
        let detail: String
        let points: Double?
        let maximumPoints: Double
        var id: String { name }
    }

    let availability: Availability
    var components: [Component] = []
}

protocol WorkoutScorePolicy {
    func evaluate(_ context: WorkoutScoreContext) -> WorkoutScoreAssessment
}

struct PrescribedWorkoutScore: WorkoutScorePolicy {
    func evaluate(_ context: WorkoutScoreContext) -> WorkoutScoreAssessment {
        let session = WorkoutHistory.filtered(context.sessions).first { $0.completedAt != nil }
        return Self.assessment(session, weights: context.weights)
    }

    static func assessment(_ session: WorkoutSession?, weights: WorkoutScoreWeights = WorkoutScoreWeights()) -> WorkoutScoreAssessment {
        guard let session, session.completedAt != nil else {
            return .init(availability: .unavailable(reason: "Finish a planned workout to see its score."))
        }
        guard session.routineSnapshot.revision > 0, !session.routineSnapshot.exercises.isEmpty else {
            return .init(availability: .unavailable(reason: "This workout started without a saved routine plan."))
        }
        var prescribed = 0
        var completed = 0
        var targets: [Double] = []
        var efforts: [Double] = []
        for entry in (session.intendedPlan ?? session.routineSnapshot).exercises {
            let same = session.plan.exercises.first { $0.id == entry.id && $0.historyVariantKey == entry.historyVariantKey }
            let rows = same.map { session.historyRows(for: $0) } ?? []
            let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let ids = session.scoreSlots?[entry.id] ?? rows.filter { $0.purpose == .working && $0.prescription != nil }.map(\.id)
            var index = 0
            for plan in entry.workingSets {
                for _ in 0..<min(max(0, plan.sets), 10_000) {
                    prescribed += 1
                    defer { index += 1 }
                    guard ids.indices.contains(index), let row = byID[ids[index]], row.purpose == .working,
                          row.status == .completed, let actual = row.result else { continue }
                    completed += 1
                    if let credit = targetCredit(actual, plan: plan) { targets.append(credit) }
                    if let credit = effortCredit(actual, plan: plan) { efforts.append(credit) }
                }
            }
        }
        guard prescribed > 0 else {
            return .init(availability: .unavailable(reason: "This workout has no prescribed working sets."))
        }
        func mean(_ values: [Double]) -> Double? { values.isEmpty ? nil : values.reduce(0, +) / Double(values.count) }
        let parts: [(name: String, detail: String, credit: Double?, weight: Double)] = [
            ("Prescribed work completed", "\(completed) of \(prescribed) prescribed working sets completed.",
             Double(completed) / Double(prescribed), weights.completion),
            ("Targets met", targets.isEmpty ? "No completed sets with applicable targets." : "\(targets.count) completed sets with prescribed targets.",
             mean(targets), weights.targets),
            ("Effort alignment", efforts.isEmpty ? "No matching prescribed and recorded RIR or RPE." :
                "\(efforts.count) sets with corresponding prescribed and actual RIR or RPE.", mean(efforts), weights.effort)
        ]
        let total = parts.reduce(0) { $0 + ($1.credit == nil ? 0 : $1.weight) }
        guard weights.valid, total > 0 else {
            return .init(availability: .unavailable(reason: "The enabled score components need more logged information."))
        }
        let components = parts.map { part in
            let maximum = part.credit == nil ? 0 : 100 * part.weight / total
            return WorkoutScoreAssessment.Component(name: part.name, detail: part.detail,
                points: part.credit.map { $0 * maximum }, maximumPoints: maximum)
        }
        let points = components.compactMap(\.points).reduce(0, +)
        return .init(availability: .available(score: Int(points.rounded())), components: components)
    }

    static func targetCredit(_ actual: PerformedSet, plan: SetPrescription) -> Double? {
        var marks: [Double] = []
        if let reps = plan.reps, reps.minimum > 0 {
            let minimum = Double(reps.minimum)
            switch actual.repetitions {
            case .total(let value), .perSide(let value): marks.append(cap(Double(value) / minimum))
            case .separateSides(let left, let right): marks.append(cap(Double(min(left, right)) / minimum))
            case nil: marks.append(0)
            }
        }
        if let target = plan.target {
            marks.append(amountCredit(actual.amount, target: target))
            if let right = actual.rightAmount { marks.append(amountCredit(right, target: target)) }
        }
        return marks.min()
    }

    private static func amountCredit(_ actual: SetAmount?, target: SetAmount) -> Double {
        func ratio(_ value: Double, _ goal: Double) -> Double { value >= goal - 1e-7 ? 1 : cap(value / goal) }
        switch (actual, target) {
        case (.weight(let value), .weight(let goal)), (.addedLoad(let value), .addedLoad(let goal)):
            return ratio(value.kilograms, goal.kilograms)
        case (.durationSeconds(let value), .durationSeconds(let goal)), (.distanceMeters(let value), .distanceMeters(let goal)):
            return ratio(value, goal)
        case (.assistance(let value), .assistance(let goal)):
            return value.kilograms <= goal.kilograms + 1e-7 ? 1 : cap(goal.kilograms / value.kilograms)
        case (.machineSetting(let value), .machineSetting(let goal)): return value == goal ? 1 : 0
        default: return 0
        }
    }

    private static func effortCredit(_ actual: PerformedSet, plan: SetPrescription) -> Double? {
        let difference: Double
        if let target = plan.repsInReserve, let rir = actual.actualRIR {
            difference = abs(Double(rir) - Double(target))
        } else if case .rpe(let target) = plan.effort, let rpe = actual.actualRPE {
            difference = abs(rpe - target)
        } else { return nil }
        return cap(1 - max(0, difference - 1) / 3)
    }

    private static func cap(_ value: Double) -> Double { max(0, min(1, value)) }
}

extension WorkoutSession {
    mutating func rememberScoreSlots(from log: WorkoutLog) {
        guard scoreSlots == nil else { return }
        scoreSlots = Dictionary(uniqueKeysWithValues: (intendedPlan ?? routineSnapshot).exercises.map { entry in
            let rows = log.exercises.first { $0.id == entry.id }?.rows ?? []
            let count = entry.workingSets.reduce(0) { $0 + min($1.sets, 10_000) }
            let ids = rows.filter { $0.purpose == .working && $0.prescription != nil }.prefix(max(0, count)).map(\.id)
            return (entry.id, ids)
        })
    }
}

enum DailyWorkoutScore {
    static func assessment(on day: WorkoutDate, records: TrainingRecords, today: WorkoutDate,
                           policy: any WorkoutScorePolicy = PrescribedWorkoutScore()) -> WorkoutScoreAssessment {
        policy.evaluate(WorkoutScoreContext(date: day, sessions: records.sessions.filter { $0.localDate == day },
            schedule: records.scheduled(on: [day], today: today), weights: records.scoreWeights ?? WorkoutScoreWeights()))
    }
}
