import Foundation

struct BackupOptions {
    var notes = true
    var bodyweight = true
    var readiness = true
    var forecasts = true
    var photos = false
}

struct ShareOptions {
    var notes = false
    var bodyweight = false
    var effort = false
    var sets = true
}

struct BackupDisplaySettings: Codable, Equatable {
    let appearance: String
    let opaque: Bool
    let unit: WeightUnit
}

struct SetlineBackup: Codable {
    static let sizeLimit = 20 * 1024 * 1024
    struct Payload: Codable {
        let records: TrainingRecords
        let settings: BackupDisplaySettings
    }
    let format: String
    let version: Int
    let platform: String
    let createdAt: String
    let payload: Payload

    static func make(_ records: TrainingRecords, settings: BackupDisplaySettings, options: BackupOptions) throws -> Self {
        var copy = records
        copy.clearCompanionState()
        if !options.bodyweight {
            copy.bodyweightEntries = []
            copy.bodyweightTargetKgPerWeek = nil
            copy.photos.removeAll { if case .bodyweight = $0.subject { true } else { false } }
        }
        if !options.readiness { copy.readiness = [] }
        if !options.photos { copy.photos = [] }
        if !options.forecasts {
            copy.predictions = []
            for index in copy.sessions.indices { copy.sessions[index].performanceForecasts = nil }
        }
        if !options.notes {
            let document = try JSONSerialization.jsonObject(with: JSONEncoder().encode(copy))
            copy = try JSONDecoder().decode(TrainingRecords.self, from: JSONSerialization.data(withJSONObject: redactNotes(document)))
        }
        return Self(format: "setline-backup", version: 1, platform: "ios", createdAt: Date().ISO8601Format(),
            payload: Payload(records: copy, settings: settings))
    }

    var data: Data { get throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let result = try encoder.encode(self)
        guard result.count <= Self.sizeLimit else { throw TrainingDataError.invalidRecord("The backup exceeds the 20 MB limit.") }
        return result
    } }

    static func read(_ bytes: Data) throws -> Self {
        struct Header: Decodable { let format: String; let version: Int; let platform: String }
        guard bytes.count <= sizeLimit else { throw TrainingDataError.invalidRecord("Choose a file up to 20 MB.") }
        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(Header.self, from: bytes), header.format == "setline-backup", header.version == 1 else {
            throw TrainingDataError.invalidRecord("This Setline backup version is unsupported.")
        }
        guard header.platform == "ios" else { throw TrainingDataError.invalidRecord("This backup was made for the browser preview. Restore it there.") }
        guard let backup = try? decoder.decode(Self.self, from: bytes),
              (try? Date.ISO8601FormatStyle().parse(backup.createdAt)) != nil,
              ["system", "light", "dark"].contains(backup.payload.settings.appearance) else {
            throw TrainingDataError.invalidRecord("The backup data or display settings are invalid.")
        }
        try validate(backup.payload.records)
        return backup
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw TrainingDataError.invalidRecord(message) }
    }

    private static func ids<T: Identifiable>(_ list: [T], _ label: String) throws -> Set<T.ID> {
        let values = Set(list.map(\.id))
        try require(values.count == list.count, "Duplicate identifiers in \(label).")
        return values
    }

    private static func plan(_ plan: RoutineVersion, emptyAllowed: Bool) throws {
        _ = try ids(plan.exercises, "exercise slots")
        try require(!plan.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (emptyAllowed || !plan.exercises.isEmpty),
            "A routine name or exercise list is missing.")
        _ = try RoutineGroup.normalized(plan.groups ?? [], exercises: plan.exercises)
        for row in plan.exercises {
            try require(row.variant.measurement.supports(row.variant.equipment), "An exercise has incompatible equipment.")
            var remaining = 10_000
            for set in row.allPrescriptions {
                try require(set.sets <= remaining && set.isValid(for: row.variant.measurement, allowsUntargetedReps: emptyAllowed), "A set prescription is invalid.")
                remaining -= set.sets
            }
        }
    }

    static func validate(_ records: TrainingRecords) throws {
        let equipment = try ids(records.equipment, "equipment")
        let exercises = try ids(records.exercises, "custom exercises")
        let routines = try ids(records.routines, "routines")
        let versions = try ids(records.routineVersions, "routine versions")
        let sessions = try ids(records.sessions, "workouts")
        let schedule = try ids(records.schedule, "schedule")
        let blocks = try ids(records.programBlocks, "programs")
        let weights = try ids(records.bodyweightEntries, "bodyweight")
        let categories = try ids(records.routineCategories ?? [], "categories")
        let rotations = try ids(records.rotations ?? [], "rotations")
        _ = try ids(records.weekdayRules ?? [], "weekday assignments")
        _ = try ids(records.readiness, "readiness")
        _ = try ids(records.photos, "photo links")
        _ = try ids(records.predictions, "predictions")
        try require(Set(records.bodyweightEntries.map(\.localDate)).count == weights.count && records.bodyweightEntries.allSatisfy { $0.mass.kilograms > 0 },
            "Bodyweight entries have duplicate dates or invalid values.")
        try require(Set(records.readiness.map(\.localDate)).count == records.readiness.count, "Readiness entries have duplicate dates.")
        try require(records.analyticsSettings?.valid != false, "Analytics settings are invalid.")
        try require(records.sessions.filter { $0.completedAt == nil }.count <= 1, "The backup contains multiple active workouts.")
        for routine in records.routines {
            let history = records.versions(for: routine.id)
            try require(history.first?.id == routine.currentVersionID && history.map(\.revision) == Array((1...max(1, history.count)).reversed()),
                "A routine has a missing or duplicate version.")
        }
        for version in records.routineVersions {
            try require(routines.contains(version.routineID) && (version.categoryID.map(categories.contains) ?? true) &&
                version.exercises.allSatisfy { $0.variant.equipment.map { equipment.contains($0.id) } ?? true }, "A routine version has a missing relationship.")
            try plan(version, emptyAllowed: false)
        }
        for slot in records.schedule {
            try require(versions.contains(slot.routineVersionID) && (slot.programBlockID.map(blocks.contains) ?? true) &&
                (slot.rotationID.map(rotations.contains) ?? true), "A scheduled workout has a missing relationship.")
        }
        for block in records.programBlocks { try require(block.firstDay <= block.lastDay, "A program has invalid dates.") }
        for rule in records.weekdayRules ?? [] { try require(versions.contains(rule.versionID), "A weekday assignment has no routine.") }
        for rule in records.rotations ?? [] { try require(rule.interval > 0 && !rule.versionIDs.isEmpty &&
            rule.versionIDs.allSatisfy(versions.contains), "A rotation has invalid routine assignments.") }
        for session in records.sessions {
            try plan(session.routineSnapshot, emptyAllowed: true)
            if let changed = session.sessionPlan { try plan(changed, emptyAllowed: true) }
            try require((session.scheduleID.map(schedule.contains) ?? true) && (session.referenceSessionID.map(sessions.contains) ?? true) &&
                (session.completedAt.map { $0 >= session.startedAt } ?? true), "A workout has invalid dates or a missing relationship.")
            let slots = Dictionary(uniqueKeysWithValues: session.plan.exercises.map { ($0.id, $0.variant.measurement) })
            let results = try ids(session.performedSets, "performed sets")
            for set in session.performedSets {
                guard let measurement = slots[set.plannedExerciseID] else { throw TrainingDataError.invalidRecord("A set has no workout exercise.") }
                try require(set.order > 0 && set.recordedAt >= session.startedAt && measurement.accepts(set.amount) &&
                    measurement.acceptsPerformed(reps: set.repetitions, rightAmount: set.rightAmount), "A performed set is invalid.")
            }
            if let log = session.workoutLog {
                _ = try ids(log.exercises, "logged exercise slots")
                let sets = log.exercises.flatMap(\.rows)
                _ = try ids(sets, "logged set rows")
                try require(log.exercises.allSatisfy { slots[$0.id] != nil } && Set(sets.filter { $0.status == .completed }.map(\.id)) == results,
                    "A workout has inconsistent set completion data.")
            }
            let forecasts = session.performanceForecasts ?? []
            _ = try ids(forecasts, "saved forecasts")
            try require(forecasts.allSatisfy { $0.sources.allSatisfy { sessions.contains($0.id) } &&
                $0.ranges.values.allSatisfy { $0.low <= $0.high } }, "A forecast has missing evidence or an invalid range.")
            try require(session.energyInput?.isValid != false, "A workout has invalid calorie inputs.")
        }
        for photo in records.photos {
            let found: Bool = switch photo.subject {
            case .exercise(let id): exercises.contains(id)
            case .session(let id): sessions.contains(id)
            case .bodyweight(let id): weights.contains(id)
            case nil: true
            }
            // Built-in exercise IDs are resolved by the installed catalog.
            if case .exercise = photo.subject {
                try require(photo.location.isValid, "A device photo reference is invalid.")
            } else { try require(found && photo.location.isValid, "A device photo reference is invalid.") }
        }
    }

    private static func redactNotes(_ data: Any) -> Any {
        if let list = data as? [Any] { return list.map(redactNotes) }
        guard let values = data as? [String: Any] else { return data }
        return Dictionary(uniqueKeysWithValues: values.map { key, value in
            if ["notes", "setup", "cues"].contains(key), value is String { return (key, "" as Any) }
            if key == "machineSetup" { return (key, ["seat": "", "attachment": "", "incline": "", "handle": ""] as Any) }
            return (key, redactNotes(value))
        })
    }
}

enum TrainingCSV {
    static func bodyweight(_ records: TrainingRecords) -> String {
        var rows = [["local_date", "bodyweight_kg"]]
        rows += records.bodyweightEntries.sorted { $0.localDate < $1.localDate }.map { [$0.localDate.key, String($0.mass.kilograms)] }
        return encode(rows)
    }

    static func workouts(_ records: TrainingRecords, options: ShareOptions) -> String {
        var header = ["session_id", "local_date", "workout", "completed_at", "exercise", "equipment", "measurement", "load_basis", "rep_counting", "set", "purpose",
            "status", "reps", "right_reps", "weight_kg", "right_weight_kg", "added_load_kg", "right_added_load_kg", "assistance_kg", "right_assistance_kg",
            "duration_s", "right_duration_s", "distance_m", "right_distance_m", "machine_setting"]
        if options.effort { header += ["actual_rir", "actual_rpe", "to_failure"] }
        if options.notes { header += ["session_notes", "exercise_notes"] }
        var rows = [header]
        for session in records.sessions {
            let head = [session.id.uuidString, session.localDate.key, session.plan.name, session.completedAt?.ISO8601Format() ?? ""]
            let count = rows.count
            for row in session.plan.exercises {
                let wire = RoutineExchange.measurement(row.variant.measurement)
                let prefix = head + [row.variant.exercise.name, row.historyEquipmentName, wire.kind, wire.basis, wire.counting]
                for set in session.historyRows(for: row) {
                    let result = set.result
                    let reps = repetitions(result?.repetitions)
                    let left = RoutineExchange.amount(result?.amount)
                    let right = RoutineExchange.amount(result?.rightAmount)
                    let amounts = ["weight", "added", "assistance", "duration", "distance"].flatMap { kind in
                        [left, right].map { $0?.kind == kind ? ($0?.value.number.map { String($0) } ?? "") : "" }
                    }
                    var resultRow = prefix + [String(set.order), set.purpose == .warmUp ? "warm-up" : "working", set.status.rawValue, reps.0, reps.1]
                    resultRow += amounts + [left?.value.setting ?? ""]
                    if options.effort { resultRow += [result?.actualRIR.map { String($0) } ?? "", result?.actualRPE.map { String($0) } ?? "",
                        result.map { $0.effortOutcome == .failure ? "true" : "false" } ?? ""] }
                    if options.notes { resultRow += [session.workoutLog?.notes ?? "", session.workoutLog?.exercises.first { $0.id == row.id }?.notes ?? ""] }
                    rows.append(resultRow)
                }
            }
            if rows.count == count { rows.append(head + Array(repeating: "", count: header.count - head.count)) }
        }
        return encode(rows)
    }

    private static func repetitions(_ value: Repetitions?) -> (String, String) {
        switch value {
        case .total(let count), .perSide(let count): (String(count), "")
        case .separateSides(let left, let right): (String(left), String(right))
        case nil: ("", "")
        }
    }

    private static func encode(_ rows: [[String]]) -> String {
        rows.map { row in row.map { value in
            let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
            let unsafe = candidate.first.map { "=+-@".contains($0) } == true || value.first.map { "\t\r\n".contains($0) } == true
            return "\"" + (unsafe ? "'" : "") + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }.joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }
}
