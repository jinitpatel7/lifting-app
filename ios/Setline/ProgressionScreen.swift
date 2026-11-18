import SwiftUI

struct ProgressionSheet: View {
    let model: TrainingModel
    let unit: WeightUnit
    var routineID: UUID? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                let versions = model.records.currentRoutines.filter { routineID == nil || $0.routineID == routineID }
                if versions.isEmpty { Text("Save a routine to configure progression for its exercises.") }
                ForEach(versions) { version in
                    Section(version.name) {
                        ForEach(version.exercises) { row in
                            let suggestion = ExerciseProgression.suggest(row, in: version, records: model.records)
                            NavigationLink {
                                ProgressionDetail(model: model, unit: unit, routineID: version.routineID, rowID: row.id)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(row.variant.exercise.name)
                                    Text("\(row.historyEquipmentName) · \(suggestion.action.rawValue)").font(.caption).foregroundStyle(Palette.muted)
                                }.frame(minHeight: 44)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Exercise progression")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }.tint(Palette.purple)
    }
}

private struct ProgressionDetail: View {
    let model: TrainingModel
    let unit: WeightUnit
    let routineID: UUID
    let rowID: UUID
    @State private var configure = false
    @State private var editingTargets = false
    @State private var status: String?

    var body: some View {
        Group {
            if let version = model.records.currentRoutines.first(where: { $0.routineID == routineID }),
               let row = version.exercises.first(where: { $0.id == rowID }) {
                review(version, row: row)
            } else { Text("This exercise slot is no longer in the routine.") }
        }
    }

    private func review(_ version: RoutineVersion, row: PlannedExercise) -> some View {
        let rule = model.records.progressionRule(for: row)
        let suggestion = ExerciseProgression.suggest(row, in: version, records: model.records)
        return List {
            Section("\(version.name) · Version \(version.revision)") {
                Text(row.historyEquipmentName)
                if row.progressionModes.isEmpty {
                    Text("Name the specific machine or cable station in the routine to use progression for this exercise.")
                } else {
                    Button(rule.map { "Edit rule · \($0.mode.rawValue)" } ?? "Configure progression rule") { configure = true }
                        .frame(minHeight: 44)
                }
                if let status { Text(status).foregroundStyle(Palette.purple) }
                if let error = model.storageError { Text(error).foregroundStyle(Palette.red) }
            }
            Section("Planned targets") {
                ForEach(row.workingSets.indices, id: \.self) { index in
                    Text("Block \(index + 1) · \(row.summary(row.workingSets[index], unit: unit, fractionDigits: 0...4))")
                }
            }
            Section("Suggestion · \(suggestion.action.rawValue)") {
                Text(suggestion.reason)
                ForEach(suggestion.changes.keys.sorted(), id: \.self) { index in
                    if let prescription = suggestion.changes[index] {
                        Text("Block \(index + 1) · \(row.summary(prescription, unit: unit, fractionDigits: 0...4))")
                    }
                }
                if !suggestion.changes.isEmpty {
                    Button("Accept suggestion") {
                        if model.updateUserData({ try $0.acceptProgression(suggestion, versionID: version.id, rowID: row.id) }) {
                            status = "Suggestion saved as a new routine version."
                        }
                    }.frame(minHeight: 44)
                }
                Button("Override targets in routine editor") { editingTargets = true }.frame(minHeight: 44)
                Text("Saving a target change creates a new routine version. Existing workouts and scheduled versions keep their original targets.")
                    .font(.caption).foregroundStyle(Palette.muted)
            }
            if let day = suggestion.sourceDate {
                Section("Actual results · \(suggestion.sourceName ?? "Workout") · \(day.key)") {
                    ForEach(suggestion.evidence) { evidence($0, row: row, assessment: suggestion.assessment[$0.order]) }
                    if !suggestion.excluded.isEmpty {
                        DisclosureGroup("Sets outside the rule (\(suggestion.excluded.count))") {
                            ForEach(suggestion.excluded) { evidence($0, row: row) }
                        }
                    }
                }
            }
        }
        .navigationTitle(row.variant.exercise.name)
        .sheet(isPresented: $configure) { ProgressionRuleEditor(model: model, unit: unit, version: version, row: row, rule: rule) }
        .sheet(isPresented: $editingTargets) { RoutineEditor(model: model, unit: unit, original: version, focusedExerciseID: row.id) }
    }

    private func evidence(_ item: HistorySet, row: PlannedExercise, assessment: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(item.purpose == .warmUp ? "Warm-up" : "Set") \(item.order)").font(.subheadline.weight(.semibold))
            if let plan = item.prescription.map(singleSet) {
                Text("Prescribed · \(row.summary(plan, unit: unit, fractionDigits: 0...4))").font(.caption).foregroundStyle(Palette.muted)
            }
            if let result = item.result {
                Text("Actual · \(result.summary(unit: unit, measurement: row.variant.measurement, fractionDigits: 0...4))").font(.subheadline)
            } else { Text(item.status == .skipped ? "Skipped" : "Unfinished").font(.subheadline) }
            if let assessment { Text(assessment).font(.caption.weight(.semibold)).foregroundStyle(Palette.purple) }
        }
    }

    private func singleSet(_ prescription: SetPrescription) -> SetPrescription {
        var result = prescription
        result.sets = 1
        return result
    }
}

private struct ProgressionRuleEditor: View {
    let model: TrainingModel
    let unit: WeightUnit
    let version: RoutineVersion
    let row: PlannedExercise
    let rule: ProgressionRule?
    @Environment(\.dismiss) private var dismiss
    @State private var mode: ProgressionMode?
    @State private var threshold: ProgressionRule.Threshold
    @State private var miss: ProgressionRule.Miss
    @State private var effort: ProgressionRule.Effort
    @State private var step: String
    @State private var effortLimit: String

    init(model: TrainingModel, unit: WeightUnit, version: RoutineVersion, row: PlannedExercise, rule: ProgressionRule?) {
        self.model = model
        self.unit = unit
        self.version = version
        self.row = row
        self.rule = rule
        _mode = State(initialValue: rule?.mode)
        _threshold = State(initialValue: rule?.threshold ?? .top)
        _miss = State(initialValue: rule?.miss ?? .hold)
        _effort = State(initialValue: rule?.effort ?? .none)
        _step = State(initialValue: Self.stepText(rule, unit: unit))
        _effortLimit = State(initialValue: rule?.effortLimit.map { $0.formatted() } ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Progression method", selection: $mode) {
                        Text("Off").tag(nil as ProgressionMode?)
                        ForEach(row.progressionModes) { Text($0.rawValue).tag(Optional($0)) }
                    }
                    if let mode {
                        if mode != .reps {
                            TextField("Available increment (\(stepLabel(mode)))", text: $step).keyboardType(.decimalPad)
                        }
                        if mode == .load || mode == .assistance {
                            Picker("Reps required to progress", selection: $threshold) {
                                ForEach(ProgressionRule.Threshold.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                            }
                        }
                        Picker("When a minimum target is missed", selection: $miss) {
                            ForEach(ProgressionRule.Miss.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        Picker("Use recorded effort", selection: $effort) {
                            ForEach(ProgressionRule.Effort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        if effort != .none { TextField("Effort threshold", text: $effortLimit).keyboardType(.decimalPad) }
                    }
                    if let error = model.storageError { Text(error).foregroundStyle(Palette.red) }
                } header: {
                    Text("Progression rule")
                } footer: {
                    Text("Reps progression raises the minimum by one within the prescribed range after every straight working set meets its target. Load, duration, distance, and assistance use the full increment you enter. Effort is used when all eligible sets record the selected metric.")
                }
            }
            .navigationTitle("Progression rule")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save rule") { save() } }
            }
        }
    }

    private func stepLabel(_ mode: ProgressionMode) -> String {
        if mode == .duration { return "seconds" }
        if mode == .distance { return "meters" }
        if case .weightReps(.perDumbbell, _) = row.variant.measurement { return "\(unit.rawValue) per dumbbell" }
        return unit.rawValue
    }

    private static func stepText(_ rule: ProgressionRule?, unit: WeightUnit) -> String {
        guard let rule, let step = rule.step else { return "" }
        return (step / (rule.mode.isMass ? unit.kilogramsPerUnit : 1)).formatted(.number.precision(.fractionLength(0...6)))
    }

    private func save() {
        let configuration = mode.map { mode in
            let value = try? Double(step, format: .number, lenient: false)
            let amount = rule?.mode == mode && step == Self.stepText(rule, unit: unit) ? rule?.step :
                value.map { $0 * (mode.isMass ? unit.kilogramsPerUnit : 1) }
            let limit = effort == .none ? nil : (try? Double(effortLimit, format: .number, lenient: false))
            return ProgressionRule(mode: mode, threshold: threshold, miss: miss, step: mode == .reps ? nil : amount,
                effort: effort, effortLimit: limit)
        }
        if model.updateUserData({ try $0.saveProgressionRule(configuration, versionID: version.id, rowID: row.id) }) { dismiss() }
    }
}
