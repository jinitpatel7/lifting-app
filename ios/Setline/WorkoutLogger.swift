import SwiftUI
import UIKit

struct ScheduleWorkoutSheet: View {
    let model: TrainingModel
    let version: RoutineVersion
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Workout date", selection: $date, displayedComponents: .date)
                if let error = model.storageError { Text(error).foregroundStyle(Palette.red) }
            }
            .navigationTitle("Schedule \(version.name)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Schedule") { if model.scheduleWorkout(versionID: version.id, date: date) { dismiss() } }
                }
            }
        }
    }
}

struct WorkoutLogger: View {
    let model: TrainingModel
    let unit: WeightUnit
    @Environment(\.dismiss) private var dismiss
    @State private var adding = false
    @State private var editing = false
    @State private var confirmEarly = false
    @State private var confirmRoutine = false
    @State private var notice: String?
    @State private var deletion: WorkoutLogChange?

    var body: some View {
        if let session = model.records.activeSession {
            NavigationStack {
                List {
                    if let log = session.workoutLog {
                        logger(session, log: log)
                    } else {
                        Button("Prepare set rows") { model.prepareWorkoutLog(session.id) }
                        if let error = model.storageError { Text(error).foregroundStyle(Palette.red) }
                    }
                }
                .navigationTitle(session.plan.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
                .sheet(isPresented: $adding) { LoggingExercisePicker(model: model, sessionID: session.id) }
                .sheet(isPresented: $editing) { RoutineEditor(model: model, unit: unit, original: session.plan, sessionID: session.id) }
                .confirmationDialog("End this workout early?", isPresented: $confirmEarly, titleVisibility: .visible) {
                    Button("End early and save", role: .destructive) { finish(session.id, early: true) }
                } message: { Text("Completed results are saved. Pending and skipped sets keep their own status.") }
                .confirmationDialog("Update the linked routine?", isPresented: $confirmRoutine, titleVisibility: .visible) {
                    Button("Save new routine version") {
                        if model.updateRoutineFromWorkout(session.id) { notice = "Routine saved for future workouts." }
                    }
                } message: { Text("Use the current exercise order, set rows, and edited performance targets. Completed results and notes stay with this workout.") }
                .confirmationDialog("Delete recorded work?", isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } }), titleVisibility: .visible) {
                    Button("Delete", role: .destructive) { if let deletion { model.logChange(session.id, deletion) } }
                } message: { Text("This removes the selected results from the active workout.") }
                .task(id: session.id) { model.prepareWorkoutLog(session.id) }
                .tint(Palette.purple)
            }
        }
    }

    @ViewBuilder private func logger(_ session: WorkoutSession, log: WorkoutLog) -> some View {
        let pending = log.exercises.flatMap(\.rows).filter { $0.status == .pending }.count
        Section {
            Text("\(session.performedSets.count) completed · \(pending) pending").font(.subheadline.weight(.semibold))
            TextField("Workout notes", text: Binding(get: { log.notes }, set: { change(session, .sessionNotes($0)) }), axis: .vertical)
            Button("Add exercise") { adding = true }
            Menu("Today only or update routine") {
                Button("Edit plan for today only") { editing = true }
                if model.records.routines.contains(where: { $0.id == session.plan.routineID }) {
                    Button("Update routine") { confirmRoutine = true }
                }
            }
            if session.referenceSessionID != nil { Text("Previous results from the repeated workout appear alongside each set.").font(.caption) }
            if let notice { Text(notice).font(.caption).foregroundStyle(Palette.muted) }
            if let error = model.storageError { Text(error).foregroundStyle(Palette.red) }
        }
        ForEach(log.exercises.filter { !$0.queued }) { exercise in
            if let entry = session.plan.exercises.first(where: { $0.id == exercise.id }) {
                Section(entry.variant.exercise.name) {
                    exerciseActions(session, exercise: exercise)
                    ForEach(exercise.rows) { row in
                        setRow(row, exercise: exercise, entry: entry, session: session)
                    }
                    Menu("Add set") {
                        Button("Working set") { change(session, .addSet(exercise.id, .working)) }
                        Button("Warm-up set") { change(session, .addSet(exercise.id, .warmUp)) }
                    }
                }
            }
        }
        let queue = log.exercises.filter(\.queued).sorted { ($0.queuedAt ?? .distantPast) < ($1.queuedAt ?? .distantPast) }
        if !queue.isEmpty {
            Section("Busy equipment queue") {
                ForEach(queue) { exercise in
                    if let entry = session.plan.exercises.first(where: { $0.id == exercise.id }) {
                        HStack {
                            Text(entry.variant.exercise.name)
                            Spacer()
                            Button("Resume exercise") { change(session, .queue(exercise.id, false)) }.buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
        Section {
            Button("Finish workout") {
                if pending > 0 { confirmEarly = true } else { finish(session.id, early: false) }
            }
            Button("End early", role: .destructive) { confirmEarly = true }
        }
    }

    private func exerciseActions(_ session: WorkoutSession, exercise: WorkoutExerciseLog) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let group = session.plan.groups?.first(where: { $0.exerciseIDs.first == exercise.id }) {
                Text(group.summary).font(.caption).foregroundStyle(Palette.purple)
            }
            TextField("Exercise notes", text: Binding(get: { exercise.notes }, set: { change(session, .exerciseNotes(exercise.id, $0)) }), axis: .vertical)
            Menu("Exercise options") {
                Button("Equipment busy") { change(session, .queue(exercise.id, true)) }
                Button("Move exercise up") { change(session, .moveExercise(exercise.id, -1)) }
                Button("Move exercise down") { change(session, .moveExercise(exercise.id, 1)) }
                Button("Skip remaining sets") { change(session, .skipExercise(exercise.id)) }
                if exercise.rows.contains(where: { $0.status == .skipped }) {
                    Button("Restore skipped sets") { change(session, .restoreExercise(exercise.id)) }
                }
                Button("Delete exercise", role: .destructive) {
                    remove(.removeExercise(exercise.id), hasResults: exercise.rows.contains { $0.status == .completed }, in: session)
                }
            }
        }
    }

    @ViewBuilder private func setRow(_ row: WorkoutSetRow, exercise: WorkoutExerciseLog, entry: PlannedExercise, session: WorkoutSession) -> some View {
        let index = exercise.rows.firstIndex { $0.id == row.id } ?? 0
        let measurement = entry.variant.measurement
        let input = row.input ?? WorkoutSetInput(unit: unit, prescription: row.prescription)
        let status = row.status == .completed ? "Completed" : row.status == .skipped ? "Skipped" : row.input == nil ? "Planned" : "Edited"
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(row.purpose == .warmUp ? "Warm-up" : "Working") set \(index + 1)").font(.subheadline.weight(.bold))
                Spacer()
                Text(status).font(.caption.weight(.semibold))
                    .foregroundStyle(row.status == .completed ? Color.green : row.status == .skipped ? Palette.muted : Palette.purple)
            }
            if let plan = row.prescription {
                Text("Planned · \(entry.summary(plan, unit: unit))").font(.caption).foregroundStyle(Palette.muted)
            }
            if let previous = previousSet(for: entry, row: row, exercise: exercise, session: session) {
                Text("Previous · \(previous.summary(unit: unit, measurement: measurement))")
                    .font(.caption).foregroundStyle(Palette.muted)
                    .padding(5).background(Palette.soft, in: RoundedRectangle(cornerRadius: 5))
            }
            if row.status == .completed {
                if let result = session.performedSets.first(where: { $0.id == row.id }) {
                    Text("Result · \(result.summary(unit: unit, measurement: measurement))").font(.subheadline.weight(.semibold))
                }
                Button("Undo completion") { change(session, .undo(exercise.id, row.id)) }.buttonStyle(.borderless)
            } else if row.status == .skipped {
                Button("Restore set") { change(session, .setSkipped(exercise.id, row.id, false)) }.buttonStyle(.borderless)
            } else {
                if let label = measurement.loggingAmountLabel(input.unit) {
                    setField(label, input: input, key: \.amount, keyboard: measurement.isMachineSetting ? .default : .decimalPad,
                             session: session, exercise: exercise.id, row: row.id)
                }
                if let counting = measurement.repCounting {
                    setField(counting == .total ? "Reps" : counting == .perSide ? "Reps per side" : "Left reps", input: input, key: \.reps,
                             keyboard: .numberPad, session: session, exercise: exercise.id, row: row.id)
                    if counting == .separateSides {
                        setField("Right reps", input: input, key: \.rightReps, keyboard: .numberPad, session: session, exercise: exercise.id, row: row.id)
                    }
                }
                DisclosureGroup("Actual effort") {
                    setField("Actual RIR", input: input, key: \.rir, keyboard: .numberPad, session: session, exercise: exercise.id, row: row.id)
                    setField("Actual RPE", input: input, key: \.rpe, keyboard: .decimalPad, session: session, exercise: exercise.id, row: row.id)
                    Toggle("Reached failure", isOn: Binding(get: { input.failure }, set: { value in
                        var edited = input
                        edited.failure = value
                        change(session, .editSet(exercise.id, row.id, edited))
                    }))
                }
                Button("Complete set") { change(session, .complete(exercise.id, row.id, unit)) }
                    .buttonStyle(.borderedProminent)
            }
            Menu("Set options") {
                if row.status == .pending { Button("Skip set") { change(session, .setSkipped(exercise.id, row.id, true)) } }
                Button("Move set up") { change(session, .moveSet(exercise.id, row.id, -1)) }
                Button("Move set down") { change(session, .moveSet(exercise.id, row.id, 1)) }
                Button("Delete set", role: .destructive) { remove(.removeSet(exercise.id, row.id), hasResults: row.status == .completed, in: session) }
            }
        }
        .padding(.vertical, 5)
    }

    private func setField(_ label: String, input: WorkoutSetInput, key: WritableKeyPath<WorkoutSetInput, String>, keyboard: UIKeyboardType,
                          session: WorkoutSession, exercise: UUID, row: UUID) -> some View {
        LabeledContent(label) {
            TextField(label, text: Binding(get: { input[keyPath: key] }, set: { value in
                let current = model.records.activeSession?.workoutLog?.exercises.first { $0.id == exercise }?.rows.first { $0.id == row }?.input
                var edited = current ?? input
                edited[keyPath: key] = value
                change(session, .editSet(exercise, row, edited))
            }))
            .keyboardType(keyboard)
            .textFieldStyle(.roundedBorder)
        }
    }

    private func previousSet(for entry: PlannedExercise, row: WorkoutSetRow, exercise: WorkoutExerciseLog, session: WorkoutSession) -> PerformedSet? {
        let index = exercise.rows.filter { $0.purpose == row.purpose }.firstIndex { $0.id == row.id } ?? 0
        let historical = model.records.sessions.filter { $0.completedAt != nil }.sorted { $0.startedAt > $1.startedAt }
        let reference = historical.first { $0.id == session.referenceSessionID }
        for prior in (reference.map { [$0] } ?? []) + historical.filter({ $0.id != session.referenceSessionID }) {
            let entries = prior.plan.exercises.filter { $0.variant.key == entry.variant.key }
            let matching = entries.first { $0.id == entry.id } ?? entries.first
            if let previousExercise = prior.workoutLog?.exercises.first(where: { $0.id == matching?.id }) {
                let previousRows = previousExercise.rows.filter { $0.purpose == row.purpose }
                if previousRows.indices.contains(index),
                   let result = prior.performedSets.first(where: { $0.id == previousRows[index].id }) { return result }
                if prior.id == session.referenceSessionID { return nil }
                continue
            }
            let results = prior.performedSets.filter { $0.plannedExerciseID == matching?.id && ($0.purpose ?? .working) == row.purpose }
                .sorted { $0.order < $1.order }
            if results.indices.contains(index) { return results[index] }
            if prior.id == session.referenceSessionID && matching != nil { return nil }
        }
        return nil
    }

    private func change(_ session: WorkoutSession, _ action: WorkoutLogChange) { model.logChange(session.id, action) }

    private func remove(_ action: WorkoutLogChange, hasResults: Bool, in session: WorkoutSession) {
        if hasResults { deletion = action } else { change(session, action) }
    }

    private func finish(_ id: UUID, early: Bool) { if model.finishSession(id, early: early) { dismiss() } }
}

private extension Measurement {
    var isMachineSetting: Bool { if case .machineSetting = self { true } else { false } }

    func loggingAmountLabel(_ unit: WeightUnit) -> String? {
        switch self {
        case .weightReps(.perDumbbell, _): "\(unit.rawValue) per dumbbell"
        case .weightReps: "Weight (\(unit.rawValue))"
        case .addedLoad: "Added load (\(unit.rawValue))"
        case .assistance: "Assistance (\(unit.rawValue))"
        case .duration: "Duration (seconds)"
        case .distance: "Distance (meters)"
        case .machineSetting: "Machine setting"
        case .bodyweight: nil
        }
    }
}

private struct LoggingExercisePicker: View {
    let model: TrainingModel
    let sessionID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(ExerciseLibraryQuery(name: search).results(catalog: model.catalog, custom: model.records.exercises,
                    preferences: model.records.exercisePreferences ?? [:])) { exercise in
                    NavigationLink(exercise.name) { LoggingExerciseSetup(model: model, sessionID: sessionID, exercise: exercise, close: { dismiss() }) }
                }
            }
            .searchable(text: $search, prompt: "Search exercises")
            .navigationTitle("Add exercise")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

private struct LoggingExerciseSetup: View {
    let model: TrainingModel
    let sessionID: UUID
    let exercise: Exercise
    let close: () -> Void
    @State private var choice = MeasurementChoice.weight
    @State private var counting = RepCounting.total
    @State private var basis = LoadBasis.total
    @State private var equipmentID: UUID?

    var body: some View {
        Form {
            Picker("Track by", selection: $choice) { ForEach(MeasurementChoice.allCases) { Text($0.rawValue).tag($0) } }
            if choice.hasReps {
                Picker("Rep counting", selection: $counting) {
                    Text("Total reps").tag(RepCounting.total)
                    Text("Per side").tag(RepCounting.perSide)
                    Text("Separate sides").tag(RepCounting.separateSides)
                }
            }
            if choice == .weight {
                Picker("Load convention", selection: $basis) {
                    Text("Total load").tag(LoadBasis.total)
                    Text("Per dumbbell").tag(LoadBasis.perDumbbell)
                }
            }
            Picker("Equipment", selection: $equipmentID) {
                Text("Unspecified").tag(nil as UUID?)
                ForEach(model.records.equipment) { Text($0.name).tag(Optional($0.id)) }
            }
            Button("Add to workout") {
                model.logChange(sessionID, .addExercise(exercise, choice.measurement(basis: basis, reps: counting),
                    model.records.equipment.first { $0.id == equipmentID }))
                if model.storageError == nil { close() }
            }
            if let error = model.storageError { Text(error).foregroundStyle(Palette.red) }
        }
        .navigationTitle(exercise.name)
        .onAppear { if exercise.profile != nil && exercise.profile?.equipmentKind == nil { choice = .bodyweight } }
    }
}
