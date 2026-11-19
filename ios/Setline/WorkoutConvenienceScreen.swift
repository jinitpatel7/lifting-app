import SwiftUI
import UIKit
import UserNotifications

@MainActor
final class WorkoutReminderCoordinator: ObservableObject {
    private static let preferenceKey = "workoutReminderPreferences"
    private static let fireDateKey = "setlineWorkoutFireDate"

    @Published var preferences: WorkoutReminderPreferences {
        didSet {
            if let bytes = try? JSONEncoder().encode(preferences) { defaults.set(bytes, forKey: Self.preferenceKey) }
        }
    }
    @Published private(set) var authorization: UNAuthorizationStatus?
    @Published private(set) var requestsPermission = false
    @Published private(set) var error: String?

    private let center = UNUserNotificationCenter.current()
    private let defaults: UserDefaults
    private var lastScheduled: [WorkoutReminder]?
    private var latestPlan: [WorkoutReminder] = []
    private var nextPlan: [WorkoutReminder]?
    private var isReconciling = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        preferences = defaults.data(forKey: Self.preferenceKey)
            .flatMap { try? JSONDecoder().decode(WorkoutReminderPreferences.self, from: $0) } ?? WorkoutReminderPreferences()
    }

    var permissionLabel: String {
        switch authorization {
        case nil: "Checking notification permission"
        case .notDetermined: "Notification permission needed"
        case .denied: "Notifications are off in iPhone Settings"
        case .provisional: "Quiet notifications allowed"
        case .authorized, .ephemeral: "Notifications allowed"
        @unknown default: "Notification permission unavailable"
        }
    }

    func requestPermission() async {
        guard authorization == .notDetermined, preferences.enabled, !requestsPermission else { return }
        requestsPermission = true
        defer { requestsPermission = false }
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound])
            queue(latestPlan, force: true)
        } catch {
            error = "Setline couldn’t request notification permission. Try again."
        }
    }

    func refresh(records: TrainingRecords, force: Bool = false) {
        latestPlan = WorkoutReminderPlanner.upcoming(in: records, preferences: preferences, now: Date())
        queue(latestPlan, force: force)
    }

    private func queue(_ plan: [WorkoutReminder], force: Bool) {
        if !force, !isReconciling, lastScheduled == plan { return }
        nextPlan = plan
        guard !isReconciling else { return }
        isReconciling = true
        Task {
            while let plan = nextPlan {
                nextPlan = nil
                await reconcile(plan)
            }
            isReconciling = false
        }
    }

    private func reconcile(_ plan: [WorkoutReminder]) async {
        let settings = await center.notificationSettings()
        authorization = settings.authorizationStatus
        let allowed = authorization == .authorized || authorization == .provisional || authorization == .ephemeral
        let desired = allowed ? plan.filter { $0.fireAt > Date() } : []
        let requested = await center.pendingNotificationRequests().filter { Self.owns($0.identifier) }
        let current = Dictionary(uniqueKeysWithValues: requested.map { ($0.identifier, $0) })
        let keep = Set(desired.map(\.id))
        let obsolete = current.keys.filter { !keep.contains($0) }
        if !obsolete.isEmpty { center.removePendingNotificationRequests(withIdentifiers: obsolete) }
        var issue: String?
        for reminder in desired {
            let timestamp = reminder.fireAt.timeIntervalSinceReferenceDate
            if let old = current[reminder.id],
               old.content.userInfo[Self.fireDateKey] as? Double == timestamp,
               old.content.userInfo[WorkoutReminder.routeKey] as? String == reminder.route.url.absoluteString { continue }
            let content = UNMutableNotificationContent()
            content.title = "Workout reminder"
            content.body = "A workout is on your schedule."
            content.sound = .default
            content.userInfo = [WorkoutReminder.routeKey: reminder.route.url.absoluteString, Self.fireDateKey: timestamp]
            let trigger = UNCalendarNotificationTrigger(dateMatching: reminder.localTime, repeats: false)
            do {
                try await center.add(UNNotificationRequest(identifier: reminder.id, content: content, trigger: trigger))
            } catch {
                center.removePendingNotificationRequests(withIdentifiers: [reminder.id])
                issue = "Some reminders couldn’t be scheduled. Reopen Setline to retry."
            }
        }
        let delivered = await center.deliveredNotifications().map { $0.request.identifier }
            .filter { Self.owns($0) && !keep.contains($0) }
        if !delivered.isEmpty { center.removeDeliveredNotifications(withIdentifiers: delivered) }
        error = issue
        lastScheduled = issue == nil ? plan : nil
    }

    nonisolated static func owns(_ identifier: String) -> Bool {
        identifier.hasPrefix(WorkoutReminder.identifierPrefix)
    }

    nonisolated static func route(for request: UNNotificationRequest) -> WorkoutEntryRoute? {
        guard owns(request.identifier), let value = request.content.userInfo[WorkoutReminder.routeKey] as? String,
              let url = URL(string: value), let route = WorkoutEntryRoute(url), case .scheduled = route else { return nil }
        return route
    }
}

@MainActor
final class WorkoutReminderAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate, ObservableObject {
    @Published var openedRoute: WorkoutEntryRoute?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let route = WorkoutReminderCoordinator.route(for: response.notification.request) else { return }
        await MainActor.run { self.openedRoute = route }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        WorkoutReminderCoordinator.owns(notification.request.identifier) ? [.banner, .list, .sound] : []
    }
}

struct WorkoutConvenienceSettings: View {
    @ObservedObject var reminders: WorkoutReminderCoordinator
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                IconTile(symbol: "bell", size: 32)
                CardHeading(title: "Workout reminders")
            }
            Toggle("Weekday routines", isOn: $reminders.preferences.weekdays).frame(minHeight: 44)
            Toggle("Rotating routines", isOn: $reminders.preferences.rotations).frame(minHeight: 44)
            if reminders.preferences.enabled {
                DatePicker("Reminder time", selection: time, displayedComponents: .hourAndMinute)
                    .environment(\.calendar, pickerCalendar)
                    .environment(\.timeZone, pickerCalendar.timeZone)
                    .frame(minHeight: 44)
                Text("Setline schedules up to 14 days ahead when it opens. Rotating routines use the next scheduled workout.")
                    .font(.caption).foregroundStyle(Palette.muted)
                Text(reminders.permissionLabel).font(.subheadline)
                if reminders.authorization == .notDetermined {
                    Button("Allow notifications") { Task { await reminders.requestPermission() } }
                        .buttonStyle(SecondaryButton()).disabled(reminders.requestsPermission)
                } else if reminders.authorization == .denied || reminders.authorization == .provisional {
                    Button("Open iPhone notification settings") {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                    }
                    .buttonStyle(SecondaryButton())
                }
                if let error = reminders.error {
                    Text(error).font(.caption).foregroundStyle(Palette.muted)
                }
            }
        }
        .tint(Palette.action)
        .padding(14).surface()
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                IconTile(symbol: "applewatch", size: 32)
                CardHeading(title: "Watch and Lock Screen")
            }
            Text("Apple Watch logging and Lock Screen Live Activities require companion targets. They’re unavailable in this build.")
                .font(.subheadline).foregroundStyle(Palette.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14).surface()
    }

    private var time: Binding<Date> {
        Binding {
            // Use a reference day in a fixed zone so the picker can edit any wall-clock time, including DST gaps.
            pickerCalendar.date(from: DateComponents(year: 2001, month: 1, day: 1,
                hour: reminders.preferences.hour, minute: reminders.preferences.minute)) ?? Date(timeIntervalSinceReferenceDate: 0)
        } set: { date in
            let components = pickerCalendar.dateComponents([.hour, .minute], from: date)
            guard let hour = components.hour, let minute = components.minute else { return }
            var next = reminders.preferences
            next.hour = hour
            next.minute = minute
            reminders.preferences = next
        }
    }

    private var pickerCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }
}
