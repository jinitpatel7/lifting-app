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

**Weekly recap** summarizes the selected training week and separates scheduled completions, incomplete logs, and unscheduled work. Expand **Next scheduled workout** for planned targets and a separate forecast. On Today, **Workout score unavailable** opens the proposed breakdown. No score is calculated while the formula is under review.

Open **Calorie inputs** on a finished workout to choose an activity and enter its duration. A weigh-in on that workout’s date lets Setline show estimated gross calories using the Adult Compendium. [Compendium activity table](https://pacompendium.com/conditioning-exercise/)

Choose **Review progression** in History → Progress, routine options, or the finish summary. Select an exercise slot and configure how to progress it and what to do after a missed target. The review shows the planned targets, the recorded sets behind each suggestion, and any proposed targets. **Accept suggestion** saves a new routine version. **Override targets in routine editor** lets you choose the new targets yourself. Scheduled versions and workout history stay pinned to their saved plans.

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

## Open the preview

Run `npm run dev` from this folder. The Node.js preview stores routines, workout plans, weights, and preferences in the browser and includes the separate sample mode. Photo linking uses a supported local file picker, such as Chrome’s on desktop. Camera capture uses the iPhone app. [Open the local preview](http://127.0.0.1:4173/)

On a Mac with Xcode 16 or later, open `ios/Setline.xcodeproj`, select the **Setline** scheme and an iPhone simulator, then run. The deployment target is iOS 17.

Run `npm test` for browser model and storage tests and `swift test` for the native data repository tests.

See the [project brief](PROJECT_BRIEF.md) for the stage scope, data conventions, verification, and remaining work.
