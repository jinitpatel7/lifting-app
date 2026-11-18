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
    @State private var gearEntry: PlannedExercise?
    @State private var restEntry: PerformedSet?

    var body: some View {
        if let session = model.records.activeSession {
            NavigationStack {
                ScrollViewReader { scroll in
                    List {
                        if let log = session.workoutLog {
                            logger(session, log: log)
                        } else {
                            Button("Prepare set rows") { model.prepareWorkoutLog(session.id) }
                            if let error = model.storageError { Text(error).foregroundStyle(Palette.red) }
                        }
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        if let log = session.workoutLog {
                            workoutDock(session, log: log) { id in scroll.scrollTo(id, anchor: .center) }
                        }
                    }
                }
                .navigationTitle(session.plan.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
                .sheet(isPresented: $adding) { LoggingExercisePicker(model: model, sessionID: session.id) }
                .sheet(isPresented: $editing) { RoutineEditor(model: model, unit: unit, original: session.plan, sessionID: session.id) }
                .sheet(item: $gearEntry) { entry in
                    WorkoutGearSheet(entry: entry, profile: session.workoutLog?.loadProfiles?[entry.variant.loggingEquipmentKey], unit: unit) { profile in
                        change(session, .loadProfile(entry.variant.loggingEquipmentKey, profile))
                    }
                }
                .sheet(item: $restEntry) { result in
                    EditWorkoutRestSheet(result: result) { value in
                        change(session, .editRest(result.id, value))
                        return model.storageError == nil
                    }
                }
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
        let nextID = log.sequence(groups: session.plan.groups ?? []).first { $0.row.status == .pending }?.row.id
        Section {
            Text("\(session.performedSets.count) completed · \(pending) pending").font(.subheadline.weight(.semibold))
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(session.workoutTimeSummary(at: context.date)).font(.caption).monospacedDigit()
            }
            Toggle("Track actual rest", isOn: Binding(get: { log.trackRest == true }, set: { change(session, .trackRest($0)) }))
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
                        setRow(row, exercise: exercise, entry: entry, session: session, isNext: row.id == nextID)
                            .id(row.id)
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

    @ViewBuilder private func workoutDock(_ session: WorkoutSession, log: WorkoutLog, focus: @escaping (UUID) -> Void) -> some View {
        let next = log.sequence(groups: session.plan.groups ?? []).first { $0.row.status == .pending }
        let entry = session.plan.exercises.first { $0.id == next?.exerciseID }
        let paused = log.clock?.pausedAt != nil
        let pause = Button(paused ? "Resume workout" : "Pause workout") {
            change(session, paused ? .resume : .pause)
        }.frame(minHeight: 44)
        let undo = log.undo.map { entry in
            Button("Undo \(entry.label)") { change(session, .undoLast) }.frame(minHeight: 44)
        }
        Group {
            VStack(alignment: .leading, spacing: 2) {
                if let rest = log.rest {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let active = session.workoutTimes(at: context.date, clock: log.clock).active
                        let remaining = rest.remaining(active: active)
                        Text(rest.rule + " · " + (remaining == 0 ? "Ready" : workoutClockText(remaining)))
                            .font(.subheadline.weight(.semibold)).monospacedDigit()
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack { restActions(session, log: log) }
                        VStack(alignment: .leading) { restActions(session, log: log) }
                    }
                }
                if let next, let entry {
                    Button { focus(next.row.id) } label: {
                        Label("Next · \(entry.variant.exercise.name)", systemImage: "arrow.down.circle")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 44)
                    .accessibilityHint("Scroll to the next set")
                    if log.clock?.pausedAt == nil {
                        Button {
                            change(session, .complete(next.exerciseID, next.row.id, unit))
                        } label: { Text("Complete next set").frame(maxWidth: .infinity, minHeight: 36) }
                        .buttonStyle(.borderedProminent)
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack { pause; if let undo { undo } }
                    VStack(alignment: .leading) { pause; if let undo { undo } }
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface)
        }
    }

    @ViewBuilder private func restActions(_ session: WorkoutSession, log: WorkoutLog) -> some View {
        if log.clock?.pausedAt == nil {
            Button("Extend 15s") { change(session, .extendRest) }.frame(minHeight: 44)
            Button("Restart rest") { change(session, .restartRest) }.frame(minHeight: 44)
        }
        Button("Skip rest") { change(session, .skipRest) }.frame(minHeight: 44)
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

    @ViewBuilder private func setRow(_ row: WorkoutSetRow, exercise: WorkoutExerciseLog, entry: PlannedExercise, session: WorkoutSession,
                                     isNext: Bool) -> some View {
        let index = exercise.rows.firstIndex { $0.id == row.id } ?? 0
        let measurement = entry.variant.measurement
        let input = row.input ?? WorkoutSetInput(unit: unit, prescription: row.prescription)
        let canToggleSides = measurement.repCounting == nil || measurement.repCounting == .perSide
        let sided = measurement.repCounting == .separateSides || (canToggleSides && input.separateSides == true)
        let previous = previousSet(for: entry, row: row, exercise: exercise, session: session)
        let profile = session.workoutLog?.loadProfiles?[entry.variant.loggingEquipmentKey]
        let status = row.status == .completed ? "Completed" : row.status == .skipped ? "Skipped" : row.input == nil ? "Planned" : "Edited"
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(row.purpose == .warmUp ? "Warm-up" : "Working") set \(index + 1)").font(.subheadline.weight(.bold))
                if isNext { Text("Next").font(.caption.weight(.bold)).foregroundStyle(Palette.purple) }
                Spacer()
                Text(status).font(.caption.weight(.semibold))
                    .foregroundStyle(row.status == .completed ? Color.green : row.status == .skipped ? Palette.muted : Palette.purple)
            }
            if let plan = row.prescription {
                Text("Planned · \(entry.summary(plan, unit: unit))").font(.caption).foregroundStyle(Palette.muted)
            }
            if let previous {
                Text("Previous · \(previous.summary(unit: unit, measurement: measurement))")
                    .font(.caption).foregroundStyle(Palette.muted)
                    .padding(5).background(Palette.soft, in: RoundedRectangle(cornerRadius: 5))
            }
            if row.status == .completed {
                if let result = session.performedSets.first(where: { $0.id == row.id }) {
                    Text("Result · \(result.summary(unit: unit, measurement: measurement))").font(.subheadline.weight(.semibold))
                    Button(result.restSummary ?? "Edit actual rest") { restEntry = result }.buttonStyle(.borderless)
                }
                Button("Undo completion") { change(session, .undo(exercise.id, row.id)) }.buttonStyle(.borderless)
            } else if row.status == .skipped {
                Button("Restore set") { change(session, .setSkipped(exercise.id, row.id, false)) }.buttonStyle(.borderless)
            } else {
                if let label = measurement.loggingAmountLabel(input.unit) {
                    setField(sided ? "Left · \(label)" : label, input: input, key: \.amount, keyboard: measurement.isMachineSetting ? .default : .decimalPad,
                             session: session, exercise: exercise.id, row: row.id)
                    if sided {
                        LabeledContent("Right · \(label)" + (measurement.repCounting == nil ? "" : " (optional)")) {
                            TextField("Right result", text: Binding(get: { input.rightAmount ?? "" }, set: { value in
                                updateInput(input, session: session, exercise: exercise.id, row: row.id) { $0.rightAmount = value }
                            })).keyboardType(measurement.isMachineSetting ? .default : .decimalPad).textFieldStyle(.roundedBorder)
                        }
                    }
                }
                if let counting = measurement.repCounting {
                    setField(sided ? "Left reps" : counting == .perSide ? "Reps per side" : "Reps", input: input, key: \.reps,
                             keyboard: .numberPad, session: session, exercise: exercise.id, row: row.id)
                    if sided {
                        setField("Right reps", input: input, key: \.rightReps, keyboard: .numberPad, session: session, exercise: exercise.id, row: row.id)
                    }
                }
                if canToggleSides {
                    Button(sided ? "Use a single result" : "Log left and right") {
                        updateInput(input, session: session, exercise: exercise.id, row: row.id) {
                            $0.separateSides = !sided
                            if !sided { $0.rightReps = $0.reps }
                        }
                    }.buttonStyle(.borderless)
                }
                quickControls(input, entry: entry, session: session, row: row.id, sided: sided, profile: profile)
                if measurement.isPhysicalLoad && exercise.rows.first(where: { $0.status == .pending })?.id == row.id {
                    Button(entry.variant.usesPlateCalculator ? "Plate calculator" : "Equipment increment") { gearEntry = entry }
                        .buttonStyle(.borderless)
                }
                if entry.variant.usesPlateCalculator, let profile, let target = loggingNumber(input.amount),
                   let options = try? profile.options(for: target * input.unit.kilogramsPerUnit / profile.unit.kilogramsPerUnit) {
                    Text(options.summary(unit: profile.unit)).font(.caption).foregroundStyle(Palette.muted)
                }
                if let warning = input.typoWarning(prescription: row.prescription, previous: previous, measurement: measurement, sided: sided) {
                    Label(warning, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(Palette.muted)
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
                if session.workoutLog?.clock?.pausedAt == nil {
                    Button("Complete set") { change(session, .complete(exercise.id, row.id, unit)) }
                        .buttonStyle(.borderedProminent)
                }
            }
            Menu("Set options") {
                if row.status == .pending { Button("Skip set") { change(session, .setSkipped(exercise.id, row.id, true)) } }
                Button("Move set up") { change(session, .moveSet(exercise.id, row.id, -1)) }
                Button("Move set down") { change(session, .moveSet(exercise.id, row.id, 1)) }
                Button("Delete set", role: .destructive) { remove(.removeSet(exercise.id, row.id), hasResults: row.status == .completed, in: session) }
            }
        }
        .padding(.vertical, 5)
        .listRowBackground(isNext ? Palette.soft : Palette.surface)
    }

    @ViewBuilder private func quickControls(_ input: WorkoutSetInput, entry: PlannedExercise, session: WorkoutSession, row: UUID,
                                           sided: Bool, profile: WorkoutLoadProfile?) -> some View {
        let measurement = entry.variant.measurement
        let value = loggingNumber(input.amount) ?? 0
        if measurement.isPhysicalLoad, let profile {
            let ratio = input.unit.kilogramsPerUnit / profile.unit.kilogramsPerUnit
            if entry.variant.usesPlateCalculator, let options = try? profile.options(for: value * ratio) {
                quickPair("Load", low: options.lower.map { $0 / ratio }, high: options.upper.map { $0 / ratio }) { next in
                    updateInput(input, session: session, exercise: entry.id, row: row) { $0.amount = loggingValue(next) }
                }
            } else if let increment = profile.increment {
                quickPair(sided ? "Left load" : "Load", low: max(0, value - increment / ratio), high: value + increment / ratio) { next in
                    updateInput(input, session: session, exercise: entry.id, row: row) { $0.amount = loggingValue(next) }
                }
                if sided {
                    let right = input.rightAmount.flatMap(loggingNumber) ?? value
                    quickPair("Right load", low: max(0, right - increment / ratio), high: right + increment / ratio) { next in
                        updateInput(input, session: session, exercise: entry.id, row: row) { $0.rightAmount = loggingValue(next) }
                    }
                }
            }
        }
        if measurement == .duration || measurement == .distance {
            let quantity = measurement == .duration ? "time" : "distance"
            quickPair(sided ? "Left " + quantity : quantity.capitalized, low: max(0, value - 5), high: value + 5) { next in
                updateInput(input, session: session, exercise: entry.id, row: row) { $0.amount = loggingValue(next) }
            }
            if sided {
                let right = input.rightAmount.flatMap(loggingNumber) ?? 0
                quickPair("Right " + quantity, low: max(0, right - 5), high: right + 5) { next in
                    updateInput(input, session: session, exercise: entry.id, row: row) { $0.rightAmount = loggingValue(next) }
                }
            }
        }
        if measurement.repCounting != nil {
            let count = Double(Int(input.reps) ?? 0)
            quickPair(sided ? "Left reps" : "Reps", low: max(0, count - 1), high: count + 1) { next in
                updateInput(input, session: session, exercise: entry.id, row: row) { $0.reps = loggingValue(next) }
            }
        }
        if sided && measurement.repCounting != nil {
            let count = Double(Int(input.rightReps) ?? 0)
            quickPair("Right reps", low: max(0, count - 1), high: count + 1) { next in
                updateInput(input, session: session, exercise: entry.id, row: row) { $0.rightReps = loggingValue(next) }
            }
        }
    }

    private func quickPair(_ label: String, low: Double?, high: Double?, apply: @escaping (Double) -> Void) -> some View {
        HStack {
            Button("\(label) −") { if let low { apply(low) } }.disabled(low == nil).accessibilityLabel("Decrease \(label)")
            Button("\(label) +") { if let high { apply(high) } }.disabled(high == nil).accessibilityLabel("Increase \(label)")
        }
        .buttonStyle(.borderless)
        .frame(minHeight: 44)
    }

    private func updateInput(_ input: WorkoutSetInput, session: WorkoutSession, exercise: UUID, row: UUID,
                             edit: (inout WorkoutSetInput) -> Void) {
        let current = model.records.activeSession?.workoutLog?.exercises.first { $0.id == exercise }?.rows.first { $0.id == row }?.input
        var edited = current ?? input
        edit(&edited)
        change(session, .editSet(exercise, row, edited))
    }

    private func setField(_ label: String, input: WorkoutSetInput, key: WritableKeyPath<WorkoutSetInput, String>, keyboard: UIKeyboardType,
                          session: WorkoutSession, exercise: UUID, row: UUID) -> some View {
        LabeledContent(label) {
            TextField(label, text: Binding(get: { input[keyPath: key] }, set: { value in
                updateInput(input, session: session, exercise: exercise, row: row) { $0[keyPath: key] = value }
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
    var isPhysicalLoad: Bool {
        switch self {
        case .weightReps, .addedLoad, .assistance: true
        default: false
        }
    }

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

private func loggingNumber(_ value: String) -> Double? {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
    guard let amount = Double(normalized), amount.isFinite else { return nil }
    return amount
}

private func loggingValue(_ value: Double) -> String {
    value.formatted(.number.locale(Locale(identifier: "en_US_POSIX")).grouping(.never).precision(.fractionLength(0...5)))
}

private extension WorkoutLoadProfile.Options {
    func summary(unit: WeightUnit) -> String {
        if let plates {
            if plates.isEmpty { return "Empty bar." }
            return "Per side: " + plates.map(loggingValue).joined(separator: " + ") + " " + unit.rawValue
        }
        let totals = [lower, upper].compactMap { $0 }.map { "\(loggingValue($0)) \(unit.rawValue)" }
        return totals.isEmpty ? "No reachable load." : "Closest available totals: " + totals.joined(separator: " or ") + "."
    }
}

private extension WorkoutSetInput {
    func typoWarning(prescription: SetPrescription?, previous: PerformedSet?, measurement: Measurement, sided: Bool) -> String? {
        let expected = WorkoutSetInput(unit: unit, prescription: prescription)
        var reference = previous.map(WorkoutSetInput.init(result:)) ?? WorkoutSetInput(unit: unit)
        if measurement.isPhysicalLoad && reference.unit != unit {
            if let value = loggingNumber(reference.amount) { reference.amount = loggingValue(value * reference.unit.kilogramsPerUnit / unit.kilogramsPerUnit) }
            if let value = reference.rightAmount.flatMap(loggingNumber) { reference.rightAmount = loggingValue(value * reference.unit.kilogramsPerUnit / unit.kilogramsPerUnit) }
        }
        func unusual(_ text: String?, _ baseline: String?, gap: Double) -> Bool {
            guard let value = text.flatMap(loggingNumber), let typical = baseline.flatMap(loggingNumber), value > 0, typical > 0 else { return false }
            return (value >= typical * 2 && value - typical >= gap) || (value <= typical / 2 && typical - value >= gap)
        }
        let typicalAmount = expected.amount.isEmpty ? reference.amount : expected.amount
        let typicalReps = expected.reps.isEmpty ? reference.reps : expected.reps
        func unusualReps(_ text: String, typical: String) -> Bool {
            if let count = Int(text), let range = prescription?.reps, (range.minimum...range.maximum).contains(count) { return false }
            return unusual(text, typical, gap: 4)
        }
        var fields: [String] = []
        if measurement.isPhysicalLoad || measurement == .duration {
            let gap: Double = measurement == .duration ? 15 : 2
            if unusual(amount, typicalAmount, gap: gap) || (sided && unusual(rightAmount, reference.rightAmount ?? typicalAmount, gap: gap)) {
                fields.append(measurement == .duration ? "duration" : "load")
            }
        }
        if measurement.repCounting != nil, unusualReps(reps, typical: typicalReps) || (sided && unusualReps(rightReps, typical: reference.rightReps.isEmpty ? typicalReps : reference.rightReps)) {
            fields.append("reps")
        }
        return fields.isEmpty ? nil : "Double-check " + fields.joined(separator: " and ") + ". You can still log this set."
    }
}

private struct WorkoutGearSheet: View {
    let entry: PlannedExercise
    let unit: WeightUnit
    let save: (WorkoutLoadProfile) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var bar: String
    @State private var plates: String
    @State private var increment: String
    @State private var error: String?

    init(entry: PlannedExercise, profile: WorkoutLoadProfile?, unit: WeightUnit, save: @escaping (WorkoutLoadProfile) -> Void) {
        self.entry = entry
        self.unit = profile?.unit ?? unit
        self.save = save
        _bar = State(initialValue: profile?.bar.map(loggingValue) ?? "")
        _plates = State(initialValue: profile?.plates.map { "\(loggingValue($0.weight))x\($0.count)" }.joined(separator: ", ") ?? "")
        _increment = State(initialValue: profile?.increment.map(loggingValue) ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                if entry.variant.usesPlateCalculator {
                    TextField("Bar weight (\(unit.rawValue))", text: $bar).keyboardType(.decimalPad)
                    TextField("Available plates", text: $plates, prompt: Text("20x2, 5x1"))
                    Text("Enter each plate weight and the number of matching pairs available.").font(.caption)
                } else {
                    TextField("Load step (\(unit.rawValue))", text: $increment).keyboardType(.decimalPad)
                    Text("Use the change in the recorded load. For paired dumbbells this follows the set’s load convention.").font(.caption)
                }
                if let error { Text(error).foregroundStyle(Palette.red) }
            }
            .navigationTitle(entry.variant.usesPlateCalculator ? "Plate calculator" : "Equipment increment")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { saveGear() } }
            }
        }
    }

    private func saveGear() {
        do {
            var profile = WorkoutLoadProfile(unit: unit)
            if entry.variant.usesPlateCalculator {
                guard let weight = loggingNumber(bar), (0...1_000_000).contains(weight) else {
                    throw TrainingDataError.invalidRecord("Enter a valid bar weight.")
                }
                profile.bar = weight
                profile.plates = try WorkoutLoadProfile.parsePlates(plates)
                _ = try profile.options(for: weight)
            } else if !increment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard let value = loggingNumber(increment), (0.001...1_000_000).contains(value) else {
                    throw TrainingDataError.invalidRecord("Enter a valid equipment increment.")
                }
                profile.increment = value
            }
            save(profile)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct EditWorkoutRestSheet: View {
    let result: PerformedSet
    let save: (String) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var edited: String
    @State private var invalid = false

    init(result: PerformedSet, save: @escaping (String) -> Bool) {
        self.result = result
        self.save = save
        _edited = State(initialValue: result.actualRest?.editedSeconds.map { String($0) } ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                if let measured = result.actualRest?.measuredSeconds { LabeledContent("Measured rest", value: "\(measured) s") }
                TextField("Edited rest (seconds)", text: $edited).keyboardType(.numberPad)
                if invalid { Text("Check the seconds and try saving again.").foregroundStyle(Palette.red) }
            }
            .navigationTitle("Actual rest")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { if save(edited) { dismiss() } else { invalid = true } }
                }
            }
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
