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

    private func exercise(_ id: UUID) -> Exercise? {
        records.exercises.first { $0.id == id } ?? catalog.first { $0.id == id }
    }

    @discardableResult
    func saveRoutine(id: UUID = UUID(), name: String, exercises: [PlannedExercise], categoryID: UUID? = nil,
                     groups: [RoutineGroup] = [], expectedVersionID: UUID? = nil, at date: Date = Date()) throws -> RoutineVersion {
        try requireName(name)
        if let categoryID, records.routineCategories?.contains(where: { $0.id == categoryID }) != true {
            throw TrainingDataError.unknownRecord("Choose a saved routine category.")
        }
        let snapshots = try snapshots(for: exercises)
        let normalized = try RoutineGroup.normalized(groups, exercises: snapshots)
        let index = records.routines.firstIndex { $0.id == id }
        let current = index.flatMap { records.version(records.routines[$0].currentVersionID) }
        if let expectedVersionID, expectedVersionID != current?.id {
            throw TrainingDataError.conflictingRecord("This routine changed. Reopen it before saving an edit.")
        }
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

    private func snapshots(for exercises: [PlannedExercise], prior: [PlannedExercise] = []) throws -> [PlannedExercise] {
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
            guard variant.measurement.supports(variant.equipment), entry.allPrescriptions.allSatisfy({ $0.isValid(for: variant.measurement) }) else {
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
            guard records.schedule.contains(where: { $0.id == scheduleID && $0.routineVersionID == versionID }) else {
                throw TrainingDataError.unknownRecord("The scheduled workout must refer to this routine version.")
            }
        }
        let session = WorkoutSession(localDate: WorkoutDate(date, timeZone: timeZone),
                                     timeZoneIdentifier: timeZone.identifier, startedAt: date,
                                     scheduleID: scheduleID, routineSnapshot: version)
        try commit { $0.sessions.append(session) }
        return session
    }

    func saveSet(_ set: PerformedSet, in sessionID: UUID) throws {
        let index = try sessionIndex(sessionID)
        let session = records.sessions[index]
        guard session.completedAt == nil else { throw TrainingDataError.sessionFinished }
        guard let entry = session.plan.exercises.first(where: { $0.id == set.plannedExerciseID }),
              set.order > 0, set.recordedAt >= session.startedAt,
              entry.variant.measurement.accepts(set.amount), entry.variant.measurement.accepts(set.repetitions) else {
            throw TrainingDataError.invalidRecord("The performed set must match the session’s exercise, measurement, and rep convention.")
        }
        guard !session.performedSets.contains(where: {
            $0.id != set.id && $0.plannedExerciseID == set.plannedExerciseID && $0.order == set.order
        }) else { throw TrainingDataError.conflictingRecord("A set already occupies this position for the exercise.") }
        try commit { next in
            if let existing = session.performedSets.firstIndex(where: { $0.id == set.id }) {
                next.sessions[index].performedSets[existing] = set
            } else {
                next.sessions[index].performedSets.append(set)
            }
        }
    }

    @discardableResult
    func repeatSession(_ sourceID: UUID, at date: Date = Date(), timeZone: TimeZone = .current) throws -> WorkoutSession {
        guard records.activeSession == nil else { throw TrainingDataError.activeSessionExists }
        let source = records.sessions[try sessionIndex(sourceID)]
        guard source.completedAt != nil else { throw TrainingDataError.invalidRecord("Choose a completed workout to repeat.") }
        let session = WorkoutSession(localDate: WorkoutDate(date, timeZone: timeZone), timeZoneIdentifier: timeZone.identifier,
                                     startedAt: date, scheduleID: nil, routineSnapshot: source.plan, referenceSessionID: source.id)
        try commit { $0.sessions.append(session) }
        return session
    }

    func editSessionPlan(_ id: UUID, name: String, exercises: [PlannedExercise], groups: [RoutineGroup] = []) throws {
        try requireName(name)
        let index = try sessionIndex(id)
        let session = records.sessions[index]
        guard session.completedAt == nil else { throw TrainingDataError.sessionFinished }
        let prior = session.plan
        let snapshots = try snapshots(for: exercises, prior: prior.exercises)
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
        try commit { $0.sessions[index].sessionPlan = plan == session.routineSnapshot ? nil : plan }
    }

    func finishSession(_ id: UUID, at date: Date = Date()) throws {
        let index = try sessionIndex(id)
        let session = records.sessions[index]
        if session.completedAt != nil { return }
        guard date >= session.startedAt, session.performedSets.allSatisfy({ $0.recordedAt <= date }) else {
            throw TrainingDataError.invalidRecord("The finish time must follow the start and all recorded sets.")
        }
        try commit { $0.sessions[index].completedAt = date }
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
        guard (1...5).contains(checkIn.energy), (1...5).contains(checkIn.soreness), (checkIn.sleepMinutes ?? 0) >= 0 else {
            throw TrainingDataError.invalidRecord("Energy and soreness use a scale from 1 to 5, and sleep is measured in minutes.")
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

    private func commit(_ update: (inout TrainingRecords) -> Void) throws {
        var next = records
        update(&next)
        try files.saveUserData(next)
        records = next
    }
}
