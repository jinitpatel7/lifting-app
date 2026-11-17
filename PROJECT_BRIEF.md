# Setline project brief

## Product and stage

Setline helps experienced lifters follow their own routines, record performance, and review exercise-specific progress. Workouts are always authored by the lifter. Stage 1 established the interface and navigation. Stage 2 adds the offline data foundation and opens into personal records by default. **View sample data** opens the original, separately stored sample week anchored on November 17, 2026.

- **Today / Log** reads the device calendar, saved schedule, and daily bodyweight. The sample version shows front and back muscle maps and sample prescriptions.
- **Routines** reads the current version of each saved routine. Sample exercise cards show thumbnails, previous best sets, future prediction placeholders, and expandable RIR and rest details.
- **History / Progress** reads completed session snapshots, sets, and bodyweight history. The bench press trend remains in the sample preview.
- **Settings** provides system, light, and dark appearance, solid navigation, and kilogram or pound display.
- The workout bar is available across all four tabs. The native app can start a saved routine, resume its active session, and finish it. Starting or ending a sample workout changes only the sample preview.

## Architecture and data conventions

- The iOS 17+ app uses SwiftUI and a single main-actor repository. Each successful record write atomically replaces the versioned `TrainingData.json` file in Application Support. Active sessions and their sets save incrementally. Unsupported schemas block user-store writes. `AppStorage` holds display preferences.
- Schema 2 migrates manually entered bodyweight from `TrainingState-v1.json` into dated records. The old file stays available and its modification time supplies missing timestamps. Legacy active sample workouts resume in the isolated `SamplePreview-v1.json` state. Bundled sample routines, history, and new sample entries stay outside the personal repository.
- Navigation uses a 50% surface tint over a blur. The app and browser honor the platform reduced-transparency preference as well as the in-app setting. Native layouts use Dynamic Type and accessibility labels.
- Both implementations work without an internet connection or an account. The browser preview serves its assets over loopback and stores bodyweight, preferences, and the sample preview in separate local keys. The full workout repository is native. [Sample data](ios/Setline/Resources/SampleData.json)
- The layout draws on daily dashboard and progress patterns, as well as Apple’s native control and material conventions. [Appetite UI Fitness](https://www.appetiteui.com/docs/screens-fitness) · [Apple Design Resources](https://developer.apple.com/design/resources/) · [Apple’s Reduce Transparency documentation](https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducetransparency)

## Training records

- Native records have UUIDs and timestamps. Workout dates use Gregorian `YYYY-MM-DD` keys. A session captures the device’s local date and time zone when started. Bodyweight edits retain one ID per day.
- The repository appends a routine version when its name or prescriptions change. A scheduled workout points to a specific routine version. Starting a session copies that version, exercises, equipment, and prescriptions into the session. Performed sets reference the copied prescription IDs. Predictions store their own targets and source sessions.
- Equipment has its own type and ID. Comparison keys use the exercise ID, equipment ID, measurement, load basis, and rep convention. Different cable or machine records stay distinct even when their labels or settings match.
- Physical mass is stored in kilograms. One pound is exactly `0.45359237 kg`. Combined weight is the total loaded mass, including the bar for barbell lifts. A pair of 20 kg dumbbells is recorded as either 20 kg per dumbbell or 40 kg combined, with the basis stored explicitly. The unit preference changes display only.
- Rep counts are total, equal per side, or separate left and right counts. Per-side targets apply to each side. Added load is the external weight applied to a bodyweight movement. Assistance is a positive amount that offsets load. Each has its own measurement type.
- Machine settings are device-specific labels such as `007`. They retain their exact text and stay outside mass conversion. Duration and rest use seconds, distance uses meters, and RIR counts reps in reserve.
- Program blocks group pinned scheduled workouts within inclusive local dates. Readiness records capture 1–5 energy and soreness scores and optional sleep minutes. Photo references store a Photos library identifier or an app-relative file path.

## Verification and remaining work

- Browser storage tests passed migration, stable IDs, unit conversion, local date handling, and failed-write recovery. Chromium at iPhone width verified bodyweight persistence and sample isolation across reloads, sample navigation, and personal entry with external requests blocked and the sample fixture unavailable in a separate check.
- Swift syntax and Xcode source membership passed static checks on Windows. The `swift test` suite covers native migration, relaunch, incremental sets, machine setting validation, historical snapshots, failed saves, and device photo references. Running it requires a Swift toolchain. The app still needs an Xcode build, simulator and device testing, and a VoiceOver pass.
- Future stages include authoring routines and schedules, set entry screens, readiness and photo entry, and exercise-specific progression. Prediction panels are static placeholders. Photo selection will need PhotosPicker. Apple Watch needs a watchOS target and WatchConnectivity. Lock Screen needs an ActivityKit Live Activity and WidgetKit extension.

## Artwork

Built-in ImageGen supplied the bench press photo. The bench press thumbnail reuses it, and the other sample thumbnails use symbols. The muscle maps are simplified exercise illustrations. [Bench press photo](ios/Setline/Resources/workout-hero.png) · [Upper-body map](ios/Setline/Resources/muscle-map.png) · [Lower-body map](ios/Setline/Resources/muscle-map-lower.png)

<details>
<summary>Hero photo prompt</summary>

Generate a photographic hero asset for a contemporary strength training workout tracker. A wide landscape editorial sports photograph (roughly 2.25:1 composition). A muscular adult lifter in a dark charcoal t-shirt with their hands wrapping a barbell for a bench press, viewed from a low close side angle in a polished black steel power rack. Focus on a realistic large black bumper plate at the far right and the lifter's forearm and grip toward the center-right. Put all visually interesting detail in the right 58 percent; left 42 percent is almost black negative space for white interface typography. Shadowy charcoal private powerlifting gym, clean black and white/grayscale treatment, directional soft overhead light, subtle film grain, high contrast, serious strength journal editorial style. No purple effects, no logos, no added lettering, no borders. Look like a real professional photograph.

</details>
