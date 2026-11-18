import Foundation

enum ForecastDimension: String, Codable, CaseIterable {
    case weight, added, assistance, reps, duration, distance

    var floor: Double {
        switch self {
        case .weight, .added, .assistance: 0.5
        case .reps: 1
        case .duration, .distance: 2
        }
    }

    var isMass: Bool { [.weight, .added, .assistance].contains(self) }
}

struct ForecastContext: Codable, Equatable {
    let first: Bool
    let target: SetAmount?
    let reps: RepRange?
    let rest: Int?
    let warmRest: Int?
    let rir: Int?
    let effort: EffortTarget?
    let specialOnly: Bool
}

struct ForecastRange: Codable, Equatable {
    let center: Double
    let low: Double
    let high: Double
}

struct ForecastSource: Codable, Equatable, Identifiable {
    let id: UUID
    let day: WorkoutDate
    let setID: UUID
}

struct ForecastBenchmark: Codable, Equatable {
    let sessionID: UUID
    let day: WorkoutDate
    let values: [ForecastDimension: Double]
}

struct PerformanceForecast: Codable, Equatable, Identifiable {
    enum Status: String, Codable { case learning, paused, ready }
    static let modelVersion = "recent-median-v1"

    var id = UUID()
    var revision = 1
    let model: String
    let slotID: UUID
    let name: String
    let equipment: String
    let variant: ExerciseVariantKey
    let issuedAt: Date
    let context: ForecastContext
    var status: Status = .learning
    var confidence: String? = nil
    var settingsLabel: String? = nil
    var sources: [ForecastSource] = []
    var notes: [String] = []
    var ranges: [ForecastDimension: ForecastRange] = [:]
    var previous: ForecastBenchmark? = nil
    var priorRanges: [ForecastDimension: ForecastRange]? = nil
}

struct ForecastScore: Identifiable {
    struct Key: Hashable { let variant: ExerciseVariantKey; let model: String; let setting: String? }
    struct Metric {
        var forecastError = 0.0
        var previousError = 0.0
        var inside = 0
    }
    let id: Key
    let name: String
    let equipment: String
    var count = 0
    var metrics: [ForecastDimension: Metric] = [:]
}

enum ExerciseForecasts {
    private static let minimum = 3
    private static let windowSize = 8

    private struct Outcome {
        let values: [ForecastDimension: Double]
        let set: PerformedSet
        let first: Bool
        let priorRest: Int?
    }

    private struct Observation {
        let source: ForecastSource
        let actual: Outcome
        let context: ForecastContext
    }

    static func context(for row: PlannedExercise, in plan: RoutineVersion, log: WorkoutLog?) -> ForecastContext {
        let logged = log?.exercises.first { $0.id == row.id }?.rows.compactMap { set in
            set.purpose == .working && set.status != .skipped ? set.prescription : nil
        }
        let prescription = (logged ?? row.workingSets).first { straight($0) }
        return ForecastContext(first: plan.exercises.first?.id == row.id, target: prescription?.target, reps: prescription?.reps,
            rest: prescription?.restSeconds, warmRest: row.warmUps?.last?.restSeconds,
            rir: prescription?.repsInReserve, effort: prescription?.effort,
            specialOnly: prescription == nil && row.workingSets.allSatisfy { !straight($0) })
    }

    static func make(for row: PlannedExercise, in plan: RoutineVersion, records: TrainingRecords, at cutoff: Date,
                     day: WorkoutDate, deload: Bool, log: WorkoutLog? = nil) -> PerformanceForecast {
        let target = context(for: row, in: plan, log: log)
        let latest = records.sessions.flatMap { $0.performanceForecasts ?? [] }.filter {
            $0.variant == row.variant.key && $0.status == .ready && $0.issuedAt < cutoff
        }.max { $0.issuedAt < $1.issuedAt }
        var forecast = PerformanceForecast(model: PerformanceForecast.modelVersion, slotID: row.id, name: row.variant.exercise.name,
            equipment: row.historyEquipmentName, variant: row.variant.key, issuedAt: cutoff, context: target, priorRanges: latest?.ranges)
        if row.unlinkedStation || target.specialOnly || deload {
            forecast.status = .paused
            if deload { forecast.notes = ["A planned deload changes the training intent. This forecast is paused."] }
            else if row.unlinkedStation { forecast.notes = ["Name this machine or cable station to start its own baseline."] }
            else { forecast.notes = ["This method uses straight working sets. Special sets have no estimate."] }
            return forecast
        }
        let history = observations(for: row, in: plan, records: records, before: cutoff)
        var candidates = history.results
        if case .machineSetting = row.variant.measurement {
            let label = setting(target.target) ?? setting(candidates.first?.actual.set.amount)
            forecast.settingsLabel = label
            candidates = candidates.filter { setting($0.actual.set.amount) == label }
            if let label { forecast.notes.append("Only results at machine setting \(label) are comparable.") }
        }
        let previous = candidates.first
        let age = previous?.source.day.distance(to: day) ?? 0
        candidates = candidates.filter { $0.source.day.distance(to: day) < 120 }
        guard candidates.count >= minimum, age < 120, let previous else {
            forecast.sources = candidates.prefix(windowSize).map(\.source)
            forecast.notes.append(age >= 120 ? "The last comparable result is at least 120 days old. A fresh result is needed." :
                "\(candidates.count) of \(minimum) recent comparable sessions logged.")
            if history.otherSetup { forecast.notes.append("Results on different equipment or tracking conventions have a separate baseline.") }
            if history.deloads { forecast.notes.append("Planned deloads are outside the baseline.") }
            return forecast
        }
        var varied = false
        func prefer(_ predicate: (Observation) -> Bool, match: String, mixed: String) {
            let subset = candidates.filter(predicate)
            if subset.count >= minimum { candidates = subset; forecast.notes.append(match) }
            else { varied = true; forecast.notes.append(mixed) }
        }
        prefer({ $0.actual.first == target.first }, match: "Matched workouts where this exercise went \(target.first ? "first" : "later").",
            mixed: "Exercise order varied in the available history.")
        if let band = target.reps {
            prefer({ $0.context.reps == band }, match: "Matched the prescribed rep range.", mixed: "Prescribed rep ranges varied.")
        }
        if let load = mass(target.target) {
            prefer({ item in
                let left = mass(item.actual.set.amount)
                let right = mass(item.actual.set.rightAmount ?? item.actual.set.amount)
                return left.map { abs($0 - load) < 0.001 } == true && right.map { abs($0 - load) < 0.001 } == true
            }, match: "Matched actual sets at the planned load or assistance.",
               mixed: "Too few sets used the planned load or assistance. The range reflects nearby training history.")
        }
        if let rest = target.rest {
            prefer({ abs(Double($0.context.rest ?? -1_000) - Double(rest)) <= 15 }, match: "Matched similar prescribed rest.",
                mixed: "Prescribed rest varied or was missing.")
        }
        if let rest = target.warmRest {
            prefer({ abs(Double($0.actual.priorRest ?? -1_000) - Double(rest)) <= 15 },
                match: "Matched measured rest before the first working set to the planned warm-up rest.",
                mixed: "Measured rest before the first working set was too sparse or varied.")
        }
        if target.rir != nil || target.effort != nil {
            prefer({ matchesEffort(target, $0.actual.set) }, match: "Matched recorded effort near the prescribed effort.",
                mixed: "Recorded effort was too sparse or varied to narrow this estimate.")
        }
        let window = Array(candidates.prefix(windowSize))
        let dimensions = ForecastDimension.allCases.filter { previous.actual.values[$0] != nil }
        let trimmed = rejectOutliers(window, dimensions: dimensions)
        let used = trimmed.count >= minimum ? trimmed : window
        let gap = used[0].source.day.distance(to: day)
        let spread = gap >= 21
        if used.count < window.count {
            let removed = window.count - used.count
            forecast.notes.append("\(removed) isolated result\(removed == 1 ? " was" : "s were") outside the recent range and left out.")
        }
        if spread { forecast.notes.append("The last result used was \(gap) days ago. The range is wider after that break.") }
        if history.deloads { forecast.notes.append("Planned deloads were left out of the baseline.") }
        forecast.status = .ready
        forecast.confidence = used.count >= 6 && !varied && !spread ? "More comparable history" : "Limited confidence"
        forecast.sources = used.map(\.source)
        forecast.previous = ForecastBenchmark(sessionID: previous.source.id, day: previous.source.day, values: previous.actual.values)
        for dimension in dimensions {
            let values = used.compactMap { $0.actual.values[dimension] }
            let center = quantile(values, 0.5)
            let low = quantile(values, values.count >= 5 ? 0.1 : 0)
            let high = quantile(values, values.count >= 5 ? 0.9 : 1)
            let width = min(Double.greatestFiniteMagnitude, max(dimension.floor, abs(center - low), abs(high - center)) * (spread ? 1.5 : 1))
            forecast.ranges[dimension] = dimension == .reps ? ForecastRange(center: center.rounded(), low: max(0, floor(center - width)),
                high: ceil(center + width)) : ForecastRange(center: center, low: max(0, center - width),
                    high: min(Double.greatestFiniteMagnitude, center + width))
        }
        if let latest {
            let contextChanged = latest.context != target
            if dimensions.contains(where: { metric in
                guard let old = latest.ranges[metric]?.center, let center = forecast.ranges[metric]?.center else { return false }
                return abs(old - center) >= metric.floor
            }) {
                forecast.notes.append(contextChanged ?
                    "The typical estimate changed since the last saved forecast as the planned context or available results changed." :
                    "The typical estimate changed since the last saved forecast because the recent comparable results changed.")
            }
            if !spread && dimensions.contains(where: { metric in
                guard let old = latest.ranges[metric], let interval = forecast.ranges[metric] else { return false }
                return abs((interval.high - interval.low) - (old.high - old.low)) >= metric.floor
            }) {
                forecast.notes.append(contextChanged ? "The ranges changed after the planned context or evidence changed." :
                    "The ranges changed because recent comparable results were more or less variable.")
            }
        }
        return forecast
    }

    private static func observations(for row: PlannedExercise, in plan: RoutineVersion, records: TrainingRecords, before cutoff: Date)
        -> (results: [Observation], otherSetup: Bool, deloads: Bool) {
        var output: [Observation] = []
        var otherSetup = false, deloads = false
        let sorted = records.sessions.sorted { $0.startedAt == $1.startedAt ? $0.id.uuidString < $1.id.uuidString : $0.startedAt > $1.startedAt }
        for session in sorted {
            guard let end = session.completedAt, session.startedAt < cutoff, end < cutoff,
                  session.forecastEvidenceAt.map({ $0 < cutoff }) != false else { continue }
            let matches = session.plan.exercises.filter { !$0.unlinkedStation && $0.historyVariantKey == row.historyVariantKey }
            let sameSlot = session.plan.routineID == plan.routineID ? matches.first { $0.id == row.id } : nil
            guard let entry = sameSlot ?? (matches.count == 1 ? matches.first : nil) else {
                if session.plan.exercises.contains(where: { $0.variant.exercise.id == row.variant.exercise.id && $0.historyVariantKey != row.historyVariantKey }) {
                    otherSetup = true
                }
                continue
            }
            guard let result = actual(session, row: entry), result.set.recordedAt < cutoff else { continue }
            if WorkoutAnalytics.context(session, records: records).kind == .deload { deloads = true; continue }
            output.append(Observation(source: ForecastSource(id: session.id, day: session.localDate, setID: result.set.id), actual: result,
                context: context(for: entry, in: session.plan, log: session.workoutLog)))
        }
        return (output, otherSetup, deloads)
    }

    private static func actual(_ session: WorkoutSession, row: PlannedExercise) -> Outcome? {
        let positions = Dictionary(uniqueKeysWithValues: session.plan.exercises.enumerated().map { ($0.element.id, $0.offset) })
        let ordered = session.performedSets.sorted { left, right in
            if left.recordedAt != right.recordedAt { return left.recordedAt < right.recordedAt }
            if left.plannedExerciseID == right.plannedExerciseID { return left.order < right.order }
            return (positions[left.plannedExerciseID] ?? 0) < (positions[right.plannedExerciseID] ?? 0)
        }
        let rows = session.historyRows(for: row)
        guard let index = ordered.firstIndex(where: { item in
            guard item.plannedExerciseID == row.id else { return false }
            let saved = rows.first { $0.result?.id == item.id }
            return (item.purpose ?? saved?.purpose ?? .working) == .working && item.amrap != true &&
                (item.structure ?? .straight) == .straight && straight(saved?.prescription)
        }) else { return nil }
        let set = ordered[index]
        guard let values = outcomeValues(set, row: row) else { return nil }
        let preceding = ordered.prefix(index)
        let prior = preceding.last
        return Outcome(values: values, set: set, first: !preceding.contains { $0.plannedExerciseID != row.id },
            priorRest: prior?.plannedExerciseID == row.id ? prior?.actualRest?.measuredSeconds : nil)
    }

    private static func outcomeValues(_ set: PerformedSet, row: PlannedExercise) -> [ForecastDimension: Double]? {
        let measure = row.variant.measurement
        guard measure.accepts(set.amount), measure.acceptsPerformed(reps: set.repetitions, rightAmount: set.rightAmount) else { return nil }
        var values: [ForecastDimension: Double] = [:]
        switch set.repetitions {
        case .total(let count), .perSide(let count): values[.reps] = Double(count)
        case .separateSides(let left, let right): values[.reps] = Double(min(left, right))
        case nil: break
        }
        switch (set.amount, set.rightAmount ?? set.amount) {
        case (.weight(let left), .weight(let right)): values[.weight] = min(left.kilograms, right.kilograms)
        case (.addedLoad(let left), .addedLoad(let right)): values[.added] = min(left.kilograms, right.kilograms)
        case (.assistance(let left), .assistance(let right)): values[.assistance] = max(left.kilograms, right.kilograms)
        case (.durationSeconds(let left), .durationSeconds(let right)): values[.duration] = min(left, right)
        case (.distanceMeters(let left), .distanceMeters(let right)): values[.distance] = min(left, right)
        default: break
        }
        return values.isEmpty ? nil : values
    }

    private static func straight(_ set: SetPrescription?) -> Bool { (set?.structure ?? .straight) == .straight && set?.amrap != true }

    private static func mass(_ amount: SetAmount?) -> Double? {
        switch amount {
        case .weight(let value), .addedLoad(let value), .assistance(let value): value.kilograms
        default: nil
        }
    }

    private static func setting(_ amount: SetAmount?) -> String? {
        if case .machineSetting(let label) = amount { return label }
        return nil
    }

    private static func matchesEffort(_ context: ForecastContext, _ set: PerformedSet) -> Bool {
        switch context.effort {
        case .rpe(let value): return set.actualRPE.map { abs($0 - value) <= 1 } ?? false
        case .failure: return set.effortOutcome == .failure
        case nil:
            guard let rir = context.rir else { return false }
            return set.actualRIR.map { abs(Double($0) - Double(rir)) <= 1 } ?? false
        }
    }

    private static func rejectOutliers(_ window: [Observation], dimensions: [ForecastDimension]) -> [Observation] {
        guard window.count >= 5 else { return window }
        let fences = dimensions.map { metric -> (ForecastDimension, ClosedRange<Double>) in
            let values = window.compactMap { $0.actual.values[metric] }
            let low = quantile(values, 0.25), high = quantile(values, 0.75)
            let fence = max(3 * (high - low), metric.floor)
            return (metric, (low - fence)...(high + fence))
        }
        return window.filter { item in fences.allSatisfy { pair in item.actual.values[pair.0].map(pair.1.contains) == true } }
    }

    private static func quantile(_ values: [Double], _ fraction: Double) -> Double {
        let sorted = values.sorted()
        let position = Double(sorted.count - 1) * fraction
        let low = Int(position.rounded(.down)), high = Int(position.rounded(.up))
        return sorted[low] + (sorted[high] - sorted[low]) * (position - Double(low))
    }

    static func scores(_ records: TrainingRecords) -> [ForecastScore] {
        var groups: [ForecastScore.Key: ForecastScore] = [:]
        for session in records.sessions where session.completedAt != nil && session.performanceForecasts?.isEmpty == false &&
            WorkoutAnalytics.context(session, records: records).kind != .deload {
            for row in session.plan.exercises {
                guard let result = actual(session, row: row),
                      let forecast = session.performanceForecasts?.last(where: { $0.slotID == row.id && $0.issuedAt <= result.set.recordedAt }),
                      forecast.status == .ready, let previous = forecast.previous, row.variant.key == forecast.variant,
                      result.first == forecast.context.first else { continue }
                if case .machineSetting = row.variant.measurement, setting(result.set.amount) != forecast.settingsLabel { continue }
                let key = ForecastScore.Key(variant: forecast.variant, model: forecast.model, setting: forecast.settingsLabel)
                var group = groups[key] ?? ForecastScore(id: key, name: forecast.name, equipment: forecast.equipment)
                group.count += 1
                for (dimension, range) in forecast.ranges {
                    guard let observed = result.values[dimension], let baseline = previous.values[dimension] else { continue }
                    group.metrics[dimension, default: ForecastScore.Metric()].forecastError += abs(observed - range.center)
                    group.metrics[dimension, default: ForecastScore.Metric()].previousError += abs(observed - baseline)
                    if range.low...range.high ~= observed { group.metrics[dimension, default: ForecastScore.Metric()].inside += 1 }
                }
                groups[key] = group
            }
        }
        return groups.values.sorted { ($0.name + $0.equipment) < ($1.name + $1.equipment) }
    }
}

extension WorkoutSession {
    mutating func captureForecasts(in records: TrainingRecords, at date: Date) {
        guard completedAt == nil, date >= startedAt else { return }
        let current = plan
        let deload = WorkoutAnalytics.context(self, records: records).kind == .deload
        let performed = (forecastPerformedSlots ?? []).union(performedSets.map(\.plannedExerciseID))
        for entry in current.exercises where !performed.contains(entry.id) {
            let archived = performanceForecasts?.filter { $0.slotID == entry.id } ?? []
            let context = ExerciseForecasts.context(for: entry, in: current, log: workoutLog)
            if let latest = archived.last, latest.variant == entry.variant.key, latest.context == context { continue }
            var forecast = ExerciseForecasts.make(for: entry, in: current, records: records, at: date, day: localDate,
                deload: deload, log: workoutLog)
            forecast.revision = archived.count + 1
            if performanceForecasts == nil { performanceForecasts = [] }
            performanceForecasts?.append(forecast)
        }
    }

    mutating func rememberForecastOutcomes() {
        let slots = performedSets.map(\.plannedExerciseID)
        if !slots.isEmpty { forecastPerformedSlots = (forecastPerformedSlots ?? []).union(slots) }
    }
}
