import Foundation

struct TrainingRecords: Codable, Equatable {
    var equipment: [Equipment] = []
    var exercises: [Exercise] = []
    var routines: [RoutineRecord] = []
    var routineVersions: [RoutineVersion] = []
    var sessions: [WorkoutSession] = []
    var schedule: [ScheduledWorkout] = []
    var programBlocks: [ProgramBlock] = []
    var bodyweightEntries: [BodyweightEntry] = []
    var readiness: [ReadinessCheckIn] = []
    var photos: [DevicePhotoReference] = []
    var predictions: [FuturePrediction] = []
    var exercisePreferences: [String: ExercisePreference]? = nil
    var routineCategories: [RoutineCategory]? = nil
    var scheduleSettings: ScheduleSettings? = nil
    var weekdayRules: [WeekdayAssignment]? = nil
    var rotations: [RoutineRotation]? = nil
    var analyticsSettings: AnalyticsSettings? = nil
    var bodyweightTargetKgPerWeek: Double? = nil
    var progressionRules: [ExerciseProgressionRule]? = nil

    var activeSession: WorkoutSession? { sessions.first { $0.completedAt == nil } }
    var currentRoutines: [RoutineVersion] {
        routines.compactMap { routine in version($0.currentVersionID) }
    }

    func version(_ id: UUID) -> RoutineVersion? { routineVersions.first { $0.id == id } }
    func versions(for routineID: UUID) -> [RoutineVersion] {
        routineVersions.filter { $0.routineID == routineID }.sorted { $0.revision > $1.revision }
    }
    func bodyweight(on date: WorkoutDate) -> BodyweightEntry? { bodyweightEntries.first { $0.localDate == date } }
}

struct SamplePreviewState: Codable {
    var bodyweightByDay: [String: Double] = [:]
    var activeRoutineID: String?
}

enum TrainingDataError: Error, LocalizedError, Equatable {
    case unsupportedSchema(Int)
    case invalidRecord(String)
    case unknownRecord(String)
    case conflictingRecord(String)
    case activeSessionExists
    case sessionFinished

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version): "This training data needs a version of Setline that supports schema \(version)."
        case .invalidRecord(let reason), .unknownRecord(let reason), .conflictingRecord(let reason): reason
        case .activeSessionExists: "Finish the active workout before starting another."
        case .sessionFinished: "This workout is already complete."
        }
    }
}

struct TrainingFiles {
    static let schemaVersion = 2
    static let userFilename = "TrainingData.json"
    static let sampleFilename = "SamplePreview-v1.json"
    static let legacyFilename = "TrainingState-v1.json"

    let directory: URL

    static func applicationSupport() throws -> Self {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        return Self(directory: root.appendingPathComponent("Setline", isDirectory: true))
    }

    func loadUserData() throws -> TrainingRecords {
        if let data = try read(Self.userFilename) {
            let decoder = JSONDecoder()
            let version = try decoder.decode(SchemaHeader.self, from: data).schemaVersion
            switch version {
            case Self.schemaVersion: return try decoder.decode(Envelope.self, from: data).records
            default: throw TrainingDataError.unsupportedSchema(version)
            }
        }
        guard let legacyData = try read(Self.legacyFilename) else { return TrainingRecords() }
        let legacy = try JSONDecoder().decode(SamplePreviewState.self, from: legacyData)
        let updated = (try? url(Self.legacyFilename).resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? Date()
        var records = TrainingRecords()
        for (key, kilograms) in legacy.bodyweightByDay.sorted(by: { $0.key < $1.key }) {
            guard let date = WorkoutDate(key), let mass = Mass(kilograms), mass.kilograms > 0 else {
                throw TrainingDataError.invalidRecord("A previous bodyweight entry could not be migrated.")
            }
            records.bodyweightEntries.append(BodyweightEntry(localDate: date, createdAt: updated, updatedAt: updated, mass: mass))
        }
        try saveUserData(records)
        return records
    }

    func saveUserData(_ records: TrainingRecords) throws {
        try write(JSONEncoder().encode(Envelope(schemaVersion: Self.schemaVersion, records: records)), to: Self.userFilename)
    }

    func loadSamplePreview() throws -> SamplePreviewState {
        let decoder = JSONDecoder()
        if let data = try read(Self.sampleFilename) {
            return try decoder.decode(SamplePreviewState.self, from: data)
        }
        guard let legacy = try read(Self.legacyFilename) else { return SamplePreviewState() }
        let existing = try decoder.decode(SamplePreviewState.self, from: legacy)
        return SamplePreviewState(activeRoutineID: existing.activeRoutineID)
    }

    func saveSamplePreview(_ preview: SamplePreviewState) throws {
        try write(JSONEncoder().encode(preview), to: Self.sampleFilename)
    }

    private struct SchemaHeader: Decodable { let schemaVersion: Int }
    private struct Envelope: Codable {
        let schemaVersion: Int
        let records: TrainingRecords
    }

    private func url(_ filename: String) -> URL { directory.appendingPathComponent(filename) }

    private func read(_ filename: String) throws -> Data? {
        do {
            return try Data(contentsOf: url(filename))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        }
    }

    private func write(_ data: Data, to filename: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url(filename), options: .atomic)
    }

}

@MainActor
final class TrainingRepository {
    private let files: TrainingFiles
    private let catalog: [Exercise]
    private(set) var records: TrainingRecords

    init(files: TrainingFiles, catalog: [Exercise] = []) throws {
        self.files = files
        self.catalog = catalog
        records = try files.loadUserData()
    }

    func addEquipment(_ equipment: Equipment) throws {
        try requireName(equipment.name)
        try insert(equipment, at: \.equipment)
    }

    func addExercise(_ exercise: Exercise) throws {
        try requireName(exercise.name)
        guard !catalog.contains(where: { $0.id == exercise.id }) else {
            throw TrainingDataError.conflictingRecord("Create a custom variation to edit a built-in exercise.")
        }
        try insert(exercise, at: \.exercises)
    }

    func editExercise(_ exercise: Exercise, at date: Date = Date()) throws {
        try requireName(exercise.name)
        guard let index = records.exercises.firstIndex(where: { $0.id == exercise.id }) else {
            throw TrainingDataError.unknownRecord("Choose a custom exercise to edit.")
        }
        let previous = records.exercises[index]
        if let profile = previous.profile {
            guard let edited = exercise.profile, edited.equipmentKind == profile.equipmentKind,
                  edited.variation == profile.variation else {
                throw TrainingDataError.invalidRecord("Save a new variation when changing exercise equipment or movement identity.")
            }
        }
        var updated = exercise
        updated.createdAt = previous.createdAt
        updated.updatedAt = date
        try commit { $0.exercises[index] = updated }
    }

    func setExercisePreference(_ preference: ExercisePreference, for id: UUID) throws {
        guard exercise(id) != nil else { throw TrainingDataError.unknownRecord("This exercise could not be found.") }
        try commit { next in
            var preferences = next.exercisePreferences ?? [:]
            preferences[id.uuidString] = preference == ExercisePreference() ? nil : preference
            next.exercisePreferences = preferences
        }
    }

    func exercise(_ id: UUID) -> Exercise? {
        records.exercises.first { $0.id == id } ?? catalog.first { $0.id == id }
    }

    @discardableResult
    func saveRoutine(id: UUID = UUID(), name: String, exercises: [PlannedExercise], categoryID: UUID? = nil,
                     groups: [RoutineGroup] = [], expectedVersionID: UUID? = nil, at date: Date = Date(),
                     preserveCurrentSnapshots: Bool = false) throws -> RoutineVersion {
        try requireName(name)
        if let categoryID, records.routineCategories?.contains(where: { $0.id == categoryID }) != true {
            throw TrainingDataError.unknownRecord("Choose a saved routine category.")
        }
        let index = records.routines.firstIndex { $0.id == id }
        let current = index.flatMap { records.version(records.routines[$0].currentVersionID) }
        if let expectedVersionID, expectedVersionID != current?.id {
            throw TrainingDataError.conflictingRecord("This routine changed. Reopen it before saving an edit.")
        }
        let snapshots = try snapshots(for: exercises, prior: preserveCurrentSnapshots ? (current?.exercises ?? []) : [])
        let normalized = try RoutineGroup.normalized(groups, exercises: snapshots)
        if let current, current.name == name, current.exercises == snapshots, current.categoryID == categoryID,
           (current.groups ?? []) == normalized { return current }
        let version = RoutineVersion(routineID: id, revision: (current?.revision ?? 0) + 1, createdAt: date,
                                     name: name, exercises: snapshots, categoryID: categoryID, groups: normalized.isEmpty ? nil : normalized)
        try appendVersion(version, at: index)
        return version
    }

    func addRoutineCategory(_ category: RoutineCategory) throws {
        try requireName(category.name)
        let categories = records.routineCategories ?? []
        guard !categories.contains(where: { $0.name.compare(category.name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) else {
            throw TrainingDataError.conflictingRecord("A category with that name already exists.")
        }
        try commit { $0.routineCategories = categories + [category] }
    }

    @discardableResult
    func duplicateRoutine(versionID: UUID, at date: Date = Date()) throws -> RoutineVersion {
        guard let source = records.version(versionID) else { throw TrainingDataError.unknownRecord("This routine version could not be found.") }
        var slotIDs: [UUID: UUID] = [:]
        let exercises = source.exercises.map { entry in
            var copy = entry
            copy.id = UUID()
            slotIDs[entry.id] = copy.id
            return copy
        }
        let groups = source.groups?.map { group in
            var copy = group
            copy.id = UUID()
            copy.exerciseIDs = group.exerciseIDs.compactMap { slotIDs[$0] }
            return copy
        }
        let copy = RoutineVersion(routineID: UUID(), revision: 1, createdAt: date, name: "\(source.name) copy",
                                  exercises: exercises, categoryID: source.categoryID, groups: groups)
        try appendVersion(copy, at: nil)
        return copy
    }

    private func snapshots(for exercises: [PlannedExercise], prior: [PlannedExercise] = [], allowsUntargetedReps: Bool = false) throws -> [PlannedExercise] {
        guard !exercises.isEmpty, Set(exercises.map(\.id)).count == exercises.count else {
            throw TrainingDataError.invalidRecord("A routine needs at least one exercise and distinct prescription IDs.")
        }
        return try exercises.map { entry in
            let variant = entry.variant
            let existing = prior.first { $0.id == entry.id && $0.variant.key == variant.key }
            guard let exercise = existing?.variant.exercise ?? self.exercise(variant.exercise.id),
                  existing != nil || (variant.equipment.map(records.equipment.contains) ?? true) else {
                throw TrainingDataError.unknownRecord("Register the exercise and equipment before using them in a routine.")
            }
            guard variant.measurement.supports(variant.equipment), entry.allPrescriptions.allSatisfy({
                $0.isValid(for: variant.measurement, allowsUntargetedReps: allowsUntargetedReps)
            }) else {
                throw TrainingDataError.invalidRecord("The prescription and measurement must match the equipment and rep convention.")
            }
            return PlannedExercise(id: entry.id, variant: existing?.variant ?? ExerciseVariant(exercise: exercise,
                equipment: variant.equipment, measurement: variant.measurement), prescription: entry.prescription,
                warmUps: entry.warmUps, additionalWorkingSets: entry.additionalWorkingSets)
        }
    }

    private func appendVersion(_ version: RoutineVersion, at index: Int?) throws {
        try commit { next in
            next.routineVersions.append(version)
            if let index { next.routines[index].currentVersionID = version.id }
            else { next.routines.append(RoutineRecord(id: version.routineID, createdAt: version.createdAt, currentVersionID: version.id)) }
        }
    }

    func addProgramBlock(_ block: ProgramBlock) throws {
        try requireName(block.name)
        guard block.firstDay <= block.lastDay else {
            throw TrainingDataError.invalidRecord("A program block’s end date must follow or match its start date.")
        }
        try insert(block, at: \.programBlocks)
    }

    func addScheduledWorkout(_ workout: ScheduledWorkout) throws {
        guard records.version(workout.routineVersionID) != nil else {
            throw TrainingDataError.unknownRecord("Choose a saved routine version for the schedule.")
        }
        if let blockID = workout.programBlockID {
            guard let block = records.programBlocks.first(where: { $0.id == blockID }),
                  block.firstDay...block.lastDay ~= workout.localDate else {
                throw TrainingDataError.invalidRecord("The workout date must fall within its program block.")
            }
        }
        try insert(workout, at: \.schedule)
    }

    @discardableResult
    func startSession(versionID: UUID, scheduleID: UUID? = nil, at date: Date = Date(),
                      timeZone: TimeZone = .current) throws -> WorkoutSession {
        guard records.activeSession == nil else { throw TrainingDataError.activeSessionExists }
        guard let version = records.version(versionID) else {
            throw TrainingDataError.unknownRecord("Choose a saved routine version for the session.")
        }
        if let scheduleID {
            guard let entry = records.schedule.first(where: { $0.id == scheduleID && $0.routineVersionID == versionID }) else {
                throw TrainingDataError.unknownRecord("The scheduled workout must refer to this routine version.")
            }
            return try startScheduled(entry.id.uuidString, on: entry.localDate, at: date, timeZone: timeZone)
        }
        var session = WorkoutSession(localDate: WorkoutDate(date, timeZone: timeZone),
                                     timeZoneIdentifier: timeZone.identifier, startedAt: date,
                                     scheduleID: scheduleID, routineSnapshot: version)
        session.captureForecasts(in: records, at: date)
        try commit { $0.sessions.append(session) }
        return session
    }

    func saveSet(_ set: PerformedSet, in sessionID: UUID) throws {
        let index = try sessionIndex(sessionID)
        let session = records.sessions[index]
        guard session.completedAt == nil else { throw TrainingDataError.sessionFinished }
        guard let entry = session.plan.exercises.first(where: { $0.id == set.plannedExerciseID }),
              set.order > 0, set.recordedAt >= session.startedAt,
              entry.variant.measurement.accepts(set.amount),
              entry.variant.measurement.acceptsPerformed(reps: set.repetitions, rightAmount: set.rightAmount) else {
            throw TrainingDataError.invalidRecord("The performed set must match the session’s exercise, measurement, and rep convention.")
        }
        guard !session.performedSets.contains(where: {
            $0.id != set.id && $0.plannedExerciseID == set.plannedExerciseID && $0.order == set.order
        }) else { throw TrainingDataError.conflictingRecord("A set already occupies this position for the exercise.") }
        if let previous = session.performedSets.first(where: { $0.id == set.id }), previous.plannedExerciseID != set.plannedExerciseID {
            throw TrainingDataError.conflictingRecord("A completed set belongs to its original exercise.")
        }
        var updated = session
        if let existing = session.performedSets.firstIndex(where: { $0.id == set.id }) {
            updated.performedSets[existing] = set
        } else {
            updated.performedSets.append(set)
        }
        if var log = updated.workoutLog,
           let exercise = log.exercises.firstIndex(where: { $0.id == set.plannedExerciseID }) {
            let slot = log.exercises[exercise].rows.firstIndex(where: { $0.id == set.id }) ?? set.order - 1
            if log.exercises[exercise].rows.indices.contains(slot) {
                log.exercises[exercise].rows[slot].id = set.id
                log.exercises[exercise].rows[slot].status = .completed
            } else {
                log.exercises[exercise].rows.append(WorkoutSetRow(id: set.id, purpose: set.purpose ?? .working, status: .completed))
            }
            updated.workoutLog = log
            synchronizeResults(in: &updated)
        }
        updated.rememberForecastOutcomes()
        try commit { $0.sessions[index] = updated }
    }

    @discardableResult
    func repeatSession(_ sourceID: UUID, at date: Date = Date(), timeZone: TimeZone = .current) throws -> WorkoutSession {
        guard records.activeSession == nil else { throw TrainingDataError.activeSessionExists }
        let source = records.sessions[try sessionIndex(sourceID)]
        guard source.completedAt != nil else { throw TrainingDataError.invalidRecord("Choose a completed workout to repeat.") }
        var session = WorkoutSession(localDate: WorkoutDate(date, timeZone: timeZone), timeZoneIdentifier: timeZone.identifier,
                                     startedAt: date, scheduleID: nil, routineSnapshot: source.plan, referenceSessionID: source.id,
                                     workoutLog: source.workoutLog?.repeated(), routineUpdateBaseID: source.routineUpdateBaseID)
        session.captureForecasts(in: records, at: date)
        try commit { $0.sessions.append(session) }
        return session
    }

    func editSessionPlan(_ id: UUID, name: String, exercises: [PlannedExercise], groups: [RoutineGroup] = [], at date: Date = Date()) throws {
        try requireName(name)
        let index = try sessionIndex(id)
        let session = records.sessions[index]
        guard session.completedAt == nil else { throw TrainingDataError.sessionFinished }
        let prior = session.plan
        let snapshots = try snapshots(for: exercises, prior: prior.exercises, allowsUntargetedReps: true)
        let normalized = try RoutineGroup.normalized(groups, exercises: snapshots)
        for slot in Set(session.performedSets.map(\.plannedExerciseID)) {
            let previous = prior.exercises.first { $0.id == slot }
            let updated = snapshots.first { $0.id == slot }
            guard let previous, let updated, previous.variant.key == updated.variant.key else {
                throw TrainingDataError.invalidRecord("Keep the exercise and measurement for sets already logged in this workout.")
            }
        }
        let plan = RoutineVersion(id: prior.id, routineID: prior.routineID, revision: prior.revision,
                                  createdAt: prior.createdAt, name: name, exercises: snapshots,
                                  categoryID: prior.categoryID, groups: normalized.isEmpty ? nil : normalized)
        var updated = session
        updated.sessionPlan = plan == session.routineSnapshot ? nil : plan
        if let log = session.workoutLog {
            let exercises = try snapshots.map { entry in
                guard var existing = log.exercises.first(where: { $0.id == entry.id }) else { return try WorkoutExerciseLog(entry: entry) }
                let old = prior.exercises.first { $0.id == entry.id }
                if old?.variant.key != entry.variant.key {
                    let replacement = try WorkoutExerciseLog(entry: entry)
                    existing.rows = replacement.rows
                } else if old?.allPrescriptions != entry.allPrescriptions || old?.warmUps != entry.warmUps {
                    let planned = try WorkoutExerciseLog(entry: entry).rows
                    var remaining = planned[...]
                    existing.rows = existing.rows.compactMap { row in
                        let replacement = remaining.popFirst()
                        return row.status != .pending || row.input != nil ? row : replacement
                    } + Array(remaining)
                }
                return existing
            }
            updated.workoutLog?.exercises = exercises
            updated.workoutLog?.undo = nil
            synchronizeResults(in: &updated)
        }
        updated.captureForecasts(in: records, at: date)
        try commit { $0.sessions[index] = updated }
    }

    func finishSession(_ id: UUID, early: Bool = false, at date: Date = Date()) throws {
        let index = try sessionIndex(id)
        let session = records.sessions[index]
        if session.completedAt != nil { return }
        guard date >= session.startedAt, session.performedSets.allSatisfy({ $0.recordedAt <= date }) else {
            throw TrainingDataError.invalidRecord("The finish time must follow the start and all recorded sets.")
        }
        let unfinished = session.workoutLog?.exercises.contains { exercise in
            exercise.rows.contains { $0.status == .pending }
        } == true
        try commit {
            $0.sessions[index].completedAt = date
            $0.sessions[index].forecastEvidenceAt = date
            $0.sessions[index].endedEarly = early || unfinished ? true : nil
            $0.sessions[index].workoutLog?.rest = nil
            $0.sessions[index].workoutLog?.undo = nil
        }
    }

    func saveBodyweight(_ mass: Mass, on day: WorkoutDate, at date: Date = Date()) throws {
        guard mass.kilograms > 0 else { throw TrainingDataError.invalidRecord("Bodyweight must be greater than zero.") }
        try commit { next in
            if let index = next.bodyweightEntries.firstIndex(where: { $0.localDate == day }) {
                next.bodyweightEntries[index].mass = mass
                next.bodyweightEntries[index].updatedAt = date
            } else {
                next.bodyweightEntries.append(BodyweightEntry(localDate: day, createdAt: date, updatedAt: date, mass: mass))
            }
        }
    }

    func addReadinessCheckIn(_ checkIn: ReadinessCheckIn) throws {
        let ratings = [checkIn.energy, checkIn.soreness] + [checkIn.sleepQuality, checkIn.motivation].compactMap { $0 }
        guard ratings.allSatisfy({ (1...5).contains($0) }), (checkIn.sleepMinutes ?? 0) >= 0 else {
            throw TrainingDataError.invalidRecord("Use ratings from 1 to 5 and nonnegative sleep minutes.")
        }
        try insert(checkIn, at: \.readiness)
    }

    func addPhotoReference(_ reference: DevicePhotoReference) throws {
        guard reference.location.isValid else {
            throw TrainingDataError.invalidRecord("Use a Photos library identifier or a relative path in Setline’s local storage.")
        }
        let subjectExists: Bool = switch reference.subject {
        case nil: true
        case .exercise(let id): records.exercises.contains { $0.id == id }
        case .session(let id): records.sessions.contains { $0.id == id }
        case .bodyweight(let id): records.bodyweightEntries.contains { $0.id == id }
        }
        guard subjectExists else { throw TrainingDataError.unknownRecord("Choose an existing record to attach this photo.") }
        try insert(reference, at: \.photos)
    }

    func addPrediction(_ prediction: FuturePrediction) throws {
        let key = prediction.variant
        let variantExists = records.routineVersions.contains { version in
            version.exercises.contains { $0.variant.key == key }
        }
        guard variantExists, !prediction.sourceSessionIDs.isEmpty,
              Set(prediction.sourceSessionIDs).count == prediction.sourceSessionIDs.count,
              prediction.sourceSessionIDs.allSatisfy({ hasResults(for: key, in: $0) }),
              prediction.amount != nil || prediction.reps != nil,
              prediction.amount == nil || key.measurement.accepts(prediction.amount),
              prediction.reps == nil || (key.measurement.repCounting != nil && prediction.reps?.isValid == true) else {
            throw TrainingDataError.invalidRecord("A prediction needs a compatible target and completed results for the same exercise variant.")
        }
        try insert(prediction, at: \.predictions)
    }

    private func hasResults(for key: ExerciseVariantKey, in id: UUID) -> Bool {
        guard let session = records.sessions.first(where: { $0.id == id && $0.completedAt != nil }) else { return false }
        let plannedIDs = Set(session.plan.exercises.filter { $0.variant.key == key }.map(\.id))
        return session.performedSets.contains { plannedIDs.contains($0.plannedExerciseID) }
    }

    private func sessionIndex(_ id: UUID) throws -> Int {
        guard let index = records.sessions.firstIndex(where: { $0.id == id }) else {
            throw TrainingDataError.unknownRecord("This workout session could not be found.")
        }
        return index
    }

    private func requireName(_ name: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TrainingDataError.invalidRecord("Enter a name for the record.")
        }
    }

    private func insert<Record: Identifiable & Equatable>(_ record: Record, at path: WritableKeyPath<TrainingRecords, [Record]>) throws {
        if let existing = records[keyPath: path].first(where: { $0.id == record.id }) {
            guard existing == record else { throw TrainingDataError.conflictingRecord("This record ID is already in use.") }
            return
        }
        try commit { $0[keyPath: path].append(record) }
    }

    func commit(_ update: (inout TrainingRecords) -> Void) throws {
        var next = records
        update(&next)
        next.invalidateHistoryPredictions(comparedTo: records)
        try files.saveUserData(next)
        records = next
    }
}

extension TrainingRepository {
    @discardableResult
    func startEmptySession(at date: Date = Date(), timeZone: TimeZone = .current) throws -> WorkoutSession {
        guard records.activeSession == nil else { throw TrainingDataError.activeSessionExists }
        let plan = RoutineVersion(routineID: UUID(), revision: 0, createdAt: date, name: "Empty workout", exercises: [])
        var session = WorkoutSession(localDate: WorkoutDate(date, timeZone: timeZone), timeZoneIdentifier: timeZone.identifier,
                                     startedAt: date, scheduleID: nil, routineSnapshot: plan)
        session.workoutLog = try WorkoutLog(session: session)
        try commit { $0.sessions.append(session) }
        return session
    }

    func prepareWorkoutLog(_ id: UUID) throws {
        let index = try sessionIndex(id)
        let session = records.sessions[index]
        guard session.completedAt == nil else { throw TrainingDataError.sessionFinished }
        if session.workoutLog != nil { return }
        let log = try WorkoutLog(session: session)
        try commit { $0.sessions[index].workoutLog = log }
    }

    func changeWorkout(_ id: UUID, _ change: WorkoutLogChange, at date: Date = Date()) throws {
        let index = try sessionIndex(id)
        var session = records.sessions[index]
        guard session.completedAt == nil else { throw TrainingDataError.sessionFinished }
        session.rememberForecastOutcomes()
        var log = try session.workoutLog ?? WorkoutLog(session: session)
        let originalPlan = session.plan
        var exercises = originalPlan.exercises
        let times = session.workoutTimes(at: date, clock: log.clock)
        let previousUndo = log.undo
        if let label = change.undoLabel {
            log.undo = WorkoutUndo(label: label, exercises: log.exercises, results: session.performedSets,
                                  plan: session.sessionPlan, rest: log.rest)
        } else {
            switch change {
            case .undoLast, .pause, .resume, .trackRest, .loadProfile, .sessionNotes: break
            case .extendRest, .restartRest:
                if previousUndo?.label != "set completion" { log.undo = nil }
            default: log.undo = nil
            }
        }
        func exerciseIndex(_ id: UUID) throws -> Int {
            guard let position = log.exercises.firstIndex(where: { $0.id == id }) else {
                throw TrainingDataError.unknownRecord("This exercise is no longer in the workout.")
            }
            return position
        }
        func setIndex(_ id: UUID, in position: Int) throws -> Int {
            guard let row = log.exercises[position].rows.firstIndex(where: { $0.id == id }) else {
                throw TrainingDataError.unknownRecord("This set is no longer in the workout.")
            }
            return row
        }
        switch change {
        case .undoLast:
            guard let undo = previousUndo else { return }
            log.exercises = undo.exercises
            session.performedSets = undo.results
            session.sessionPlan = undo.plan
            log.rest = undo.rest
            log.undo = nil
        case .pause:
            guard log.clock?.pausedAt == nil else { return }
            log.clock = WorkoutClock(pausedAt: date, pausedSeconds: times.paused)
        case .resume:
            guard log.clock?.pausedAt != nil else { return }
            log.clock = WorkoutClock(pausedAt: nil, pausedSeconds: times.paused)
        case .trackRest(let enabled): log.trackRest = enabled
        case .extendRest:
            guard var rest = log.rest, log.clock?.pausedAt == nil else { return }
            let spent = times.active - rest.countdownActive
            rest.extensionSeconds = max(rest.extensionSeconds, spent - Double(rest.targetSeconds)) + 15
            log.rest = rest
        case .restartRest:
            guard var rest = log.rest, log.clock?.pausedAt == nil else { return }
            rest.countdownStartedAt = date
            rest.countdownActive = times.active
            rest.extensionSeconds = 0
            log.rest = rest
        case .skipRest:
            guard log.rest != nil else { return }
            log.closeRest(results: &session.performedSets, at: date, active: times.active, reason: "skipped")
        case .editRest(let row, let text):
            guard let result = session.performedSets.firstIndex(where: { $0.id == row }) else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            var rest = session.performedSets[result].actualRest ?? ActualWorkoutRest()
            if trimmed.isEmpty {
                rest.editedSeconds = nil
            } else {
                guard let value = Int(trimmed), value >= 0 else { throw TrainingDataError.invalidRecord("Enter actual rest in whole seconds.") }
                rest.editedSeconds = value
            }
            session.performedSets[result].actualRest = rest.measuredSeconds == nil && rest.editedSeconds == nil ? nil : rest
        case .loadProfile(let key, let profile):
            var profiles = log.loadProfiles ?? [:]
            profiles[key] = profile
            log.loadProfiles = profiles
        case .sessionNotes(let notes): log.notes = notes
        case .exerciseNotes(let id, let notes):
            let position = try exerciseIndex(id)
            log.exercises[position].notes = notes
        case .addExercise(let selected, let measurement, let equipment):
            guard let exercise = exercise(selected.id), equipment.map(records.equipment.contains) ?? true,
                  measurement.supports(equipment) else { throw TrainingDataError.invalidRecord("Choose compatible exercise equipment.") }
            let entry = PlannedExercise(variant: ExerciseVariant(exercise: exercise, equipment: equipment, measurement: measurement),
                                        prescription: SetPrescription(sets: 1))
            exercises.append(entry)
            var item = try WorkoutExerciseLog(entry: entry)
            item.rows[0].prescription = nil
            log.exercises.append(item)
        case .removeExercise(let id):
            let position = try exerciseIndex(id)
            if log.exercises[position].rows.contains(where: { $0.id == log.rest?.setID }) { log.rest = nil }
            log.exercises.remove(at: position)
            exercises.removeAll { $0.id == id }
        case .moveExercise(let id, let direction):
            guard direction == -1 || direction == 1 else { return }
            let from = try exerciseIndex(id)
            let to = from + direction
            guard log.exercises.indices.contains(to) else { return }
            log.exercises.swapAt(from, to)
            let lookup = Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, $0) })
            exercises = log.exercises.compactMap { lookup[$0.id] }
        case .queue(let id, let queued):
            let position = try exerciseIndex(id)
            log.exercises[position].queued = queued
            log.exercises[position].queuedAt = queued ? date : nil
        case .skipExercise(let id), .restoreExercise(let id):
            let position = try exerciseIndex(id)
            let skipping: Bool
            if case .skipExercise = change { skipping = true } else { skipping = false }
            log.exercises[position].queued = false
            log.exercises[position].queuedAt = nil
            for row in log.exercises[position].rows.indices {
                if log.exercises[position].rows[row].status == (skipping ? .pending : .skipped) {
                    log.exercises[position].rows[row].status = skipping ? .skipped : .pending
                }
            }
        case .addSet(let id, let purpose):
            let position = try exerciseIndex(id)
            log.exercises[position].rows.append(WorkoutSetRow(purpose: purpose))
        case .removeSet(let id, let row):
            let position = try exerciseIndex(id)
            let slot = try setIndex(row, in: position)
            if log.rest?.setID == row { log.rest = nil }
            log.exercises[position].rows.remove(at: slot)
        case .moveSet(let id, let row, let direction):
            guard direction == -1 || direction == 1 else { return }
            let position = try exerciseIndex(id)
            let from = try setIndex(row, in: position)
            let to = from + direction
            guard log.exercises[position].rows.indices.contains(to) else { return }
            log.exercises[position].rows.swapAt(from, to)
        case .editSet(let id, let row, let input):
            let position = try exerciseIndex(id)
            let slot = try setIndex(row, in: position)
            guard log.exercises[position].rows[slot].status == .pending else { return }
            log.exercises[position].rows[slot].input = input
        case .setSkipped(let id, let row, let skipped):
            let position = try exerciseIndex(id)
            let slot = try setIndex(row, in: position)
            guard log.exercises[position].rows[slot].status != .completed else { return }
            log.exercises[position].rows[slot].status = skipped ? .skipped : .pending
        case .undo(let id, let row):
            let position = try exerciseIndex(id)
            let slot = try setIndex(row, in: position)
            guard log.exercises[position].rows[slot].status == .completed else { return }
            if log.exercises[position].rows[slot].input == nil, let result = session.performedSets.first(where: { $0.id == row }) {
                log.exercises[position].rows[slot].input = WorkoutSetInput(result: result)
            }
            if previousUndo?.label == "set completion", log.rest?.setID == row, let previousUndo {
                session.performedSets = previousUndo.results
                log.rest = previousUndo.rest
            } else if log.rest?.setID == row {
                log.rest = nil
            }
            log.exercises[position].rows[slot].status = .pending
        case .complete(let id, let row, let unit):
            let position = try exerciseIndex(id)
            let slot = try setIndex(row, in: position)
            let set = log.exercises[position].rows[slot]
            guard set.status == .pending, !log.exercises[position].queued else { return }
            guard log.clock?.pausedAt == nil else { throw TrainingDataError.invalidRecord("Resume the workout before completing a set.") }
            guard let measurement = exercises.first(where: { $0.id == id })?.variant.measurement else {
                throw TrainingDataError.unknownRecord("This exercise is no longer in the workout.")
            }
            let input = set.input ?? WorkoutSetInput(unit: unit, prescription: set.prescription)
            let amount = try input.performedAmount(for: measurement)
            let reps = try input.repetitions(for: measurement)
            let rightAmount = try input.performedRightAmount(for: measurement, reps: reps)
            let effort = try input.efforts()
            guard measurement.accepts(amount), measurement.acceptsPerformed(reps: reps, rightAmount: rightAmount),
                  date >= session.startedAt else {
                throw TrainingDataError.invalidRecord("Enter valid performance values before completing this set.")
            }
            log.closeRest(results: &session.performedSets, at: date, active: times.active, reason: "nextSet")
            session.performedSets.append(PerformedSet(id: row, plannedExerciseID: id, order: slot + 1, repetitions: reps,
                amount: amount, recordedAt: date, effortOutcome: input.failure ? .failure : nil, purpose: set.purpose,
                structure: set.prescription?.structure, amrap: set.prescription?.amrap, actualRIR: effort.rir, actualRPE: effort.rpe, rightAmount: rightAmount))
            log.exercises[position].rows[slot].input = input
            log.exercises[position].rows[slot].status = .completed
            log.openRest(for: set, groups: originalPlan.groups ?? [], at: date, active: times.active)
        }
        if exercises != originalPlan.exercises {
            let groups = (originalPlan.groups ?? []).compactMap { group in
                (try? RoutineGroup.normalized([group], exercises: exercises))?.first
            }
            session.sessionPlan = RoutineVersion(id: originalPlan.id, routineID: originalPlan.routineID,
                revision: originalPlan.revision, createdAt: originalPlan.createdAt, name: originalPlan.name,
                exercises: exercises, categoryID: originalPlan.categoryID, groups: groups.isEmpty ? nil : groups)
        }
        session.workoutLog = log
        synchronizeResults(in: &session)
        session.rememberForecastOutcomes()
        switch change {
        case .addExercise, .removeExercise, .moveExercise, .moveSet, .removeSet, .setSkipped, .skipExercise, .restoreExercise, .undoLast:
            session.captureForecasts(in: records, at: date)
        default: break
        }
        if session != records.sessions[index] { try commit { $0.sessions[index] = session } }
    }

    @discardableResult
    func updateRoutineFromWorkout(_ id: UUID, at date: Date = Date()) throws -> RoutineVersion {
        let sessionPosition = try sessionIndex(id)
        let session = records.sessions[sessionPosition]
        guard session.completedAt == nil else { throw TrainingDataError.sessionFinished }
        let plan = session.plan
        guard let routinePosition = records.routines.firstIndex(where: { $0.id == plan.routineID }),
              let current = records.version(records.routines[routinePosition].currentVersionID) else {
            throw TrainingDataError.unknownRecord("This workout has no linked routine.")
        }
        guard current.id == (session.routineUpdateBaseID ?? session.routineSnapshot.id) else {
            throw TrainingDataError.conflictingRecord("A newer routine version exists. Open Routines to edit it directly.")
        }
        let log = try session.workoutLog ?? WorkoutLog(session: session)
        let entries = try plan.exercises.map { entry in
            let rows = log.exercises.first { $0.id == entry.id }?.rows ?? []
            let warm = try routineBlocks(rows.filter { $0.purpose == .warmUp }, measurement: entry.variant.measurement)
            let work = try routineBlocks(rows.filter { $0.purpose == .working }, measurement: entry.variant.measurement)
            guard let first = work.first else { throw TrainingDataError.invalidRecord("Keep a working set for \(entry.variant.exercise.name) before updating the routine.") }
            return PlannedExercise(id: entry.id, variant: entry.variant, prescription: first,
                warmUps: warm.isEmpty ? nil : warm, additionalWorkingSets: work.count > 1 ? Array(work.dropFirst()) : nil)
        }
        let snapshots = try snapshots(for: entries)
        let groups = try RoutineGroup.normalized(plan.groups ?? [], exercises: snapshots)
        if current.exercises == snapshots, (current.groups ?? []) == groups { return current }
        let updated = RoutineVersion(routineID: current.routineID, revision: current.revision + 1, createdAt: date,
            name: current.name, exercises: snapshots, categoryID: current.categoryID, groups: groups.isEmpty ? nil : groups)
        try commit { records in
            records.routineVersions.append(updated)
            records.routines[routinePosition].currentVersionID = updated.id
            records.sessions[sessionPosition].routineUpdateBaseID = updated.id
        }
        return updated
    }

    private func routineBlocks(_ rows: [WorkoutSetRow], measurement: Measurement) throws -> [SetPrescription] {
        var blocks: [SetPrescription] = []
        for row in rows {
            var prescription = row.prescription ?? SetPrescription(sets: 1)
            prescription.sets = 1
            if let input = row.input {
                let prefill = WorkoutSetInput(unit: input.unit, prescription: row.prescription)
                if input.amount != prefill.amount, !input.amount.isEmpty { prescription.target = try input.performedAmount(for: measurement) }
                if input.reps != prefill.reps || input.rightReps != prefill.rightReps {
                    switch try input.repetitions(for: measurement) {
                    case .total(let count), .perSide(let count): prescription.reps = RepRange(minimum: count, maximum: count)
                    case .separateSides(let left, let right):
                        let maximum = max(left, right)
                        prescription.reps = RepRange(minimum: min(left, right) > 0 ? min(left, right) : maximum, maximum: maximum)
                    case nil: break
                    }
                }
            }
            guard prescription.isValid(for: measurement) else {
                throw TrainingDataError.invalidRecord("Enter valid targets for added sets, or remove them before updating the routine.")
            }
            if var previous = blocks.last {
                let count = previous.sets
                previous.sets = 1
                if previous == prescription {
                    blocks[blocks.count - 1].sets = count + 1
                    continue
                }
            }
            blocks.append(prescription)
        }
        return blocks
    }

    private func synchronizeResults(in session: inout WorkoutSession) {
        guard let log = session.workoutLog else { return }
        let lookup = Dictionary(uniqueKeysWithValues: session.performedSets.map { ($0.id, $0) })
        session.performedSets = log.exercises.flatMap { exercise in
            exercise.rows.enumerated().compactMap { index, row -> PerformedSet? in
                guard row.status == .completed, var result = lookup[row.id] else { return nil }
                result.order = index + 1
                return result
            }
        }
    }
}
