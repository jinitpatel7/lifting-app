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
    var pinnedVersionID: UUID? = nil
    @State private var configure = false
    @State private var editingTargets = false
    @State private var status: String?
    @State private var showCurrent = false

    var body: some View {
        Group {
            let version = (!showCurrent ? pinnedVersionID.flatMap(model.records.version) : nil) ??
                model.records.currentRoutines.first(where: { $0.routineID == routineID })
            if let version,
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
                        let before = row.summary(row.workingSets[index], unit: unit, fractionDigits: 0...4)
                        let after = (suggestion.replacements[index] ?? [prescription]).map {
                            row.summary($0, unit: unit, fractionDigits: 0...4)
                        }.joined(separator: " + ")
                        Text("Block \(index + 1) · \(before) → \(after.isEmpty ? "Remove block" : after)")
                    }
                }
                if !suggestion.changes.isEmpty {
                    if let warning = suggestion.warning { Text(warning).foregroundStyle(Palette.purple) }
                    Button("Apply once") { apply(suggestion, version: version, row: row, scope: .once) }
                        .frame(minHeight: 44)
                    if model.records.currentRoutines.contains(where: { $0.id == version.id }) {
                        Button("Update routine") { apply(suggestion, version: version, row: row, scope: .routine) }
                            .frame(minHeight: 44)
                    }
                    Button("Edit recommendation") { editingTargets = true }.frame(minHeight: 44)
                    Button(suggestion.warning == nil ? "Dismiss recommendation" : "Hold for now") {
                        apply(suggestion, version: version, row: row, scope: .dismiss)
                    }.frame(minHeight: 44)
                }
                Text("Apply once uses the next matching workout. Update routine saves a new version. Existing scheduled versions keep their original targets.")
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
        .sheet(isPresented: $editingTargets) {
            ProgressionTargetEditor(model: model, unit: unit, version: version, row: row, suggestion: suggestion) { scope in
                showCurrent = scope == .routine
                status = scope == .routine ? "Edited targets saved as a new routine version." : "Edited targets queued for the next matching workout."
            }
        }
    }

    private func apply(_ suggestion: ProgressionSuggestion, version: RoutineVersion, row: PlannedExercise, scope: ProgressionScope) {
        if model.updateUserData({ try $0.acceptProgression(suggestion, versionID: version.id, rowID: row.id, scope: scope) }) {
            switch scope {
            case .routine: showCurrent = true; status = "Recommendation saved as a new routine version."
            case .once: status = "Queued for the next matching workout."
            case .dismiss: status = "Recommendation dismissed."
            }
        }
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
    @State private var topSessions: Int
    @State private var allowExtraSet: Bool
    @State private var plateauSessions: Int
    @State private var volumeCap: Int
    @State private var effort: ProgressionRule.Effort
    @State private var step: String
    @State private var effortLimit: String

    init(model: TrainingModel, unit: WeightUnit, version: RoutineVersion, row: PlannedExercise, rule: ProgressionRule?) {
        self.model = model
        self.unit = unit
        self.version = version
        self.row = row
        self.rule = rule
        _mode = State(initialValue: model.records.disabledProgression?.contains(row.variant.key) == true ? nil :
            (rule?.mode ?? row.progressionModes.first))
        _topSessions = State(initialValue: rule?.topSessions ?? 2)
        _allowExtraSet = State(initialValue: rule?.allowExtraSet ?? false)
        _plateauSessions = State(initialValue: rule?.plateauSessions ?? 3)
        _volumeCap = State(initialValue: rule?.volumeCap ?? 6)
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
                            TextField("Smallest available increment (\(stepLabel(mode)))", text: $step).keyboardType(.decimalPad)
                            Stepper("Sessions required to increase target · \(topSessions)", value: $topSessions, in: 2...12)
                        }
                        Picker("Use recorded effort", selection: $effort) {
                            ForEach(ProgressionRule.Effort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        if effort != .none { TextField("Effort threshold", text: $effortLimit).keyboardType(.decimalPad) }
                        Toggle("Allow an extra working set on a plateau", isOn: $allowExtraSet)
                        if allowExtraSet {
                            Stepper("Plateau sessions · \(plateauSessions)", value: $plateauSessions, in: 2...12)
                            Stepper("Working set cap per workout · \(volumeCap)", value: $volumeCap, in: 1...30)
                        }
                    }
                    if let error = model.storageError { Text(error).foregroundStyle(Palette.red) }
                } header: {
                    Text("Progression rule")
                } footer: {
                    Text("Load changes use the entered increment or saved equipment inventory. Adding a set also needs recorded effort in reserve or a favorable readiness check-in.")
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
            return ProgressionRule(mode: mode, threshold: .top, miss: .stepBack, step: mode == .reps ? nil : amount,
                effort: effort, effortLimit: limit, topSessions: topSessions, allowExtraSet: allowExtraSet,
                plateauSessions: plateauSessions, volumeCap: volumeCap)
        }
        if model.updateUserData({ try $0.saveProgressionRule(configuration, versionID: version.id, rowID: row.id) }) { dismiss() }
    }
}

struct WorkoutRecommendations: View {
    let model: TrainingModel
    let version: RoutineVersion
    let unit: WeightUnit
    var exerciseIDs: Set<UUID>? = nil
    @State private var selected: PlannedExercise?
    @State private var expanded = true

    var body: some View {
        if version.revision > 0 {
            let entries = version.exercises.filter { exerciseIDs?.contains($0.id) ?? true }
            if !entries.isEmpty {
                DisclosureGroup("Workout recommendations", isExpanded: $expanded) {
                    ForEach(entries) { row in
                        let suggestion = ExerciseProgression.suggest(row, in: version, records: model.records)
                        if suggestion.action != .off {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("\(row.variant.exercise.name) · \(suggestion.action.rawValue)").font(.subheadline.weight(.semibold))
                                Text(suggestion.reason).font(.caption)
                                if let queued = model.records.progressionDecisions?.first(where: {
                                    $0.versionID == version.id && $0.rowID == row.id
                                })?.working {
                                    let summary = queued.map { row.summary($0, unit: unit, fractionDigits: 0...4) }.joined(separator: " + ")
                                    Text("Queued targets · \(summary)").font(.caption)
                                }
                                ForEach(suggestion.changes.keys.sorted(), id: \.self) { index in
                                    if let changed = suggestion.changes[index] {
                                        let before = row.summary(row.workingSets[index], unit: unit, fractionDigits: 0...4)
                                        let after = (suggestion.replacements[index] ?? [changed]).map {
                                            row.summary($0, unit: unit, fractionDigits: 0...4)
                                        }.joined(separator: " + ")
                                        Text("\(before) → \(after.isEmpty ? "Remove block" : after)").font(.caption)
                                    }
                                }
                                if let warning = suggestion.warning { Text(warning).font(.caption).foregroundStyle(Palette.purple) }
                                Button("Review \(row.variant.exercise.name)") { selected = row }.buttonStyle(SecondaryButton())
                            }.padding(.vertical, 6)
                        }
                    }
                }
                .sheet(item: $selected) { row in
                    NavigationStack {
                        ProgressionDetail(model: model, unit: unit, routineID: version.routineID, rowID: row.id, pinnedVersionID: version.id)
                            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { selected = nil } } }
                    }
                }
            }
        }
    }
}
