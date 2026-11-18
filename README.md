# Setline

Setline is an offline iPhone-first training log for experienced lifters who plan their own workouts. The native app opens to personal data. Select **View sample data** to explore the sample week and workout preview.

Open **Routines → Exercise Library** to search the built-in catalog, add custom exercises, or browse substitutions. Tap a region on the Today muscle map to identify its muscles and open a filtered library.

## Open the preview

Run `npm run dev` from this folder. The Node.js preview stores weights and preferences in the browser and includes the separate sample mode. [Open the local preview](http://127.0.0.1:4173/)

On a Mac with Xcode 16 or later, open `ios/Setline.xcodeproj`, select the **Setline** scheme and an iPhone simulator, then run. The deployment target is iOS 17.

Run `npm test` for browser storage tests and `swift test` for the native data repository tests.

See the [project brief](PROJECT_BRIEF.md) for the stage scope, data conventions, verification, and remaining work.
