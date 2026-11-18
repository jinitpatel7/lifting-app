import SwiftUI

struct RoutineEditor: View {
    let model: TrainingModel
    let unit: WeightUnit
    let original: RoutineVersion?
    let sessionID: UUID?
    @Environment(\.dismiss) private var dismiss
    @State private var routineID: UUID
    @State private var name: String
    @State private var categoryID: UUID?
    @State private var rows: [ExercisePlanDraft]
    @State private var groups: [RoutineGroup]
    @State private var picking = false
    @State private var advanced = false
    @State private var categoryName = ""
    @State private var error: String?

    init(model: TrainingModel, unit: WeightUnit, original: RoutineVersion? = nil, sessionID: UUID? = nil) {
        self.model = model
        self.unit = unit
        self.original = original
        self.sessionID = sessionID
        _routineID = State(initialValue: original?.routineID ?? UUID())
        _name = State(initialValue: original?.name ?? "")
        _categoryID = State(initialValue: original?.categoryID)
        _rows = State(initialValue: original?.exercises.map { ExercisePlanDraft($0, unit: unit) } ?? [])
        _groups = State(initialValue: original?.groups ?? [])
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Routine name", text: $name).frame(minHeight: 44)
                    if sessionID == nil {
                        Picker("Category", selection: $categoryID) {
                            Text("Uncategorized").tag(nil as UUID?)
                            ForEach(model.records.routineCategories ?? []) { Text($0.name).tag(Optional($0.id)) }
                        }
                    }
                } footer: {
                    if sessionID != nil { Text("Changes apply to this workout only.") }
                    else if original != nil { Text("Saving creates a routine version for future workouts.") }
                }
                Section("Exercises") {
                    ForEach($rows) { $row in
                        NavigationLink {
                            ExercisePlanEditor(model: model, unit: unit, row: $row)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(row.exercise.name)
                                Text(row.label).font(.caption).foregroundStyle(Palette.muted)
                            }
                            .frame(minHeight: 44)
                        }
                    }
                    .onMove { from, to in rows.move(fromOffsets: from, toOffset: to) }
                    .onDelete(perform: remove)
                    Button { picking = true } label: { Label("Add exercise", systemImage: "plus") }.frame(minHeight: 44)
                }
                Section {
                    DisclosureGroup("Advanced routine options", isExpanded: $advanced) {
                        if sessionID == nil {
                            TextField("New category", text: $categoryName)
                            Button("Create category", action: createCategory).disabled(categoryName.trimmed.isEmpty)
                        }
                        ForEach($groups) { $group in
                            NavigationLink("\(group.kind.rawValue) · \(group.exerciseIDs.count) exercises") {
                                RoutineGroupEditor(group: $group, rows: rows, otherGroups: groups.filter { $0.id != group.id })
                            }
                        }
                        .onDelete { groups.remove(atOffsets: $0) }
                        Button("Add superset") { addGroup(.superset) }
                        Button("Add circuit") { addGroup(.circuit) }
                        if !groups.isEmpty { Text("Group members run in routine order. Drag to keep members together.").font(.caption) }
                    }
                }
                if let issue = error ?? model.storageError {
                    Section { Text(issue).foregroundStyle(Palette.red) }
                }
            }
            .navigationTitle(sessionID != nil ? "Edit this workout" : original == nil ? "New routine" : "Edit routine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItemGroup(placement: .primaryAction) {
                    EditButton()
                    Button(sessionID == nil ? "Save routine" : "Save this workout", action: save)
                        .disabled(name.trimmed.isEmpty || rows.isEmpty)
                }
            }
            .sheet(isPresented: $picking) {
                RoutineExercisePicker(model: model) { rows.append(ExercisePlanDraft(exercise: $0)) }
            }
            .tint(Palette.purple)
        }
    }

    private func remove(_ offsets: IndexSet) {
        let removed = Set(offsets.map { rows[$0].id })
        rows.remove(atOffsets: offsets)
        for index in groups.indices { groups[index].exerciseIDs.removeAll(where: removed.contains) }
        groups.removeAll { $0.exerciseIDs.count < 2 }
    }

    private func addGroup(_ kind: RoutineGroup.Kind) {
        groups.append(RoutineGroup(kind: kind, exerciseIDs: [], rounds: 3))
    }

    private func createCategory() {
        let category = RoutineCategory(name: categoryName.trimmed)
        if model.addRoutineCategory(category) {
            categoryID = category.id
            categoryName = ""
            error = nil
        }
    }

    private func save() {
        error = nil
        do {
            let exercises = try rows.map { try $0.planned(unit: unit) }
            let saved: Bool
            if let sessionID {
                saved = model.editSessionPlan(sessionID, name: name.trimmed, exercises: exercises, groups: groups)
            } else {
                saved = model.saveRoutine(id: routineID, name: name.trimmed, exercises: exercises, categoryID: categoryID,
                                          groups: groups, expectedVersionID: original?.id)
            }
            if saved { dismiss() }
        } catch { self.error = error.localizedDescription }
    }
}

private struct RoutineExercisePicker: View {
    let model: TrainingModel
    let pick: (Exercise) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        NavigationStack {
            List {
                let results = ExerciseLibraryQuery(name: name).results(catalog: model.catalog, custom: model.records.exercises,
                                                                      preferences: model.records.exercisePreferences ?? [:])
                if results.isEmpty { ContentUnavailableView("No matching exercises", systemImage: "magnifyingglass") }
                ForEach(results) { exercise in
                    Button {
                        pick(exercise)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(exercise.name)
                            if let profile = exercise.profile {
                                Text([LibraryEquipment(profile.equipmentKind).label, profile.variation].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(Palette.muted)
                            }
                        }
                        .frame(minHeight: 44)
                    }
                }
            }
            .searchable(text: $name, prompt: "Search exercises")
            .navigationTitle("Add exercise")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

private struct RoutineGroupEditor: View {
    @Binding var group: RoutineGroup
    let rows: [ExercisePlanDraft]
    let otherGroups: [RoutineGroup]

    var body: some View {
        Form {
            Section("Rounds and rest") {
                Stepper("Rounds: \(group.rounds)", value: $group.rounds, in: 1...Int.max)
                LabeledContent("Rest between exercises (sec)") { TextField("0", value: $group.restBetweenExercises, format: .number).keyboardType(.numberPad) }
                LabeledContent("Rest between rounds (sec)") { TextField("0", value: $group.restBetweenRounds, format: .number).keyboardType(.numberPad) }
            }
            Section("Consecutive exercises") {
                ForEach(rows.indices, id: \.self) { index in
                    let row = rows[index]
                    Toggle("\(index + 1). \(row.exercise.name)", isOn: Binding(get: { group.exerciseIDs.contains(row.id) }, set: { included in
                        if included { group.exerciseIDs.append(row.id) }
                        else { group.exerciseIDs.removeAll { $0 == row.id } }
                    }))
                    .disabled(otherGroups.contains { $0.exerciseIDs.contains(row.id) })
                }
            }
        }
        .navigationTitle(group.kind.rawValue)
    }
}

private enum MeasurementChoice: String, CaseIterable, Identifiable, Hashable {
    case weight = "Weight and reps", bodyweight = "Bodyweight", added = "Added load", assistance = "Assistance"
    case duration = "Duration", distance = "Distance", setting = "Machine setting"
    var id: Self { self }
    var hasReps: Bool { self != .duration && self != .distance }

    init(_ measurement: Measurement) {
        switch measurement {
        case .weightReps: self = .weight
        case .bodyweight: self = .bodyweight
        case .addedLoad: self = .added
        case .assistance: self = .assistance
        case .duration: self = .duration
        case .distance: self = .distance
        case .machineSetting: self = .setting
        }
    }

    func measurement(basis: LoadBasis, reps: RepCounting) -> Measurement {
        switch self {
        case .weight: .weightReps(basis: basis, reps: reps)
        case .bodyweight: .bodyweight(reps: reps)
        case .added: .addedLoad(reps: reps)
        case .assistance: .assistance(reps: reps)
        case .duration: .duration
        case .distance: .distance
        case .setting: .machineSetting(reps: reps)
        }
    }

    func targetLabel(_ unit: WeightUnit) -> String {
        switch self {
        case .duration: "Duration (seconds)"
        case .distance: "Distance (meters)"
        case .setting: "Machine setting"
        default: "Target load (\(unit.rawValue))"
        }
    }

    func amount(_ input: String, unit: WeightUnit) throws -> SetAmount? {
        guard self != .bodyweight, !input.trimmed.isEmpty else { return nil }
        if self == .setting { return .machineSetting(input.trimmed) }
        guard let value = try? Double(input.trimmed, format: .number, lenient: false), value.isFinite,
              let mass = Mass(value, unit: unit) else {
            throw TrainingDataError.invalidRecord("Enter a valid nonnegative number for \(targetLabel(unit).lowercased()).")
        }
        switch self {
        case .duration: return .durationSeconds(value)
        case .distance: return .distanceMeters(value)
        case .added: return .addedLoad(mass)
        case .assistance: return .assistance(mass)
        default: return .weight(mass)
        }
    }
}

private struct ExercisePlanDraft: Identifiable {
    var id = UUID()
    let exercise: Exercise
    var equipment: Equipment?
    var choice: MeasurementChoice
    var basis: LoadBasis = .total
    var counting: RepCounting = .total
    var warmUps: [SetPlanDraft] = []
    var work: [SetPlanDraft] = [SetPlanDraft()]

    var label: String { "\(warmUps.count + work.count) set blocks · \(choice.rawValue)" }

    init(exercise: Exercise) {
        self.exercise = exercise
        choice = exercise.profile != nil && exercise.profile?.equipmentKind == nil ? .bodyweight : .weight
    }

    init(_ entry: PlannedExercise, unit: WeightUnit) {
        id = entry.id
        exercise = entry.variant.exercise
        equipment = entry.variant.equipment
        choice = MeasurementChoice(entry.variant.measurement)
        if case .weightReps(let loadBasis, _) = entry.variant.measurement { basis = loadBasis }
        counting = entry.variant.measurement.repCounting ?? .total
        warmUps = (entry.warmUps ?? []).map { SetPlanDraft($0, unit: unit) }
        work = entry.workingSets.map { SetPlanDraft($0, unit: unit) }
    }

    func planned(unit: WeightUnit) throws -> PlannedExercise {
        let measurement = choice.measurement(basis: basis, reps: counting)
        guard measurement.supports(equipment) else {
            throw TrainingDataError.invalidRecord("Choose compatible equipment for \(exercise.name).")
        }
        let working = try work.map { try $0.prescription(choice: choice, measurement: measurement, unit: unit) }
        guard let first = working.first else { throw TrainingDataError.invalidRecord("Add a working set block for \(exercise.name).") }
        let warm = try warmUps.map { try $0.prescription(choice: choice, measurement: measurement, unit: unit) }
        return PlannedExercise(id: id, variant: ExerciseVariant(exercise: exercise, equipment: equipment, measurement: measurement),
                               prescription: first, warmUps: warm.isEmpty ? nil : warm,
                               additionalWorkingSets: working.count > 1 ? Array(working.dropFirst()) : nil)
    }
}

private enum EffortChoice: String, CaseIterable, Identifiable, Hashable {
    case none = "None", rir = "RIR", rpe = "RPE", failure = "To failure"
    var id: Self { self }
}

private struct SetPlanDraft: Identifiable {
    var id = UUID()
    var count = "1"
    var minReps = ""
    var maxReps = ""
    var amount = ""
    var rest = ""
    var effortChoice: EffortChoice = .none
    var effortValue = ""
    var structure: SetStructure = .straight
    var amrap = false
    private var originalTarget: SetAmount?
    private var originalAmount = ""

    init(warmUp: Bool = false) { if warmUp { count = "1" } }

    init(_ prescription: SetPrescription, unit: WeightUnit) {
        count = String(prescription.sets)
        minReps = prescription.reps.map { String($0.minimum) } ?? ""
        maxReps = prescription.reps.map { String($0.maximum) } ?? ""
        rest = prescription.restSeconds.map { String($0) } ?? ""
        structure = prescription.structure ?? .straight
        amrap = prescription.amrap == true
        if let rir = prescription.repsInReserve { effortChoice = .rir; effortValue = String(rir) }
        if case .rpe(let rpe) = prescription.effort { effortChoice = .rpe; effortValue = rpe.formatted(.number.grouping(.never)) }
        if prescription.effort == .failure { effortChoice = .failure }
        switch prescription.target {
        case .weight(let mass), .assistance(let mass), .addedLoad(let mass):
            amount = mass.value(in: unit).formatted(.number.grouping(.never).precision(.fractionLength(0...6)))
        case .durationSeconds(let value), .distanceMeters(let value): amount = value.formatted(.number.grouping(.never))
        case .machineSetting(let label): amount = label
        case nil: break
        }
        originalTarget = prescription.target
        originalAmount = amount
    }

    mutating func clearTarget() {
        amount = ""
        originalTarget = nil
        originalAmount = ""
    }

    func prescription(choice: MeasurementChoice, measurement: Measurement, unit: WeightUnit) throws -> SetPrescription {
        guard let sets = Int(count.trimmed), sets > 0 else { throw TrainingDataError.invalidRecord("Each set block needs a positive set count.") }
        var reps: RepRange?
        if choice.hasReps, !amrap || !minReps.trimmed.isEmpty || !maxReps.trimmed.isEmpty {
            guard let minimum = Int(minReps.trimmed), let maximum = Int(maxReps.trimmed.isEmpty ? minReps.trimmed : maxReps.trimmed) else {
                throw TrainingDataError.invalidRecord("Enter a rep range or enable AMRAP.")
            }
            reps = RepRange(minimum: minimum, maximum: maximum)
        }
        var restSeconds: Int?
        if !rest.trimmed.isEmpty {
            guard let seconds = Int(rest.trimmed) else { throw TrainingDataError.invalidRecord("Enter rest in whole seconds.") }
            restSeconds = seconds
        }
        var rir: Int?
        var effort: EffortTarget?
        switch effortChoice {
        case .none: break
        case .failure: effort = .failure
        case .rir:
            guard let value = Int(effortValue.trimmed) else { throw TrainingDataError.invalidRecord("Enter target RIR as a whole number.") }
            rir = value
        case .rpe:
            guard let value = try? Double(effortValue.trimmed, format: .number, lenient: false) else {
                throw TrainingDataError.invalidRecord("Enter target RPE from 1 to 10.")
            }
            effort = .rpe(value)
        }
        let target = amount == originalAmount && originalTarget != nil ? originalTarget : try choice.amount(amount, unit: unit)
        let result = SetPrescription(sets: sets, reps: reps, target: target, repsInReserve: rir, restSeconds: restSeconds,
                                     structure: structure == .straight ? nil : structure, amrap: choice.hasReps && amrap ? true : nil, effort: effort)
        guard result.isValid(for: measurement) else { throw TrainingDataError.invalidRecord("Check the rep range, target, rest, and effort for each set block.") }
        return result
    }
}

private struct ExercisePlanEditor: View {
    let model: TrainingModel
    let unit: WeightUnit
    @Binding var row: ExercisePlanDraft
    @State private var equipmentName = ""
    @State private var equipmentKind: EquipmentKind = .machine

    var body: some View {
        Form {
            Section("Measurement") {
                Picker("Track by", selection: $row.choice) { ForEach(MeasurementChoice.allCases) { Text($0.rawValue).tag($0) } }
                    .onChange(of: row.choice) { clearTargets() }
                DisclosureGroup("Equipment and rep convention") {
                    Picker("Equipment", selection: Binding(get: { row.equipment?.id }, set: { id in
                        row.equipment = model.records.equipment.first { $0.id == id }
                    })) {
                        Text("Unspecified").tag(nil as UUID?)
                        ForEach(model.records.equipment) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .onChange(of: row.equipment?.id) { if row.choice == .setting { clearTargets() } }
                    if row.choice == .weight {
                        Picker("Load convention", selection: $row.basis) {
                            Text("Total load").tag(LoadBasis.total)
                            Text("Per dumbbell").tag(LoadBasis.perDumbbell)
                        }
                        .onChange(of: row.basis) { clearTargets() }
                    }
                    if row.choice.hasReps {
                        Picker("Rep counting", selection: $row.counting) {
                            Text("Total reps").tag(RepCounting.total)
                            Text("Per side").tag(RepCounting.perSide)
                            Text("Separate sides").tag(RepCounting.separateSides)
                        }
                    }
                    TextField("New equipment name", text: $equipmentName)
                    Picker("Equipment type", selection: $equipmentKind) {
                        ForEach(EquipmentKind.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    Button("Add equipment") {
                        let equipment = Equipment(name: equipmentName.trimmed, kind: equipmentKind)
                        if model.addEquipment(equipment) { row.equipment = equipment; equipmentName = "" }
                    }
                    .disabled(equipmentName.trimmed.isEmpty)
                }
            }
            Section("Working sets") {
                ForEach($row.work) { $block in SetBlockEditor(block: $block, choice: row.choice, unit: unit) }
                    .onDelete { if row.work.count > $0.count { row.work.remove(atOffsets: $0) } }
                Button("Add working set block") { row.work.append(SetPlanDraft()) }
            }
            Section {
                DisclosureGroup("Warm-up sets") {
                    ForEach($row.warmUps) { $block in SetBlockEditor(block: $block, choice: row.choice, unit: unit) }
                        .onDelete { row.warmUps.remove(atOffsets: $0) }
                    Button("Add warm-up set block") { row.warmUps.append(SetPlanDraft(warmUp: true)) }
                }
            }
            if let error = model.storageError { Text(error).foregroundStyle(Palette.red) }
        }
        .navigationTitle(row.exercise.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
    }

    private func clearTargets() {
        for index in row.work.indices { row.work[index].clearTarget() }
        for index in row.warmUps.indices { row.warmUps[index].clearTarget() }
    }
}

private struct SetBlockEditor: View {
    @Binding var block: SetPlanDraft
    let choice: MeasurementChoice
    let unit: WeightUnit

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            field("Sets", value: $block.count)
            if choice.hasReps {
                field("Minimum reps", value: $block.minReps)
                field("Maximum reps", value: $block.maxReps)
            }
            if choice != .bodyweight {
                LabeledContent(choice.targetLabel(unit)) {
                    TextField("Optional", text: $block.amount).keyboardType(choice == .setting ? .default : .decimalPad)
                }
            }
            field("Rest (seconds)", value: $block.rest)
            DisclosureGroup("Set structure and effort") {
                Picker("Set structure", selection: $block.structure) { ForEach(SetStructure.allCases) { Text($0.rawValue).tag($0) } }
                if choice.hasReps { Toggle("AMRAP", isOn: $block.amrap) }
                Picker("Target effort", selection: $block.effortChoice) { ForEach(EffortChoice.allCases) { Text($0.rawValue).tag($0) } }
                if block.effortChoice == .rir || block.effortChoice == .rpe {
                    LabeledContent(block.effortChoice.rawValue) { TextField("Target", text: $block.effortValue).keyboardType(.decimalPad) }
                }
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(.vertical, 5)
    }

    private func field(_ title: String, value: Binding<String>) -> some View {
        LabeledContent(title) { TextField(title, text: value).keyboardType(.numberPad) }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
