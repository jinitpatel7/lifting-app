import SwiftUI

extension ScheduleStatus {
    var symbol: String {
        switch self {
        case .planned: "calendar"
        case .completed: "checkmark.circle.fill"
        case .active: "play.circle.fill"
        case .skipped: "forward.circle"
        case .missed: "clock.badge.exclamationmark"
        case .rescheduled, .moved: "arrow.turn.down.right"
        }
    }

    var tint: Color {
        switch self {
        case .completed: .green
        case .skipped, .missed: Palette.muted
        case .rescheduled, .moved: Palette.red
        default: Palette.purple
        }
    }
}

extension WorkoutDate {
    var localPickerDate: Date {
        var format = Self.format
        format.timeZone = .current
        return (try? format.parse(key)) ?? Date()
    }
}

private struct ScheduleVersionPicker: View {
    let records: TrainingRecords
    let label: String
    @Binding var selection: UUID?

    var body: some View {
        Picker(label, selection: $selection) {
            Text("Choose a version").tag(nil as UUID?)
            ForEach(records.routineVersions.reversed()) { version in
                Text("\(version.name) · v\(version.revision)").tag(Optional(version.id))
            }
        }
    }
}

struct TrainingScheduleSheet: View {
    let model: TrainingModel
    @Environment(\.dismiss) private var dismiss
    @State private var settings: ScheduleSettings

    init(model: TrainingModel) {
        self.model = model
        _settings = State(initialValue: model.records.scheduleSettings ?? ScheduleSettings())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Calendar view") {
                    Picker("Week starts on", selection: $settings.weekStart) {
                        ForEach(TrainingWeekday.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Calendar view", selection: $settings.mode) {
                        ForEach(ScheduleSettings.ViewMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Button("Save calendar view") {
                        if model.updateUserData({ try $0.saveScheduleSettings(settings) }) { dismiss() }
                    }
                }
                Section("Planning") {
                    NavigationLink("Weekday assignments") { WeekdayAssignmentScreen(model: model) }
                    NavigationLink("Rotating sequence") { RotationScheduleScreen(model: model) }
                    NavigationLink("Program blocks") { ProgramBlocksScreen(model: model) }
                }
                ScheduleError(model: model)
            }
            .navigationTitle("Training schedule")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }
}

private struct WeekdayAssignmentScreen: View {
    let model: TrainingModel
    @State private var weekday = WorkoutDate(Date()).weekday
    @State private var start = Date()
    @State private var versionID: UUID?

    var body: some View {
        Form {
            Section("Assignments") {
                let rules = (model.records.weekdayRules ?? []).filter { $0.endBefore == nil }
                if rules.isEmpty { Text("No weekday assignments").foregroundStyle(Palette.muted) }
                ForEach(rules) { rule in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(rule.weekday.label + " · " + (model.records.version(rule.versionID)?.name ?? "Routine"))
                        Text("From \(rule.start.key)").font(.caption).foregroundStyle(Palette.muted)
                        Button("End weekday assignment", role: .destructive) {
                            _ = model.updateUserData { try $0.endWeekday(rule.id, today: WorkoutDate(Date())) }
                        }.buttonStyle(.borderless)
                    }
                }
            }
            Section("Add assignment") {
                Picker("Weekday", selection: $weekday) { ForEach(TrainingWeekday.allCases) { Text($0.label).tag($0) } }
                ScheduleVersionPicker(records: model.records, label: "Routine version", selection: $versionID)
                DatePicker("Start date", selection: $start, displayedComponents: .date)
                Button("Assign weekday") {
                    if let versionID {
                        _ = model.updateUserData { try $0.assignWeekday(WeekdayAssignment(weekday: weekday,
                            versionID: versionID, start: WorkoutDate(start))) }
                    }
                }.disabled(versionID == nil)
            }
            ScheduleError(model: model)
        }
        .navigationTitle("Weekday assignments")
    }
}

private struct RotationScheduleScreen: View {
    let model: TrainingModel
    @State private var start = Date()
    @State private var interval: Int
    @State private var versionID: UUID?
    @State private var steps: [UUID]

    init(model: TrainingModel) {
        self.model = model
        let current = model.records.rotations?.first { $0.endBefore == nil }
        _interval = State(initialValue: current?.interval ?? 1)
        _steps = State(initialValue: current?.versionIDs ?? [])
    }

    var body: some View {
        Form {
            Section {
                Text("A finished session with logged sets or an explicit skip advances the sequence. A missed day holds your place. The calendar shows the next rotation slot.")
                    .font(.subheadline).foregroundStyle(Palette.muted)
                if let current = model.records.rotations?.first(where: { $0.endBefore == nil }) {
                    Text(current.versionIDs.compactMap { model.records.version($0)?.name }.joined(separator: " → "))
                    Text("Every \(current.interval) day(s) from \(current.start.key)").font(.caption).foregroundStyle(Palette.muted)
                    Button("End rotation", role: .destructive) {
                        if model.updateUserData({ try $0.endRotation(current.id, today: WorkoutDate(Date())) }) { steps = [] }
                    }
                }
            }
            Section("Sequence settings") {
                DatePicker("Start date", selection: $start, displayedComponents: .date)
                Stepper("Days between slots · \(interval)", value: $interval, in: 1...30)
                ScheduleVersionPicker(records: model.records, label: "Routine version", selection: $versionID)
                Button("Add to sequence") { if let versionID { steps.append(versionID); self.versionID = nil } }.disabled(versionID == nil)
            }
            Section("Sequence order") {
                ForEach(steps.indices, id: \.self) { index in
                    HStack {
                        Text("\(index + 1). \(model.records.version(steps[index])?.name ?? "Routine")")
                        Spacer()
                        Menu("Step options") {
                            if index > 0 { Button("Move up") { steps.swapAt(index, index - 1) } }
                            if index + 1 < steps.count { Button("Move down") { steps.swapAt(index, index + 1) } }
                            Button("Remove step", role: .destructive) { steps.remove(at: index) }
                        }
                    }
                }
                Button(model.records.rotations?.contains(where: { $0.endBefore == nil }) == true ? "Replace rotation" : "Save rotation") {
                    _ = model.updateUserData { try $0.saveRotation(RoutineRotation(start: WorkoutDate(start), interval: interval,
                        versionIDs: steps), today: WorkoutDate(Date())) }
                }.disabled(steps.isEmpty)
            }
            ScheduleError(model: model)
        }
        .navigationTitle("Rotating sequence")
    }
}

private struct ProgramBlocksScreen: View {
    let model: TrainingModel
    @State private var name = ""
    @State private var start = Date()
    @State private var count = 4

    var body: some View {
        Form {
            Section("Saved programs") {
                if model.records.programBlocks.isEmpty { Text("No program blocks").foregroundStyle(Palette.muted) }
                ForEach(model.records.programBlocks) { block in
                    NavigationLink {
                        ProgramWeeksScreen(model: model, blockID: block.id)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(block.name)
                            Text("\(block.firstDay.key) to \(block.lastDay.key)").font(.caption).foregroundStyle(Palette.muted)
                        }
                    }
                }
            }
            Section("New program block") {
                TextField("Program name", text: $name)
                DatePicker("Start date", selection: $start, displayedComponents: .date)
                Stepper("Number of weeks · \(count)", value: $count, in: 2...52)
                Button("Create program block") {
                    let first = WorkoutDate(start)
                    if model.updateUserData({ try $0.addProgramBlock(ProgramBlock(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                        firstDay: first, lastDay: first.offset(count * 7 - 1))) }) { name = "" }
                }
            }
            ScheduleError(model: model)
        }
        .navigationTitle("Program blocks")
    }
}

private struct ProgramWeeksScreen: View {
    let model: TrainingModel
    let blockID: UUID
    @State private var week = 0
    @State private var draft = ProgramWeek()
    @State private var workoutDate = Date()
    @State private var versionID: UUID?

    var body: some View {
        if let block = model.records.programBlocks.first(where: { $0.id == blockID }) {
            let first = block.firstDay.offset(week * 7)
            let last = min(first.offset(6), block.lastDay)
            Form {
                Section("Week") {
                    Picker("Program week", selection: $week) {
                        ForEach(0..<block.weekCount, id: \.self) { index in
                            Text("Week \(index + 1) · \((block.weeks?[index]?.kind ?? .training).rawValue)").tag(index)
                        }
                    }
                    Text("\(first.key) to \(last.key)").font(.caption).foregroundStyle(Palette.muted)
                    Picker("Week type", selection: $draft.kind) {
                        ForEach(ProgramWeekKind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    TextField("Progression or deload notes", text: $draft.notes, axis: .vertical)
                    Button("Save week") { _ = model.updateUserData { try $0.setProgramWeek(blockID: block.id, index: week, week: draft) } }
                }
                Section("Scheduled sessions") {
                    let entries = model.records.schedule.filter {
                        $0.programBlockID == blockID && block.weekIndex(for: $0.movedFrom?.first ?? $0.localDate) == week
                    }
                    let slots = model.records.scheduled(on: entries.map(\.localDate), today: WorkoutDate(Date()))
                    ForEach(entries) { entry in
                        if let version = model.records.version(entry.routineVersionID) {
                            let status = slots.first { $0.id == entry.id.uuidString }?.status ?? .planned
                            Label("\(entry.localDate.key) · \(version.name) · v\(version.revision) · \(status.rawValue)", systemImage: status.symbol)
                        }
                    }
                    Text("Choose the routine version with the targets you want to train this week.").font(.caption).foregroundStyle(Palette.muted)
                    DatePicker("Program session date", selection: $workoutDate, displayedComponents: .date)
                    ScheduleVersionPicker(records: model.records, label: "Routine version", selection: $versionID)
                    Button("Add program session") {
                        if let versionID {
                            _ = model.updateUserData { store in
                                let chosen = WorkoutDate(workoutDate)
                                guard first...last ~= chosen else { throw TrainingDataError.invalidRecord("Choose a date within this program week.") }
                                try store.addScheduledWorkout(ScheduledWorkout(localDate: chosen, routineVersionID: versionID, programBlockID: block.id))
                            }
                        }
                    }.disabled(versionID == nil)
                }
                ScheduleError(model: model)
            }
            .navigationTitle(block.name)
            .onAppear { selectWeek(block) }
            .onChange(of: week) { selectWeek(block) }
        }
    }

    private func selectWeek(_ block: ProgramBlock) {
        draft = block.weeks?[week] ?? ProgramWeek()
        workoutDate = block.firstDay.offset(week * 7).localPickerDate
    }
}

struct ScheduleMoveSheet: View {
    let model: TrainingModel
    let slot: ScheduleOccurrence
    @Environment(\.dismiss) private var dismiss
    @State private var destination: Date

    init(model: TrainingModel, slot: ScheduleOccurrence) {
        self.model = model
        self.slot = slot
        let today = WorkoutDate(Date())
        _destination = State(initialValue: (today == slot.date ? today.offset(1) : today).localPickerDate)
    }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("New workout date", selection: $destination, displayedComponents: .date)
                ScheduleError(model: model)
            }
            .navigationTitle("Move scheduled session")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save new date") {
                        if model.updateUserData({ try $0.moveSchedule(slot.id, on: slot.date, to: WorkoutDate(destination),
                            today: WorkoutDate(Date())) }) { dismiss() }
                    }
                }
            }
        }
    }
}

struct ReadinessSheet: View {
    let model: TrainingModel
    let day: WorkoutDate
    @Environment(\.dismiss) private var dismiss
    @State private var soreness: Int
    @State private var sleep: Int
    @State private var energy: Int
    @State private var motivation: Int

    init(model: TrainingModel, day: WorkoutDate) {
        self.model = model
        self.day = day
        let entry = model.records.readiness.last { $0.localDate == day }
        _soreness = State(initialValue: entry?.soreness ?? 0)
        _sleep = State(initialValue: entry?.sleepQuality ?? 0)
        _energy = State(initialValue: entry?.energy ?? 0)
        _motivation = State(initialValue: entry?.motivation ?? 0)
    }

    var body: some View {
        NavigationStack {
            Form {
                Text("Soreness ranges from none to high. Sleep quality, energy, and motivation range from low to high.").font(.subheadline)
                rating("Soreness", value: $soreness)
                rating("Sleep quality", value: $sleep)
                rating("Energy", value: $energy)
                rating("Motivation", value: $motivation)
                ScheduleError(model: model)
            }
            .navigationTitle("Readiness")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save check-in") {
                        if model.updateUserData({ try $0.saveReadiness(on: day, soreness: soreness, sleep: sleep, energy: energy, motivation: motivation) }) { dismiss() }
                    }.disabled([soreness, sleep, energy, motivation].contains(0))
                }
            }
        }
    }

    private func rating(_ title: String, value: Binding<Int>) -> some View {
        Picker(title, selection: value) {
            Text("Choose 1–5").tag(0)
            ForEach(1...5, id: \.self) { Text("\($0)").tag($0) }
        }
    }
}

private struct ScheduleError: View {
    let model: TrainingModel
    var body: some View {
        if let error = model.storageError { Text(error).foregroundStyle(Palette.red) }
    }
}
