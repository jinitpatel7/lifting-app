import AVKit
import SwiftUI
import UIKit

struct LibraryEntryButton: View {
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack {
                IconTile(symbol: "dumbbell", size: 34)
                Text("Exercise Library").font(.headline)
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(Palette.purple).accessibilityHidden(true)
            }
            .padding(12).surface().contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ExerciseLibraryScreen: View {
    let model: TrainingModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ExerciseLibraryQuery()
    @State private var creating = false

    init(model: TrainingModel, initialMuscle: MuscleGroup? = nil) {
        self.model = model
        _query = State(initialValue: ExerciseLibraryQuery(muscle: initialMuscle))
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Find exercises") {
                    TextField("Search by name", text: $query.name)
                        .autocorrectionDisabled().frame(minHeight: 44)
                    Picker("Collection", selection: $query.collection) {
                        ForEach(ExerciseCollection.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Muscle group", selection: $query.muscle) {
                        Text("All muscles").tag(nil as MuscleGroup?)
                        ForEach(MuscleGroup.allCases) { Text($0.label).tag(Optional($0)) }
                    }
                    Picker("Equipment", selection: $query.equipment) {
                        Text("All equipment").tag(nil as LibraryEquipment?)
                        ForEach(LibraryEquipment.choices) { Text($0.label).tag(Optional($0)) }
                    }
                    Picker("Movement pattern", selection: $query.pattern) {
                        Text("All patterns").tag(nil as MovementPattern?)
                        ForEach(MovementPattern.allCases) { Text($0.label).tag(Optional($0)) }
                    }
                }
                Section("Exercises") {
                    let results = query.results(catalog: model.catalog, custom: model.records.exercises,
                                                preferences: model.records.exercisePreferences ?? [:])
                    if results.isEmpty {
                        ContentUnavailableView(emptyTitle, systemImage: "magnifyingglass",
                                               description: Text(model.library.isEmpty ? "Add a custom exercise to start your library." : "Try changing your search or filters."))
                        if model.library.isEmpty || query.collection == .custom {
                            Button("Add custom exercise") { creating = true }.frame(minHeight: 44)
                        }
                    }
                    ForEach(results) { exercise in
                        NavigationLink { ExerciseDetails(model: model, id: exercise.id) } label: {
                            ExerciseRow(exercise: exercise, preference: model.exercisePreference(exercise.id))
                        }
                    }
                }
            }
            .navigationTitle("Exercise Library")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { creating = true } label: { Label("Add custom exercise", systemImage: "plus") }
                }
            }
            .sheet(isPresented: $creating) { ExerciseEditor(model: model) }
            .tint(Palette.purple)
        }
    }

    private var emptyTitle: String {
        if model.library.isEmpty { return "Your exercise library is empty" }
        if !query.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || query.muscle != nil
            || query.equipment != nil || query.pattern != nil { return "No matching exercises" }
        switch query.collection {
        case .custom: return "No custom exercises yet"
        case .favorites: return "No favorites yet"
        case .excluded: return "No excluded exercises"
        case .all: return "No matching exercises"
        }
    }
}

private struct ExerciseRow: View {
    let exercise: Exercise
    let preference: ExercisePreference

    var body: some View {
        HStack(spacing: 9) {
            IconTile(symbol: "dumbbell", size: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(exercise.name).font(.subheadline.weight(.semibold))
                if let profile = exercise.profile {
                    Text([LibraryEquipment(profile.equipmentKind).label, profile.pattern.label, profile.variation]
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(Palette.muted)
                }
            }
            Spacer(minLength: 0)
            if preference.favorite { Image(systemName: "star.fill").accessibilityLabel("Favorite") }
            if preference.excluded { Image(systemName: "eye.slash").accessibilityLabel("Excluded") }
        }
        .frame(minHeight: 44)
    }
}

private struct ExerciseDetails: View {
    let model: TrainingModel
    let id: UUID
    @State private var editing = false
    @State private var duplicating = false

    var body: some View {
        if let exercise = model.library.first(where: { $0.id == id }) {
            let preference = model.exercisePreference(id)
            let profile = exercise.profile ?? ExerciseProfile()
            let isCustom = model.records.exercises.contains { $0.id == id }
            List {
                Section {
                    if exercise.profile != nil { ExerciseRow(exercise: exercise, preference: preference) }
                    Toggle("Favorite", isOn: Binding(get: { model.exercisePreference(id).favorite }, set: { value in
                        var updated = model.exercisePreference(id)
                        updated.favorite = value
                        _ = model.saveExercisePreference(updated, id: id)
                    }))
                    Toggle("Exclude from browsing", isOn: Binding(get: { model.exercisePreference(id).excluded }, set: { value in
                        var updated = model.exercisePreference(id)
                        updated.excluded = value
                        _ = model.saveExercisePreference(updated, id: id)
                    }))
                    if let error = model.storageError { Text(error).foregroundStyle(Palette.red) }
                }
                Section("Setup and technique") {
                    LabeledContent("Setup", value: profile.setup.isEmpty ? "No setup instructions yet" : profile.setup)
                    LabeledContent("Technique cues", value: profile.cues.isEmpty ? "No technique cues yet" : profile.cues)
                }
                Section("Muscles") {
                    LabeledContent("Primary", value: muscleList(profile.primary))
                    LabeledContent("Secondary", value: muscleList(profile.secondary))
                }
                if !profile.machineSetup.fields.isEmpty {
                    let fields = profile.machineSetup.fields
                    Section("Equipment setup") {
                        ForEach(fields.indices, id: \.self) { index in
                            let field = fields[index]
                            LabeledContent(field.0, value: field.1)
                        }
                    }
                }
                Section("Demonstration") {
                    ExerciseMedia(demonstration: profile.demonstration)
                }
                Section {
                    NavigationLink("Browse substitutions") { SubstitutionScreen(model: model, source: exercise) }
                    if isCustom { Button("Edit custom exercise") { editing = true }.frame(minHeight: 44) }
                    Button("Create a variation") { duplicating = true }.frame(minHeight: 44)
                }
            }
            .navigationTitle(exercise.name)
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $editing) { ExerciseEditor(model: model, source: exercise, editing: true) }
            .sheet(isPresented: $duplicating) { ExerciseEditor(model: model, source: exercise) }
        }
    }

    private func muscleList(_ groups: [MuscleGroup]) -> String {
        groups.isEmpty ? "None listed" : groups.map(\.label).joined(separator: ", ")
    }
}

private struct ExerciseMedia: View {
    let demonstration: ExerciseDemonstration?

    var body: some View {
        if let demonstration, demonstration.isBundleResource,
           let file = Bundle.main.url(forResource: demonstration.resource, withExtension: nil) {
            switch demonstration.kind {
            case .image:
                if let image = UIImage(contentsOfFile: file.path) {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 240)
                        .accessibilityLabel("Exercise demonstration image")
                } else {
                    placeholder
                }
            case .video: DemonstrationVideo(file: file)
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        Label("No demonstration media available", systemImage: "play.rectangle").foregroundStyle(Palette.muted)
    }
}

private struct DemonstrationVideo: View {
    @State private var player: AVPlayer

    init(file: URL) { _player = State(initialValue: AVPlayer(url: file)) }

    var body: some View {
        VideoPlayer(player: player).frame(height: 210).onDisappear { player.pause() }
    }
}

private struct ExerciseEditor: View {
    let model: TrainingModel
    let editing: Bool
    let identityLocked: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var exercise: Exercise
    @State private var profile: ExerciseProfile

    init(model: TrainingModel, source: Exercise? = nil, editing: Bool = false) {
        self.model = model
        self.editing = editing
        identityLocked = editing && source?.profile != nil
        _exercise = State(initialValue: editing ? source ?? Exercise(name: "")
                          : Exercise(name: source.map { "\($0.name) variation" } ?? ""))
        _profile = State(initialValue: source?.profile ?? ExerciseProfile())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Exercise") {
                    TextField("Name", text: $exercise.name)
                    Picker("Equipment", selection: $profile.equipmentKind) {
                        ForEach(LibraryEquipment.choices) { Text($0.label).tag($0.kind) }
                    }
                    .disabled(identityLocked)
                    Picker("Movement pattern", selection: $profile.pattern) {
                        ForEach(MovementPattern.allCases) { Text($0.label).tag($0) }
                    }
                    TextField("Variation or machine name", text: $profile.variation).disabled(identityLocked)
                }
                Section("Setup and technique") {
                    TextField("Setup instructions", text: $profile.setup, axis: .vertical)
                    TextField("Technique cues", text: $profile.cues, axis: .vertical)
                }
                Section("Muscles") {
                    muscleOptions("Primary muscles", primary: true)
                    muscleOptions("Secondary muscles", primary: false)
                }
                Section("Machine or equipment setup") {
                    TextField("Seat position", text: $profile.machineSetup.seat)
                    TextField("Attachment", text: $profile.machineSetup.attachment)
                    TextField("Incline", text: $profile.machineSetup.incline)
                    TextField("Handle", text: $profile.machineSetup.handle)
                }
                if let error = model.storageError { Section { Text(error).foregroundStyle(Palette.red) } }
            }
            .navigationTitle(editing ? "Edit exercise" : "New custom exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        exercise.name = exercise.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        exercise.profile = profile
                        if model.saveExercise(exercise, editing: editing) { dismiss() }
                    }
                    .disabled(exercise.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .tint(Palette.purple)
        }
    }

    private func muscleOptions(_ label: String, primary: Bool) -> some View {
        DisclosureGroup(label) {
            ForEach(MuscleGroup.allCases) { muscle in
                Toggle(muscle.label, isOn: Binding(get: {
                    (primary ? profile.primary : profile.secondary).contains(muscle)
                }, set: { selected in
                    if primary {
                        profile.primary.removeAll { $0 == muscle }
                        if selected {
                            profile.primary.append(muscle)
                            profile.secondary.removeAll { $0 == muscle }
                        }
                    } else {
                        profile.secondary.removeAll { $0 == muscle }
                        if selected {
                            profile.secondary.append(muscle)
                            profile.primary.removeAll { $0 == muscle }
                        }
                    }
                }))
            }
        }
    }
}

private struct SubstitutionScreen: View {
    let model: TrainingModel
    let source: Exercise
    @State private var available: Set<LibraryEquipment> = []

    var body: some View {
        List {
            Section("Available equipment") {
                ForEach(LibraryEquipment.choices) { equipment in
                    Toggle(equipment.label, isOn: Binding(get: { available.contains(equipment) }, set: { selected in
                        if selected { available.insert(equipment) }
                        else { available.remove(equipment) }
                    }))
                }
            }
            Section("Exercises with shared muscles") {
                let candidates = ExerciseLibraryQuery.substitutions(for: source, in: model.library, available: available,
                                                                     preferences: model.records.exercisePreferences ?? [:])
                if available.isEmpty { Text("Select the equipment you have available.").foregroundStyle(Palette.muted) }
                else if candidates.isEmpty { Text("No matches for this equipment and muscle selection.").foregroundStyle(Palette.muted) }
                ForEach(candidates) { exercise in
                    NavigationLink { ExerciseDetails(model: model, id: exercise.id) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            ExerciseRow(exercise: exercise, preference: model.exercisePreference(exercise.id))
                            if let original = source.profile, let candidate = exercise.profile {
                                let overlap = MuscleGroup.allCases.filter { original.muscles.contains($0) && candidate.muscles.contains($0) }
                                Text(overlap.map(\.label).joined(separator: " · ")).font(.caption).foregroundStyle(Palette.muted)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Substitutions")
        .navigationBarTitleDisplayMode(.inline)
    }
}
