import Foundation

enum WorkoutEntryRoute: Equatable, Sendable {
    case active
    case scheduled(WorkoutDate)

    init?(_ url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "setline", parts.host == "workout", parts.user == nil,
              parts.password == nil, parts.port == nil, parts.query == nil, parts.fragment == nil else { return nil }
        if parts.percentEncodedPath == "/active" {
            self = .active
        } else if parts.percentEncodedPath.hasPrefix("/scheduled/"),
                  let day = WorkoutDate(String(parts.percentEncodedPath.dropFirst("/scheduled/".count))) {
            self = .scheduled(day)
        } else {
            return nil
        }
    }

    var url: URL {
        var parts = URLComponents()
        parts.scheme = "setline"
        parts.host = "workout"
        switch self {
        case .active: parts.path = "/active"
        case .scheduled(let day): parts.path = "/scheduled/\(day.key)"
        }
        return parts.url!
    }
}

struct WorkoutCompanionCursor: Codable, Hashable, Sendable {
    var streamID = UUID()
    var revision: UInt64 = 0

    func advanced() -> Self {
        guard revision < UInt64.max else { return Self() }
        return Self(streamID: streamID, revision: revision + 1)
    }
}

struct WorkoutCompanionTimer: Codable, Hashable, Sendable {
    let deadline: Date?
    let pausedSecondsRemaining: Int?

    init(rest: WorkoutRest, active: TimeInterval, paused: Bool, now: Date) {
        let remaining = Double(rest.targetSeconds) + rest.extensionSeconds - (active - rest.countdownActive)
        deadline = paused ? nil : now.addingTimeInterval(remaining)
        pausedSecondsRemaining = paused ? rest.remaining(active: active) : nil
    }
}

struct WorkoutCompanionSet: Codable, Equatable, Identifiable {
    let exerciseID: UUID
    let exerciseName: String
    let measurement: Measurement
    let row: WorkoutSetRow
    let queued: Bool

    var id: UUID { row.id }
}

struct WorkoutCompanionWorkout: Codable, Equatable {
    let id: UUID
    let name: String
    let startedAt: Date
    let paused: Bool
    let rows: [WorkoutCompanionSet]
    let timer: WorkoutCompanionTimer?

    var nextSet: WorkoutCompanionSet? { rows.first { !$0.queued && $0.row.status == .pending } }
    var completedSets: Int { rows.filter { $0.row.status == .completed }.count }
    var pendingSets: Int { rows.filter { $0.row.status == .pending }.count }

    init(session: WorkoutSession, log: WorkoutLog, now: Date) {
        id = session.id
        name = session.plan.name
        startedAt = session.startedAt
        let isPaused = log.clock?.pausedAt != nil
        paused = isPaused
        let times = session.workoutTimes(at: now, clock: log.clock)
        timer = log.rest.map { WorkoutCompanionTimer(rest: $0, active: times.active, paused: isPaused, now: now) }
        let entries = Dictionary(uniqueKeysWithValues: session.plan.exercises.map { ($0.id, $0.variant) })
        let sequence = log.sequence(groups: session.plan.groups ?? [])
        let ordered = sequence.compactMap { item -> WorkoutCompanionSet? in
            guard let variant = entries[item.exerciseID] else { return nil }
            return WorkoutCompanionSet(exerciseID: item.exerciseID, exerciseName: variant.exercise.name,
                                       measurement: variant.measurement, row: item.row, queued: false)
        }
        let queued = log.exercises.filter(\.queued).flatMap { exercise -> [WorkoutCompanionSet] in
            guard let variant = entries[exercise.id] else { return [] }
            return exercise.rows.map {
                WorkoutCompanionSet(exerciseID: exercise.id, exerciseName: variant.exercise.name,
                                    measurement: variant.measurement, row: $0, queued: true)
            }
        }
        rows = ordered + queued
    }
}

struct WorkoutCompanionState: Codable, Equatable {
    static let version = 1
    var protocolVersion = WorkoutCompanionState.version
    let cursor: WorkoutCompanionCursor
    let workout: WorkoutCompanionWorkout?
}

enum WorkoutRestAction: String, Codable, CaseIterable {
    case extend, skip, restart

    var change: WorkoutLogChange {
        switch self {
        case .extend: .extendRest
        case .skip: .skipRest
        case .restart: .restartRest
        }
    }
}

struct WorkoutCompanionCommand: Codable, Equatable, Identifiable {
    enum Action: Codable, Equatable {
        case completeSet(exerciseID: UUID, setID: UUID, input: WorkoutSetInput)
        case rest(WorkoutRestAction)
        case finish(early: Bool)
    }

    var protocolVersion = WorkoutCompanionState.version
    var id = UUID()
    let sessionID: UUID
    let cursor: WorkoutCompanionCursor
    let action: Action
}

struct WorkoutCompanionReply: Codable, Equatable {
    enum Outcome: String, Codable {
        case applied, alreadyApplied, outdated, workoutEnded, invalidAction, unsupportedVersion
    }

    let commandID: UUID
    let outcome: Outcome
    let state: WorkoutCompanionState
}

// The watch can persist this value atomically before sending and after receiving a reply.
// Only one command can rely on a given confirmed state.
struct WorkoutCompanionOutbox: Codable, Equatable {
    private(set) var state: WorkoutCompanionState? = nil
    private(set) var pending: WorkoutCompanionCommand? = nil

    mutating func observe(_ incoming: WorkoutCompanionState, freshConnection: Bool = false) {
        guard incoming.protocolVersion == WorkoutCompanionState.version else { return }
        if let state {
            if incoming.cursor.streamID == state.cursor.streamID {
                guard incoming.cursor.revision >= state.cursor.revision else { return }
            } else {
                guard freshConnection else { return }
            }
        }
        state = incoming
    }

    mutating func enqueue(_ action: WorkoutCompanionCommand.Action) -> WorkoutCompanionCommand? {
        guard pending == nil, let state, let workout = state.workout else { return nil }
        let command = WorkoutCompanionCommand(sessionID: workout.id, cursor: state.cursor, action: action)
        pending = command
        return command
    }

    @discardableResult
    mutating func acknowledge(_ reply: WorkoutCompanionReply) -> WorkoutCompanionReply.Outcome? {
        guard pending?.id == reply.commandID else { return nil }
        observe(reply.state)
        pending = nil
        return reply.outcome
    }
}

// The WidgetKit adapter should use this projection and can build commands with these rest actions.
// Keep the richer watch snapshot out of ActivityKit content and attributes.
struct WorkoutLockScreenState: Codable, Hashable, Sendable {
    let sessionID: UUID
    let cursor: WorkoutCompanionCursor
    let paused: Bool
    let timer: WorkoutCompanionTimer?
    let routineName: String?
    let nextExerciseName: String?
    let completedSets: Int?

    init?(state: WorkoutCompanionState, showsDetails: Bool = false) {
        guard let workout = state.workout else { return nil }
        sessionID = workout.id
        cursor = state.cursor
        paused = workout.paused
        timer = workout.timer
        routineName = showsDetails ? Self.shortLabel(workout.name) : nil
        nextExerciseName = showsDetails ? workout.nextSet.map { Self.shortLabel($0.exerciseName) } : nil
        completedSets = showsDetails ? workout.completedSets : nil
    }

    var openURL: URL { WorkoutEntryRoute.active.url }

    func command(for action: WorkoutRestAction) -> WorkoutCompanionCommand? {
        guard !paused, timer != nil else { return nil }
        return WorkoutCompanionCommand(sessionID: sessionID, cursor: cursor, action: .rest(action))
    }

    private static func shortLabel(_ text: String) -> String {
        String(decoding: text.utf8.prefix(160), as: UTF8.self)
    }
}

extension TrainingRecords {
    mutating func clearCompanionState() {
        companionCursor = nil
        for index in sessions.indices { sessions[index].companionCommands = nil }
    }
}

extension WorkoutSession {
    mutating func recordCompanionCommand(_ id: UUID?) {
        guard let id else { return }
        var commands = companionCommands ?? []
        commands.insert(id)
        companionCommands = commands
    }
}

extension TrainingRepository {
    func companionState(at date: Date = Date()) throws -> WorkoutCompanionState {
        if let session = records.activeSession, session.workoutLog == nil { try prepareWorkoutLog(session.id) }
        if records.companionCursor == nil { try commit { $0.companionCursor = WorkoutCompanionCursor() } }
        let workout = records.activeSession.flatMap { session in
            session.workoutLog.map { WorkoutCompanionWorkout(session: session, log: $0, now: date) }
        }
        guard let cursor = records.companionCursor else { throw TrainingDataError.invalidRecord("Workout state is unavailable.") }
        return WorkoutCompanionState(cursor: cursor, workout: workout)
    }

    func receiveCompanionCommand(_ command: WorkoutCompanionCommand, at date: Date = Date()) throws -> WorkoutCompanionReply {
        let state = try companionState(at: date)
        func reply(_ outcome: WorkoutCompanionReply.Outcome, state: WorkoutCompanionState) -> WorkoutCompanionReply {
            WorkoutCompanionReply(commandID: command.id, outcome: outcome, state: state)
        }
        guard command.protocolVersion == WorkoutCompanionState.version else { return reply(.unsupportedVersion, state: state) }
        if records.sessions.first(where: { $0.id == command.sessionID })?.companionCommands?.contains(command.id) == true {
            return reply(.alreadyApplied, state: state)
        }
        guard let workout = state.workout, workout.id == command.sessionID,
              let session = records.activeSession else { return reply(.workoutEnded, state: state) }
        guard state.cursor == command.cursor else { return reply(.outdated, state: state) }
        let mostRecentSet = session.performedSets.map(\.recordedAt).max() ?? session.startedAt
        let effectiveDate = max(date, mostRecentSet, session.startedAt)
        do {
            switch command.action {
            case .completeSet(let exerciseID, let setID, let input):
                guard !workout.paused, workout.rows.contains(where: {
                    $0.exerciseID == exerciseID && $0.id == setID && $0.row.status == .pending && !$0.queued
                }) else { return reply(.invalidAction, state: state) }
                try changeWorkout(session.id, .complete(exerciseID, setID, input.unit), at: effectiveDate,
                                  completionInput: input, companionCommand: command.id)
            case .rest(let action):
                guard !workout.paused, workout.timer != nil else { return reply(.invalidAction, state: state) }
                try changeWorkout(session.id, action.change, at: effectiveDate, companionCommand: command.id)
            case .finish(let early):
                guard early || workout.pendingSets == 0 else { return reply(.invalidAction, state: state) }
                try finishSession(session.id, early: early, at: effectiveDate, companionCommand: command.id)
            }
        } catch is TrainingDataError {
            return reply(.invalidAction, state: state)
        }
        return reply(.applied, state: try companionState(at: effectiveDate))
    }
}
