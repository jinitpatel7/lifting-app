import Charts
import SwiftUI

struct BodyweightProgressCard: View {
    let model: TrainingModel
    let unit: WeightUnit
    let edit: (WorkoutDate) -> Void
    @State private var selectedDate = Date()
    @State private var targetOpen = false

    var body: some View {
        let today = WorkoutDate(Date())
        let readings = BodyweightTrend.points(model.records.bodyweightEntries, through: today)
        let recent = readings.last.map { last in
            readings.filter { $0.entry.localDate >= last.entry.localDate.offset(-89) }
        } ?? []
        PersonalStatus(title: "Bodyweight history", symbol: "scalemass") {
            if recent.isEmpty {
                Text("No readings yet").foregroundStyle(Palette.muted)
            } else {
                BodyweightHistoryChart(points: recent, unit: unit)
                if let newest = recent.last {
                    Text("Latest reading · " + massText(newest.entry.mass.kilograms))
                        .font(.subheadline.weight(.semibold))
                    if let trend = newest.smoothedKilograms {
                        Text("Smoothed trend on \(newest.entry.localDate.key) · " + massText(trend)).font(.subheadline)
                    }
                }
            }
            Text("The smoothed trend is a trailing 7-day average of recorded readings. It appears after two readings in that window and follows historical dates.")
                .font(.caption).foregroundStyle(Palette.muted)
            Button("Edit target rate") { targetOpen = true }.buttonStyle(SecondaryButton())
                .sheet(isPresented: $targetOpen) { BodyweightTargetSheet(model: model, unit: unit) }
            if let target = model.records.bodyweightTargetKgPerWeek {
                Text("Target rate · \(target > 0 ? "+" : "")\(unit.display(target, fractionDigits: 0...3)) \(unit.rawValue) per week")
                    .font(.caption).foregroundStyle(Palette.muted)
            }
            DatePicker("Reading date", selection: $selectedDate, in: ...Date(), displayedComponents: .date)
            Button("Log or edit reading") { edit(WorkoutDate(selectedDate)) }.buttonStyle(SecondaryButton())
            if !readings.isEmpty {
                DisclosureGroup("Raw readings") {
                    ForEach(readings.reversed()) { point in
                        Button { edit(point.entry.localDate) } label: {
                            LabeledContent(point.entry.localDate.key, value: massText(point.entry.mass.kilograms))
                                .frame(minHeight: 44)
                        }.accessibilityHint("Edit this reading")
                    }
                }
            }
        }
    }

    private func massText(_ value: Double) -> String {
        unit.display(value, fractionDigits: 1...2) + " " + unit.rawValue
    }
}

private struct BodyweightHistoryChart: View {
    let points: [BodyweightTrendPoint]
    let unit: WeightUnit

    var body: some View {
        let values = points.flatMap { point in
            [point.entry.mass.value(in: unit)] + (point.smoothedKilograms.map { [$0 / unit.kilogramsPerUnit] } ?? [])
        }
        let lower = (values.min() ?? 0) - 0.4
        let upper = (values.max() ?? 1) + 0.4
        Chart(points) { point in
            let date = point.entry.localDate.localPickerDate
            PointMark(x: .value("Date", date), y: .value("Raw reading", point.entry.mass.value(in: unit)))
                .foregroundStyle(Palette.red)
            if let smoothed = point.smoothedKilograms {
                LineMark(x: .value("Date", date), y: .value("Smoothed trend", smoothed / unit.kilogramsPerUnit))
                    .foregroundStyle(Palette.purple)
                PointMark(x: .value("Date", date), y: .value("Smoothed trend", smoothed / unit.kilogramsPerUnit))
                    .foregroundStyle(Palette.purple).symbolSize(15)
            }
        }
        .chartYScale(domain: lower...upper)
        .chartYAxisLabel(unit.rawValue)
        .frame(height: 150)
        HStack {
            Label("Raw readings", systemImage: "circle.fill").foregroundStyle(Palette.red)
            Label("Smoothed 7-day trend", systemImage: "line.diagonal").foregroundStyle(Palette.purple)
        }.font(.caption)
    }
}

private struct BodyweightTargetSheet: View {
    let model: TrainingModel
    let unit: WeightUnit
    @Environment(\.dismiss) private var dismiss
    @State private var input: String
    @State private var invalid = false
    let originalText: String

    init(model: TrainingModel, unit: WeightUnit) {
        self.model = model
        self.unit = unit
        originalText = model.records.bodyweightTargetKgPerWeek.map { unit.display($0, fractionDigits: 0...6) } ?? ""
        _input = State(initialValue: originalText)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Target \(unit.rawValue) per week", text: $input).keyboardType(.numbersAndPunctuation)
                Text("Use a negative number for loss, a positive number for gain, or zero for maintenance. Leave it blank to remove the target.")
                    .font(.caption).foregroundStyle(Palette.muted)
                if invalid { Text("Enter a valid weekly rate of change.").foregroundStyle(Palette.red) }
                if let error = model.storageError { Text(error).foregroundStyle(Palette.red) }
            }
            .navigationTitle("Bodyweight target")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
            }
        }
    }

    private func save() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let kilograms: Double?
        if text == originalText { kilograms = model.records.bodyweightTargetKgPerWeek }
        else if text.isEmpty { kilograms = nil }
        else if let value = try? Double(text, format: .number, lenient: false), value.isFinite {
            kilograms = value * unit.kilogramsPerUnit
        } else { invalid = true; return }
        if model.updateUserData({ try $0.saveBodyweightTarget(kilograms) }) { dismiss() }
    }
}
