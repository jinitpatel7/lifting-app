import Foundation

enum TrainingWeekday: Int, CaseIterable, Identifiable, Codable {
    case sunday = 1, monday, tuesday, wednesday, thursday, friday, saturday
    var id: Self { self }
    var label: String { Calendar.current.weekdaySymbols[rawValue - 1] }
}

struct ScheduleSettings: Codable, Equatable {
    enum ViewMode: String, CaseIterable, Identifiable, Codable {
        case week = "Training week", rolling = "Rolling seven days"
        var id: Self { self }
    }
    var weekStart: TrainingWeekday = .monday
    var mode: ViewMode = .week

    func dates(around anchor: WorkoutDate) -> [WorkoutDate] {
        let offset = mode == .rolling ? 0 : (anchor.weekday.rawValue - weekStart.rawValue + 7) % 7
        return (0..<7).map { anchor.offset($0 - offset) }
    }
}

extension WorkoutDate {
    private static var dayCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }

    var calendarDate: Date { (try? Self.format.parse(key)) ?? .distantPast }
    var weekday: TrainingWeekday { TrainingWeekday(rawValue: Self.dayCalendar.component(.weekday, from: calendarDate)) ?? .monday }

    func offset(_ count: Int) -> Self {
        guard let shifted = Self.dayCalendar.date(byAdding: .day, value: count, to: calendarDate) else { return self }
        return WorkoutDate(shifted, timeZone: .gmt)
    }

    func distance(to day: WorkoutDate) -> Int {
        Self.dayCalendar.dateComponents([.day], from: calendarDate, to: day.calendarDate).day ?? 0
    }
}

struct WeekdayAssignment: Codable, Equatable, Identifiable {
    var id = UUID()
    let weekday: TrainingWeekday
    let versionID: UUID
    let start: WorkoutDate
    var endBefore: WorkoutDate? = nil
}

struct RoutineRotation: Codable, Equatable, Identifiable {
    var id = UUID()
    let start: WorkoutDate
    let interval: Int
    let versionIDs: [UUID]
    var endBefore: WorkoutDate? = nil
}

enum ProgramWeekKind: String, CaseIterable, Identifiable, Codable {
    case training = "Training", progression = "Progression", deload = "Deload"
    var id: Self { self }
}

struct ProgramWeek: Codable, Equatable {
    var kind: ProgramWeekKind = .training
    var notes = ""
}

extension ProgramBlock {
    var weekCount: Int { firstDay.distance(to: lastDay) / 7 + 1 }
    func weekIndex(for day: WorkoutDate) -> Int { max(0, firstDay.distance(to: day) / 7) }
}

enum ScheduleStatus: String {
    case planned = "Planned", completed = "Completed", active = "In progress", skipped = "Skipped",
         missed = "Missed", rescheduled = "Rescheduled", moved = "Moved"
}

struct ScheduleOccurrence: Identifiable {
    let id: String
    let date: WorkoutDate
    let versionID: UUID
    let status: ScheduleStatus
    var record: ScheduledWorkout? = nil
    var rotationID: UUID? = nil

    var canChange: Bool {
        status == .planned || status == .rescheduled || (status == .missed && rotationID == nil)
    }
}

extension TrainingRecords {
    func scheduled(on days: [WorkoutDate], today: WorkoutDate) -> [ScheduleOccurrence] {
        let dates = Set(days)
        let occupied = Set(schedule.compactMap(\.sourceKey))
        var result: [ScheduleOccurrence] = []
        func disposition(_ entry: ScheduledWorkout) -> ScheduleStatus {
            if let session = sessions.first(where: { $0.scheduleID == entry.id }) { return session.completedAt == nil ? .active : .completed }
            if entry.skippedOn != nil { return .skipped }
            if entry.localDate < today { return .missed }
            return entry.movedFrom?.isEmpty == false ? .rescheduled : .planned
        }
        for entry in schedule {
            if dates.contains(entry.localDate) {
                result.append(ScheduleOccurrence(id: entry.id.uuidString, date: entry.localDate, versionID: entry.routineVersionID,
                    status: disposition(entry), record: entry, rotationID: entry.rotationID))
            }
            for former in Set(entry.movedFrom ?? []) where dates.contains(former) && former != entry.localDate {
                result.append(ScheduleOccurrence(id: "\(entry.id.uuidString):moved:\(former.key)", date: former,
                    versionID: entry.routineVersionID, status: .moved, record: entry, rotationID: entry.rotationID))
            }
        }
        for rule in weekdayRules ?? [] {
            for day in dates where day >= rule.start && day.weekday == rule.weekday && (rule.endBefore.map { day < $0 } ?? true) {
                let key = "weekday:\(rule.id.uuidString):\(day.key)"
                if !occupied.contains(key) {
                    result.append(ScheduleOccurrence(id: key, date: day, versionID: rule.versionID, status: day < today ? .missed : .planned))
                }
            }
        }
        for rotation in rotations ?? [] where rotation.interval > 0 && !rotation.versionIDs.isEmpty {
            let entries = schedule.filter { $0.rotationID == rotation.id }
            let decisions: [WorkoutDate] = entries.compactMap { entry in
                if let skipped = entry.skippedOn { return max(entry.localDate, skipped) }
                guard let session = sessions.first(where: { $0.scheduleID == entry.id && !$0.performedSets.isEmpty }),
                      let completed = session.completedAt else { return nil }
                let zone = TimeZone(identifier: session.timeZoneIdentifier) ?? .gmt
                return max(entry.localDate, WorkoutDate(completed, timeZone: zone))
            }
            func cadence(onOrAfter start: WorkoutDate) -> WorkoutDate {
                let remainder = rotation.start.distance(to: start) % rotation.interval
                return start.offset(remainder == 0 ? 0 : rotation.interval - remainder)
            }
            var upcoming = cadence(onOrAfter: max(today, rotation.start))
            func key(_ day: WorkoutDate) -> String { "rotation:\(rotation.id.uuidString):\(day.key)" }
            func displacement(_ day: WorkoutDate) -> WorkoutDate? {
                entries.compactMap { entry -> WorkoutDate? in
                    guard let original = entry.movedFrom?.first, original <= day, day <= entry.localDate else { return nil }
                    return entry.localDate
                }.max()
            }
            while true {
                if let end = displacement(upcoming) { upcoming = cadence(onOrAfter: end.offset(1)) }
                else if occupied.contains(key(upcoming)) { upcoming = upcoming.offset(rotation.interval) }
                else { break }
            }
            let holdsNext = entries.contains { [.planned, .rescheduled, .active].contains(disposition($0)) }
            for day in dates {
                guard day >= rotation.start, (rotation.endBefore.map { day < $0 } ?? true),
                      rotation.start.distance(to: day) % rotation.interval == 0, !occupied.contains(key(day)),
                      day < today || (!holdsNext && day == upcoming) else { continue }
                if displacement(day) != nil { continue }
                let index = decisions.filter { $0 <= day }.count % rotation.versionIDs.count
                result.append(ScheduleOccurrence(id: key(day), date: day, versionID: rotation.versionIDs[index],
                    status: day < today ? .missed : .planned, rotationID: rotation.id))
            }
        }
        return result.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }
    }
}

struct MuscleTrainingDate {
    let date: WorkoutDate
    let days: Int
}

extension TrainingRecords {
    func recentMuscles(asOf day: WorkoutDate) -> [MuscleGroup: MuscleTrainingDate] {
        var recent: [MuscleGroup: MuscleTrainingDate] = [:]
        for session in sessions where session.localDate <= day {
            let logged = Set(session.performedSets.map(\.plannedExerciseID))
            for row in session.plan.exercises where logged.contains(row.id) {
                guard let profile = row.variant.exercise.profile ?? exercises.first(where: { $0.id == row.variant.exercise.id })?.profile else { continue }
                for muscle in profile.muscles {
                    if recent[muscle].map({ $0.date < session.localDate }) ?? true {
                        recent[muscle] = MuscleTrainingDate(date: session.localDate, days: session.localDate.distance(to: day))
                    }
                }
            }
        }
        return recent
    }
}

extension TrainingRepository {
    func saveScheduleSettings(_ settings: ScheduleSettings) throws {
        try commit { $0.scheduleSettings = settings }
    }

    func assignWeekday(_ assignment: WeekdayAssignment) throws {
        guard records.version(assignment.versionID) != nil else { throw TrainingDataError.unknownRecord("Choose a saved routine version.") }
        var rules = records.weekdayRules ?? []
        guard !rules.contains(where: { $0.weekday == assignment.weekday && $0.versionID == assignment.versionID && $0.endBefore == nil }) else { return }
        rules.append(assignment)
        try commit { $0.weekdayRules = rules }
    }

    func endWeekday(_ id: UUID, today: WorkoutDate) throws {
        var rules = records.weekdayRules ?? []
        guard let index = rules.firstIndex(where: { $0.id == id && $0.endBefore == nil }) else { return }
        rules[index].endBefore = today
        try commit { $0.weekdayRules = rules }
    }

    func saveRotation(_ rotation: RoutineRotation, today: WorkoutDate) throws {
        guard (1...30).contains(rotation.interval), !rotation.versionIDs.isEmpty,
              rotation.versionIDs.allSatisfy({ records.version($0) != nil }),
              !(records.rotations ?? []).contains(where: { $0.endBefore == nil && rotation.start < today }) else {
            throw TrainingDataError.invalidRecord("Choose an ordered sequence, a cadence of 1–30 days, and a valid start date.")
        }
        var rotations = records.rotations ?? []
        for index in rotations.indices where rotations[index].endBefore == nil { rotations[index].endBefore = today }
        rotations.append(rotation)
        try commit { $0.rotations = rotations }
    }

    func endRotation(_ id: UUID, today: WorkoutDate) throws {
        var rotations = records.rotations ?? []
        guard let index = rotations.firstIndex(where: { $0.id == id && $0.endBefore == nil }) else { return }
        rotations[index].endBefore = today
        try commit { $0.rotations = rotations }
    }

    private func editableSchedule(_ key: String, on day: WorkoutDate, today: WorkoutDate) throws -> ScheduledWorkout {
        guard let slot = records.scheduled(on: [day], today: today).first(where: { $0.id == key }), slot.canChange else {
            throw TrainingDataError.invalidRecord("This scheduled workout can no longer be changed. Open the current schedule.")
        }
        return slot.record ?? ScheduledWorkout(localDate: day, routineVersionID: slot.versionID, sourceKey: key, rotationID: slot.rotationID)
    }

    private func storeSchedule(_ entry: ScheduledWorkout, in records: inout TrainingRecords) {
        if let index = records.schedule.firstIndex(where: { $0.id == entry.id }) { records.schedule[index] = entry }
        else { records.schedule.append(entry) }
    }

    func moveSchedule(_ key: String, on day: WorkoutDate, to destination: WorkoutDate, today: WorkoutDate) throws {
        guard destination >= today, destination != day else { throw TrainingDataError.invalidRecord("Choose a different date, today or later.") }
        var entry = try editableSchedule(key, on: day, today: today)
        entry.movedFrom = (entry.movedFrom ?? []) + [entry.localDate]
        entry.localDate = destination
        try commit { next in storeSchedule(entry, in: &next) }
    }

    func skipSchedule(_ key: String, on day: WorkoutDate, today: WorkoutDate) throws {
        var entry = try editableSchedule(key, on: day, today: today)
        entry.skippedOn = today
        try commit { next in storeSchedule(entry, in: &next) }
    }

    @discardableResult
    func startScheduled(_ key: String, on day: WorkoutDate, at date: Date = Date(), timeZone: TimeZone = .current) throws -> WorkoutSession {
        guard records.activeSession == nil else { throw TrainingDataError.activeSessionExists }
        let today = WorkoutDate(date, timeZone: timeZone)
        let entry = try editableSchedule(key, on: day, today: today)
        guard entry.rotationID == nil || entry.localDate == today else {
            throw TrainingDataError.invalidRecord("Start the rotation on its scheduled date, or move it to today.")
        }
        guard let version = records.version(entry.routineVersionID) else { throw TrainingDataError.unknownRecord("Scheduled routine not found.") }
        var session = WorkoutSession(localDate: today, timeZoneIdentifier: timeZone.identifier, startedAt: date,
            scheduleID: entry.id, routineSnapshot: version)
        try commit { next in
            storeSchedule(entry, in: &next)
            session.captureForecasts(in: next, at: date)
            next.sessions.append(session)
        }
        return session
    }

    func setProgramWeek(blockID: UUID, index: Int, week: ProgramWeek) throws {
        guard let position = records.programBlocks.firstIndex(where: { $0.id == blockID }),
              (0..<records.programBlocks[position].weekCount).contains(index) else {
            throw TrainingDataError.invalidRecord("Choose a week within the program block.")
        }
        try commit { next in
            var weeks = next.programBlocks[position].weeks ?? [:]
            weeks[index] = week
            next.programBlocks[position].weeks = weeks
        }
    }

    func saveReadiness(on day: WorkoutDate, soreness: Int, sleep: Int, energy: Int, motivation: Int,
                       at date: Date = Date(), timeZone: TimeZone = .current) throws {
        guard day <= WorkoutDate(date, timeZone: timeZone), [soreness, sleep, energy, motivation].allSatisfy({ (1...5).contains($0) }) else {
            throw TrainingDataError.invalidRecord("Enter all four ratings from 1 to 5 on a local date through today.")
        }
        let prior = records.readiness.last { $0.localDate == day }
        let entry = ReadinessCheckIn(id: prior?.id ?? UUID(), localDate: day, energy: energy, soreness: soreness,
            sleepMinutes: prior?.sleepMinutes, recordedAt: date, sleepQuality: sleep, motivation: motivation)
        try commit { next in
            next.readiness.removeAll { $0.localDate == day }
            next.readiness.append(entry)
        }
    }
}
