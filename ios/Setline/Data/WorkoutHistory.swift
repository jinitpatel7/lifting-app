import Foundation

enum HistoryStatus: String {
    case completed = "Completed", incomplete = "Incomplete", active = "In progress · Incomplete"
}

struct HistoryFilter {
    var routineID: UUID?
    var exerciseID: UUID?
    var equipment: String = ""
    var from: WorkoutDate?
    var to: WorkoutDate?
}

struct HistorySet: Identifiable {
    let id: UUID
    let order: Int
    let purpose: SetPurpose
    let prescription: SetPrescription?
    let status: WorkoutSetStatus
    let result: PerformedSet?
}

extension PlannedExercise {
    var historyEquipmentKey: String { variant.equipment?.id.uuidString ?? "kind-" + (variant.exercise.profile?.equipmentKind?.rawValue ?? "bodyweight") }
    var historyEquipmentName: String { variant.equipment?.name ?? variant.exercise.profile?.equipmentKind?.rawValue.capitalized ?? "Bodyweight" }
    var historyVariantKey: HistoryVariantKey { HistoryVariantKey(variant: variant.key, equipment: historyEquipmentKey) }
    var isStation: Bool {
        let kind = variant.equipment?.kind ?? variant.exercise.profile?.equipmentKind
        return kind == .machine || kind == .cable
    }
    var unlinkedStation: Bool { isStation && variant.equipment == nil }
    func comparableKey(in session: UUID) -> HistoryVariantKey {
        unlinkedStation ? HistoryVariantKey(variant: variant.key, equipment: historyEquipmentKey + session.uuidString + id.uuidString) : historyVariantKey
    }
}

struct HistoryVariantKey: Hashable {
    let variant: ExerciseVariantKey
    let equipment: String
}

extension WorkoutSession {
    func historyRows(for exercise: PlannedExercise) -> [HistorySet] {
        let results = performedSets.filter { $0.plannedExerciseID == exercise.id }
        if let log = workoutLog?.exercises.first(where: { $0.id == exercise.id }) {
            return log.rows.enumerated().map { position, row in
                HistorySet(id: row.id, order: position + 1, purpose: row.purpose, prescription: row.prescription,
                    status: row.status, result: results.first { $0.id == row.id })
            }
        }
        let targets = (try? WorkoutExerciseLog(entry: exercise).rows) ?? []
        let byOrder = Dictionary(results.map { ($0.order, $0) }, uniquingKeysWith: { previous, _ in previous })
        let orders = Set(targets.indices.map { $0 + 1 }).union(byOrder.keys).sorted()
        return orders.map { order in
            let result = byOrder[order]
            let target = order > 0 && targets.indices.contains(order - 1) ? targets[order - 1] : nil
            return HistorySet(id: result?.id ?? target?.id ?? UUID(), order: order,
                purpose: target?.purpose ?? result?.purpose ?? .working, prescription: target?.prescription,
                status: result == nil ? .pending : .completed, result: result)
        }
    }

    var historyStatus: HistoryStatus {
        guard completedAt != nil else { return .active }
        return endedEarly == true || performedSets.isEmpty || plan.exercises.contains { entry in
            historyRows(for: entry).contains { $0.status != .completed }
        } ? .incomplete : .completed
    }
}

struct HistoryMetrics {
    let sets: Int
    let duration: TimeInterval?
    let volume: Double?
}

struct HistoryScope: Identifiable {
    var id: String { exerciseID?.uuidString ?? "routine" }
    let exerciseID: UUID?
    let label: String
}

struct HistoryComparison {
    let current: HistoryMetrics
    let previous: HistoryMetrics
    let orderChanged: Bool
    let equipmentChanged: Bool
    let exercisesChanged: Bool
    let volumeChange: Double?
    let repsChange: Double?
}

enum WorkoutHistory {
    static func filtered(_ sessions: [WorkoutSession], by filter: HistoryFilter = HistoryFilter()) -> [WorkoutSession] {
        sessions.filter { session in
            if filter.from.map({ session.localDate < $0 }) == true || filter.to.map({ session.localDate > $0 }) == true { return false }
            if let routine = filter.routineID, session.routineSnapshot.routineID != routine { return false }
            if filter.exerciseID == nil, filter.equipment.isEmpty { return true }
            return session.plan.exercises.contains { entry in
                (filter.exerciseID == nil || filter.exerciseID == entry.variant.exercise.id) &&
                    (filter.equipment.isEmpty || filter.equipment == entry.historyEquipmentKey)
            }
        }.sorted { $0.localDate == $1.localDate ? $0.startedAt > $1.startedAt : $0.localDate > $1.localDate }
    }

    static func externalLoad(_ amount: SetAmount?) -> Double? {
        switch amount {
        case .weight(let mass), .addedLoad(let mass): mass.kilograms
        default: nil
        }
    }

    static func totalReps(_ reps: Repetitions?) -> Double? {
        switch reps {
        case .total(let count): Double(count)
        case .perSide(let count): Double(count) * 2
        case .separateSides(let left, let right): Double(left) + Double(right)
        case nil: nil
        }
    }

    static func volume(_ set: PerformedSet, exercise: PlannedExercise) -> Double? {
        guard let load = externalLoad(set.amount), let reps = set.repetitions else { return nil }
        let right = externalLoad(set.rightAmount) ?? load
        let value: Double
        switch reps {
        case .total(let count):
            if case .weightReps(.perDumbbell, _) = exercise.variant.measurement { value = load * Double(count) * 2 }
            else { value = load * Double(count) }
        case .perSide(let count): value = load * Double(count) * 2
        case .separateSides(let left, let rightReps): value = load * Double(left) + right * Double(rightReps)
        }
        return value.isFinite ? value : nil
    }

    static func metrics(_ session: WorkoutSession, exerciseID: UUID? = nil, variants: Set<HistoryVariantKey>? = nil) -> HistoryMetrics {
        let exercises = session.plan.exercises.filter { exercise in
            (exerciseID == nil || exerciseID == exercise.variant.exercise.id) && (variants?.contains(exercise.comparableKey(in: session.id)) ?? true)
        }
        let lookup = Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, $0) })
        let sets = session.performedSets.filter { lookup[$0.plannedExerciseID] != nil }
        let allowStation = exerciseID != nil && Set(exercises.map { $0.comparableKey(in: session.id) }).count == 1
        let volumes = sets.compactMap { set -> Double? in
            guard let entry = lookup[set.plannedExerciseID], !entry.isStation || (allowStation && !entry.unlinkedStation) else { return nil }
            return volume(set, exercise: entry)
        }
        let duration = session.manualDurationKnown == false ? nil : session.completedAt.map { session.workoutTimes(at: $0, clock: session.workoutLog?.clock).elapsed }
        return HistoryMetrics(sets: sets.count, duration: duration, volume: volumes.isEmpty ? nil : volumes.reduce(0, +))
    }

    static func scopes(_ a: WorkoutSession, _ b: WorkoutSession) -> [HistoryScope] {
        var scopes: [HistoryScope] = []
        if a.routineSnapshot.revision > 0, a.routineSnapshot.routineID == b.routineSnapshot.routineID {
            scopes.append(HistoryScope(exerciseID: nil, label: "Same routine"))
        }
        var shared = Set(b.plan.exercises.map { $0.variant.exercise.id })
        for row in a.plan.exercises where shared.remove(row.variant.exercise.id) != nil {
            scopes.append(HistoryScope(exerciseID: row.variant.exercise.id, label: row.variant.exercise.name))
        }
        return scopes
    }

    static func compare(_ current: WorkoutSession, _ previous: WorkoutSession, scope: HistoryScope) -> HistoryComparison {
        func rows(_ session: WorkoutSession) -> [PlannedExercise] {
            session.plan.exercises.filter { scope.exerciseID == nil || scope.exerciseID == $0.variant.exercise.id }
        }
        let left = rows(current), right = rows(previous)
        let leftOrder = left.map { $0.variant.exercise.id }, rightOrder = right.map { $0.variant.exercise.id }
        let shared = Set(leftOrder).intersection(rightOrder)
        func equipment(_ rows: [PlannedExercise], for id: UUID) -> Set<String> {
            Set(rows.filter { $0.variant.exercise.id == id }.map(\.historyEquipmentKey))
        }
        let compatible = comparableVariants(in: current).intersection(comparableVariants(in: previous))
        let ownVolume = metrics(current, exerciseID: scope.exerciseID, variants: compatible).volume
        let pastVolume = metrics(previous, exerciseID: scope.exerciseID, variants: compatible).volume
        let change = ownVolume.flatMap { own in pastVolume.map { own - $0 } }
        func reps(_ session: WorkoutSession, in rows: [PlannedExercise]) -> Double? {
            let slots = Set(rows.filter { compatible.contains($0.comparableKey(in: session.id)) }.map(\.id))
            let counts: [Double] = session.performedSets.compactMap { set in
                guard slots.contains(set.plannedExerciseID) else { return nil }
                return totalReps(set.repetitions)
            }
            return counts.isEmpty ? nil : counts.reduce(0, +)
        }
        let repChange = reps(current, in: left).flatMap { current in reps(previous, in: right).map { current - $0 } }
        return HistoryComparison(current: metrics(current, exerciseID: scope.exerciseID), previous: metrics(previous, exerciseID: scope.exerciseID),
            orderChanged: scope.exerciseID == nil && leftOrder.filter(shared.contains) != rightOrder.filter(shared.contains),
            equipmentChanged: shared.contains { equipment(left, for: $0) != equipment(right, for: $0) },
            exercisesChanged: scope.exerciseID == nil && Set(leftOrder) != Set(rightOrder), volumeChange: change, repsChange: repChange)
    }

    static func prior(to session: WorkoutSession, in sessions: [WorkoutSession]) -> (WorkoutSession, HistoryScope)? {
        let older = filtered(sessions).filter { $0.id != session.id && $0.startedAt < session.startedAt && $0.completedAt != nil && !$0.performedSets.isEmpty }
        for other in older {
            if let routine = scopes(session, other).first(where: { $0.exerciseID == nil }) { return (other, routine) }
        }
        let performed = comparableVariants(in: session)
        for other in older {
            let common = performed.intersection(comparableVariants(in: other))
            if let row = session.plan.exercises.first(where: { common.contains($0.comparableKey(in: session.id)) }) {
                return (other, HistoryScope(exerciseID: row.variant.exercise.id, label: row.variant.exercise.name))
            }
        }
        return nil
    }

    static func performedVariants(in session: WorkoutSession) -> Set<ExerciseVariantKey> {
        Set(comparableVariants(in: session).map(\.variant))
    }

    private static func comparableVariants(in session: WorkoutSession) -> Set<HistoryVariantKey> {
        let performed = Set(session.performedSets.map(\.plannedExerciseID))
        return Set(session.plan.exercises.filter { performed.contains($0.id) }.map { $0.comparableKey(in: session.id) })
    }

}

extension TrainingRecords {
    mutating func invalidateHistoryPredictions(comparedTo previous: TrainingRecords) {
        guard !predictions.isEmpty, sessions != previous.sessions else { return }
        let prior = Dictionary(uniqueKeysWithValues: previous.sessions.filter { $0.completedAt != nil }.map { ($0.id, $0) })
        var sessionIDs = Set<UUID>()
        var variants = Set<ExerciseVariantKey>()
        for session in sessions where session.completedAt != nil {
            let old = prior[session.id]
            if let old, old.localDate == session.localDate, old.performedSets == session.performedSets,
               WorkoutHistory.performedVariants(in: old) == WorkoutHistory.performedVariants(in: session) { continue }
            sessionIDs.insert(session.id)
            variants.formUnion(WorkoutHistory.performedVariants(in: session))
            if let old { variants.formUnion(WorkoutHistory.performedVariants(in: old)) }
        }
        predictions.removeAll { variants.contains($0.variant) || !$0.sourceSessionIDs.allSatisfy({ !sessionIDs.contains($0) }) }
    }
}

struct HistorySetDraft: Identifiable {
    var row: WorkoutSetRow
    var input: WorkoutSetInput
    var id: UUID { row.id }

    init(unit: WeightUnit, set: HistorySet? = nil) {
        row = WorkoutSetRow(id: set?.id ?? UUID(), purpose: set?.purpose ?? .working,
            prescription: set?.prescription, status: set?.status ?? .pending)
        input = set?.result.map { WorkoutSetInput(result: $0, unit: unit) } ?? WorkoutSetInput(unit: unit)
    }
}

struct HistoryExerciseDraft: Identifiable {
    let entry: PlannedExercise
    var notes = ""
    var sets: [HistorySetDraft]
    var id: UUID { entry.id }
}

struct HistoryEditDraft {
    let originalID: UUID?
    let unit: WeightUnit
    var versionID: UUID?
    var name: String
    var start: Date
    var minutes = ""
    var notes: String
    var incomplete: Bool
    var exercises: [HistoryExerciseDraft]

    init(session: WorkoutSession? = nil, template: RoutineVersion? = nil, day: WorkoutDate, start: Date, unit: WeightUnit) {
        originalID = session?.id
        self.unit = unit
        versionID = template?.id
        name = session?.plan.name ?? template?.name ?? ""
        self.start = session?.startedAt ?? start
        notes = session?.workoutLog?.notes ?? ""
        incomplete = session?.endedEarly == true
        let source = session ?? template.map {
            WorkoutSession(localDate: day, timeZoneIdentifier: TimeZone.current.identifier, startedAt: start,
                scheduleID: nil, routineSnapshot: $0)
        }
        exercises = source.map { session in
            session.plan.exercises.map { entry in
                HistoryExerciseDraft(entry: entry, notes: session.workoutLog?.exercises.first(where: { $0.id == entry.id })?.notes ?? "",
                    sets: session.historyRows(for: entry).map { HistorySetDraft(unit: unit, set: $0) })
            }
        } ?? []
    }

    mutating func addExercise(_ exercise: Exercise, equipment: Equipment?, measurement: Measurement) {
        let entry = PlannedExercise(variant: ExerciseVariant(exercise: exercise, equipment: equipment, measurement: measurement),
            prescription: SetPrescription(sets: 1))
        exercises.append(HistoryExerciseDraft(entry: entry, sets: [HistorySetDraft(unit: unit)]))
    }
}

extension TrainingRepository {
    @discardableResult
    func saveHistory(_ draft: HistoryEditDraft, at now: Date = Date(), timeZone: TimeZone = .current) throws -> UUID {
        let position = draft.originalID.flatMap { id in records.sessions.firstIndex { $0.id == id } }
        var session: WorkoutSession
        if let position {
            session = records.sessions[position]
            guard session.completedAt != nil else { throw TrainingDataError.invalidRecord("Choose a finished workout to edit.") }
        } else {
            guard draft.originalID == nil else { throw TrainingDataError.unknownRecord("Workout history entry not found.") }
            let minutesText = draft.minutes.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
            let minutes = minutesText.isEmpty ? nil : Double(minutesText)
            guard minutesText.isEmpty || minutes.map({ (0...1440).contains($0) }) == true else {
                throw TrainingDataError.invalidRecord("Enter a duration up to 24 hours.")
            }
            let end = draft.start.addingTimeInterval((minutes ?? 0) * 60)
            guard end <= now else { throw TrainingDataError.invalidRecord("The workout must have ended by now.") }
            let template = draft.versionID.flatMap(records.version)
            guard draft.versionID == nil || template != nil else { throw TrainingDataError.unknownRecord("Choose an existing routine version.") }
            let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty || template != nil else { throw TrainingDataError.invalidRecord("Name the workout or choose a routine.") }
            let snapshot = template ?? RoutineVersion(routineID: UUID(), revision: 0, createdAt: now, name: name, exercises: [])
            session = WorkoutSession(localDate: WorkoutDate(draft.start, timeZone: timeZone), timeZoneIdentifier: timeZone.identifier,
                startedAt: draft.start, scheduleID: nil, routineSnapshot: snapshot, completedAt: end, manualDurationKnown: minutes != nil)
        }

        let current = session.plan
        let byID = Dictionary(uniqueKeysWithValues: current.exercises.map { ($0.id, $0) })
        let draftIDs = Set(draft.exercises.map(\.id))
        guard draftIDs.count == draft.exercises.count, Set(byID.keys).isSubset(of: draftIDs) else {
            throw TrainingDataError.invalidRecord("Keep the original workout exercises when correcting their results.")
        }
        let additions = draft.exercises.map(\.entry).filter { byID[$0.id] == nil }
        guard additions.allSatisfy({ entry in
            let variant = entry.variant
            return exercise(variant.exercise.id) != nil && variant.measurement.supports(variant.equipment)
                && (variant.equipment.map(records.equipment.contains) ?? true)
        }) else { throw TrainingDataError.invalidRecord("Choose an available exercise and compatible equipment.") }
        if !additions.isEmpty {
            session.sessionPlan = RoutineVersion(id: current.id, routineID: current.routineID, revision: current.revision,
                createdAt: current.createdAt, name: current.name, exercises: current.exercises + additions,
                categoryID: current.categoryID, groups: current.groups)
        }
        let oldResults = Dictionary(uniqueKeysWithValues: session.performedSets.map { ($0.id, $0) })
        var log = try session.workoutLog ?? WorkoutLog(session: session)
        var result: [PerformedSet] = []
        var rowIDs = Set<UUID>()
        var entries: [WorkoutExerciseLog] = []
        for exercise in draft.exercises {
            let entry = byID[exercise.id] ?? exercise.entry
            let measurement = entry.variant.measurement
            let recorded = Dictionary(uniqueKeysWithValues: session.historyRows(for: entry).map { ($0.id, $0) })
            var logEntry = try log.exercises.first(where: { $0.id == entry.id }) ?? WorkoutExerciseLog(entry: entry)
            logEntry.notes = exercise.notes
            logEntry.queued = false
            logEntry.queuedAt = nil
            logEntry.rows = try exercise.sets.enumerated().map { index, set in
                guard rowIDs.insert(set.id).inserted else { throw TrainingDataError.invalidRecord("Each historical set needs a distinct record.") }
                var row = set.row
                if let prior = recorded[set.id] {
                    row.prescription = prior.prescription
                    row.purpose = prior.purpose
                }
                if row.status == .completed {
                    let old = oldResults[set.id]
                    var actual = old ?? PerformedSet(id: set.id, plannedExerciseID: entry.id, order: index + 1,
                        recordedAt: session.completedAt ?? now, purpose: row.purpose, structure: row.prescription?.structure,
                        amrap: row.prescription?.amrap)
                    guard actual.plannedExerciseID == entry.id else { throw TrainingDataError.invalidRecord("A saved set belongs to its original exercise.") }
                    if old == nil || WorkoutSetInput(result: actual, unit: set.input.unit) != set.input {
                        let amount = try set.input.performedAmount(for: measurement)
                        let reps = try set.input.repetitions(for: measurement)
                        let right = try set.input.performedRightAmount(for: measurement, reps: reps)
                        let effort = try set.input.efforts()
                        guard measurement.accepts(amount), measurement.acceptsPerformed(reps: reps, rightAmount: right) else {
                            throw TrainingDataError.invalidRecord("Enter valid results for \(entry.variant.exercise.name), set \(index + 1).")
                        }
                        actual.amount = amount
                        actual.rightAmount = right
                        actual.repetitions = reps
                        actual.actualRIR = effort.rir
                        actual.actualRPE = effort.rpe
                        actual.effortOutcome = set.input.failure ? .failure : nil
                    }
                    actual.order = index + 1
                    result.append(actual)
                    row.input = set.input
                } else {
                    row.input = nil
                }
                return row
            }
            entries.append(logEntry)
        }
        if position == nil && result.isEmpty { throw TrainingDataError.invalidRecord("Mark at least one set as performed and enter its results.") }
        log.notes = draft.notes
        log.exercises = entries
        log.rest = nil
        log.undo = nil
        session.workoutLog = log
        session.performedSets = result
        session.endedEarly = draft.incomplete ? true : nil
        try commit { next in
            if let position { next.sessions[position] = session } else { next.sessions.append(session) }
        }
        return session.id
    }
}
