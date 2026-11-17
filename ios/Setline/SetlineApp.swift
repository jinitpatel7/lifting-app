import SwiftUI

@main
@MainActor
struct SetlineApp: App {
    @State private var model = TrainingModel()

    var body: some Scene {
        WindowGroup { SetlineRoot(model: model) }
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
    case bodyweight(String), workout

    var id: String {
        switch self {
        case .bodyweight(let date): "weight-\(date)"
        case .workout: "workout"
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
    @State private var showsSample = false

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
                WorkoutSheet(model: model, unit: unit, sampleMode: showsSample) {
                    sheet = nil
                    tab = .routines
                }
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
                            start: start, editWeight: { sheet = .bodyweight($0) }, selectedDay: $day)
            } else {
                PersonalTodayScreen(records: model.records, unit: unit, browse: { tab = .routines },
                                    start: startSession, editWeight: { sheet = .bodyweight($0) }, selectedDay: $day)
            }
        case .routines:
            if showsSample, let sample = model.sample {
                RoutinesScreen(sample: sample, unit: unit, active: model.activeRoutine != nil, start: start, selection: $routine)
            } else {
                PersonalRoutinesScreen(records: model.records, unit: unit, start: startSession)
            }
        case .history:
            if showsSample, let sample = model.sample {
                HistoryScreen(sample: sample, unit: unit, selection: $history)
            } else {
                PersonalHistoryScreen(sessions: model.records.sessions, bodyweight: model.records.bodyweightEntries,
                                      unit: unit, selection: $history)
            }
        case .settings:
            SettingsScreen(appearance: $appearance, opaque: $opaque, unit: $unit)
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
            let activeName = showsSample ? model.activeRoutine?.name : model.records.activeSession?.routineSnapshot.name
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
                            Text(activeName == nil ? "No active workout" : showsSample ? "Active preview" : "Active workout").font(.caption)
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

    private func startSession(_ versionID: UUID, _ scheduleID: UUID?) {
        if model.startSession(versionID: versionID, scheduleID: scheduleID) { sheet = .workout }
    }
}

private struct WeightSheet: View {
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
    let browse: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if !sampleMode, let session = model.records.activeSession {
                    Section("Saved session plan") {
                        ForEach(session.routineSnapshot.exercises) { exercise in
                            LabeledContent(exercise.variant.exercise.name, value: exercise.summary(unit: unit))
                        }
                    }
                    Section {
                        Button("Finish workout") {
                            if model.finishSession(session.id) { dismiss() }
                        }
                        .frame(minHeight: 44)
                    } footer: {
                        if let error = model.storageError { Text(error).foregroundStyle(Palette.red) }
                    }
                } else if sampleMode, let routine = model.activeRoutine {
                    Section("Active workout preview · Sample routine") {
                        ForEach(routine.exercises) { exercise in
                            LabeledContent(exercise.name, value: exercise.prescription)
                        }
                    }
                    Section {
                        Button(role: .destructive) {
                            if model.endPreview() {
                                model.storageError = nil
                                dismiss()
                            }
                        } label: {
                            Text("End workout preview").frame(minHeight: 44)
                        }
                    } footer: {
                        Text(model.storageError ?? "Set logging and session history will be available in a later stage.")
                            .foregroundStyle(model.storageError == nil ? Palette.muted : Palette.red)
                    }
                } else {
                    Text(sampleMode ? "Choose a sample routine to start a workout preview." : "Choose a saved routine to start a workout.")
                    Button("Browse routines", action: browse).frame(minHeight: 44)
                }
            }
            .navigationTitle((sampleMode ? model.activeRoutine?.name : model.records.activeSession?.routineSnapshot.name) ?? "Workout log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .tint(Palette.purple)
        }
    }
}
