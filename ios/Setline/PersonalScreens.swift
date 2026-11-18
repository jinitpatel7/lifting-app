import SwiftUI

struct PersonalTodayScreen: View {
    let records: TrainingRecords
    let unit: WeightUnit
    let browse: () -> Void
    let start: (UUID, UUID?) -> Void
    let startEmpty: () -> Void
    let editWeight: (String) -> Void
    let browseMuscle: (MuscleGroup) -> Void
    @Binding var selectedDay: String?

    var body: some View {
        TimelineView(.everyMinute) { context in
            let today = WorkoutDate(context.date)
            let week = WorkoutDate.week(containing: today)
            let day = week.first { $0.key == selectedDay } ?? today
            let planned = records.schedule.filter { $0.localDate == day }
            VStack(spacing: 14) {
                PageHeading(title: "Today", subtitle: today.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                WeekScheduleCard(days: week.map { date in
                    let scheduled = records.schedule.first { $0.localDate == date }
                    let name = scheduled.flatMap { records.version($0.routineVersionID)?.name }
                    return WeekScheduleCard.Day(date: date.key, routineName: name)
                }, selection: day.key) { selectedDay = $0 }
                if planned.isEmpty {
                    PersonalStatus(title: "No workout scheduled", symbol: "calendar") {
                        Button("View routines", action: browse).buttonStyle(SecondaryButton())
                        Button(records.activeSession == nil ? "Start empty workout" : "Resume workout", action: startEmpty)
                            .buttonStyle(PrimaryButton())
                    }
                }
                ForEach(planned) { workout in
                    if let version = records.version(workout.routineVersionID) {
                        PersonalRoutineCard(version: version, unit: unit, subtitle: "Planned workout", active: records.activeSession != nil) {
                            start(version.id, workout.id)
                        }
                    }
                }
                BodyweightCard(value: records.bodyweight(on: day)?.mass.kilograms, unit: unit,
                               date: today == day ? "Today" : day.formatted(.dateTime.month(.abbreviated).day())) {
                    editWeight(day.key)
                }
                let plannedProfiles = planned.flatMap { workout in
                    records.version(workout.routineVersionID)?.exercises.compactMap { entry in
                        let exercise = entry.variant.exercise
                        return exercise.profile ?? records.exercises.first { $0.id == exercise.id }?.profile
                    } ?? []
                }
                InteractiveMuscleMap(involvement: MuscleInvolvement(plannedProfiles), browse: browseMuscle)
            }
        }
    }
}

struct PersonalRoutinesScreen: View {
    let records: TrainingRecords
    let unit: WeightUnit
    let start: (UUID, UUID?) -> Void
    let browseLibrary: () -> Void
    let edit: (RoutineVersion?) -> Void
    let duplicate: (UUID) -> Void
    let versionHistory: (UUID) -> Void
    let schedule: (RoutineVersion) -> Void
    @State private var category: UUID?

    var body: some View {
        PageHeading(title: "Routines", subtitle: "Your training library")
        LibraryEntryButton(open: browseLibrary)
        Button { edit(nil) } label: { Label("New routine", systemImage: "plus") }.buttonStyle(PrimaryButton())
            .frame(maxWidth: .infinity, alignment: .leading)
        if let categories = records.routineCategories, !categories.isEmpty {
            Picker("Filter by category", selection: $category) {
                Text("All categories").tag(nil as UUID?)
                ForEach(categories) { Text($0.name).tag(Optional($0.id)) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        if records.currentRoutines.isEmpty {
            PersonalStatus(title: "No saved routines", symbol: "square.stack") {
                Text("Your routines will appear here.").font(.subheadline).foregroundStyle(Palette.muted)
            }
        }
        ForEach(records.currentRoutines.filter { category == nil || $0.categoryID == category }) { version in
            let category = records.routineCategories?.first { $0.id == version.categoryID }
            let subtitle = ["Version \(version.revision)", category?.name].compactMap { $0 }.joined(separator: " · ")
            VStack(alignment: .leading, spacing: 5) {
                PersonalRoutineCard(version: version, unit: unit, subtitle: subtitle, active: records.activeSession != nil) {
                    start(version.id, nil)
                }
                Menu {
                    Button("Edit routine") { edit(version) }
                    Button("Duplicate routine") { duplicate(version.id) }
                    Button("Version history") { versionHistory(version.routineID) }
                    Button("Schedule workout") { schedule(version) }
                } label: {
                    Label("Routine options", systemImage: "ellipsis.circle").frame(minHeight: 44)
                }
                .accessibilityLabel("Options for \(version.name)")
            }
        }
    }
}

struct PersonalRoutineCard: View {
    let version: RoutineVersion
    let unit: WeightUnit
    let subtitle: String
    let active: Bool
    let start: () -> Void

    var body: some View {
        PersonalStatus(title: version.name, symbol: "dumbbell") {
            Text(subtitle).font(.caption.weight(.semibold)).foregroundStyle(Palette.muted)
            RoutinePlanRows(version: version, unit: unit)
            Button(action: start) {
                Label(active ? "Resume Workout" : "Log Workout", systemImage: active ? "chevron.right" : "play.fill")
            }
            .buttonStyle(PrimaryButton())
        }
    }
}

struct PersonalHistoryScreen: View {
    let sessions: [WorkoutSession]
    let bodyweight: [BodyweightEntry]
    let unit: WeightUnit
    let repeatWorkout: (UUID) -> Void
    let hasActiveWorkout: Bool
    @Binding var selection: HistoryScreen.Section

    private var completed: [WorkoutSession] {
        sessions.filter { $0.completedAt != nil }.sorted { $0.startedAt > $1.startedAt }
    }

    var body: some View {
        PageHeading(title: "History", subtitle: "Your training progress")
        SelectionControl(label: "History view", selection: $selection, options: HistoryScreen.Section.allCases, title: \.rawValue)
        if selection == .progress {
            PersonalStatus(title: "Recorded sets", symbol: "chart.xyaxis.line") {
                let results = completed.filter { !$0.performedSets.isEmpty }
                if results.isEmpty {
                    Text("Results from completed workouts will appear here.").font(.subheadline).foregroundStyle(Palette.muted)
                }
                ForEach(results) { session in
                    ForEach(session.plan.exercises) { entry in
                        let sets = session.performedSets.filter { $0.plannedExerciseID == entry.id }.sorted { $0.order < $1.order }
                        if !sets.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.variant.exercise.name).font(.subheadline.weight(.semibold))
                                Text("\(entry.variant.equipment?.name ?? "No equipment") · \(session.localDate.formatted(.dateTime.month(.abbreviated).day()))")
                                    .font(.caption).foregroundStyle(Palette.muted)
                                ForEach(sets) { set in
                                    Text(set.summary(unit: unit, measurement: entry.variant.measurement)).font(.caption)
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
            if !bodyweight.isEmpty {
                PersonalStatus(title: "Bodyweight history", symbol: "scalemass") {
                    ForEach(bodyweight.sorted { $0.localDate > $1.localDate }) { entry in
                        LabeledContent(entry.localDate.formatted(.dateTime.year().month(.abbreviated).day()),
                                       value: "\(unit.display(entry.mass.kilograms, fractionDigits: 1...1)) \(unit.rawValue)")
                            .font(.subheadline)
                    }
                }
            }
        } else {
            if completed.isEmpty {
                PersonalStatus(title: "No completed workouts", symbol: "clock") {
                    Text("Finished workouts will appear here.").font(.subheadline).foregroundStyle(Palette.muted)
                }
            }
            ForEach(completed) { session in
                PersonalStatus(title: session.plan.name, symbol: "dumbbell") {
                    Text("\(session.localDate.formatted(.dateTime.month(.abbreviated).day())) · \(session.performedSets.count) recorded sets\(session.endedEarly == true ? " · Ended early" : "")")
                        .font(.caption).foregroundStyle(Palette.muted)
                    if let log = session.workoutLog {
                        if let ended = session.completedAt {
                            Text(session.workoutTimeSummary(at: ended)).font(.caption).foregroundStyle(Palette.muted)
                        }
                        if !log.notes.isEmpty { Text(log.notes).font(.subheadline) }
                        ForEach(log.exercises) { workout in
                            if let entry = session.plan.exercises.first(where: { $0.id == workout.id }) {
                                Text(entry.variant.exercise.name).font(.subheadline.weight(.semibold))
                                if !workout.notes.isEmpty { Text(workout.notes).font(.caption).foregroundStyle(Palette.muted) }
                                ForEach(workout.rows) { row in
                                    if let result = session.performedSets.first(where: { $0.id == row.id }) {
                                        Text("Completed · \(result.summary(unit: unit, measurement: entry.variant.measurement))").font(.caption)
                                        if let rest = result.restSummary { Text(rest).font(.caption).foregroundStyle(Palette.muted) }
                                    } else {
                                        Text(row.status == .skipped ? "Skipped" : "Unfinished").font(.caption).foregroundStyle(Palette.muted)
                                    }
                                }
                            }
                        }
                    } else {
                        RoutinePlanRows(version: session.plan, unit: unit)
                    }
                    Button("Repeat workout") { repeatWorkout(session.id) }.buttonStyle(SecondaryButton())
                        .disabled(hasActiveWorkout)
                }
            }
        }
    }
}

struct RoutinePlanRows: View {
    let version: RoutineVersion
    let unit: WeightUnit

    var body: some View {
        ForEach(version.exercises) { entry in
            if let group = version.groups?.first(where: { $0.exerciseIDs.first == entry.id }) {
                Text(group.summary).font(.caption.weight(.semibold)).foregroundStyle(Palette.purple)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.variant.exercise.name).font(.subheadline.weight(.semibold))
                if let variation = entry.variant.exercise.profile?.variation, !variation.isEmpty {
                    Text(variation).font(.caption).foregroundStyle(Palette.muted)
                }
                if let equipment = entry.variant.equipment { Text(equipment.name).font(.caption).foregroundStyle(Palette.muted) }
                if let warm = entry.warmUps {
                    ForEach(warm.indices, id: \.self) { index in
                        Text("Warm-up · \(entry.summary(warm[index], unit: unit))").font(.caption)
                    }
                }
                ForEach(entry.workingSets.indices, id: \.self) { index in
                    Text("Working · \(entry.summary(entry.workingSets[index], unit: unit))").font(.caption)
                }
            }
        }
    }
}

struct RoutineHistorySheet: View {
    let versions: [RoutineVersion]
    let categories: [RoutineCategory]
    let unit: WeightUnit
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(versions) { version in
                DisclosureGroup("Version \(version.revision) · \(version.name)") {
                    Text(version.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(Palette.muted)
                    if let category = categories.first(where: { $0.id == version.categoryID }) { Text(category.name).font(.caption) }
                    RoutinePlanRows(version: version, unit: unit)
                }
            }
            .navigationTitle("Version history")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .tint(Palette.purple)
        }
    }
}

struct PersonalStatus<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                IconTile(symbol: symbol, size: 32)
                CardHeading(title: title)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14).surface()
    }
}

extension PlannedExercise {
    func summary(_ prescription: SetPrescription, unit: WeightUnit) -> String {
        let measurement = variant.measurement
        let sets = if let reps = prescription.reps, let counting = measurement.repCounting {
            "\(prescription.sets) × \(reps.label) \(counting.label)"
        } else {
            "\(prescription.sets) sets"
        }
        let amount = prescription.target?.summary(unit: unit, measurement: measurement)
        let effort: String? = switch prescription.effort {
        case .rpe(let value): "RPE \(value.formatted())"
        case .failure: "To failure"
        case nil: prescription.repsInReserve.map { "RIR \($0)" }
        }
        return [sets, amount, prescription.restSeconds.map { "\($0)s rest" }, effort,
                prescription.structure?.rawValue, prescription.amrap == true ? "AMRAP" : nil].compactMap { $0 }.joined(separator: " · ")
    }
}

extension PerformedSet {
    var restSummary: String? {
        let measured = actualRest?.measuredSeconds.map { "Measured rest \($0)s" }
        let edited = actualRest?.editedSeconds.map { "Edited rest \($0)s" }
        let values = [measured, edited].compactMap { $0 }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }

    func summary(unit: WeightUnit, measurement: Measurement) -> String {
        var load = amount?.summary(unit: unit, measurement: measurement)
        if let left = load, let right = rightAmount?.summary(unit: unit, measurement: measurement) { load = "\(left) left / \(right) right" }
        let reps: String? = switch repetitions {
        case .total(let count): "\(count) reps total"
        case .perSide(let count): "\(count) reps per side"
        case .separateSides(let left, let right): "\(left) left / \(right) right"
        case nil: nil
        }
        return [load, reps, actualRIR.map { "RIR \($0)" }, actualRPE.map { "RPE \($0.formatted())" },
                effortOutcome == .failure ? "To failure" : nil].compactMap { $0 }.joined(separator: " · ")
    }
}

func workoutClockText(_ seconds: Int) -> String {
    let remainder = seconds % 60
    return "\(seconds / 60):\(remainder < 10 ? "0" : "")\(remainder)"
}

extension WorkoutSession {
    func workoutTimeSummary(at date: Date) -> String {
        let time = workoutTimes(at: date, clock: workoutLog?.clock)
        return "Elapsed \(workoutClockText(Int(time.elapsed))) · Active \(workoutClockText(Int(time.active))) · Paused \(workoutClockText(Int(time.paused)))"
    }
}

private extension SetAmount {
    func summary(unit: WeightUnit, measurement: Measurement) -> String {
        switch self {
        case .weight(let mass): "\(unit.display(mass.kilograms)) \(unit.rawValue) \(measurement.loadLabel)"
        case .addedLoad(let mass): "\(unit.display(mass.kilograms)) \(unit.rawValue) added"
        case .assistance(let mass): "\(unit.display(mass.kilograms)) \(unit.rawValue) assistance"
        case .durationSeconds(let seconds): "\(seconds.formatted()) s"
        case .distanceMeters(let meters): "\(meters.formatted()) m"
        case .machineSetting(let setting): "Setting \(setting)"
        }
    }
}

private extension RepCounting {
    var label: String {
        switch self {
        case .total: "reps total"
        case .perSide: "reps per side"
        case .separateSides: "reps per side (logged separately)"
        }
    }
}

private extension Measurement {
    var loadLabel: String {
        if case .weightReps(.perDumbbell, _) = self { return "per dumbbell" }
        return "total"
    }
}
