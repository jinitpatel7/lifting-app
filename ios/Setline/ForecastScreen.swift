import SwiftUI

struct WorkoutForecastPreview: View {
    let plan: RoutineVersion
    let records: TrainingRecords
    let unit: WeightUnit
    let day: WorkoutDate
    let deload: Bool
    let now: Date
    @State private var expanded = false

    var body: some View {
        DisclosureGroup("Performance forecast preview", isExpanded: $expanded) {
            if expanded {
                Text("A forecast is saved when you start the workout.").font(.caption).foregroundStyle(Palette.muted)
                ForEach(plan.exercises) { row in
                    let forecast = ExerciseForecasts.make(for: row, in: plan, records: records, at: now,
                        day: day, deload: deload)
                    ForecastDetails(forecast: forecast, unit: unit, label: row.variant.exercise.name, saved: false)
                }
            }
        }.tint(Palette.purple)
    }
}

struct WorkoutForecastArchive: View {
    let session: WorkoutSession
    let unit: WeightUnit

    var body: some View {
        if let forecasts = session.performanceForecasts, !forecasts.isEmpty {
            DisclosureGroup("Saved performance forecasts") {
                Text("These forecasts were saved before the respective exercise results. Each revision preserves its original estimate.")
                    .font(.caption).foregroundStyle(Palette.muted)
                ForEach(forecasts) { forecast in
                    ForecastDetails(forecast: forecast, unit: unit, label: "\(forecast.name) · Revision \(forecast.revision)", saved: true)
                }
            }.tint(Palette.purple)
        }
    }
}

struct ForecastDetails: View {
    let forecast: PerformanceForecast
    let unit: WeightUnit
    let label: String
    let saved: Bool

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                Text([status, forecast.sources.isEmpty ? nil : "\(forecast.sources.count) sessions used"].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline.weight(.semibold))
                if saved {
                    Text("Saved \(forecast.issuedAt.formatted(date: .abbreviated, time: .shortened)) · \(forecast.equipment) · \(forecast.model)")
                        .font(.caption).foregroundStyle(Palette.muted)
                }
                ForEach(ForecastDimension.allCases.filter { forecast.ranges[$0] != nil }, id: \.self) { metric in
                    if let range = forecast.ranges[metric] {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(metric.title) · \(rangeText(range, metric: metric))").font(.subheadline.weight(.semibold))
                            Text("Typical \(metric.value(range.center, unit: unit))" + previousText(metric, current: range.center))
                                .font(.caption).foregroundStyle(Palette.muted)
                        }
                    }
                }
                if forecast.status == .ready {
                    Text("The range describes recent variation in the first straight working set.").font(.caption)
                    if let conventions { Text(conventions).font(.caption).foregroundStyle(Palette.muted) }
                }
                if let previous = forecast.previous {
                    let values = ForecastDimension.allCases.compactMap { metric in previous.values[metric].map { metric.value($0, unit: unit) } }
                    let date = previous.day.formatted(.dateTime.month(.abbreviated).day().year())
                    Text("Previous-session benchmark · " + ([date] + values).joined(separator: " · "))
                        .font(.caption).foregroundStyle(Palette.muted)
                }
                ForEach(forecast.notes.indices, id: \.self) { index in
                    Text(forecast.notes[index]).font(.caption).foregroundStyle(Palette.muted)
                }
                if !forecast.sources.isEmpty {
                    Text("Source dates · " + forecast.sources.map { $0.day.formatted(.dateTime.month(.abbreviated).day().year()) }.joined(separator: ", "))
                        .font(.caption).foregroundStyle(Palette.muted)
                }
            }.padding(.vertical, 5)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(label).font(.subheadline.weight(.semibold))
                Text(brief).font(.caption).foregroundStyle(Palette.purple)
            }.frame(minHeight: 44)
        }.tint(Palette.purple)
    }

    private var status: String {
        switch forecast.status {
        case .learning: "Learning your baseline"
        case .paused: "Forecast unavailable"
        case .ready: forecast.confidence ?? "Limited confidence"
        }
    }

    private var brief: String {
        if forecast.status != .ready { return status }
        return ForecastDimension.allCases.compactMap { metric in
            forecast.ranges[metric].map { rangeText($0, metric: metric) }
        }.joined(separator: " · ")
    }

    private var conventions: String? {
        let measurement = forecast.variant.measurement
        let load = if case .weightReps(.perDumbbell, _) = measurement { "Load per dumbbell." } else { "" }
        let reps = switch measurement.repCounting {
        case .perSide, .separateSides: "Reps per side. Separately logged sides use the lower reps."
        default: ""
        }
        let side: String
        switch measurement {
        case .duration, .distance: side = "Separately logged sides use the shorter result."
        case .assistance(let count) where count != .total: side = "Separate sides use the greater assistance."
        case .weightReps(_, let count), .addedLoad(let count):
            side = count == .total ? "" : "Separate sides use the lower load."
        default: side = ""
        }
        let info = [load, reps, side].filter { !$0.isEmpty }.joined(separator: " ")
        return info.isEmpty ? nil : info
    }

    private func rangeText(_ range: ForecastRange, metric: ForecastDimension) -> String {
        "\(metric.value(range.low, unit: unit, includeUnit: false))–\(metric.value(range.high, unit: unit))"
    }

    private func previousText(_ metric: ForecastDimension, current: Double) -> String {
        guard forecast.notes.contains(where: { $0.hasPrefix("The typical estimate changed") }),
              let previous = forecast.priorRanges?[metric]?.center, previous != current else { return "" }
        return " · Prior forecast " + metric.value(previous, unit: unit)
    }
}

struct ForecastAccuracyCard: View {
    let records: TrainingRecords
    let unit: WeightUnit

    var body: some View {
        PersonalStatus(title: "Forecast accuracy", symbol: "chart.line.uptrend.xyaxis") {
            let scores = ExerciseForecasts.scores(records)
            Text("Setline scores saved forecasts against the first comparable straight working set in each finished workout. The benchmark repeats the previous comparable session. Smaller average errors are better.")
                .font(.caption).foregroundStyle(Palette.muted)
            if scores.isEmpty { Text("No comparable forecasts have been scored yet.").font(.subheadline) }
            ForEach(scores) { score in
                let setting = score.id.setting.map { " · Setting \($0)" } ?? ""
                DisclosureGroup("\(score.name) · \(score.equipment)\(setting) · \(score.count) scored") {
                    Text("Model \(score.id.model)").font(.caption).foregroundStyle(Palette.muted)
                    ForEach(ForecastDimension.allCases.filter { score.metrics[$0] != nil }, id: \.self) { dimension in
                        if let metric = score.metrics[dimension] {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(dimension.title).font(.subheadline.weight(.semibold))
                                Text("Forecast error \(dimension.value(metric.forecastError / Double(score.count), unit: unit))")
                                Text("Previous-session error \(dimension.value(metric.previousError / Double(score.count), unit: unit))")
                                Text("\(metric.inside) of \(score.count) inside the forecast range")
                            }.font(.caption)
                        }
                    }
                }
            }
            DisclosureGroup("How forecasts work") {
                Text("Model \(PerformanceForecast.modelVersion) uses the median of up to eight comparable sessions from the preceding 120 days. It needs at least three. Ranges reflect recent variation and widen after a break of at least 21 days. They have no guaranteed coverage.")
                Text("Equipment and tracking stay separate. Exercise order, planned load or assistance, rep ranges, rest, and recorded effort can narrow the evidence when enough sessions match. Warm-ups, special sets, deloads, and isolated extremes stay outside the estimate.")
                Text("Scores require matching equipment, tracking, and first-or-later exercise order. Machine settings must also match. “More comparable history” requires at least six results without a long break or mixed context. Your workouts are processed locally. This version uses a fixed rule and leaves bodyweight and readiness out.")
            }.font(.caption)
        }
    }
}

private extension ForecastDimension {
    var title: String {
        switch self {
        case .weight: "Load"
        case .added: "Added load"
        case .assistance: "Assistance"
        case .reps: "Reps"
        case .duration: "Duration"
        case .distance: "Distance"
        }
    }

    func value(_ amount: Double, unit: WeightUnit, includeUnit: Bool = true) -> String {
        let number = isMass ? unit.display(amount, fractionDigits: 0...2) : amount.formatted(.number.precision(.fractionLength(0...2)))
        guard includeUnit else { return number }
        let suffix = switch self {
        case .reps: "reps"
        case .duration: "s"
        case .distance: "m"
        default: unit.rawValue
        }
        return number + " " + suffix
    }
}
