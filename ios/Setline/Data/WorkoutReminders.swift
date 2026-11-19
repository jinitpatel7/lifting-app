import Foundation

struct WorkoutReminderPreferences: Codable, Equatable {
    var weekdays = false
    var rotations = false
    var hour = 18
    var minute = 0

    var enabled: Bool { weekdays || rotations }
}

struct WorkoutReminder: Equatable, Identifiable {
    static let identifierPrefix = "setline.workout.reminder."
    static let routeKey = "setlineWorkoutRoute"
    let id: String
    let day: WorkoutDate
    let fireAt: Date
    let localTime: DateComponents

    var route: WorkoutEntryRoute { .scheduled(day) }
}

enum WorkoutReminderPlanner {
    static func upcoming(in records: TrainingRecords, preferences: WorkoutReminderPreferences,
                         now: Date, timeZone: TimeZone = .current) -> [WorkoutReminder] {
        guard preferences.enabled, (0..<24).contains(preferences.hour), (0..<60).contains(preferences.minute) else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start = calendar.startOfDay(for: now)
        let today = WorkoutDate(now, timeZone: timeZone)
        var starts = [WorkoutDate: Date]()
        for offset in 0..<14 {
            if let date = calendar.date(byAdding: .day, value: offset, to: start) {
                starts[WorkoutDate(date, timeZone: timeZone)] = calendar.startOfDay(for: date)
            }
        }
        let slots = records.scheduled(on: Array(starts.keys), today: today)
        var reminders: [WorkoutReminder] = []
        var includedDays = Set<WorkoutDate>()
        let time = DateComponents(hour: preferences.hour, minute: preferences.minute, second: 0)
        for slot in slots {
            guard slot.status == .planned || slot.status == .rescheduled else { continue }
            let source = slot.record?.sourceKey ?? slot.id
            let weekday = preferences.weekdays && source.hasPrefix("weekday:")
            let rotation = preferences.rotations && (slot.rotationID != nil || source.hasPrefix("rotation:"))
            guard weekday || rotation, let localStart = starts[slot.date],
                  let fireAt = calendar.nextDate(after: localStart.addingTimeInterval(-1), matching: time,
                      matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward),
                  fireAt > now, WorkoutDate(fireAt, timeZone: timeZone) == slot.date,
                  includedDays.insert(slot.date).inserted else { continue }
            var localTime = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fireAt)
            localTime.calendar = calendar
            localTime.timeZone = timeZone
            reminders.append(WorkoutReminder(id: WorkoutReminder.identifierPrefix + slot.date.key,
                day: slot.date, fireAt: fireAt, localTime: localTime))
        }
        return reminders
    }
}
