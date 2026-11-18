import SwiftUI

struct PersonalTodayScreen: View {
    let records: TrainingRecords
    let unit: WeightUnit
    let browse: () -> Void
    let start: (UUID, UUID?) -> Void
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

    var body: some View {
        PageHeading(title: "Routines", subtitle: "Your training library")
        LibraryEntryButton(open: browseLibrary)
        if records.currentRoutines.isEmpty {
            PersonalStatus(title: "No saved routines", symbol: "square.stack") {
                Text("Your routines will appear here.").font(.subheadline).foregroundStyle(Palette.muted)
            }
        }
        ForEach(records.currentRoutines) { version in
            PersonalRoutineCard(version: version, unit: unit, subtitle: "Version \(version.revision)", active: records.activeSession != nil) {
                start(version.id, nil)
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
            ForEach(version.exercises) { entry in
                LabeledContent(entry.variant.exercise.name, value: entry.summary(unit: unit))
                    .font(.subheadline)
            }
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
                    ForEach(session.routineSnapshot.exercises) { entry in
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
                PersonalStatus(title: session.routineSnapshot.name, symbol: "dumbbell") {
                    Text("\(session.localDate.formatted(.dateTime.month(.abbreviated).day())) · \(session.performedSets.count) recorded sets")
                        .font(.caption).foregroundStyle(Palette.muted)
                    ForEach(session.routineSnapshot.exercises) { entry in
                        LabeledContent(entry.variant.exercise.name, value: entry.summary(unit: unit))
                            .font(.subheadline)
                    }
                }
            }
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
    func summary(unit: WeightUnit) -> String {
        let measurement = variant.measurement
        let sets = if let reps = prescription.reps, let counting = measurement.repCounting {
            "\(prescription.sets) × \(reps.label) \(counting.label)"
        } else {
            "\(prescription.sets) sets"
        }
        let amount = prescription.target?.summary(unit: unit, measurement: measurement)
        return [sets, amount].compactMap { $0 }.joined(separator: " · ")
    }
}

private extension PerformedSet {
    func summary(unit: WeightUnit, measurement: Measurement) -> String {
        let load = amount?.summary(unit: unit, measurement: measurement)
        let reps: String? = switch repetitions {
        case .total(let count): "\(count) reps total"
        case .perSide(let count): "\(count) reps per side"
        case .separateSides(let left, let right): "\(left) left / \(right) right"
        case nil: nil
        }
        return [load, reps].compactMap { $0 }.joined(separator: " · ")
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
