# Setline

Setline is an offline iPhone-first training log for experienced lifters who plan their own workouts. The native app opens to personal data. Select **View sample data** to explore the sample week and workout preview.

Open **Routines → Exercise Library** to search the built-in catalog, add custom exercises, or browse substitutions. Tap a region on the Today muscle map to identify its muscles and open a filtered library.

Open **Routines → New routine** in personal mode to build a plan. Drag exercise rows to reorder them. The routine options contain **Edit routine**, **Duplicate routine**, and **Version history**. Use **History → Sessions → Repeat workout** to start from a completed plan and reference its recorded results.

Schedule a saved routine from **Routines** and start it on **Today**, or choose **Start empty workout**. Use the workout bar to return to the active session from any tab. **Complete set** records the displayed values, and **Undo completion** returns the set to pending. **End early** saves completed results alongside skipped and unfinished rows.

Use the bottom workout controls to jump to or complete the next set, pause the session, and manage rest. Turn on **Track actual rest** to save measured intervals. Open **Plate calculator** or **Equipment increment** on a pending set to configure the equipment available for load shortcuts. For per-side prescriptions, **Log left and right** opens separate result fields.

Open **Today → Training schedule** to set your week start, switch to a rolling seven-day view, assign weekdays, set a rotation, or build a program block. Mark each program week and assign the versions containing your targets. Use **Move session** or **Skip session** on the calendar. A rotation advances when you finish its session with recorded sets or explicitly skip it. A missed day holds your place.

Use **Readiness** for an optional daily check-in and **Recent training** on the muscle map to see when each muscle last had logged work.

Open **History → Sessions** for the calendar or chronological list. Use **Add missed workout** to record an earlier session, or **Edit workout** to correct completed results and notes. Choose **Compare sessions** to view two workouts side by side. Finishing a workout opens its summary before you return to the app.

Open **History → Progress** for exercise trends, records, and weekly set counts. Switch between working sets and warm-ups. **Analytics settings** controls visible metrics, weekly dashboard statistics, and the criteria for possible plateau flags.

**Weekly recap** summarizes the selected training week and separates scheduled completions, incomplete logs, and unscheduled work. Expand **Next scheduled workout** for planned targets and a separate forecast.

Expand **Workout score** at finish or in History to see the breakdown against the session’s saved working targets. **Settings → Workout score weights** defaults to 60 for prescribed work completed, 25 for targets met, and 15 for effort alignment. Available weights are normalized on each workout. Finishing an unplanned workout still shows the session summary.

Open **Calorie inputs** on a finished workout to choose an activity and enter its duration. A weigh-in on that workout’s date lets Setline show estimated gross calories using the Adult Compendium. [Compendium activity table](https://pacompendium.com/conditioning-exercise/)

Review recommendations at finish, on the scheduled workout, or in the active logger. **Review progression** in History or Routines also opens the exercise rules. The review shows the planned targets, actual results, and exact proposed change. Choose **Apply once** for the next matching routine start, **Update routine** to create a new version, or **Edit recommendation** before choosing a scope. **Dismiss** hides that suggestion until its evidence changes. Historical sessions and already scheduled versions retain their saved plans.

Open **Performance forecast preview** on a scheduled workout or a saved routine to see the expected range for the first straight working set of each exercise. Setline saves the issued forecast in the workout, where it remains available after corrections. **History → Progress → Forecast accuracy** compares the model with the previous comparable session. Forecasts describe expected performance and leave all routine targets under your control.

Log bodyweight from **Today**. In **History → Progress**, edit past readings, review the trailing seven-day average, or set an optional weekly target rate. **History → Sessions → Calendar** also offers weigh-in editing for the selected date.

Use **Add progress photos** after finishing a workout, or link photos from the selected date or workout in History. **Compare progress photos** shows two dates side by side. The iPhone app uses Photos to select originals or save a new camera photo. Setline keeps only the device references. Your personal iCloud Photos storage follows your own Photos sync settings. [Apple’s iCloud Photos documentation](https://support.apple.com/en-us/108782)

## Backups and sharing

Open **Settings → Data portability** to export workout CSV, bodyweight CSV, or a versioned full backup. Restore previews the file and replaces the local profile only after confirmation. Full backups restore in the client that created them. Routine files work across iPhone and browser, and equivalent imports keep a single copy. Use **Share routine** or **Share workout summary** to see what you are about to share.

Full backups and account saves have optional controls for notes, bodyweight, readiness, forecasts, and device-photo references. Photo files are excluded. References are off by default and may need relinking on another device. CSV uses kilograms, seconds, and meters, with separate columns for different kinds of load and side-specific results. Exported files contain readable data, so choose a private location for personal backups.

## Optional account storage

**Settings → Account storage** allows you to create an account or sign in, manually save or restore a backup, or delete the saved backup. Each account has a separate iPhone and browser snapshot. Accounts are optional. Sign-in sessions are held in memory by the clients.

The account service runs with the preview on Node.js 22.15 or later. It listens on loopback and defaults to `.setline-data` for its SQLite database and backup encryption key. Set `SETLINE_DATA_DIR` to a private persistent directory for long-lived use. An optional `SETLINE_BACKUP_KEY` supplies a stable 32-byte key as 64 hexadecimal characters. Keep the key with secure server backups so saved records remain readable.

For access from an iPhone or another device, serve the loopback app through an HTTPS reverse proxy and set `SETLINE_PUBLIC_ORIGIN` to its public HTTPS origin. Enter that same HTTPS address in the iPhone account screen. No hosted service ships with the workspace. The account service uses password sign-in and has no password recovery flow.

## Native workout convenience

Use **Settings → Workout reminders** on iPhone to enable weekday or rotating-routine reminders, set a local time, and request notification permission. Reminders use generic text and open the corresponding date in Today. Setline uses one reminder per eligible date within the next 14 days and queues the next known date for each rotation. Starting, moving, skipping, or finishing a scheduled workout refreshes pending requests. Open Setline periodically to refresh the window and review a rotation that has missed its last scheduled date. iPhone Focus, notification delivery settings, and the system’s scheduling policies apply. [Notification authorization](https://developer.apple.com/documentation/usernotifications/asking-permission-to-use-notifications) · [Calendar triggers](https://developer.apple.com/documentation/usernotifications/uncalendarnotificationtrigger)

`setline://workout/active` returns to the personal active workout, or opens Today if the workout has ended. Notification links open the corresponding personal schedule date. The browser preview provides the regular in-app workout bar.

### Companion targets

The iPhone deployment target is iOS 17. Local reminders use UserNotifications, available on iOS 10 and later. For the future Watch app, use watchOS 10 or later as the project baseline. WatchConnectivity itself is available from watchOS 2 and iOS 9. For Lock Screen status, ActivityKit starts at iOS 16.1 and interactive Live Activity buttons use App Intents on iOS 17 and later. Select Xcode based on the Apple OS versions installed on the test devices. [WatchConnectivity](https://developer.apple.com/documentation/watchconnectivity/wcsession) · [ActivityKit](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities) · [Live Activity interactivity](https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities) · [Xcode system requirements](https://developer.apple.com/xcode/system-requirements/)

- **Apple Watch** requires a paired watchOS target and a WatchConnectivity adapter on each side. Activate `WCSession` and check pairing, installation, and reachability. Use application context for the latest `WorkoutCompanionState`, interactive messaging for reachable commands, and queued user-info transfers for delayed commands and acknowledgments. Persist `WorkoutCompanionOutbox` atomically before sending or clearing an action. Show an explicit pending state while disconnected. Accept a new state stream only after a fresh phone handshake. Apply incoming commands through the iPhone’s existing `TrainingModel.updateUserData` repository, publish the resulting state, and return an acknowledgment only after persistence. Retries reuse the original UUID. A stale action needs explicit review against the refreshed state. The phone records a delayed completion at receipt because offline timing is unconfirmed. [Apple’s WatchConnectivity transfer sample](https://developer.apple.com/documentation/watchconnectivity/transferring-data-with-watch-connectivity)
- **Lock Screen** requires a WidgetKit extension, an ActivityKit `ActivityConfiguration`, `NSSupportsLiveActivities`, and an actual permission check using `ActivityAuthorizationInfo`. Use `WorkoutLockScreenState` for the ActivityKit payload and add an explicit settings opt-in before displaying workout details. The planned quick actions are extend, skip, and restart rest. A `LiveActivityIntent` should run them through the same phone command path and refresh the activity on acceptance or conflict. Set logging and finish actions should open the app using the active-workout URL. Account for device unlock and end the activity when the session closes. Apple limits the combined static and dynamic ActivityKit data to 4 KB. [Activity authorization](https://developer.apple.com/documentation/activitykit/activityauthorizationinfo) · [Live Activity links](https://developer.apple.com/documentation/widgetkit/linking-to-specific-app-scenes-from-your-widget-or-live-activity)

The Watch and widget targets and their adapters are pending. To verify the iPhone work, run `swift test` on a Mac and build the iOS target. On an iPhone, test reminder permission approval, denial, and revocation, then verify rescheduled delivery and tapping through with the app closed. For the extensions, test unreachable delivery and replay, phone and watch finish races, timer pause and restart, process relaunch, iPhone unlock and the return link, and privacy with the Lock Screen detail preference off and on. Test queued WatchConnectivity delivery on a physical iPhone and paired Apple Watch. [Apple’s queued transfer reference](https://developer.apple.com/documentation/watchconnectivity/wcsession/transferuserinfo(_:))

## Open the preview

Run `npm run dev` from this folder. The Node.js preview stores routines, workout plans, weights, and preferences in the browser and includes the separate sample mode. Photo linking uses a supported local file picker, such as Chrome’s on desktop. Camera capture uses the iPhone app. [Open the local preview](http://127.0.0.1:4173/)

On a Mac with Xcode 16 or later, open `ios/Setline.xcodeproj`, select the **Setline** scheme and an iPhone simulator, then run. The deployment target is iOS 17.

Run `npm test` for browser model and storage tests and `swift test` for the native data repository tests.

See the [project brief](PROJECT_BRIEF.md) for the stage scope, data conventions, verification, and remaining work.
