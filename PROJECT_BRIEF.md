# Setline project brief

## Product and stage

Setline helps experienced lifters follow their own routines, record performance, and review exercise-specific progress. Workouts are always authored by the lifter. Stage 1 establishes the visual foundation and navigation with a labeled sample week anchored on November 17, 2026.

- **Today / Log** shows an interactive sample week, the planned workout or rest day, front and back muscle maps, daily bodyweight entry, and a Log Workout action.
- **Routines** opens two sample routines and their exercise prescriptions. Exercise cards show thumbnails, sets and reps, previous best sets, future prediction placeholders, and expandable RIR and rest details.
- **History / Progress** shows a sample bench press trend and a list of sample sessions.
- **Settings** provides system, light, and dark appearance, solid navigation, and kilogram or pound display.
- The workout bar is available across all four tabs. The workout preview can be started, resumed, or ended. Ending it clears its active state.

## Architecture and data conventions

- The iOS 17+ app uses SwiftUI, SF Symbols, Swift Charts, and a shared observable training model. A versioned JSON snapshot in Application Support stores bodyweight and active preview state with atomic writes. `AppStorage` stores appearance, transparency, and unit choices.
- Navigation uses a 50% surface tint over a blur. The app and browser honor the platform reduced-transparency preference as well as the in-app setting. Native layouts use Dynamic Type and accessibility labels.
- Both implementations work without a backend and share the same artwork. The browser keeps its own local state and serves the shared fixture. [Sample data](ios/Setline/Resources/SampleData.json)
- Routine, exercise, and session IDs are stable strings. Dates are `YYYY-MM-DD` calendar keys. Bodyweight has one editable entry per date. All loads are stored in kilograms and converted for display. Rest is stored in seconds and RIR counts reps in reserve. The sample chart plots the heaviest recorded load per date.
- The layout draws on daily dashboard and progress patterns, as well as Apple’s native control and material conventions. [Appetite UI Fitness](https://www.appetiteui.com/docs/screens-fitness) · [Apple Design Resources](https://developer.apple.com/design/resources/) · [Apple’s Reduce Transparency documentation](https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducetransparency)

## Verification and remaining work

- Chromium checks covered four-tab navigation, routine detail, planned and rest days, keyboard disclosure, bodyweight form validation and reload persistence, unit conversion, active workout start/resume/end, light and dark modes, and the solid-navigation setting. At 390 px, primary controls measured at least 44 × 44 px and the page fit the viewport without horizontal overflow.
- Automated axe scans reported no WCAG A or AA violations across the four tabs in either theme.
- JavaScript and Swift syntax, sample references, the Xcode project, and the shared scheme were checked on Windows. The SwiftUI target still needs an Xcode build, simulator and iPhone testing, and a VoiceOver pass.
- Future stages include routine editing, scheduling, set-by-set logging, completed-session history, and exercise-specific progression. Future prediction panels are static placeholders. Device photo selection will need PhotosPicker and local asset storage. Apple Watch needs a watchOS target and WatchConnectivity. Lock Screen needs an ActivityKit Live Activity and WidgetKit extension.

## Artwork

Built-in ImageGen supplied the bench press photo. The bench press thumbnail reuses it, and the other sample thumbnails use symbols. The muscle maps are simplified exercise illustrations. [Bench press photo](ios/Setline/Resources/workout-hero.png) · [Upper-body map](ios/Setline/Resources/muscle-map.png) · [Lower-body map](ios/Setline/Resources/muscle-map-lower.png)

<details>
<summary>Hero photo prompt</summary>

Generate a photographic hero asset for a contemporary strength training workout tracker. A wide landscape editorial sports photograph (roughly 2.25:1 composition). A muscular adult lifter in a dark charcoal t-shirt with their hands wrapping a barbell for a bench press, viewed from a low close side angle in a polished black steel power rack. Focus on a realistic large black bumper plate at the far right and the lifter's forearm and grip toward the center-right. Put all visually interesting detail in the right 58 percent; left 42 percent is almost black negative space for white interface typography. Shadowy charcoal private powerlifting gym, clean black and white/grayscale treatment, directional soft overhead light, subtle film grain, high contrast, serious strength journal editorial style. No purple effects, no logos, no added lettering, no borders. Look like a real professional photograph.

</details>
