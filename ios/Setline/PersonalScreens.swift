import SwiftUI

struct PersonalTodayScreen: View {
    let records: TrainingRecords
    let unit: WeightUnit
    let browse: () -> Void
    let start: (ScheduleOccurrence) -> Void
    let startEmpty: () -> Void
    let editWeight: (String) -> Void
    let browseMuscle: (MuscleGroup) -> Void
    let openSchedule: () -> Void
    let move: (ScheduleOccurrence) -> Void
    let skip: (ScheduleOccurrence) -> Void
    let logReadiness: (WorkoutDate) -> Void
    let reviewProgression: (UUID) -> Void
    @Binding var selectedDay: String?
    @State private var anchor: WorkoutDate?
    @State private var recentView = false
    @State private var pendingSkip: ScheduleOccurrence?

    var body: some View {
        TimelineView(.everyMinute) { context in
            let today = WorkoutDate(context.date)
            let settings = records.scheduleSettings ?? ScheduleSettings()
            let week = settings.dates(around: anchor ?? today)
            let day = week.first { $0.key == selectedDay } ?? anchor ?? today
            let slots = records.scheduled(on: week, today: today)
            let planned = slots.filter { $0.date == day }
            VStack(spacing: 14) {
                PageHeading(title: "Today", subtitle: today.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                WeekScheduleCard(days: week.map { date in
                    let entries = slots.filter { $0.date == date }
                    let names = entries.compactMap { entry in
                        records.version(entry.versionID).map { "\(entry.status.rawValue) \($0.name)" }
                    }
                    return WeekScheduleCard.Day(date: date.key, routineName: names.isEmpty ? nil : names.joined(separator: ", "),
                        statuses: entries.map(\.status))
                }, selection: day.key, title: settings.mode.rawValue) { selectedDay = $0 }
                HStack {
                    Button { navigate(-7, today: today) } label: { Image(systemName: "chevron.left").frame(minWidth: 44, minHeight: 44) }
                        .accessibilityLabel("Previous seven days")
                    Button("Today") { navigate(0, today: today) }.frame(minHeight: 44)
                    Button { navigate(7, today: today) } label: { Image(systemName: "chevron.right").frame(minWidth: 44, minHeight: 44) }
                        .accessibilityLabel("Next seven days")
                    Spacer()
                    Button("Training schedule", action: openSchedule).buttonStyle(SecondaryButton())
                }.foregroundStyle(Palette.purple)
                if planned.isEmpty {
                    PersonalStatus(title: "No workout scheduled", symbol: "calendar") {
                        Button("View routines", action: browse).buttonStyle(SecondaryButton())
                        Button(records.activeSession == nil ? "Start empty workout" : "Resume workout", action: startEmpty)
                            .buttonStyle(PrimaryButton())
                    }
                }
                ForEach(planned) { workout in
                    if let version = records.version(workout.versionID) {
                        scheduleCard(workout, version: version, today: today, now: context.date)
                    }
                }
                BodyweightCard(value: records.bodyweight(on: day)?.mass.kilograms, unit: unit,
                               date: today == day ? "Today" : day.formatted(.dateTime.month(.abbreviated).day())) {
                    editWeight(day.key)
                }
                readiness(on: day, today: today)
                let plannedProfiles = planned.filter { [.planned, .rescheduled, .active].contains($0.status) }.flatMap { workout in
                    records.version(workout.versionID)?.exercises.compactMap { entry in
                        let exercise = entry.variant.exercise
                        return exercise.profile ?? records.exercises.first { $0.id == exercise.id }?.profile
                    } ?? []
                }
                let asOf = min(day, today)
                Picker("Muscle map view", selection: $recentView) {
                    Text("Planned targets").tag(false)
                    Text("Recent training").tag(true)
                }.pickerStyle(.segmented)
                InteractiveMuscleMap(involvement: MuscleInvolvement(plannedProfiles), browse: browseMuscle,
                    recent: recentView ? records.recentMuscles(asOf: asOf) : nil, asOf: asOf)
                WorkoutScoreBreakdown(assessment: DailyWorkoutScore.assessment(on: day, records: records, today: today))
            }
        }
        .onChange(of: records.scheduleSettings) { anchor = nil; selectedDay = nil }
        .confirmationDialog("Skip scheduled session?", isPresented: Binding(get: { pendingSkip != nil },
            set: { if !$0 { pendingSkip = nil } }), titleVisibility: .visible) {
            Button("Confirm skip", role: .destructive) { if let pendingSkip { skip(pendingSkip) } }
        } message: {
            Text(pendingSkip?.rotationID == nil ? "This marks the planned session as skipped." : "This advances the rotation by one step.")
        }
    }

    private func navigate(_ distance: Int, today: WorkoutDate) {
        anchor = distance == 0 ? nil : (anchor ?? today).offset(distance)
        selectedDay = (anchor ?? today).key
    }

    private func scheduleCard(_ workout: ScheduleOccurrence, version: RoutineVersion, today: WorkoutDate, now: Date) -> some View {
        PersonalStatus(title: version.name, symbol: workout.status.symbol) {
            Label(workout.status.rawValue, systemImage: workout.status.symbol)
                .font(.caption.weight(.semibold)).foregroundStyle(workout.status.tint)
            if workout.status == .moved, let destination = workout.record?.localDate {
                Text("Rescheduled to \(destination.key)").font(.caption)
            } else if let former = workout.record?.movedFrom?.last {
                Text("Moved from \(former.key)").font(.caption)
            } else if workout.rotationID != nil {
                Text("Rotating sequence").font(.caption)
            }
            if let block = records.programBlocks.first(where: { $0.id == workout.record?.programBlockID }) {
                let index = block.weekIndex(for: workout.record?.movedFrom?.first ?? workout.date)
                let week = block.weeks?[index] ?? ProgramWeek()
                Text("\(block.name) · Week \(index + 1) · \(week.kind.rawValue)").font(.caption)
                if !week.notes.isEmpty { Text(week.notes).font(.subheadline) }
            }
            if workout.canChange || workout.status == .active { RoutinePlanRows(version: version, unit: unit) }
            if workout.status == .planned || workout.status == .rescheduled {
                WorkoutForecastPreview(plan: version, records: records, unit: unit, day: workout.date,
                    deload: WorkoutAnalytics.context(for: workout, records: records).kind == .deload, now: now)
            }
            if workout.canChange, records.currentRoutines.contains(where: { $0.id == version.id }),
               WorkoutAnalytics.context(for: workout, records: records).kind != .deload {
                Button("Review progression") { reviewProgression(version.routineID) }.buttonStyle(SecondaryButton())
            }
            if workout.status == .active || (workout.canChange && (workout.rotationID == nil || workout.date == today)) {
                Button(records.activeSession == nil ? "Start scheduled workout" : "Resume workout") { start(workout) }.buttonStyle(PrimaryButton())
            }
            if workout.canChange {
                HStack {
                    Button("Move session") { move(workout) }.buttonStyle(SecondaryButton())
                    Button("Skip session") { pendingSkip = workout }.buttonStyle(SecondaryButton())
                }
            }
        }
    }

    private func readiness(on day: WorkoutDate, today: WorkoutDate) -> some View {
        let entry = records.readiness.last { $0.localDate == day }
        return PersonalStatus(title: "Readiness", symbol: "slider.horizontal.3") {
            if let entry {
                let ratings: [String?] = ["Soreness \(entry.soreness)/5", entry.sleepQuality.map { "Sleep quality \($0)/5" },
                    "Energy \(entry.energy)/5", entry.motivation.map { "Motivation \($0)/5" }]
                Text(ratings.compactMap { $0 }.joined(separator: " · ")).font(.subheadline)
            } else {
                Text("Optional training context").font(.subheadline).foregroundStyle(Palette.muted)
            }
            if day <= today {
                Button(entry == nil ? "Log readiness" : "Edit check-in") { logReadiness(day) }.buttonStyle(SecondaryButton())
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
    let reviewProgression: (UUID) -> Void
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
                PersonalRoutineCard(version: version, records: records, unit: unit, subtitle: subtitle, active: records.activeSession != nil) {
                    start(version.id, nil)
                }
                Menu {
                    Button("Edit routine") { edit(version) }
                    Button("Duplicate routine") { duplicate(version.id) }
                    Button("Version history") { versionHistory(version.routineID) }
                    Button("Schedule workout") { schedule(version) }
                    Button("Review progression") { reviewProgression(version.routineID) }
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
    let records: TrainingRecords
    let unit: WeightUnit
    let subtitle: String
    let active: Bool
    let start: () -> Void

    var body: some View {
        PersonalStatus(title: version.name, symbol: "dumbbell") {
            Text(subtitle).font(.caption.weight(.semibold)).foregroundStyle(Palette.muted)
            RoutinePlanRows(version: version, unit: unit)
            let now = Date()
            let day = WorkoutDate(now)
            WorkoutForecastPreview(plan: version, records: records, unit: unit, day: day,
                deload: WorkoutAnalytics.context(on: day, entry: nil, records: records).kind == .deload, now: now)
            Button(action: start) {
                Label(active ? "Resume Workout" : "Log Workout", systemImage: active ? "chevron.right" : "play.fill")
            }
            .buttonStyle(PrimaryButton())
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
    func summary(_ prescription: SetPrescription, unit: WeightUnit, fractionDigits: ClosedRange<Int> = 0...1) -> String {
        let measurement = variant.measurement
        let sets = if let reps = prescription.reps, let counting = measurement.repCounting {
            "\(prescription.sets) × \(reps.label) \(counting.label)"
        } else {
            "\(prescription.sets) sets"
        }
        let amount = prescription.target?.summary(unit: unit, measurement: measurement, fractionDigits: fractionDigits)
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

    func summary(unit: WeightUnit, measurement: Measurement, fractionDigits: ClosedRange<Int> = 0...1) -> String {
        var load = amount?.summary(unit: unit, measurement: measurement, fractionDigits: fractionDigits)
        if let left = load, let right = rightAmount?.summary(unit: unit, measurement: measurement, fractionDigits: fractionDigits) { load = "\(left) left / \(right) right" }
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
    func summary(unit: WeightUnit, measurement: Measurement, fractionDigits: ClosedRange<Int>) -> String {
        switch self {
        case .weight(let mass): "\(unit.display(mass.kilograms, fractionDigits: fractionDigits)) \(unit.rawValue) \(measurement.loadLabel)"
        case .addedLoad(let mass): "\(unit.display(mass.kilograms, fractionDigits: fractionDigits)) \(unit.rawValue) added"
        case .assistance(let mass): "\(unit.display(mass.kilograms, fractionDigits: fractionDigits)) \(unit.rawValue) assistance"
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
