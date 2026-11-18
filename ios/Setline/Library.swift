import Charts
import SwiftUI

struct RoutinesScreen: View {
    let sample: SampleData
    let model: TrainingModel
    let unit: WeightUnit
    let active: Bool
    let start: (Routine) -> Void
    let browseLibrary: () -> Void
    let browseMuscle: (MuscleGroup) -> Void
    @Binding var selection: Routine?

    var body: some View {
        if let routine = selection {
            Button {
                selection = nil
            } label: {
                Label("All routines", systemImage: "chevron.left")
            }
            .buttonStyle(SecondaryButton())
            .frame(maxWidth: .infinity, alignment: .leading)
            WorkoutCard(routine: routine, active: active, label: "Sample routine") { start(routine) }
            InteractiveMuscleMap(involvement: model.sampleInvolvement(routine), browse: browseMuscle)
            ExerciseList(routine: routine, unit: unit).id(routine.id)
        } else {
            PageHeading(title: "Routines", subtitle: "Training library")
            LibraryEntryButton(open: browseLibrary)
            Text("Sample routines show how your own workouts will appear.")
                .font(.subheadline).foregroundStyle(Palette.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(sample.routines) { routine in
                Button {
                    selection = routine
                } label: {
                    HStack(spacing: 12) {
                        IconTile(symbol: "dumbbell", size: 48)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(routine.name).font(.headline)
                            Text("\(routine.exercises.count) exercises · \(routine.minutes) min")
                                .font(.subheadline).foregroundStyle(Palette.muted)
                            Text(routine.primaryMuscles).font(.caption).foregroundStyle(Palette.muted)
                        }
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right").foregroundStyle(Palette.purple).accessibilityHidden(true)
                    }
                    .padding(14).surface()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct HistoryScreen: View {
    enum Section: String, CaseIterable, Identifiable {
        case progress = "Progress", sessions = "Sessions"
        var id: Self { self }
    }

    let sample: SampleData
    let unit: WeightUnit
    @Binding var selection: Section

    var body: some View {
        PageHeading(title: "History", subtitle: "Training progress")
        SelectionControl(label: "History view", selection: $selection, options: Section.allCases, title: \.rawValue)
        if selection == .progress {
            chart
        } else {
            ForEach(sample.history) { entry in
                HStack(spacing: 10) {
                    IconTile(symbol: "dumbbell")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(sample.routine(entry.routineID)?.name ?? "Workout").font(.headline)
                        Text("\(entry.sets) sets · \(entry.minutes) min").font(.caption).foregroundStyle(Palette.muted)
                    }
                    Spacer(minLength: 4)
                    Text(shortDate(entry.date)).font(.caption).foregroundStyle(Palette.muted)
                }
                .padding(14).surface()
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                CardHeading(title: "Barbell Bench Press")
                Spacer()
                IconTile(symbol: "chart.xyaxis.line")
            }
            Text("Heaviest logged set by date").font(.subheadline).foregroundStyle(Palette.muted)
            if let latest = sample.benchTrend.last {
                Text("\(unit.display(latest.weightKg)) \(unit.rawValue)").font(.title.weight(.bold))
            }
            Chart(sample.benchTrend) { point in
                let load = point.weightKg / unit.kilogramsPerUnit
                LineMark(x: .value("Date", shortDate(point.date)), y: .value("Load", load))
                    .foregroundStyle(Palette.purple)
                    .accessibilityHidden(true)
                PointMark(x: .value("Date", shortDate(point.date)), y: .value("Load", load))
                    .foregroundStyle(Palette.purple)
                    .accessibilityLabel(shortDate(point.date))
                    .accessibilityValue("\(unit.display(point.weightKg)) \(unit.rawValue)")
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .frame(height: 185)
            .accessibilityLabel("Sample bench press progress in \(unit.name.lowercased())")
        }
        .padding(16).surface()
    }

    private func shortDate(_ date: String) -> String {
        SampleDate.label(date, .dateTime.month(.abbreviated).day())
    }
}

enum Appearance: String, CaseIterable, Identifiable {
    case system = "System", light = "Light", dark = "Dark"

    var id: Self { self }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

struct SettingsScreen: View {
    @Binding var appearance: Appearance
    @Binding var opaque: Bool
    @Binding var unit: WeightUnit
    @Environment(\.accessibilityReduceTransparency) private var systemOpaque

    var body: some View {
        PageHeading(title: "Settings", subtitle: "Preferences")
        VStack(alignment: .leading, spacing: 12) {
            title("Appearance", icon: "sun.max")
            SelectionControl(label: "Appearance", selection: $appearance, options: Appearance.allCases, title: \.rawValue)
            Divider()
            Toggle(isOn: $opaque) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Reduce transparency").font(.subheadline.weight(.semibold))
                    Text(systemOpaque ? "Solid navigation is enabled by your iPhone settings." : "Use a solid background for navigation.")
                        .font(.caption).foregroundStyle(Palette.muted)
                }
            }
            .frame(minHeight: 44)
            .tint(Palette.action)
        }
        .padding(14).surface()
        VStack(alignment: .leading, spacing: 12) {
            title("Weight units", icon: "scalemass")
            SelectionControl(label: "Weight units", selection: $unit, options: WeightUnit.allCases, title: \.name)
        }
        .padding(14).surface()
        VStack(alignment: .leading, spacing: 10) {
            title("Local data", icon: "info.circle")
            Text("Your training data is stored on this iPhone. Sample data has its own preview and storage.")
                .font(.subheadline).foregroundStyle(Palette.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14).surface()
    }

    private func title(_ title: String, icon: String) -> some View {
        HStack(spacing: 8) {
            IconTile(symbol: icon, size: 32)
            CardHeading(title: title)
        }
    }
}

struct SelectionControl<Option: Identifiable & Hashable>: View {
    let label: String
    @Binding var selection: Option
    let options: [Option]
    let title: KeyPath<Option, String>
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 4))
        layout {
            ForEach(options) { option in
                let selected = option == selection
                Button {
                    selection = option
                } label: {
                    Text(option[keyPath: title]).font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(selected ? Palette.purple : Palette.muted)
                        .background(selected ? Palette.surface : .clear, in: RoundedRectangle(cornerRadius: 9))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Palette.soft, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}
