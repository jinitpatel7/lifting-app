import SwiftUI

@main
@MainActor
struct SetlineApp: App {
    @State private var model = TrainingModel()
    @StateObject private var photoAccess = ProgressPhotoAccess()

    var body: some Scene {
        WindowGroup { SetlineRoot(model: model).environmentObject(photoAccess) }
    }
}

private enum MainTab: String, CaseIterable, Identifiable {
    case today = "Today", routines = "Routines", history = "History", settings = "Settings"

    var id: Self { self }
    var accessibilityTitle: String {
        switch self {
        case .today: "Today / Log"
        case .history: "History / Progress"
        default: rawValue
        }
    }
    var icon: String {
        switch self {
        case .today: "calendar.badge.plus"
        case .routines: "square.stack"
        case .history: "chart.xyaxis.line"
        case .settings: "gearshape"
        }
    }
}

private enum ActiveSheet: Identifiable {
    case bodyweight(String), workout, exerciseLibrary(MuscleGroup?)
    case routineEditor(RoutineVersion?), routineHistory(UUID), schedule(RoutineVersion)
    case schedulePlanner, moveScheduled(ScheduleOccurrence), readiness(WorkoutDate)
    case progression(UUID)
    case portability, account, routineShare(UUID)

    var id: String {
        switch self {
        case .bodyweight(let date): "weight-\(date)"
        case .workout: "workout"
        case .exerciseLibrary(let group): "exercises-\(group?.rawValue ?? "all")"
        case .routineEditor(let version): "routine-\(version?.id.uuidString ?? "new")"
        case .routineHistory(let id): "versions-\(id.uuidString)"
        case .schedule(let version): "schedule-\(version.id.uuidString)"
        case .schedulePlanner: "schedule-planner"
        case .moveScheduled(let slot): "move-\(slot.id)"
        case .readiness(let day): "readiness-\(day.key)"
        case .progression(let id): "progression-\(id.uuidString)"
        case .portability: "portability"
        case .account: "account"
        case .routineShare(let id): "routine-share-\(id.uuidString)"
        }
    }
}

struct SetlineRoot: View {
    let model: TrainingModel
    @AppStorage("appearance") private var appearance: Appearance = .system
    @AppStorage("reduceTransparency") private var opaque = false
    @AppStorage("weightUnit") private var unit: WeightUnit = .kg
    @Environment(\.accessibilityReduceTransparency) private var systemOpaque
    @Environment(\.colorScheme) private var colorScheme
    @State private var tab: MainTab = .today
    @State private var sheet: ActiveSheet?
    @State private var day: String?
    @State private var routine: Routine?
    @State private var history: HistoryScreen.Section = .progress
    @State private var historyDay: WorkoutDate?
    @State private var showsSample = false
    @State private var account = SetlineAccountClient()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 14) {
                    Color.clear.frame(height: 0).id("top").accessibilityHidden(true)
                    screen
                }
                .padding(.horizontal, 16).padding(.bottom, 16)
                .frame(maxWidth: 590)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: tab) { proxy.scrollTo("top", anchor: .top) }
            .onChange(of: routine?.id) { proxy.scrollTo("top", anchor: .top) }
            .onChange(of: showsSample) { proxy.scrollTo("top", anchor: .top) }
        }
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .safeAreaInset(edge: .bottom, spacing: 0) { dock }
        .background(Palette.background.ignoresSafeArea())
        .preferredColorScheme(appearance.colorScheme)
        .sheet(item: $sheet) { presented in
            switch presented {
            case .bodyweight(let date):
                WeightSheet(model: model, date: date, unit: unit, sampleMode: showsSample)
            case .workout:
                WorkoutSheet(model: model, unit: unit, sampleMode: showsSample, viewHistory: { date in
                    sheet = nil
                    historyDay = date
                    history = .sessions
                    tab = .history
                }) {
                    sheet = nil
                    tab = .routines
                }
            case .exerciseLibrary(let muscle):
                ExerciseLibraryScreen(model: model, initialMuscle: muscle)
            case .routineEditor(let version):
                RoutineEditor(model: model, unit: unit, original: version)
            case .routineHistory(let id):
                RoutineHistorySheet(versions: model.records.versions(for: id), categories: model.records.routineCategories ?? [], unit: unit)
            case .schedule(let version):
                ScheduleWorkoutSheet(model: model, version: version)
            case .schedulePlanner:
                TrainingScheduleSheet(model: model)
            case .moveScheduled(let slot):
                ScheduleMoveSheet(model: model, slot: slot)
            case .readiness(let day):
                ReadinessSheet(model: model, day: day)
            case .progression(let id):
                ProgressionSheet(model: model, unit: unit, routineID: id)
            case .portability, .account:
                PortabilitySheet(model: model, account: account, mode: presented.id == "account" ? .account : .files,
                    appearance: $appearance, opaque: $opaque, unit: $unit)
            case .routineShare(let id):
                if let version = model.records.version(id) { RoutineSharePreview(version: version, unit: unit) }
            }
        }
        .alert("Local storage", isPresented: Binding(
            get: { model.storageError != nil && sheet == nil },
            set: { if !$0 { model.storageError = nil } }
        )) {
            Button("OK", role: .cancel) { model.storageError = nil }
        } message: {
            Text(model.storageError ?? "")
        }
    }

    @ViewBuilder private var screen: some View {
        switch tab {
        case .today:
            if showsSample, let sample = model.sample {
                TodayScreen(sample: sample, model: model, unit: unit, openRoutines: { tab = .routines },
                            start: start, editWeight: { sheet = .bodyweight($0) }, browseMuscle: browseMuscle, selectedDay: $day)
            } else {
                PersonalTodayScreen(records: model.records, unit: unit, browse: { tab = .routines },
                                    start: startScheduled, startEmpty: { if model.startEmptyWorkout() { sheet = .workout } },
                                    editWeight: { sheet = .bodyweight($0) }, browseMuscle: browseMuscle, openSchedule: { sheet = .schedulePlanner },
                                    move: { sheet = .moveScheduled($0) }, skip: skipScheduled, logReadiness: { sheet = .readiness($0) },
                                    reviewProgression: { sheet = .progression($0) }, selectedDay: $day)
            }
        case .routines:
            if showsSample, let sample = model.sample {
                RoutinesScreen(sample: sample, model: model, unit: unit, active: model.activeRoutine != nil, start: start,
                               browseLibrary: { sheet = .exerciseLibrary(nil) }, browseMuscle: browseMuscle, selection: $routine)
            } else {
                PersonalRoutinesScreen(records: model.records, unit: unit, start: startSession,
                    browseLibrary: { sheet = .exerciseLibrary(nil) }, edit: { sheet = .routineEditor($0) },
                    duplicate: { _ = model.duplicateRoutine($0) }, versionHistory: { sheet = .routineHistory($0) },
                    schedule: { sheet = .schedule($0) }, reviewProgression: { sheet = .progression($0) },
                    shareRoutine: { sheet = .routineShare($0) })
            }
        case .history:
            if showsSample, let sample = model.sample {
                HistoryScreen(sample: sample, unit: unit, selection: $history)
            } else {
                PersonalHistoryScreen(model: model, unit: unit, repeatWorkout: repeatWorkout, resume: { sheet = .workout },
                                      jumpTo: $historyDay, selection: $history)
            }
        case .settings:
            SettingsScreen(appearance: $appearance, opaque: $opaque, unit: $unit,
                openPortability: { sheet = .portability }, openAccount: { sheet = .account })
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "dumbbell.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Palette.action, in: RoundedRectangle(cornerRadius: 11))
                    .accessibilityHidden(true)
                Text("Setline").font(.title3.weight(.heavy))
            }
            Spacer(minLength: 0)
            if model.sample != nil {
                Button {
                    showsSample.toggle()
                    day = nil
                    routine = nil
                    history = .progress
                } label: {
                    Text(showsSample ? "Sample data" : "View sample data")
                        .font(.caption2.weight(.bold)).multilineTextAlignment(.center)
                        .foregroundStyle(Palette.purple)
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(Palette.lavender, in: Capsule())
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showsSample ? "Sample data. Return to your data" : "View sample data")
            }
            Button {
                appearance = colorScheme == .dark ? .light : .dark
            } label: {
                Image(systemName: colorScheme == .dark ? "sun.max" : "moon")
                    .frame(width: 44, height: 44)
                    .background(Palette.surface, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(colorScheme == .dark ? "Switch to light appearance" : "Switch to dark appearance")
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .frame(maxWidth: 590)
        .frame(maxWidth: .infinity)
        .background(Palette.surface.opacity(reduceTransparency ? 1 : 0.5))
    }

    private var reduceTransparency: Bool { opaque || systemOpaque }

    private var dock: some View {
        VStack(spacing: 5) {
        let activeName = showsSample ? model.activeRoutine?.name : model.records.activeSession?.plan.name
            Button {
                sheet = .workout
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "dumbbell").font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color(hex: 0xE4D4FF))
                        .frame(width: 34, height: 34)
                        .background(Color(hex: 0x483667), in: RoundedRectangle(cornerRadius: 9))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(activeName ?? "Workout log").font(.subheadline.weight(.bold))
                        HStack(spacing: 4) {
                            if activeName != nil {
                                Circle().fill(Color(hex: 0xFFA6B8)).frame(width: 6, height: 6).accessibilityHidden(true)
                            }
                            if !showsSample, let session = model.records.activeSession {
                                TimelineView(.periodic(from: .now, by: 1)) { context in
                                    let log = session.workoutLog
                                    if log?.clock?.pausedAt != nil {
                                        Text("Workout paused")
                                    } else if let rest = log?.rest {
                                        let remaining = rest.remaining(active: session.workoutTimes(at: context.date, clock: log?.clock).active)
                                        Text(remaining == 0 ? "Rest ready" : "Rest \(workoutClockText(remaining))")
                                    } else {
                                        Text("Active workout")
                                    }
                                }.font(.caption).monospacedDigit()
                            } else {
                                Text(activeName == nil ? "No active workout" : "Active preview").font(.caption)
                            }
                        }
                        .foregroundStyle(Color(hex: 0xE0D7EC))
                    }
                    Spacer(minLength: 5)
                    Image(systemName: "chevron.right").font(.caption.weight(.bold)).accessibilityHidden(true)
                }
                .padding(.horizontal, 9).padding(.vertical, 5)
                .frame(minHeight: 48)
                .foregroundStyle(.white)
                .background(Color(hex: 0x252031), in: RoundedRectangle(cornerRadius: 16))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(activeName == nil ? "Open workout log" : "Resume workout")
            HStack(spacing: 3) {
                ForEach(MainTab.allCases) { destination in
                    Button {
                        tab = destination
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: destination.icon).font(.system(size: 19, weight: .semibold))
                            Text(destination.rawValue).font(.caption2.weight(.semibold))
                                .lineLimit(1).minimumScaleFactor(0.7).dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        }
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .foregroundStyle(destination == tab ? Palette.purple : .primary)
                        .background(destination == tab ? Palette.lavender : .clear, in: RoundedRectangle(cornerRadius: 13))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(destination.accessibilityTitle)
                    .accessibilityAddTraits(destination == tab ? .isSelected : [])
                }
            }
            .padding(4)
            .background { GlassSurface(opaque: reduceTransparency) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Main navigation")
        }
        .frame(maxWidth: 540)
        .padding(.horizontal, 12).padding(.bottom, 4)
    }

    private func start(_ routine: Routine) {
        if model.startPreview(routine) { sheet = .workout }
    }

    private func browseMuscle(_ group: MuscleGroup) { sheet = .exerciseLibrary(group) }

    private func startSession(_ versionID: UUID, _ scheduleID: UUID?) {
        if model.startSession(versionID: versionID, scheduleID: scheduleID) { sheet = .workout }
    }

    private func startScheduled(_ slot: ScheduleOccurrence) {
        if model.records.activeSession != nil || model.updateUserData({ _ = try $0.startScheduled(slot.id, on: slot.date) }) {
            sheet = .workout
        }
    }

    private func skipScheduled(_ slot: ScheduleOccurrence) {
        _ = model.updateUserData { try $0.skipSchedule(slot.id, on: slot.date, today: WorkoutDate(Date())) }
    }

    private func repeatWorkout(_ id: UUID) {
        if model.repeatWorkout(id) { sheet = .workout }
    }
}

struct WeightSheet: View {
    let model: TrainingModel
    let date: String
    let unit: WeightUnit
    let sampleMode: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var entry = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Bodyweight (\(unit.rawValue))", text: $entry)
                        .keyboardType(.decimalPad).focused($focused)
                        .accessibilityLabel("Bodyweight in \(unit.name.lowercased())")
                        .frame(minHeight: 44)
                    Button {
                        let existing = model.bodyweight(on: date, sampleMode: sampleMode)
                        let kilograms = existing.flatMap { unit.display($0, fractionDigits: 1...1) == entry ? $0 : nil }
                            ?? unit.kilograms(for: entry)
                        if let kilograms, model.recordBodyweight(kilograms, on: date, sampleMode: sampleMode) {
                            model.storageError = nil
                            dismiss()
                        }
                    } label: {
                        Label("Save entry", systemImage: "checkmark").frame(minHeight: 44)
                    }
                    .disabled(unit.kilograms(for: entry) == nil)
                } header: {
                    let day = SampleDate.label(date, .dateTime.weekday(.wide).month(.wide).day())
                    Text(sampleMode ? "Sample entry · \(day)" : day)
                } footer: {
                    if let error = model.storageError { Text(error).foregroundStyle(Palette.red) }
                }
            }
            .navigationTitle("Log bodyweight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .tint(Palette.purple)
            .onAppear {
                if let kilograms = model.bodyweight(on: date, sampleMode: sampleMode) {
                    entry = unit.display(kilograms, fractionDigits: 1...1)
                }
                focused = true
            }
        }
    }
}

private struct WorkoutSheet: View {
    let model: TrainingModel
    let unit: WeightUnit
    let sampleMode: Bool
    let viewHistory: (WorkoutDate) -> Void
    let browse: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var finished: UUID?

    var body: some View {
        if let finished, let session = model.records.sessions.first(where: { $0.id == finished }) {
            HistoryFinishView(model: model, session: session, sessions: model.records.sessions, unit: unit, viewHistory: viewHistory)
        } else if !sampleMode && model.records.activeSession != nil {
            WorkoutLogger(model: model, unit: unit) { finished = $0 }
        } else {
            NavigationStack {
                List {
                    if sampleMode, let routine = model.activeRoutine {
                        Section("Active workout preview · Sample routine") {
                            ForEach(routine.exercises) { exercise in
                                LabeledContent(exercise.name, value: exercise.prescription)
                            }
                        }
                        Button("End workout preview", role: .destructive) {
                            if model.endPreview() { dismiss() }
                        }
                        Text("Switch to personal mode to record a workout.").font(.caption)
                    } else {
                        if !sampleMode { Button("Start empty workout") { _ = model.startEmptyWorkout() }.frame(minHeight: 44) }
                        Button("Browse routines", action: browse).frame(minHeight: 44)
                    }
                    if let error = model.storageError { Text(error).foregroundStyle(Palette.red) }
                }
                .navigationTitle(model.activeRoutine?.name ?? "Workout log")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
                .tint(Palette.purple)
            }
        }
    }
}
