import Charts
import SwiftUI

struct AnalyticsProgress: View {
    let model: TrainingModel
    let filter: HistoryFilter
    let unit: WeightUnit
    @State private var anchor: WorkoutDate?
    @State private var warmUps = false
    @State private var settingsOpen = false

    var body: some View {
        let settings = model.records.analyticsSettings ?? AnalyticsSettings()
        let today = WorkoutDate(Date())
        let report = WorkoutAnalytics.weekly(model.records, anchor: anchor ?? filter.to ?? today, filter: filter, today: today) { id in
            model.catalog.first(where: { $0.id == id })?.profile ?? model.records.exercises.first(where: { $0.id == id })?.profile
        }
        let purpose: SetPurpose = warmUps ? .warmUp : .working
        let series = WorkoutAnalytics.exercises(model.records, filter: filter, purpose: purpose, settings: settings)
        let displayed = series.filter { entry in
            entry.plateau != nil || entry.points.contains { point in settings.visible.contains { point.values[$0] != nil } }
        }
        Button("Analytics settings") { settingsOpen = true }.buttonStyle(SecondaryButton())
            .sheet(isPresented: $settingsOpen) { AnalyticsSettingsSheet(model: model, settings: settings) }
        PersonalStatus(title: "Weekly dashboard", symbol: "calendar") {
            HStack {
                Button { step(-7, today: today) } label: { Image(systemName: "chevron.left").frame(minWidth: 44, minHeight: 44) }
                    .accessibilityLabel("Previous week")
                Spacer()
                Button("This week") { anchor = today }.frame(minHeight: 44)
                Spacer()
                Button { step(7, today: today) } label: { Image(systemName: "chevron.right").frame(minWidth: 44, minHeight: 44) }
                    .accessibilityLabel("Next week")
            }
            if let first = report.days.first, let last = report.days.last {
                Text(first.formatted(.dateTime.month(.abbreviated).day()) + " – " +
                    last.formatted(.dateTime.month(.abbreviated).day().year())).font(.caption).foregroundStyle(Palette.muted)
            }
            ForEach(DashboardStat.allCases.filter(settings.dashboard.contains)) { item in
                if item == .plan {
                    LabeledContent("Working sets", value: countText(report.performed.working, planned: report.planned.working))
                    LabeledContent("Warm-ups", value: countText(report.performed.warmUp, planned: report.planned.warmUp))
                } else {
                    LabeledContent(item.rawValue, value: dashboardValue(item, report: report)).font(.subheadline)
                }
            }
            WeeklyMuscleSets(report: report)
        }
        PersonalStatus(title: "Exercise trends and records", symbol: "chart.xyaxis.line") {
            Picker("Trend set type", selection: $warmUps) {
                Text("Working sets").tag(false)
                Text("Warm-ups").tag(true)
            }.pickerStyle(.segmented)
            Text("Trends come from finished workouts. Dates show peak load and estimated 1RM, and totals for reps, volume, duration, and distance.")
                .font(.caption).foregroundStyle(Palette.muted)
            DisclosureGroup("Estimated 1RM formula and limitations") {
                Text(WorkoutAnalytics.formulaHelp).font(.subheadline)
                if let study = WorkoutAnalytics.study { Link("Validation study", destination: study) }
            }
            Text("Equipment series stay separate. Machine settings have no weight or volume metric. Workout totals exclude machine and cable loads.")
                .font(.caption).foregroundStyle(Palette.muted)
        }
        if displayed.isEmpty {
            PersonalStatus(title: "No matching exercise trends", symbol: "chart.xyaxis.line") {
                Text("Check the filters, the selected set type, and visible metrics.").font(.subheadline).foregroundStyle(Palette.muted)
            }
        }
        ForEach(displayed) { entry in AnalyticsExerciseCard(series: entry, settings: settings, unit: unit) }
    }

    private func step(_ days: Int, today: WorkoutDate) { anchor = (anchor ?? filter.to ?? today).offset(days) }
    private func countText(_ actual: Int, planned: Int) -> String { "\(actual) completed · \(planned) planned" }

    private func dashboardValue(_ stat: DashboardStat, report: WeeklyAnalytics) -> String {
        switch stat {
        case .workouts: String(report.workouts)
        case .sets: String(report.performed.working)
        case .plan: countText(report.performed.working, planned: report.planned.working)
        case .volume: analyticsText(.volume, report.totals[.volume], unit: unit)
        case .duration: analyticsText(.duration, report.totals[.duration], unit: unit)
        case .distance: analyticsText(.distance, report.totals[.distance], unit: unit)
        }
    }
}

private struct WeeklyMuscleSets: View {
    let report: WeeklyAnalytics

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Weekly sets by muscle").font(.subheadline.weight(.semibold))
            Text("Primary muscles count as direct sets. Secondary muscles count as indirect sets. Each performed set counts once per muscle.")
                .font(.caption).foregroundStyle(Palette.muted)
            if report.muscles.isEmpty {
                Text("No logged sets for this week and filter selection.").font(.subheadline).foregroundStyle(Palette.muted)
            }
            ForEach(report.muscles.keys.sorted { $0.label < $1.label }) { group in
                if let row = report.muscles[group] {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(group.label).font(.subheadline.weight(.medium))
                        Text("Working sets · \(row.direct.working) direct · \(row.indirect.working) indirect").font(.caption)
                        Text("Warm-ups · \(row.direct.warmUp) direct · \(row.indirect.warmUp) indirect").font(.caption).foregroundStyle(Palette.muted)
                    }.accessibilityElement(children: .combine)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AnalyticsExerciseCard: View {
    let series: ExerciseAnalytics
    let settings: AnalyticsSettings
    let unit: WeightUnit

    var body: some View {
        let row = series.row
        PersonalStatus(title: row.variant.exercise.name, symbol: "chart.xyaxis.line") {
            Text(equipment(row)).font(.caption).foregroundStyle(Palette.muted)
            if let plateau = series.plateau {
                switch plateau {
                case .deload:
                    Text("Planned deload · Plateau check paused").font(.caption.weight(.semibold)).foregroundStyle(Palette.purple)
                case .flag(let change, let count):
                    Text("Possible plateau · \(settings.plateauMetric.rawValue) · \(change.formatted(.number.precision(.fractionLength(0...2))))% best change over \(count) sessions")
                        .font(.caption.weight(.semibold)).foregroundStyle(Palette.purple)
                }
            }
            if settings.visible.contains(.load), let effort = series.records.heaviest {
                Text("Heaviest logged load \(analyticsText(.load, effort.load, unit: unit))").font(.subheadline.weight(.semibold))
                Text(detail(effort)).font(.caption).foregroundStyle(Palette.muted)
                records("Best reps at each load", efforts: series.records.byLoad)
                records("Heaviest load by rep count", efforts: series.records.byReps)
            }
            ForEach(AnalyticsMetric.allCases.filter(settings.visible.contains)) { metric in
                if series.points.contains(where: { $0.values[metric] != nil }) {
                    AnalyticsTrendChart(series: series, metric: metric, unit: unit)
                }
            }
            let events = series.points.filter { !$0.events.isEmpty }
            if !events.isEmpty {
                DisclosureGroup("Chart annotations") {
                    ForEach(events) { point in
                        Text(point.date.key + " · " + point.events.joined(separator: " · ")).font(.caption)
                    }
                }
            }
        }
    }

    private func equipment(_ row: PlannedExercise) -> String {
        var label = row.historyEquipmentName
        if case .weightReps(.perDumbbell, _) = row.variant.measurement { label += " · Per dumbbell" }
        if row.unlinkedStation { label += " · Unidentified station, single session" }
        return label
    }

    private func detail(_ effort: AnalyticsEffort) -> String {
        let side = effort.side.isEmpty ? "" : " · " + effort.side
        return "\(analyticsText(.load, effort.load, unit: unit)) × \(effort.reps)\(side) · \(effort.date.key)"
    }

    private func records(_ name: String, efforts: [AnalyticsEffort]) -> some View {
        DisclosureGroup(name) {
            ForEach(efforts) { effort in Text(detail(effort)).font(.caption) }
        }.font(.subheadline)
    }
}

private struct AnalyticsTrendChart: View {
    let series: ExerciseAnalytics
    let metric: AnalyticsMetric
    let unit: WeightUnit

    private var title: String {
        guard metric == .load else { return metric.rawValue }
        switch series.row.variant.measurement {
        case .addedLoad: return "Added load"
        case .assistance: return "Assistance load"
        default: return metric.rawValue
        }
    }

    var body: some View {
        let points = series.points.filter { $0.values[metric] != nil }
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            if let latest = points.last {
                Text("Latest · \(analyticsText(metric, latest.values[metric], unit: unit)) · \(latest.date.key)")
                    .font(.caption).foregroundStyle(Palette.muted)
            }
            Chart {
                ForEach(series.points.filter { !$0.events.isEmpty }) { point in
                    RuleMark(x: .value("Event date", point.date.localPickerDate)).foregroundStyle(Palette.muted)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
                }
                ForEach(points) { point in
                    if let value = point.values[metric] {
                        LineMark(x: .value("Date", point.date.localPickerDate), y: .value(title, converted(value)))
                            .foregroundStyle(Palette.purple)
                        PointMark(x: .value("Date", point.date.localPickerDate), y: .value(title, converted(value)))
                            .foregroundStyle(Palette.purple)
                    }
                }
            }.frame(height: 110)
            DisclosureGroup("Values by date") {
                ForEach(points) { point in
                    Text(point.date.key + " · " + analyticsText(metric, point.values[metric], unit: unit)).font(.caption)
                }
            }.font(.subheadline)
        }.padding(8).background(Palette.soft, in: RoundedRectangle(cornerRadius: 10))
    }

    private func converted(_ value: Double) -> Double {
        (metric == .load || metric == .estimate || metric == .volume) ? value / unit.kilogramsPerUnit : value
    }
}

private struct AnalyticsSettingsSheet: View {
    let model: TrainingModel
    @State var settings: AnalyticsSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Show exercise metrics and records") {
                    ForEach(AnalyticsMetric.allCases) { metric in
                        Toggle(metric.rawValue, isOn: Binding(get: { settings.visible.contains(metric) }, set: {
                            if $0 { settings.visible.insert(metric) } else { settings.visible.remove(metric) }
                        }))
                    }
                }
                Section("Weekly dashboard statistics") {
                    ForEach(DashboardStat.allCases) { stat in
                        Toggle(stat.rawValue, isOn: Binding(get: { settings.dashboard.contains(stat) }, set: {
                            if $0 { settings.dashboard.insert(stat) } else { settings.dashboard.remove(stat) }
                        }))
                    }
                }
                Section("Plateau flags") {
                    Toggle("Show possible plateau flags", isOn: $settings.plateauEnabled)
                    Picker("Plateau metric", selection: $settings.plateauMetric) {
                        ForEach(AnalyticsMetric.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Stepper("Comparable sessions · \(settings.plateauSessions)", value: $settings.plateauSessions, in: 3...12)
                    TextField("Minimum improvement (%)", value: $settings.plateauPercent, format: .number).keyboardType(.decimalPad)
                    Stepper("Training break · \(settings.breakDays) days", value: $settings.breakDays, in: 7...90)
                    Text("Setline compares the first eligible session with the best later session in the window and flags improvement below your threshold. It uses matching working sets, excludes deloads, and starts a new window after a training break or a routine version, program, or equipment change.")
                        .font(.caption).foregroundStyle(Palette.muted)
                    if let error = model.storageError { Text(error).foregroundStyle(Palette.red) }
                }
            }
            .navigationTitle("Analytics settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { if model.updateUserData({ try $0.saveAnalytics(settings) }) { dismiss() } }
                }
            }
        }
    }
}

private func analyticsText(_ metric: AnalyticsMetric, _ value: Double?, unit: WeightUnit) -> String {
    guard let value else { return "Unrecorded" }
    switch metric {
    case .load, .estimate: return "\(unit.display(value, fractionDigits: 0...2)) \(unit.rawValue)"
    case .volume: return "\(unit.display(value, fractionDigits: 0...2)) \(unit.rawValue)·reps"
    case .duration, .distance, .reps:
        let suffix = metric == .duration ? " s" : metric == .distance ? " m" : " reps"
        return value.formatted(.number.precision(.fractionLength(0...2))) + suffix
    }
}
