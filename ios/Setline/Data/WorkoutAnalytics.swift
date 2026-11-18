import Foundation

enum AnalyticsMetric: String, Codable, CaseIterable, Hashable, Identifiable {
    case load = "Load", reps = "Reps", volume = "Logged volume", duration = "Duration", distance = "Distance", estimate = "Estimated 1RM"
    var id: Self { self }
    var peak: Bool { self == .load || self == .estimate }
}

enum DashboardStat: String, Codable, CaseIterable, Hashable, Identifiable {
    case workouts = "Workouts with logged sets", sets = "Working sets", plan = "Planned vs completed"
    case volume = "Free-weight and added-load volume", duration = "Logged exercise duration", distance = "Logged distance"
    var id: Self { self }
}

struct AnalyticsSettings: Codable, Equatable {
    var visible = Set(AnalyticsMetric.allCases)
    var dashboard: Set<DashboardStat> = [.workouts, .plan]
    var plateauEnabled = true
    var plateauMetric = AnalyticsMetric.estimate
    var plateauSessions = 4
    var plateauPercent = 2.0
    var breakDays = 14

    var valid: Bool {
        (3...12).contains(plateauSessions) && (0.1...25).contains(plateauPercent) && (7...90).contains(breakDays)
    }
}

struct AnalyticsPoint: Identifiable {
    var id: WorkoutDate { date }
    let date: WorkoutDate
    var values: [AnalyticsMetric: Double] = [:]
    var events: [String] = []
}

struct AnalyticsEffort: Identifiable {
    let id = UUID()
    let load: Double
    let reps: Int
    let side: String
    let date: WorkoutDate
}

struct AnalyticsRecords {
    var heaviest: AnalyticsEffort?
    var byLoad: [AnalyticsEffort] = []
    var byReps: [AnalyticsEffort] = []
}

enum PlateauNotice: Equatable {
    case deload
    case flag(change: Double, count: Int)
}

struct ExerciseAnalytics: Identifiable {
    let id: HistoryVariantKey
    let row: PlannedExercise
    var points: [AnalyticsPoint] = []
    var records = AnalyticsRecords()
    var plateau: PlateauNotice?
}

struct SetTally {
    var working = 0
    var warmUp = 0

    mutating func add(_ purpose: SetPurpose, count: Int = 1) {
        switch purpose {
        case .working: working += count
        case .warmUp: warmUp += count
        }
    }
}

struct MuscleSetTally {
    var direct = SetTally()
    var indirect = SetTally()
}

struct WeeklyAnalytics {
    let days: [WorkoutDate]
    var planned = SetTally()
    var performed = SetTally()
    var muscles: [MuscleGroup: MuscleSetTally] = [:]
    var workouts = 0
    var totals: [AnalyticsMetric: Double] = [:]
}

enum WorkoutAnalytics {
    static let formulaHelp = "Epley uses load × (1 + reps ÷ 30) for 2–10 reps. A single uses its recorded load. Setline estimates only bilateral free-weight working sets. The estimate assumes a hard set and varies with effort, technique, and exercise."
    static let study = URL(string: "https://efyc.fahce.unlp.edu.ar/article/download/efyce222/15809?inline=1")

    struct ProgramContext {
        var id: UUID?
        var name = ""
        var week = -1
        var kind: ProgramWeekKind?
    }

    private struct Sample {
        let date: WorkoutDate
        let context: ProgramContext
        let routine: UUID
        let version: UUID
        let row: PlannedExercise
        var values: [AnalyticsMetric: Double] = [:]
        var efforts: [AnalyticsEffort] = []
        var reset = false
    }

    private struct LiftKey: Hashable {
        let value: Double
        let side: String
    }

    private struct ExerciseRoutineKey: Hashable {
        let exercise: UUID
        let routine: UUID
    }

    static func loggedPurpose(_ set: PerformedSet, row: PlannedExercise, session: WorkoutSession) -> SetPurpose {
        if let purpose = set.purpose { return purpose }
        if let result = session.workoutLog?.exercises.first(where: { $0.id == row.id })?.rows.first(where: { $0.id == set.id }) {
            return result.purpose
        }
        let warmUps = (row.warmUps ?? []).reduce(0) { $0 + $1.sets }
        return set.order <= warmUps ? .warmUp : .working
    }

    static func estimatedMax(_ set: PerformedSet, row: PlannedExercise, purpose: SetPurpose? = nil) -> Double? {
        let kind = row.variant.equipment?.kind ?? row.variant.exercise.profile?.equipmentKind
        guard let kind, [EquipmentKind.barbell, .dumbbell, .kettlebell].contains(kind),
              case .weightReps(_, .total) = row.variant.measurement, (purpose ?? set.purpose) != .warmUp,
              set.rightAmount == nil, case .total(let reps) = set.repetitions, (1...10).contains(reps),
              case .weight(let load) = set.amount, load.kilograms > 0 else { return nil }
        let estimate = reps == 1 ? load.kilograms : load.kilograms * (1 + Double(reps) / 30)
        return estimate.isFinite ? estimate : nil
    }

    private static func magnitude(_ amount: SetAmount?) -> Double? {
        if case .assistance(let mass) = amount { return mass.kilograms }
        return WorkoutHistory.externalLoad(amount)
    }

    private static func timed(_ amount: SetAmount?, metric: AnalyticsMetric) -> Double? {
        switch (amount, metric) {
        case (.durationSeconds(let seconds), .duration): seconds
        case (.distanceMeters(let meters), .distance): meters
        default: nil
        }
    }

    private static func quantity(_ set: PerformedSet, metric: AnalyticsMetric) -> Double? {
        timed(set.amount, metric: metric).map { $0 + (timed(set.rightAmount, metric: metric) ?? 0) }
    }

    private static func add(_ metric: AnalyticsMetric, _ value: Double?, to values: inout [AnalyticsMetric: Double]) {
        guard let value, value.isFinite else { return }
        let previous = values[metric]
        if metric.peak { values[metric] = max(previous ?? value, value) }
        else if (value + (previous ?? 0)).isFinite { values[metric] = value + (previous ?? 0) }
    }

    private static func accumulate(_ set: PerformedSet, row: PlannedExercise, purpose: SetPurpose, sample: inout Sample) {
        if case .separateSides(let left, let right) = set.repetitions {
            if left > 0 { add(.load, magnitude(set.amount), to: &sample.values) }
            if right > 0 { add(.load, magnitude(set.rightAmount) ?? magnitude(set.amount), to: &sample.values) }
        } else {
            add(.load, magnitude(set.amount), to: &sample.values)
            add(.load, magnitude(set.rightAmount), to: &sample.values)
        }
        add(.reps, WorkoutHistory.totalReps(set.repetitions), to: &sample.values)
        add(.volume, row.unlinkedStation ? nil : WorkoutHistory.volume(set, exercise: row), to: &sample.values)
        add(.duration, quantity(set, metric: .duration), to: &sample.values)
        add(.distance, quantity(set, metric: .distance), to: &sample.values)
        add(.estimate, estimatedMax(set, row: row, purpose: purpose), to: &sample.values)
        guard !row.unlinkedStation, let load = WorkoutHistory.externalLoad(set.amount) else { return }
        switch set.repetitions {
        case .total(let reps): sample.efforts.append(AnalyticsEffort(load: load, reps: reps, side: "", date: sample.date))
        case .perSide(let reps): sample.efforts.append(AnalyticsEffort(load: load, reps: reps, side: "Per side", date: sample.date))
        case .separateSides(let left, let right):
            if left > 0 { sample.efforts.append(AnalyticsEffort(load: load, reps: left, side: "Left", date: sample.date)) }
            if right > 0 {
                sample.efforts.append(AnalyticsEffort(load: WorkoutHistory.externalLoad(set.rightAmount) ?? load,
                    reps: right, side: "Right", date: sample.date))
            }
        case nil: break
        }
    }

    private static func recordTable(_ efforts: [AnalyticsEffort]) -> AnalyticsRecords {
        var result = AnalyticsRecords()
        var loads: [LiftKey: AnalyticsEffort] = [:]
        var reps: [LiftKey: AnalyticsEffort] = [:]
        for effort in efforts {
            let rounded = (effort.load * 1e8).rounded() / 1e8
            let loadKey = LiftKey(value: rounded.isFinite ? rounded : effort.load, side: effort.side)
            let repKey = LiftKey(value: Double(effort.reps), side: effort.side)
            if let current = result.heaviest {
                if effort.load > current.load || (effort.load == current.load && effort.reps > current.reps) { result.heaviest = effort }
            } else { result.heaviest = effort }
            if loads[loadKey].map({ effort.reps > $0.reps }) ?? true { loads[loadKey] = effort }
            if reps[repKey].map({ effort.load > $0.load }) ?? true { reps[repKey] = effort }
        }
        result.byLoad = loads.values.sorted { $0.load == $1.load ? $0.side < $1.side : $0.load > $1.load }
        result.byReps = reps.values.sorted { $0.reps == $1.reps ? $0.side < $1.side : $0.reps < $1.reps }
        return result
    }

    static func context(_ session: WorkoutSession, records: TrainingRecords) -> ProgramContext {
        let entry = records.schedule.first { $0.id == session.scheduleID }
        return context(on: session.localDate, entry: entry, records: records)
    }

    static func context(for occurrence: ScheduleOccurrence, records: TrainingRecords) -> ProgramContext {
        context(on: occurrence.date, entry: occurrence.record, records: records)
    }

    private static func context(on date: WorkoutDate, entry: ScheduledWorkout?, records: TrainingRecords) -> ProgramContext {
        let fallback = records.programBlocks.filter { $0.firstDay <= date && date <= $0.lastDay }
        guard let block = records.programBlocks.first(where: { $0.id == entry?.programBlockID }) ?? (fallback.count == 1 ? fallback.first : nil) else {
            return ProgramContext()
        }
        let day = entry?.programBlockID == block.id ? (entry?.movedFrom?.first ?? entry?.localDate ?? date) : date
        let week = block.weekIndex(for: day)
        return ProgramContext(id: block.id, name: block.name, week: week, kind: block.weeks?[week]?.kind ?? .training)
    }

    private static func matches(_ row: PlannedExercise, filter: HistoryFilter) -> Bool {
        (filter.exerciseID == nil || row.variant.exercise.id == filter.exerciseID) &&
            (filter.equipment.isEmpty || row.historyEquipmentKey == filter.equipment)
    }

    private static func includes(_ date: WorkoutDate, filter: HistoryFilter) -> Bool {
        (filter.from.map { date >= $0 } ?? true) && (filter.to.map { date <= $0 } ?? true)
    }

    private static func plateau(_ samples: [Sample], settings: AnalyticsSettings) -> PlateauNotice? {
        guard settings.plateauEnabled, let latest = samples.last else { return nil }
        if latest.context.kind == .deload { return .deload }
        if settings.plateauMetric == .load, case .assistance = latest.row.variant.measurement { return nil }
        let metric = settings.plateauMetric
        var observations: [Sample] = []
        for sample in samples {
            let gap = observations.last?.date.distance(to: sample.date) ?? 0
            if sample.reset || gap >= settings.breakDays { observations.removeAll() }
            if sample.context.kind != .deload && sample.values[metric] != nil { observations.append(sample) }
        }
        let window = Array(observations.suffix(settings.plateauSessions))
        guard window.count == settings.plateauSessions, latest.values[metric] != nil,
              let baseline = window.first?.values[metric], baseline > 0,
              let best = window.dropFirst().compactMap({ $0.values[metric] }).max() else { return nil }
        let change = (best - baseline) / baseline * 100
        return change + 1e-9 < settings.plateauPercent ? .flag(change: change, count: window.count) : nil
    }

    static func exercises(_ records: TrainingRecords, filter: HistoryFilter, purpose: SetPurpose, settings: AnalyticsSettings) -> [ExerciseAnalytics] {
        var results: [HistoryVariantKey: ExerciseAnalytics] = [:]
        var included: [HistoryVariantKey: [Sample]] = [:]
        var previousSample: [HistoryVariantKey: Sample] = [:]
        var previousGear: [UUID: Set<String>] = [:]
        var exerciseRevisions: [ExerciseRoutineKey: UUID] = [:]
        for session in WorkoutHistory.filtered(records.sessions.filter { $0.completedAt != nil }).reversed() {
            let date = session.localDate
            let program = context(session, records: records)
            let grouped = Dictionary(grouping: session.performedSets, by: \.plannedExerciseID)
            var gear: [UUID: Set<String>] = [:]
            var samples: [HistoryVariantKey: Sample] = [:]
            for row in session.plan.exercises {
                guard let sets = grouped[row.id]?.filter({ loggedPurpose($0, row: row, session: session) == purpose }), !sets.isEmpty else { continue }
                gear[row.variant.exercise.id, default: []].insert(row.historyEquipmentKey)
                let key = row.comparableKey(in: session.id)
                var sample = samples[key] ?? Sample(date: date, context: program, routine: session.routineSnapshot.routineID,
                    version: session.routineSnapshot.id, row: row)
                for set in sets { accumulate(set, row: row, purpose: purpose, sample: &sample) }
                samples[key] = sample
            }
            for (key, var sample) in samples {
                let row = sample.row
                let prior = previousSample[key]
                let programChanged = prior.map { $0.context.id != program.id } ?? (program.id != nil)
                let revisionKey = ExerciseRoutineKey(exercise: row.variant.exercise.id, routine: sample.routine)
                let routineChanged = exerciseRevisions[revisionKey].map { $0 != sample.version } ?? false
                let gap = prior?.date.distance(to: date) ?? 0
                let exerciseID = row.variant.exercise.id
                let equipmentChanged = previousGear[exerciseID].map { $0 != (gear[exerciseID] ?? []) } ?? false
                var events: [String] = []
                if programChanged { events.append(program.id == nil ? "Program ended" : "Program · " + program.name) }
                if routineChanged { events.append("Routine version changed") }
                if program.kind == .deload && (prior?.context.kind != .deload || prior?.context.week != program.week || programChanged) {
                    events.append("Deload · " + program.name)
                }
                if equipmentChanged { events.append("Equipment changed") }
                if gap >= settings.breakDays { events.append("Training break · \(gap) days between logs") }
                sample.reset = programChanged || routineChanged || equipmentChanged || gap >= settings.breakDays
                previousSample[key] = sample
                guard includes(date, filter: filter), matches(row, filter: filter),
                      filter.routineID == nil || filter.routineID == sample.routine else { continue }
                var series = results[key] ?? ExerciseAnalytics(id: key, row: row)
                var point = series.points.last?.date == date ? series.points.removeLast() : AnalyticsPoint(date: date)
                for (metric, value) in sample.values { add(metric, value, to: &point.values) }
                point.events += events.filter { !point.events.contains($0) }
                series.points.append(point)
                results[key] = series
                included[key, default: []].append(sample)
            }
            for (exercise, value) in gear {
                previousGear[exercise] = value
                exerciseRevisions[ExerciseRoutineKey(exercise: exercise, routine: session.routineSnapshot.routineID)] = session.routineSnapshot.id
            }
        }
        return results.values.map { value in
            var series = value
            let samples = included[value.id] ?? []
            series.records = recordTable(samples.flatMap(\.efforts))
            if purpose == .working && !value.row.unlinkedStation { series.plateau = plateau(samples, settings: settings) }
            return series
        }.sorted {
            let left = $0.row.variant.exercise.name + $0.row.historyEquipmentName
            let right = $1.row.variant.exercise.name + $1.row.historyEquipmentName
            return left == right ? ($0.points.last?.date ?? WorkoutDate(.distantPast)) > ($1.points.last?.date ?? WorkoutDate(.distantPast)) : left < right
        }
    }

    static func plannedCounts(_ version: RoutineVersion, filter: HistoryFilter = HistoryFilter()) -> SetTally {
        var counts = SetTally()
        guard filter.routineID == nil || filter.routineID == version.routineID else { return counts }
        for row in version.exercises where matches(row, filter: filter) {
            counts.working += row.workingSets.reduce(0) { $0 + $1.sets }
            counts.warmUp += (row.warmUps ?? []).reduce(0) { $0 + $1.sets }
        }
        return counts
    }

    static func completedCounts(_ session: WorkoutSession, filter: HistoryFilter = HistoryFilter()) -> SetTally {
        var counts = SetTally()
        for row in session.plan.exercises where matches(row, filter: filter) {
            for set in session.performedSets where set.plannedExerciseID == row.id {
                counts.add(loggedPurpose(set, row: row, session: session))
            }
        }
        return counts
    }

    static func weekly(_ records: TrainingRecords, anchor: WorkoutDate, filter: HistoryFilter, today: WorkoutDate,
                       lookup: (UUID) -> ExerciseProfile? = { _ in nil }) -> WeeklyAnalytics {
        let days = ScheduleSettings(weekStart: records.scheduleSettings?.weekStart ?? .monday).dates(around: anchor)
        let dates = Set(days.filter { includes($0, filter: filter) })
        var report = WeeklyAnalytics(days: days)
        func addPlan(_ version: RoutineVersion) {
            let counts = plannedCounts(version, filter: filter)
            report.planned.working += counts.working
            report.planned.warmUp += counts.warmUp
        }
        for slot in records.scheduled(on: Array(dates), today: today) where slot.status != .moved {
            if let version = records.version(slot.versionID) { addPlan(version) }
        }
        for session in WorkoutHistory.filtered(records.sessions, by: filter) where dates.contains(session.localDate) {
            if session.scheduleID == nil { addPlan(session.routineSnapshot) }
            var hasSets = false
            for row in session.plan.exercises where matches(row, filter: filter) {
                let profile = row.variant.exercise.profile ?? lookup(row.variant.exercise.id)
                let direct = Set(profile?.primary ?? [])
                let indirect = Set(profile?.secondary ?? []).subtracting(direct)
                for set in session.performedSets where set.plannedExerciseID == row.id {
                    hasSets = true
                    let purpose = loggedPurpose(set, row: row, session: session)
                    report.performed.add(purpose)
                    if purpose == .working {
                        add(.volume, row.isStation ? nil : WorkoutHistory.volume(set, exercise: row), to: &report.totals)
                        add(.duration, quantity(set, metric: .duration), to: &report.totals)
                        add(.distance, quantity(set, metric: .distance), to: &report.totals)
                    }
                    for muscle in direct { report.muscles[muscle, default: MuscleSetTally()].direct.add(purpose) }
                    for muscle in indirect { report.muscles[muscle, default: MuscleSetTally()].indirect.add(purpose) }
                }
            }
            if hasSets { report.workouts += 1 }
        }
        return report
    }
}

extension TrainingRepository {
    func saveAnalytics(_ settings: AnalyticsSettings) throws {
        guard settings.valid else { throw TrainingDataError.invalidRecord("Use 3–12 sessions, a 0.1–25% threshold, and 7–90 days for a training break.") }
        try commit { $0.analyticsSettings = settings }
    }
}
