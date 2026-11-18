# Setline project brief

## Product and stage

Setline helps experienced lifters follow their own routines, record performance, and review exercise-specific progress. Workouts are always authored by the lifter. Stage 5 adds the workout logger to the existing offline records, exercise library, and routine builder. **View sample data** opens the separately stored sample week anchored on November 17, 2026.

- **Today / Log** reads the device calendar, saved schedule, and daily bodyweight. It starts a scheduled plan or an empty workout. Interactive front and back maps combine muscles across the planned exercises for the selected day. Primary involvement takes precedence when a muscle has both roles.
- **Routines** creates, edits, duplicates, categorizes, and schedules manually authored plans. It shows the current plan and its saved version history, and opens the Exercise Library.
- **History / Progress** reads completed session plans, sets, and bodyweight history. Repeat opens a new workout based on a completed session with its recorded results available for reference. The bench press trend is in the sample preview.
- **Settings** provides system, light, and dark appearance, solid navigation, and kilogram or pound display.
- The workout bar resumes the persisted active session across all four tabs. The logger shows planned targets and prior results, saves field edits and notes, and supports one-tap completion and undo. Set and exercise controls change order, add and remove rows, or skip pending work. The busy-equipment queue preserves rows for later in the session.

## Architecture and data conventions

- The iOS 17+ app uses SwiftUI and a single main-actor repository. Each successful record write atomically replaces the versioned `TrainingData.json` file in Application Support. Active sessions and their sets save incrementally. Unsupported schemas block user-store writes. `AppStorage` holds display preferences.
- Schema 2 migrates manually entered bodyweight from `TrainingState-v1.json` into dated records. The old file stays available and its modification time supplies missing timestamps. Legacy active sample workouts resume in the isolated `SamplePreview-v1.json` state. Bundled sample routines, history, and new sample entries stay outside the personal repository.
- Navigation uses a 50% surface tint over a blur. The app and browser honor the platform reduced-transparency preference as well as the in-app setting. Native layouts use Dynamic Type and accessibility labels.
- Both implementations work without an internet connection or an account. The browser preview serves its assets over loopback and stores routine plans, schedules, session logs, bodyweight, preferences, and the sample preview in local keys. [Sample data](ios/Setline/Resources/SampleData.json)
- The layout draws on daily dashboard and progress patterns, as well as Apple’s native control and material conventions. [Appetite UI Fitness](https://www.appetiteui.com/docs/screens-fitness) · [Apple Design Resources](https://developer.apple.com/design/resources/) · [Apple’s Reduce Transparency documentation](https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducetransparency)

## Training records

- Native records have UUIDs and timestamps. Workout dates use Gregorian `YYYY-MM-DD` keys. A session captures the device’s local date and time zone when started. Bodyweight edits retain one ID per day.
- The repository appends a routine version when its name or prescriptions change. A scheduled workout points to a specific routine version. Starting a session copies that version, exercises, equipment, and prescriptions into the session. Performed sets reference the copied prescription IDs. Predictions store their own targets and source sessions.
- Equipment has its own type and ID. Comparison keys use the exercise ID, equipment ID, measurement, load basis, and rep convention. Different cable or machine records stay distinct even when their labels or settings match.
- Physical mass is stored in kilograms. One pound is exactly `0.45359237 kg`. Combined weight is the total loaded mass, including the bar for barbell lifts. A pair of 20 kg dumbbells is recorded as either 20 kg per dumbbell or 40 kg combined, with the basis stored explicitly. The unit preference changes display only.
- Rep counts are total, equal per side, or separate left and right counts. Per-side targets apply to each side. Added load is the external weight applied to a bodyweight movement. Assistance is a positive amount that offsets load. Each has its own measurement type.
- Machine settings are device-specific labels such as `007`. They retain their exact text and stay outside mass conversion. Duration and rest use seconds, distance uses meters, and RIR counts reps in reserve.
- Program blocks group pinned scheduled workouts within inclusive local dates. Readiness records capture 1–5 energy and soreness scores and optional sleep minutes. Photo references store a Photos library identifier or an app-relative file path.
- The offline exercise catalog uses stable IDs and original instruction copy. Favorites and exclusions are stored by exercise ID. Exclusions hide exercises from normal browsing and substitutions, with a separate collection for review. Substitutions use shared muscles and user-selected equipment types.
- Custom exercise names, muscles, cues, and setup notes are editable. A different equipment type or variation label requires a new exercise ID. Previously saved routine versions and workout snapshots retain their recorded exercise data. Physical equipment IDs still distinguish individual stations in performance records.
- Demonstrations support bundled images and video. Entries without a supplied asset display an explicit placeholder. [Exercise catalog](ios/Setline/Resources/ExerciseCatalog.json)
- Routine versions store ordered exercise slots, a category, and optional groups. A superset contains two consecutive exercises, and a circuit can contain two or more. Round count and rest between exercises and between rounds are recorded separately. Duplicates get fresh routine, group, and slot IDs.
- Set blocks separate warm-up and working prescriptions. Set structure, AMRAP, and the effort goal are independent. A goal can use RIR, RPE, or failure. Recorded effort outcomes are stored on performed sets separately from the prescribed goal.
- Workout-only edits save an effective plan on the active session. The starting snapshot and the source routine version are retained. Completed sessions are read-only. Repeats reference the completed session’s results and start with an empty performed-set list.
- Pending, skipped, and completed are separate set states. Prefills and edits save as inputs. Explicit completion creates a performed result with typed measurements and optional actual RIR, RPE, and failure. End early retains completed, skipped, and unfinished rows as recorded. Repeats reset statuses, notes, and the queue while copying the session’s exercise and set structure.
- Today-only edits are the default. **Update routine** explicitly promotes the current order, set rows, and edited targets to a new version of the linked routine. Older versions, recorded effort, session notes, and completed sessions retain their original data. A newer routine version requires editing from Routines.

## Verification and remaining work

- Browser tests cover search, exercise preferences, custom exercise identities, substitutions, and muscle involvement, alongside the previous local storage checks. Chromium at iPhone width checks direct and keyboard muscle selection, combined filters, custom creation and edits, saved preferences after reload, the sample plan after browsing substitutions, and the empty library with the catalog unavailable.
- Routine tests cover creation and categories, reorder, grouping, measurements, duplication, immutable history, workout-only edits, and start-from-history behavior. The browser workflow exercises those controls at phone width. Swift syntax and Xcode source membership passed static checks on Windows. The native test suite requires a Swift toolchain, and the app still needs an Xcode build, device testing, and a VoiceOver pass.
- Workout tests cover scheduled and empty starts, deliberate completion, undo, set and exercise edits, notes, equipment queue restoration, version promotion, end-early records, and prior results on repeat. Phone-width Chromium covered the workflow and accessibility checks.
- Future stages include program scheduling, readiness and photo entry, and exercise-specific progression. Prediction panels are static placeholders. Photo selection will need PhotosPicker. Apple Watch needs a watchOS target and WatchConnectivity. Lock Screen needs an ActivityKit Live Activity and WidgetKit extension.

## Artwork

Built-in ImageGen supplied the bench press photo. The bench press thumbnail reuses it, and the other sample thumbnails use symbols. The interactive figures use original schematic geometry shared by SwiftUI and the browser. The supplied references informed the anatomy. [Bench press photo](ios/Setline/Resources/workout-hero.png) · [Muscle map geometry](ios/Setline/Resources/MuscleRegions.json)

<details>
<summary>Hero photo prompt</summary>

Generate a photographic hero asset for a contemporary strength training workout tracker. A wide landscape editorial sports photograph (roughly 2.25:1 composition). A muscular adult lifter in a dark charcoal t-shirt with their hands wrapping a barbell for a bench press, viewed from a low close side angle in a polished black steel power rack. Focus on a realistic large black bumper plate at the far right and the lifter's forearm and grip toward the center-right. Put all visually interesting detail in the right 58 percent; left 42 percent is almost black negative space for white interface typography. Shadowy charcoal private powerlifting gym, clean black and white/grayscale treatment, directional soft overhead light, subtle film grain, high contrast, serious strength journal editorial style. No purple effects, no logos, no added lettering, no borders. Look like a real professional photograph.

</details>
