# Setline

Setline is an offline iPhone-first training log for experienced lifters who plan their own workouts. The native app opens to personal data. Select **View sample data** to explore the sample week and workout preview.

Open **Routines → Exercise Library** to search the built-in catalog, add custom exercises, or browse substitutions. Tap a region on the Today muscle map to identify its muscles and open a filtered library.

Open **Routines → New routine** in personal mode to build a plan. Drag exercise rows to reorder them. The routine options contain **Edit routine**, **Duplicate routine**, and **Version history**. Use **History → Sessions → Repeat workout** to start from a completed plan and reference its recorded results.

Schedule a saved routine from **Routines** and start it on **Today**, or choose **Start empty workout**. Use the workout bar to return to the active session from any tab. **Complete set** records the displayed values, and **Undo completion** returns the set to pending. **End early** saves completed results alongside skipped and unfinished rows.

Use the bottom workout controls to jump to or complete the next set, pause the session, and manage rest. Turn on **Track actual rest** to save measured intervals. Open **Plate calculator** or **Equipment increment** on a pending set to configure the equipment available for load shortcuts. For per-side prescriptions, **Log left and right** opens separate result fields.

Open **Today → Training schedule** to set your week start, switch to a rolling seven-day view, assign weekdays, set a rotation, or build a program block. Mark each program week and assign the versions containing your targets. Use **Move session** or **Skip session** on the calendar. A rotation advances when you finish its session with recorded sets or explicitly skip it. A missed day holds your place.

Use **Readiness** for an optional daily check-in and **Recent training** on the muscle map to see when each muscle last had logged work.

## Open the preview

Run `npm run dev` from this folder. The Node.js preview stores routines, workout plans, weights, and preferences in the browser and includes the separate sample mode. [Open the local preview](http://127.0.0.1:4173/)

On a Mac with Xcode 16 or later, open `ios/Setline.xcodeproj`, select the **Setline** scheme and an iPhone simulator, then run. The deployment target is iOS 17.

Run `npm test` for browser model and storage tests and `swift test` for the native data repository tests.

See the [project brief](PROJECT_BRIEF.md) for the stage scope, data conventions, verification, and remaining work.
