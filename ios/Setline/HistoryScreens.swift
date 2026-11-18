import SwiftUI

private enum HistorySheet: Identifiable {
    case add(WorkoutDate), edit(UUID), compare(UUID), weight(WorkoutDate)
    case photos(WorkoutDate, UUID?), comparePhotos(WorkoutDate), progression

    var id: String {
        switch self {
        case .add(let day): "add-\(day.key)"
        case .edit(let id): "edit-\(id.uuidString)"
        case .compare(let id): "compare-\(id.uuidString)"
        case .weight(let day): "weight-\(day.key)"
        case .photos(let day, let session): "photos-\(day.key)-\(session?.uuidString ?? "date")"
        case .comparePhotos(let day): "compare-photos-\(day.key)"
        case .progression: "progression"
        }
    }
}

struct PersonalHistoryScreen: View {
    let model: TrainingModel
    let unit: WeightUnit
    let repeatWorkout: (UUID) -> Void
    let resume: () -> Void
    @Binding var jumpTo: WorkoutDate?
    @Binding var selection: HistoryScreen.Section
    @State private var layout = HistoryLayout.list
    @State private var day = WorkoutDate(Date())
    @State private var month = WorkoutDate(Date())
    @State private var filter = HistoryFilter()
    @State private var presented: HistorySheet?

    private enum HistoryLayout: String, CaseIterable, Identifiable {
        case list = "Chronological list", calendar = "Calendar"
        var id: Self { self }
    }

    var body: some View {
        VStack(spacing: 14) {
            PageHeading(title: "History", subtitle: "Your training progress")
            SelectionControl(label: "History view", selection: $selection, options: HistoryScreen.Section.allCases, title: \.rawValue)
            Button("Compare progress photos") { presented = .comparePhotos(day) }.buttonStyle(SecondaryButton())
            filters
            if selection == .progress { progress }
            else { sessions }
        }
        .onAppear { focusDate(jumpTo) }
        .onChange(of: jumpTo) { focusDate(jumpTo) }
        .sheet(item: $presented) { sheet in
            switch sheet {
            case .add(let date):
                HistoryEditor(model: model, date: date, unit: unit) { saved in
                    if layout == .calendar { month = saved; day = saved }
                }
            case .edit(let id):
                if let session = model.records.sessions.first(where: { $0.id == id }) {
                    HistoryEditor(model: model, session: session, date: session.localDate, unit: unit)
                }
            case .compare(let id):
                if let session = model.records.sessions.first(where: { $0.id == id }) {
                    HistoryComparisonSheet(session: session, sessions: model.records.sessions, unit: unit)
                }
            case .weight(let date):
                WeightSheet(model: model, date: date.key, unit: unit, sampleMode: false)
            case .photos(let date, let session):
                ProgressPhotosSheet(model: model, day: date, sessionID: session)
            case .comparePhotos(let date):
                ProgressPhotoComparisonSheet(model: model, selected: date)
            case .progression:
                ProgressionSheet(model: model, unit: unit)
            }
        }
    }

    private func focusDate(_ target: WorkoutDate?) {
        guard let target else { return }
        selection = .sessions
        layout = .calendar
        month = target
        day = target
        filter = HistoryFilter()
        jumpTo = nil
    }

    private var filters: some View {
        let all = WorkoutHistory.filtered(model.records.sessions)
        let routines = all.filter { $0.routineSnapshot.revision > 0 }.map { ($0.routineSnapshot.routineID, $0.routineSnapshot.name) }
        let exercises = all.flatMap { $0.plan.exercises }
        let options = Dictionary(exercises.map { ($0.variant.exercise.id, $0.variant.exercise.name) }, uniquingKeysWith: { first, _ in first })
        let gear = Dictionary(exercises.map { ($0.historyEquipmentKey, $0.historyEquipmentName) }, uniquingKeysWith: { first, _ in first })
        return DisclosureGroup("Filters") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Routine", selection: $filter.routineID) {
                    Text("All routines").tag(nil as UUID?)
                    let names = Dictionary(routines, uniquingKeysWith: { first, _ in first })
                    ForEach(names.keys.sorted { (names[$0] ?? "") < (names[$1] ?? "") }, id: \.self) { id in
                        Text(names[id] ?? "").tag(Optional(id))
                    }
                }
                Picker("Exercise", selection: $filter.exerciseID) {
                    Text("All exercises").tag(nil as UUID?)
                    ForEach(options.keys.sorted { (options[$0] ?? "") < (options[$1] ?? "") }, id: \.self) { id in
                        Text(options[id] ?? "").tag(Optional(id))
                    }
                }
                Picker("Equipment", selection: $filter.equipment) {
                    Text("All equipment").tag("")
                    ForEach(gear.keys.sorted { (gear[$0] ?? "") < (gear[$1] ?? "") }, id: \.self) { id in
                        Text(gear[id] ?? "").tag(id)
                    }
                }
                filterDate("From date", day: $filter.from)
                filterDate("Through date", day: $filter.to)
                Button("Clear filters") { filter = HistoryFilter() }.buttonStyle(SecondaryButton())
            }
        }.padding(14).surface()
    }

    @ViewBuilder private func filterDate(_ title: String, day: Binding<WorkoutDate?>) -> some View {
        Toggle(title, isOn: Binding(get: { day.wrappedValue != nil }, set: { day.wrappedValue = $0 ? WorkoutDate(Date()) : nil }))
        if let value = day.wrappedValue {
            DatePicker(title, selection: Binding(get: { value.localPickerDate }, set: { day.wrappedValue = WorkoutDate($0) }),
                displayedComponents: .date)
        }
    }

    @ViewBuilder private var sessions: some View {
        let entries = WorkoutHistory.filtered(model.records.sessions, by: filter)
        Picker("Workout history layout", selection: $layout) {
            ForEach(HistoryLayout.allCases) { Text($0.rawValue).tag($0) }
        }.pickerStyle(.segmented)
        Button("Add missed workout") { presented = .add(layout == .calendar ? min(day, WorkoutDate(Date())) : WorkoutDate(Date())) }
            .buttonStyle(SecondaryButton())
        if layout == .calendar {
            HistoryCalendar(month: $month, selected: $day, sessions: entries,
                photoDates: Set(model.records.progressPhotoDates), weightDates: Set(model.records.bodyweightEntries.map(\.localDate)))
            Text(day.formatted(.dateTime.year().month(.wide).day())).font(.headline)
            dateDetails
        }
        let visible = layout == .calendar ? entries.filter { $0.localDate == day } : entries
        if visible.isEmpty {
            PersonalStatus(title: layout == .calendar ? "No workouts on this date" : "No matching workouts", symbol: "calendar") {
                Text("Recorded workouts appear here.").font(.subheadline).foregroundStyle(Palette.muted)
            }
        }
        ForEach(visible) { session in
            PersonalStatus(title: session.plan.name, symbol: session.historyStatus == .completed ? "checkmark.circle" : "dumbbell") {
                HistorySessionDetails(session: session, unit: unit)
                WorkoutForecastArchive(session: session, unit: unit)
                Text("Progress photos").font(.subheadline.weight(.semibold))
                ProgressPhotoCollection(photos: model.records.photos.filter { $0.subject == .session(session.id) })
                if session.completedAt != nil {
                    Button("Link workout photos") { presented = .photos(session.localDate, session.id) }.buttonStyle(SecondaryButton())
                }
                ViewThatFits(in: .horizontal) {
                    HStack { actions(session) }
                    VStack(alignment: .leading) { actions(session) }
                }
            }
        }
    }

    private var dateDetails: some View {
        PersonalStatus(title: "Date details", symbol: "calendar") {
            let weight = model.records.bodyweight(on: day)
            if let weight {
                Text("Bodyweight · \(unit.display(weight.mass.kilograms, fractionDigits: 1...2)) \(unit.rawValue)").font(.subheadline)
            } else {
                Text("No bodyweight reading").font(.caption).foregroundStyle(Palette.muted)
            }
            if day <= WorkoutDate(Date()) {
                Button(weight == nil ? "Log bodyweight" : "Edit bodyweight") { presented = .weight(day) }.buttonStyle(SecondaryButton())
            }
            Text("Date progress photos").font(.subheadline.weight(.semibold))
            ProgressPhotoCollection(photos: model.records.progressPhotos(on: day).filter { $0.subject == nil })
            if day <= WorkoutDate(Date()) {
                Button("Link date photos") { presented = .photos(day, nil) }.buttonStyle(SecondaryButton())
            }
        }
    }

    @ViewBuilder private func actions(_ session: WorkoutSession) -> some View {
        if session.completedAt != nil {
            Button("Edit workout") { presented = .edit(session.id) }.buttonStyle(SecondaryButton())
            Button("Compare sessions") { presented = .compare(session.id) }.buttonStyle(SecondaryButton())
            Button("Repeat workout") { repeatWorkout(session.id) }.buttonStyle(SecondaryButton()).disabled(model.records.activeSession != nil)
        } else {
            Button("Resume workout", action: resume).buttonStyle(SecondaryButton())
        }
    }

    @ViewBuilder private var progress: some View {
        BodyweightProgressCard(model: model, unit: unit) { presented = .weight($0) }
        PersonalStatus(title: "Exercise progression", symbol: "chart.line.uptrend.xyaxis") {
            Button("Review progression") { presented = .progression }.buttonStyle(SecondaryButton())
        }
        ForecastAccuracyCard(records: model.records, unit: unit)
        AnalyticsProgress(model: model, filter: filter, unit: unit)
    }
}

private struct HistoryCalendar: View {
    @Binding var month: WorkoutDate
    @Binding var selected: WorkoutDate
    let sessions: [WorkoutSession]
    let photoDates: Set<WorkoutDate>
    let weightDates: Set<WorkoutDate>

    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = .gmt
        return result
    }
    private var first: WorkoutDate {
        WorkoutDate(String(month.key.prefix(7)) + "-01") ?? month
    }
    private var cells: [WorkoutDate?] {
        let offset = (first.weekday.rawValue + 5) % 7
        let days = calendar.range(of: .day, in: .month, for: first.calendarDate)?.count ?? 30
        return Array(repeating: nil, count: offset) + (0..<days).map { first.offset($0) as WorkoutDate? }
    }

    var body: some View {
        PersonalStatus(title: month.formatted(.dateTime.year().month(.wide)), symbol: "calendar") {
            HStack {
                Button { shift(-1) } label: { Image(systemName: "chevron.left").frame(minWidth: 44, minHeight: 44) }
                    .accessibilityLabel("Previous month")
                Spacer()
                Button { shift(1) } label: { Image(systemName: "chevron.right").frame(minWidth: 44, minHeight: 44) }
                    .accessibilityLabel("Next month")
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 7), spacing: 3) {
                let symbols = calendar.shortWeekdaySymbols
                ForEach(0..<7) { index in Text(symbols[(index + 1) % 7]).font(.caption2).lineLimit(1) }
                let dates = cells
                ForEach(dates.indices, id: \.self) { index in
                    if let date = dates[index] { dateCell(date) }
                    else { Color.clear.frame(height: 44).accessibilityHidden(true) }
                }
            }
        }
    }

    private func shift(_ number: Int) {
        guard let date = calendar.date(byAdding: .month, value: number, to: first.calendarDate) else { return }
        month = WorkoutDate(date, timeZone: .gmt)
        selected = month
    }

    private func dateCell(_ date: WorkoutDate) -> some View {
        let workouts = sessions.filter { $0.localDate == date }
        let completed = workouts.filter { $0.historyStatus == .completed }.count
        let incomplete = workouts.count - completed
        let short = date.formatted(.dateTime.day())
        return Button { selected = date } label: {
            VStack(spacing: 4) {
                Text(short).font(.subheadline.weight(.semibold))
                HStack(spacing: 3) {
                    if completed > 0 { Circle().fill(selected == date ? .white : .green).frame(width: 5, height: 5) }
                    if incomplete > 0 { Rectangle().fill(selected == date ? .white : Palette.red).frame(width: 5, height: 5) }
                    if photoDates.contains(date) { Image(systemName: "photo").font(.system(size: 7)) }
                    if weightDates.contains(date) { Image(systemName: "scalemass").font(.system(size: 7)) }
                }.frame(height: 5)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(date == selected ? .white : .primary)
            .background(date == selected ? Palette.action : Palette.soft, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(short) · \(date.formatted(.dateTime.month(.wide).day())), \(workouts.isEmpty ? "no workouts" : "\(completed) completed and \(incomplete) incomplete")"
            + (photoDates.contains(date) ? ", progress photos" : "") + (weightDates.contains(date) ? ", bodyweight reading" : ""))
        .accessibilityAddTraits(date == selected ? .isSelected : [])
    }
}

private struct HistorySessionDetails: View {
    let session: WorkoutSession
    let unit: WeightUnit

    var body: some View {
        let revision = session.routineSnapshot.revision
        Text(session.historyStatus.rawValue + (revision > 0 ? " · Version \(revision)" : " · Standalone workout"))
            .font(.caption.weight(.semibold)).foregroundStyle(Palette.purple)
        Text(session.localDate.formatted(.dateTime.year().month(.abbreviated).day())).font(.caption).foregroundStyle(Palette.muted)
        if let ended = session.completedAt, session.manualDurationKnown != false {
            Text(session.workoutTimeSummary(at: ended)).font(.caption).foregroundStyle(Palette.muted)
        }
        HistoryPlanTally(session: session)
        if let notes = session.workoutLog?.notes, !notes.isEmpty { Text(notes).font(.subheadline) }
        HistoryExercises(session: session, unit: unit)
        if revision > 0 {
            DisclosureGroup("Original routine prescription") { RoutinePlanRows(version: session.routineSnapshot, unit: unit) }
                .font(.subheadline)
        }
    }
}

private struct HistoryPlanTally: View {
    let session: WorkoutSession
    var exerciseID: UUID? = nil

    var body: some View {
        let filter = HistoryFilter(exerciseID: exerciseID)
        let planned = WorkoutAnalytics.plannedCounts(session.routineSnapshot, filter: filter)
        let performed = WorkoutAnalytics.completedCounts(session, filter: filter)
        Text("Working sets · \(performed.working) completed · \(planned.working) originally planned").font(.caption).foregroundStyle(Palette.muted)
        Text("Warm-ups · \(performed.warmUp) completed · \(planned.warmUp) originally planned").font(.caption).foregroundStyle(Palette.muted)
    }
}

private struct HistoryExercises: View {
    let session: WorkoutSession
    let unit: WeightUnit
    var exerciseID: UUID? = nil
    var showPlans = true

    var body: some View {
        ForEach(session.plan.exercises.filter { exerciseID == nil || $0.variant.exercise.id == exerciseID }) { entry in
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.variant.exercise.name).font(.subheadline.weight(.semibold))
                Text(entry.historyEquipmentName).font(.caption).foregroundStyle(Palette.muted)
                if let notes = session.workoutLog?.exercises.first(where: { $0.id == entry.id })?.notes, !notes.isEmpty {
                    Text(notes).font(.caption)
                }
                let sets = session.historyRows(for: entry)
                if sets.isEmpty { Text("No performed sets").font(.caption).foregroundStyle(Palette.muted) }
                ForEach(sets) { set in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(set.purpose == .warmUp ? "Warm-up \(set.order)" : "Set \(set.order)").font(.caption.weight(.semibold))
                        if showPlans, let prescription = set.prescription {
                            let single = singleSet(prescription)
                            Text("Prescription · \(entry.summary(single, unit: unit))").font(.caption).foregroundStyle(Palette.muted)
                        }
                        if let result = set.result {
                            Text("Performed · \(result.summary(unit: unit, measurement: entry.variant.measurement))").font(.caption)
                            if let rest = result.restSummary { Text(rest).font(.caption).foregroundStyle(Palette.muted) }
                        } else {
                            Text(set.status == .skipped ? "Skipped" : "Unfinished").font(.caption).foregroundStyle(Palette.muted)
                        }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private func singleSet(_ prescription: SetPrescription) -> SetPrescription {
    var result = prescription
    result.sets = 1
    return result
}

private struct HistoryMetricsRows: View {
    let metrics: HistoryMetrics
    let unit: WeightUnit
    var showDuration = true

    var body: some View {
        LabeledContent("Completed sets", value: String(metrics.sets))
        if showDuration { LabeledContent("Duration", value: metrics.duration.map { workoutClockText(Int($0)) } ?? "Unrecorded") }
        if let volume = metrics.volume {
            LabeledContent("Logged volume", value: "\(unit.display(volume, fractionDigits: 0...2)) \(unit.rawValue)·reps")
        }
    }
}

private struct HistoryChanges: View {
    let comparison: HistoryComparison
    let unit: WeightUnit
    let wholeWorkout: Bool

    var body: some View {
        let sets = comparison.current.sets - comparison.previous.sets
        Text("Set count change · \(sets > 0 ? "+" : "")\(sets)")
        if wholeWorkout, let current = comparison.current.duration, let previous = comparison.previous.duration {
            let delta = current - previous
            Text("Duration change · \(sign(delta))\(workoutClockText(Int(abs(delta))))")
        }
        if let reps = comparison.repsChange {
            Text("Comparable reps change · \(sign(reps))\(abs(reps).formatted())")
        }
        if let volume = comparison.volumeChange {
            Text("Comparable volume change · \(sign(volume))\(unit.display(abs(volume), fractionDigits: 0...2)) \(unit.rawValue)·reps")
        } else { Text("Comparable logged volume unavailable") }
        if comparison.orderChanged { Label("Exercise order differed", systemImage: "arrow.up.arrow.down") }
        if comparison.equipmentChanged { Label("Equipment differed", systemImage: "dumbbell") }
        if comparison.exercisesChanged { Label("Exercise selection differed", systemImage: "list.bullet") }
    }

    private func sign(_ value: Double) -> String { value > 0 ? "+" : value < 0 ? "−" : "" }
}

private struct HistoryComparisonSheet: View {
    let session: WorkoutSession
    let sessions: [WorkoutSession]
    let unit: WeightUnit
    @State private var selected: UUID? = nil
    @State private var scopeID = "routine"
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                let candidates = WorkoutHistory.filtered(sessions).filter { $0.id != session.id && $0.completedAt != nil && !WorkoutHistory.scopes(session, $0).isEmpty }
                let prior = WorkoutHistory.prior(to: session, in: sessions)
                if let other = candidates.first(where: { $0.id == (selected ?? prior?.0.id) }) ?? candidates.first {
                    let scopes = WorkoutHistory.scopes(session, other)
                    if let scope = scopes.first(where: { $0.id == scopeID }) ?? scopes.first {
                        let comparison = WorkoutHistory.compare(session, other, scope: scope)
                        VStack(alignment: .leading, spacing: 12) {
                            Picker("Compare with", selection: Binding(get: { other.id }, set: { selected = $0; scopeID = "routine" })) {
                                ForEach(candidates) { candidate in
                                    Text(candidate.plan.name + " · " + candidate.localDate.key + " · " + versionLabel(candidate)).tag(candidate.id)
                                }
                            }
                            Picker("Compare by", selection: Binding(get: { scope.id }, set: { scopeID = $0 })) {
                                ForEach(scopes) { Text($0.label).tag($0.id) }
                            }
                            HistoryChanges(comparison: comparison, unit: unit, wholeWorkout: scope.exerciseID == nil)
                                .font(.subheadline)
                            HStack(alignment: .top, spacing: 8) {
                                side(session, title: "Selected", stats: comparison.current, scope: scope)
                                side(other, title: "Comparison", stats: comparison.previous, scope: scope)
                            }
                        }.padding(12)
                    }
                } else {
                    Text("No other finished sessions use this routine or any of its exercises.").padding(16)
                }
            }
            .navigationTitle("Compare sessions")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }

    private func versionLabel(_ session: WorkoutSession) -> String {
        session.routineSnapshot.revision > 0 ? "Version \(session.routineSnapshot.revision)" : "Standalone"
    }

    private func side(_ session: WorkoutSession, title: String, stats: HistoryMetrics, scope: HistoryScope) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.caption.weight(.bold)).foregroundStyle(Palette.purple)
            Text(session.plan.name).font(.subheadline.weight(.bold))
            Text("\(session.localDate.key) · \(versionLabel(session))").font(.caption)
            Text(session.historyStatus.rawValue).font(.caption)
            HistoryMetricsRows(metrics: stats, unit: unit, showDuration: scope.exerciseID == nil).font(.caption)
            HistoryPlanTally(session: session, exerciseID: scope.exerciseID)
            HistoryExercises(session: session, unit: unit, exerciseID: scope.exerciseID, showPlans: false)
        }.frame(maxWidth: .infinity, alignment: .topLeading).padding(8).surface()
    }
}

struct HistoryFinishView: View {
    let model: TrainingModel
    let session: WorkoutSession
    let sessions: [WorkoutSession]
    let unit: WeightUnit
    let viewHistory: (WorkoutDate) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var linking = false
    @State private var progression = false

    var body: some View {
        NavigationStack {
            List {
                Section(session.plan.name) {
                    Text(session.historyStatus.rawValue).foregroundStyle(Palette.purple)
                    HistoryMetricsRows(metrics: WorkoutHistory.metrics(session), unit: unit)
                }
                if let (previous, scope) = WorkoutHistory.prior(to: session, in: sessions) {
                    Section(scope.exerciseID == nil ? "Since the previous workout with this routine" : "Since the previous \(scope.label) session") {
                        Text("\(previous.plan.name) · \(previous.localDate.key)")
                        HistoryChanges(comparison: WorkoutHistory.compare(session, previous, scope: scope), unit: unit, wholeWorkout: scope.exerciseID == nil)
                    }
                } else { Text("No prior comparable session.") }
                WorkoutForecastArchive(session: session, unit: unit)
                Button("Add progress photos") { linking = true }
                    .sheet(isPresented: $linking) { ProgressPhotosSheet(model: model, day: session.localDate, sessionID: session.id) }
                if !model.records.currentRoutines.isEmpty {
                    Button("Review progression") { progression = true }.sheet(isPresented: $progression) {
                        ProgressionSheet(model: model, unit: unit,
                            routineID: model.records.currentRoutines.first { $0.routineID == session.routineSnapshot.routineID }?.routineID)
                    }
                }
                Button("View in history") { viewHistory(session.localDate) }
            }
            .navigationTitle("Workout summary")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }
}

private struct HistoryEditor: View {
    let model: TrainingModel
    let unit: WeightUnit
    let saved: (WorkoutDate) -> Void
    @State private var draft: HistoryEditDraft
    @State private var addingExercise = false
    @Environment(\.dismiss) private var dismiss

    init(model: TrainingModel, session: WorkoutSession? = nil, date: WorkoutDate, unit: WeightUnit,
         saved: @escaping (WorkoutDate) -> Void = { _ in }) {
        self.model = model
        self.unit = unit
        self.saved = saved
        let morning = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: date.localPickerDate) ?? date.localPickerDate
        _draft = State(initialValue: HistoryEditDraft(session: session, day: date, start: min(morning, Date()), unit: unit))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if draft.originalID == nil {
                        Picker("Routine template", selection: $draft.versionID) {
                            Text("Standalone workout").tag(nil as UUID?)
                            ForEach(model.records.routineVersions.reversed()) { version in
                                Text("\(version.name) · v\(version.revision)").tag(Optional(version.id))
                            }
                        }.onChange(of: draft.versionID) { selectTemplate() }
                        if draft.versionID == nil { TextField("Workout name", text: $draft.name) }
                        DatePicker("Workout date and start time", selection: $draft.start, in: ...Date())
                        TextField("Duration in minutes (optional)", text: $draft.minutes).keyboardType(.decimalPad)
                    } else {
                        Text("Correct recorded results and notes. The original routine prescription stays with the workout.")
                            .font(.subheadline).foregroundStyle(Palette.muted)
                    }
                    TextField("Workout notes", text: $draft.notes, axis: .vertical)
                    Toggle("Mark as incomplete", isOn: $draft.incomplete)
                }
                ForEach($draft.exercises) { $exercise in
                    Section(exercise.entry.variant.exercise.name) {
                        Text(exercise.entry.historyEquipmentName).font(.caption).foregroundStyle(Palette.muted)
                        TextField("Exercise notes", text: $exercise.notes, axis: .vertical)
                        ForEach($exercise.sets) { $set in
                            let setID = set.id
                            let order = (exercise.sets.firstIndex { $0.id == setID } ?? 0) + 1
                            HistoryEditableSet(entry: exercise.entry, order: order, set: $set) {
                                exercise.sets.removeAll { $0.id == setID }
                            }
                        }
                        Button("Add set") { exercise.sets.append(HistorySetDraft(unit: unit)) }
                    }
                }
                Button("Add exercise") { addingExercise = true }
                if let error = model.storageError { Text(error).foregroundStyle(Palette.red) }
            }
            .navigationTitle(draft.originalID == nil ? "Add missed workout" : "Edit workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(draft.originalID == nil ? "Save missed workout" : "Save corrections") {
                        if model.updateUserData({ _ = try $0.saveHistory(draft) }) {
                            if draft.originalID == nil { saved(WorkoutDate(draft.start)) }
                            dismiss()
                        }
                    }
                }
            }
            .sheet(isPresented: $addingExercise) {
                LoggingExercisePicker(model: model) { exercise, measurement, equipment in
                    guard measurement.supports(equipment) else {
                        model.storageError = "Choose compatible equipment for this measurement."
                        return false
                    }
                    draft.addExercise(exercise, equipment: equipment, measurement: measurement)
                    model.storageError = nil
                    return true
                }
            }
        }
    }

    private func selectTemplate() {
        let template = draft.versionID.flatMap(model.records.version)
        draft.exercises = HistoryEditDraft(template: template, day: WorkoutDate(draft.start), start: draft.start, unit: unit).exercises
    }
}

private struct HistoryEditableSet: View {
    let entry: PlannedExercise
    let order: Int
    @Binding var set: HistorySetDraft
    let remove: () -> Void

    var body: some View {
        let measurement = entry.variant.measurement
        let separate = measurement.repCounting == .separateSides ||
            (measurement.repCounting != .total && set.input.separateSides == true)
        VStack(alignment: .leading, spacing: 5) {
            Text(set.row.purpose == .warmUp ? "Warm-up set \(order)" : "Set \(order)").font(.subheadline.weight(.semibold))
            if let target = set.row.prescription {
                Text("Prescription · \(entry.summary(singleSet(target), unit: set.input.unit))")
                    .font(.caption).foregroundStyle(Palette.muted)
            }
            Picker("Set status", selection: $set.row.status) {
                Text("Unfinished").tag(WorkoutSetStatus.pending)
                Text("Performed").tag(WorkoutSetStatus.completed)
                Text("Skipped").tag(WorkoutSetStatus.skipped)
            }
            if set.row.status == .completed {
                if let label = measurement.loggingAmountLabel(set.input.unit) {
                    TextField(separate ? "Left " + label : label, text: $set.input.amount)
                        .keyboardType(measurement.isMachineSetting ? .default : .decimalPad)
                    if separate {
                        TextField("Right " + label, text: Binding(get: { set.input.rightAmount ?? "" }, set: { set.input.rightAmount = $0 }))
                            .keyboardType(measurement.isMachineSetting ? .default : .decimalPad)
                    }
                }
                if let counting = measurement.repCounting {
                    TextField(separate ? "Left reps" : counting == .perSide ? "Reps per side" : "Reps", text: $set.input.reps).keyboardType(.numberPad)
                    if separate { TextField("Right reps", text: $set.input.rightReps).keyboardType(.numberPad) }
                }
                if measurement.repCounting == .perSide || measurement.repCounting == nil {
                    Toggle("Log left and right", isOn: Binding(get: { set.input.separateSides == true }, set: { set.input.separateSides = $0 }))
                }
                DisclosureGroup("Actual effort") {
                    TextField("Actual RIR", text: $set.input.rir).keyboardType(.numberPad)
                    TextField("Actual RPE", text: $set.input.rpe).keyboardType(.decimalPad)
                    Toggle("Reached failure", isOn: $set.input.failure)
                }
            }
            if set.row.prescription == nil {
                Button("Remove set", role: .destructive, action: remove).buttonStyle(.borderless)
            }
        }
    }
}
