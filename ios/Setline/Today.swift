import SwiftUI

struct TodayScreen: View {
    let sample: SampleData
    let model: TrainingModel
    let unit: WeightUnit
    let openRoutines: () -> Void
    let start: (Routine) -> Void
    let editWeight: (String) -> Void
    let browseMuscle: (MuscleGroup) -> Void
    @Binding var selectedDay: String?

    private var day: String { selectedDay ?? sample.today }
    private var selectedRoutine: Routine? {
        sample.routine(sample.week.first { $0.date == day }?.routineID)
    }

    var body: some View {
        PageHeading(title: "Today", subtitle: SampleDate.label(sample.today, .dateTime.weekday(.wide).month(.wide).day()))
        WeekScheduleCard(days: sample.week.map { entry in
            WeekScheduleCard.Day(date: entry.date, routineName: sample.routine(entry.routineID)?.name)
        }, selection: day) { selectedDay = $0 }
        if let routine = selectedRoutine {
            WorkoutCard(routine: routine, active: model.activeRoutine != nil) { start(routine) }
            InteractiveMuscleMap(involvement: model.sampleInvolvement(routine), browse: browseMuscle)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                IconTile(symbol: "calendar")
                CardHeading(title: "Rest day")
                Text("No sample workout is scheduled for this day.").foregroundStyle(Palette.muted)
                Button("View routines", action: openRoutines).buttonStyle(SecondaryButton())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16).surface()
        }
        BodyweightCard(value: model.bodyweight(on: day, sampleMode: true), unit: unit,
                       date: day == sample.today ? "Today" : SampleDate.label(day, .dateTime.month(.abbreviated).day())) {
            editWeight(day)
        }
        if let routine = selectedRoutine {
            ExerciseList(routine: routine, unit: unit).id(routine.id)
        }
    }
}

struct WeekScheduleCard: View {
    struct Day: Identifiable {
        var id: String { date }
        let date: String
        let routineName: String?
        var statuses: [ScheduleStatus] = []
    }

    let days: [Day]
    let selection: String
    var title = "This week"
    let select: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                CardHeading(title: title)
                Spacer()
                if let first = days.first, let last = days.last {
                    let start = SampleDate.label(first.date, .dateTime.month(.abbreviated).day())
                    let end = SampleDate.label(last.date, .dateTime.month(.abbreviated).day())
                    Label("\(start) – \(end)", systemImage: "calendar")
                        .font(.caption.weight(.semibold)).foregroundStyle(Palette.muted)
                }
            }
            ViewThatFits(in: .horizontal) {
                daysRow
                ScrollView(.horizontal) { daysRow.fixedSize(horizontal: true, vertical: false) }
            }
        }
        .padding(12).surface()
    }

    private var daysRow: some View {
        HStack(spacing: 3) {
            ForEach(days) { entry in
                let selected = selection == entry.date
                Button {
                    select(entry.date)
                } label: {
                    VStack(spacing: 3) {
                        Text(SampleDate.label(entry.date, .dateTime.weekday(.abbreviated)))
                            .font(.caption2.weight(.semibold))
                        Text(SampleDate.label(entry.date, .dateTime.day())).font(.subheadline.weight(.bold))
                        if entry.statuses.isEmpty {
                            Circle().fill(entry.routineName == nil ? .clear : selected ? .white : Palette.purple)
                                .frame(width: 4, height: 4)
                        } else {
                            HStack(spacing: 2) {
                                ForEach(0..<min(3, entry.statuses.count), id: \.self) { index in
                                    let status = entry.statuses[index]
                                    Image(systemName: status.symbol).font(.system(size: 7, weight: .bold))
                                        .foregroundStyle(selected ? .white : status.tint)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 7)
                    .frame(minWidth: 44, maxWidth: .infinity, minHeight: 54)
                    .foregroundStyle(selected ? .white : .primary)
                    .background(selected ? Palette.action : Palette.soft, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(SampleDate.label(entry.date, .dateTime.weekday(.wide).month(.wide).day())), \(entry.routineName ?? "no workout scheduled")")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

struct WorkoutCard: View {
    let routine: Routine
    let active: Bool
    var label = "Planned workout"
    let start: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label.uppercased()).font(.caption2.weight(.bold)).tracking(1)
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(Color(hex: 0x493461), in: Capsule())
            Text(routine.name).font(.largeTitle.weight(.heavy)).accessibilityAddTraits(.isHeader)
            Text(routine.focus).font(.subheadline).foregroundStyle(Color(hex: 0xE3D9F4))
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { metadata }
                VStack(alignment: .leading, spacing: 5) { metadata }
            }
            .font(.caption.weight(.semibold)).foregroundStyle(Color(hex: 0xE3D9F4))
            Button(action: start) {
                Label(active ? "Resume Workout" : "Log Workout", systemImage: active ? "chevron.right" : "play.fill")
            }
            .buttonStyle(PrimaryButton())
            .padding(.top, 4)
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 235, alignment: .leading)
        .foregroundStyle(.white)
        .background {
            GeometryReader { geometry in
                ZStack(alignment: .trailing) {
                    Color(hex: 0x1A1623)
                    if routine.id == "upper-a" {
                        BundleImage(file: "workout-hero.png", contentMode: .fill)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                    } else {
                        Image(systemName: "figure.strengthtraining.traditional")
                            .font(.system(size: 138, weight: .thin)).foregroundStyle(Color(hex: 0x423351))
                            .padding(.trailing, 22).accessibilityHidden(true)
                    }
                    LinearGradient(colors: [Color(hex: 0x18141E), Color(hex: 0x18141E).opacity(0.82), .clear],
                                   startPoint: .leading, endPoint: .trailing)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 23))
    }

    @ViewBuilder private var metadata: some View {
        Label("\(routine.minutes) min", systemImage: "clock")
        Label("\(routine.exercises.count) exercises", systemImage: "dumbbell")
    }
}

struct BodyweightCard: View {
    let value: Double?
    let unit: WeightUnit
    let date: String
    let edit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                IconTile(symbol: "scalemass", size: 32)
                CardHeading(title: "Bodyweight")
                Spacer()
                Text(date).font(.caption).foregroundStyle(Palette.muted)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom) { measurement; Spacer(minLength: 8); editButton }
                VStack(alignment: .leading, spacing: 8) { measurement; editButton }
            }
        }
        .padding(14).surface()
    }

    private var measurement: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(value.map { unit.display($0, fractionDigits: 1...1) } ?? "—") \(unit.rawValue)")
                .font(.title2.weight(.bold)).monospacedDigit()
            Text(value == nil ? "No entry for this day" : "Saved on this device")
                .font(.caption).foregroundStyle(Palette.muted)
        }
    }

    private var editButton: some View {
        Button(action: edit) { Label(value == nil ? "Add entry" : "Edit", systemImage: value == nil ? "plus" : "pencil") }
            .buttonStyle(SecondaryButton())
            .accessibilityLabel(value == nil ? "Add bodyweight entry" : "Edit bodyweight entry")
    }
}

struct ExerciseList: View {
    let routine: Routine
    let unit: WeightUnit

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                CardHeading(title: "Exercises")
                Spacer()
                Text("\(routine.exercises.count) planned").font(.caption.weight(.semibold)).foregroundStyle(Palette.muted)
            }
            ForEach(routine.exercises.indices, id: \.self) { index in
                ExerciseCard(exercise: routine.exercises[index], index: index, unit: unit)
            }
        }
    }
}

struct ExerciseCard: View {
    let exercise: ExercisePrescription
    let index: Int
    let unit: WeightUnit
    @State private var expanded = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 10) {
                    if let image = exercise.image {
                        BundleImage(file: image, contentMode: .fill)
                            .frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 12))
                    } else {
                        IconTile(symbol: exercise.symbol, size: 48)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(exercise.name).font(.headline)
                        Text("\(exercise.muscles) / \(exercise.prescription)")
                            .font(.caption).foregroundStyle(Palette.muted)
                    }
                    Spacer(minLength: 2)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.bold)).foregroundStyle(Palette.muted)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded ? "Advanced details expanded" : "Advanced details collapsed")
            .accessibilityHint(expanded ? "Collapse advanced details" : "Show advanced details")
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 6)) : AnyLayout(HStackLayout(spacing: 6))
            layout {
                metric("Previous best set", value: exercise.previous.map { "\(unit.display($0.weightKg)) \(unit.rawValue) × \($0.reps)" } ?? "—")
                metric("Future prediction", value: "Coming later", prediction: true)
            }
            if expanded {
                Divider()
                detail("Set order", value: "\(index + 1)")
                detail("Target RIR", value: "\(exercise.rir) reps in reserve")
                detail("Rest", value: exercise.rest)
            }
        }
        .padding(12).surface()
    }

    private func metric(_ label: String, value: String, prediction: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if prediction {
                Label(label, systemImage: "sparkles").font(.caption2.weight(.semibold))
            } else {
                Text(label).font(.caption2.weight(.semibold)).foregroundStyle(Palette.muted)
            }
            Text(value).font(.subheadline.weight(.bold))
        }
        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
        .padding(8)
        .foregroundStyle(prediction ? Palette.purple : .primary)
        .background(prediction ? Palette.lavender : Palette.soft, in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .combine)
    }

    private func detail(_ label: String, value: String) -> some View {
        LabeledContent(label, value: value).font(.subheadline)
    }
}
