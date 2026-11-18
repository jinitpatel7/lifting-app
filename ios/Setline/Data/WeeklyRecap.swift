import Foundation

struct RecapPersonalRecord: Identifiable {
    let id: HistoryVariantKey
    let row: PlannedExercise
    let kind: String
    let day: WorkoutDate
    var effort: AnalyticsEffort? = nil
    var amount: Double? = nil
    var measurement: ForecastDimension? = nil
}

struct RecapPerformanceChange: Identifiable {
    struct Key: Hashable { let variant: HistoryVariantKey; let first: Bool; let setting: String? }
    struct Result {
        let day: WorkoutDate
        let values: [ForecastDimension: Double]
    }
    let id: Key
    let row: PlannedExercise
    let previous: Result
    let current: Result
}

struct WeeklyRecap {
    struct Sessions {
        var planned = 0
        var scheduled = 0
        var unscheduled = 0
        var incomplete = 0
        var scheduledIncomplete = 0
        var skipped = 0
        var missed = 0
        var pending = 0
        var deload = 0
    }

    struct Weight {
        let count: Int
        let latest: BodyweightTrendPoint?
        let initial: BodyweightTrendPoint?
    }

    struct Energy {
        let count: Int
        let eligible: Int
        let total: Double
    }

    struct Next {
        let occurrence: ScheduleOccurrence
        let plan: RoutineVersion
    }

    let training: WeeklyAnalytics
    let sessions: Sessions
    let deloads: [String]
    let personalRecords: [RecapPersonalRecord]
    let changes: [RecapPerformanceChange]
    let weight: Weight
    let energy: Energy
    let next: Next?

    static func make(_ records: TrainingRecords, anchor: WorkoutDate, today: WorkoutDate,
                     lookup: (UUID) -> ExerciseProfile? = { _ in nil }) -> Self {
        let training = WorkoutAnalytics.weekly(records, anchor: anchor, filter: HistoryFilter(to: today), today: today, lookup: lookup)
        let first = training.days[0]
        let last = training.days[6]
        let cutoff = min(last, today)
        let planned = records.scheduled(on: training.days, today: today).filter { $0.status != .moved }
        let local = records.sessions.filter { first <= $0.localDate && $0.localDate <= cutoff }
        var linked: [UUID: WorkoutSession] = [:]
        for session in records.sessions where session.localDate <= today {
            if let scheduleID = session.scheduleID { linked[scheduleID] = session }
        }
        var tally = Sessions()
        tally.planned = planned.count
        for slot in planned {
            if let session = slot.record.flatMap({ linked[$0.id] }) {
                if session.historyStatus == .completed { tally.scheduled += 1 }
                else { tally.scheduledIncomplete += 1 }
            } else {
                switch slot.status {
                case .skipped: tally.skipped += 1
                case .missed: tally.missed += 1
                case .planned, .rescheduled: tally.pending += 1
                default: break
                }
            }
            if WorkoutAnalytics.context(for: slot, records: records).kind == .deload { tally.deload += 1 }
        }
        for session in local {
            if session.historyStatus != .completed { tally.incomplete += 1 }
            else if session.scheduleID == nil { tally.unscheduled += 1 }
        }
        let comparable = records.sessions.filter { $0.completedAt != nil && $0.localDate <= cutoff &&
            WorkoutAnalytics.context($0, records: records).kind != .deload }
        let deloads = records.programBlocks.filter { block in
            training.days.contains { $0 >= block.firstDay && $0 <= block.lastDay && block.weeks?[block.weekIndex(for: $0)]?.kind == .deload }
        }.map(\.name)
        let readings = BodyweightTrend.points(records.bodyweightEntries, through: cutoff).filter { $0.entry.localDate >= first }
        let trend = readings.filter { $0.smoothedKilograms != nil }
        let weight = Weight(count: readings.count, latest: trend.last, initial: trend.count > 1 ? trend.first : nil)
        let eligible = local.filter { $0.completedAt != nil && !$0.performedSets.isEmpty }
        let estimates = eligible.compactMap { WorkoutEnergyEstimate.workout($0, records: records)?.kilocalories }
        let energy = Energy(count: estimates.count, eligible: eligible.count, total: estimates.reduce(0, +))
        return WeeklyRecap(training: training, sessions: tally, deloads: deloads,
            personalRecords: recordsInWeek(records, sessions: comparable, first: first, last: cutoff),
            changes: performanceChanges(comparable, first: first), weight: weight, energy: energy, next: nextWorkout(records, today: today))
    }

    private static let epsilon = 1e-7

    private static func recordsInWeek(_ records: TrainingRecords, sessions: [WorkoutSession], first: WorkoutDate, last: WorkoutDate) -> [RecapPersonalRecord] {
        guard sessions.contains(where: { $0.localDate >= first }) else { return [] }
        var scoped = records
        scoped.sessions = sessions
        let preferences = AnalyticsSettings(plateauEnabled: false)
        let history = WorkoutAnalytics.exercises(scoped, filter: HistoryFilter(to: first.offset(-1)), purpose: .working, settings: preferences)
        let prior = Dictionary(uniqueKeysWithValues: history.map { ($0.id, $0) })
        return WorkoutAnalytics.exercises(scoped, filter: HistoryFilter(from: first, to: last), purpose: .working, settings: preferences)
            .compactMap { item in
                guard let earlier = prior[item.id] else { return nil }
                if let peak = item.records.heaviest, let oldPeak = earlier.records.heaviest, peak.load > oldPeak.load + epsilon {
                    return RecapPersonalRecord(id: item.id, row: item.row, kind: "Heaviest load", day: peak.date, effort: peak)
                }
                if let peak = item.records.byLoad.first(where: { current in
                    earlier.records.byLoad.contains { $0.side == current.side && abs($0.load - current.load) < epsilon && current.reps > $0.reps }
                }) {
                    return RecapPersonalRecord(id: item.id, row: item.row, kind: "Most reps at this load", day: peak.date, effort: peak)
                }
                if let peak = item.records.byReps.first(where: { current in
                    earlier.records.byReps.contains { $0.side == current.side && $0.reps == current.reps && current.load > $0.load + epsilon }
                }) {
                    return RecapPersonalRecord(id: item.id, row: item.row, kind: "Heaviest at this rep count", day: peak.date, effort: peak)
                }
                for (metric, dimension) in [(AnalyticsMetric.duration, ForecastDimension.duration), (.distance, .distance)] {
                    guard let oldPeak = earlier.points.compactMap({ $0.values[metric] }).max(),
                          let point = item.points.filter({ $0.values[metric] != nil }).max(by: { ($0.values[metric] ?? 0) < ($1.values[metric] ?? 0) }),
                          let peak = point.values[metric], peak > oldPeak + epsilon else { continue }
                    let label = metric == .duration ? "Most working-set time in a day" : "Most working-set distance in a day"
                    return RecapPersonalRecord(id: item.id, row: item.row, kind: label, day: point.date, amount: peak, measurement: dimension)
                }
                return nil
            }
    }

    private static func performanceChanges(_ sessions: [WorkoutSession], first: WorkoutDate) -> [RecapPerformanceChange] {
        var last: [RecapPerformanceChange.Key: RecapPerformanceChange.Result] = [:]
        var changes: [RecapPerformanceChange.Key: RecapPerformanceChange] = [:]
        let ordered = sessions.sorted { $0.startedAt == $1.startedAt ? $0.id.uuidString < $1.id.uuidString : $0.startedAt < $1.startedAt }
        for session in ordered {
            var accepted = Set<RecapPerformanceChange.Key>()
            for row in session.plan.exercises where !row.unlinkedStation {
                guard let actual = ExerciseForecasts.comparableWorkingResult(session, row: row) else { continue }
                let setting: String?
                if case .machineSetting(let value) = actual.set.amount { setting = value } else { setting = nil }
                let key = RecapPerformanceChange.Key(variant: row.historyVariantKey, first: actual.first, setting: setting)
                guard accepted.insert(key).inserted else { continue }
                let result = RecapPerformanceChange.Result(day: session.localDate, values: actual.values)
                if result.day >= first, let previous = last[key] {
                    if result.values.contains(where: { abs($0.value - (previous.values[$0.key] ?? $0.value)) >= epsilon }) {
                        changes[key] = RecapPerformanceChange(id: key, row: row, previous: previous, current: result)
                    } else { changes.removeValue(forKey: key) }
                }
                last[key] = result
            }
        }
        return changes.values.sorted { ($0.row.variant.exercise.name, $0.row.historyEquipmentName) < ($1.row.variant.exercise.name, $1.row.historyEquipmentName) }
    }

    private static func nextWorkout(_ records: TrainingRecords, today: WorkoutDate) -> Next? {
        let upcoming = (0..<90).map { today.offset($0) }
        let savedDays = records.schedule.map(\.localDate).filter { today.distance(to: $0) >= upcoming.count }
        let futureStarts = ((records.weekdayRules ?? []).map(\.start) + (records.rotations ?? []).map(\.start))
            .filter { today.distance(to: $0) >= upcoming.count }
        let distant = savedDays + futureStarts.flatMap { start in (0..<7).map { start.offset($0) } }
        for slot in records.scheduled(on: upcoming + distant, today: today) where slot.status == .planned || slot.status == .rescheduled {
            if let plan = records.version(slot.versionID) { return Next(occurrence: slot, plan: plan) }
        }
        return nil
    }
}
