import SwiftUI

struct WeeklyRecapCard: View {
    let model: TrainingModel
    let unit: WeightUnit
    @State private var anchor: WorkoutDate?
    @Environment(\.dynamicTypeSize) private var bodySize

    var body: some View {
        let now = Date()
        let today = WorkoutDate(now)
        let report = WeeklyRecap.make(model.records, anchor: anchor ?? today, today: today) { id in
            model.records.exercises.first { $0.id == id }?.profile ?? model.catalog.first { $0.id == id }?.profile
        }
        let first = report.training.days[0], last = report.training.days[6]
        PersonalStatus(title: "Weekly recap", symbol: "calendar") {
            let dateRange = date(first) + " – " + date(last)
            Text(dateRange + (today <= last ? " · In progress" : "")).font(.subheadline).foregroundStyle(Palette.muted)
            ViewThatFits(in: .horizontal) {
                HStack { navigation(today: today, first: first) }
                VStack(alignment: .leading) { navigation(today: today, first: first) }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .topLeading), count: bodySize.isAccessibilitySize ? 1 : 2), alignment: .leading) {
                let statuses = [(report.sessions.pending, "upcoming"), (report.sessions.missed, "missed"),
                    (report.sessions.skipped, "skipped"), (report.sessions.scheduledIncomplete, "scheduled with incomplete logs")]
                    .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: " · ")
                recapStat("Scheduled sessions", value: "\(report.sessions.scheduled) of \(report.sessions.planned) completed", note: statuses)
                recapStat("Unscheduled sessions", value: "\(report.sessions.unscheduled) completed", note: "")
                recapStat("Working-set volume", value: report.training.totals[.volume].map {
                    "\(unit.display($0, fractionDigits: 0...2)) \(unit.rawValue)·reps"
                } ?? "Unavailable", note: "External and added load outside machine and cable work")
                let weight = report.weight.latest?.smoothedKilograms.map { mass($0) } ?? "Unavailable"
                recapStat("Bodyweight trend", value: weight, note: weightNote(report.weight))
            }
            if report.sessions.deload > 0 {
                Text("\(report.sessions.deload) scheduled \(report.sessions.deload == 1 ? "session is" : "sessions are") in a planned deload.")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Palette.purple)
            }
            if !report.deloads.isEmpty {
                Text("Deload programs this week · " + report.deloads.joined(separator: ", ")).font(.caption).foregroundStyle(Palette.muted)
            }
            if report.sessions.incomplete > 0 {
                Text("\(report.sessions.incomplete) \(report.sessions.incomplete == 1 ? "incomplete log" : "incomplete logs") this week. Logged sets contribute to volume and muscle coverage. Unlogged work stays unknown.")
                    .font(.caption).foregroundStyle(Palette.muted)
            }
            trainingHighlights(report)
            muscleCoverage(report.training.muscles)
            nextWorkout(report.next, now: now)
            energy(report.energy)
        }
    }

    @ViewBuilder private func navigation(today: WorkoutDate, first: WorkoutDate) -> some View {
        Button("Previous recap week") { anchor = (anchor ?? today).offset(-7) }.buttonStyle(SecondaryButton())
        Button("Next recap week") {
            let day = (anchor ?? today).offset(7)
            anchor = day >= today ? nil : day
        }.buttonStyle(SecondaryButton()).disabled(first.offset(7) > today)
    }

    private func recapStat(_ title: String, value: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(Palette.muted)
            Text(value).font(.subheadline.weight(.semibold))
            if !note.isEmpty { Text(note).font(.caption2).foregroundStyle(Palette.muted) }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(9).background(Palette.soft, in: RoundedRectangle(cornerRadius: 8))
    }

    private func trainingHighlights(_ report: WeeklyRecap) -> some View {
        DisclosureGroup("Personal records and comparable changes") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Personal records").font(.subheadline.weight(.semibold))
                if report.personalRecords.isEmpty { Text("No new records with an earlier comparison.").font(.caption) }
                ForEach(report.personalRecords) { record in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(record.row.variant.exercise.name) · \(record.row.historyEquipmentName)").font(.subheadline.weight(.semibold))
                        Text("\(record.kind) · \(recordValue(record)) · \(date(record.day))").font(.caption)
                    }
                }
                Text("Comparable performance changes").font(.subheadline.weight(.semibold))
                Text("First straight working sets on the same setup and in similar exercise order. Deloads stay outside these comparisons.")
                    .font(.caption).foregroundStyle(Palette.muted)
                if report.changes.isEmpty { Text("No comparable performance changes recorded.").font(.caption) }
                ForEach(report.changes) { change in
                    let setting = change.id.setting.map { " · Setting " + $0 } ?? ""
                    Text("\(change.row.variant.exercise.name) · \(change.row.historyEquipmentName)\(setting)").font(.subheadline.weight(.semibold))
                    Text("\(date(change.previous.day)) → \(date(change.current.day))").font(.caption).foregroundStyle(Palette.muted)
                    ForEach(ForecastDimension.allCases.filter { change.current.values[$0] != nil }, id: \.self) { metric in
                        if let before = change.previous.values[metric], let after = change.current.values[metric] {
                            Text("\(metric.title) · \(metric.value(before, unit: unit)) → \(metric.value(after, unit: unit))\(convention(metric, row: change.row))")
                                .font(.caption)
                        }
                    }
                }
            }.padding(.vertical, 5)
        }.tint(Palette.purple)
    }

    private func muscleCoverage(_ muscles: [MuscleGroup: MuscleSetTally]) -> some View {
        DisclosureGroup("Muscle coverage") {
            VStack(alignment: .leading, spacing: 8) {
                if muscles.isEmpty { Text("No muscle coverage logged.").font(.caption) }
                ForEach(muscles.keys.sorted { $0.label < $1.label }, id: \.self) { muscle in
                    if let counts = muscles[muscle] {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(muscle.label).font(.subheadline.weight(.semibold))
                            Text("Working sets · \(counts.direct.working) direct · \(counts.indirect.working) indirect").font(.caption)
                            Text("Warm-ups · \(counts.direct.warmUp) direct · \(counts.indirect.warmUp) indirect").font(.caption).foregroundStyle(Palette.muted)
                        }
                    }
                }
            }.padding(.vertical, 5)
        }.tint(Palette.purple)
    }

    private func nextWorkout(_ next: WeeklyRecap.Next?, now: Date) -> some View {
        DisclosureGroup("Next scheduled workout") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Upcoming from today’s schedule.").font(.caption).foregroundStyle(Palette.muted)
                if let next {
                    let deload = WorkoutAnalytics.context(for: next.occurrence, records: model.records).kind == .deload
                    Text("\(next.plan.name) · \(date(next.occurrence.date))").font(.subheadline.weight(.semibold))
                    if deload { Text("Planned deload").font(.caption).foregroundStyle(Palette.purple) }
                    Text("Planned targets · Version \(next.plan.revision)").font(.subheadline.weight(.semibold))
                    RoutinePlanRows(version: next.plan, unit: unit)
                    WorkoutForecastPreview(plan: next.plan, records: model.records, unit: unit, day: next.occurrence.date,
                        deload: deload, now: now)
                } else { Text("No upcoming session scheduled.").font(.subheadline) }
            }.padding(.vertical, 5)
        }.tint(Palette.purple)
    }

    private func energy(_ energy: WeeklyRecap.Energy) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(energy.count > 0 ? "Estimated gross calories · \(energy.total.formatted(.number.precision(.fractionLength(0)))) kcal" : "Calories unavailable")
                .font(.subheadline.weight(.semibold))
            Text(energy.count > 0 ? "\(energy.count) of \(energy.eligible) logged workouts have enough inputs. The total covers those workouts." :
                "Requires calorie inputs for a finished workout and a weigh-in on its date.")
                .font(.caption).foregroundStyle(Palette.muted)
        }.padding(9).frame(maxWidth: .infinity, alignment: .leading).background(Palette.soft, in: RoundedRectangle(cornerRadius: 8))
    }

    private func date(_ date: WorkoutDate) -> String { date.formatted(.dateTime.month(.abbreviated).day().year()) }
    private func mass(_ value: Double) -> String { unit.display(value, fractionDigits: 0...2) + " " + unit.rawValue }

    private func weightNote(_ weight: WeeklyRecap.Weight) -> String {
        guard let latest = weight.latest else { return "\(weight.count) readings this week" }
        var note = "7-day average on \(date(latest.entry.localDate))"
        if let initial = weight.initial, let before = initial.smoothedKilograms, let after = latest.smoothedKilograms {
            let delta = after - before
            note += " · \(delta >= 0 ? "+" : "")\(mass(delta)) vs \(date(initial.entry.localDate))"
        }
        return note
    }

    private func recordValue(_ record: RecapPersonalRecord) -> String {
        if let effort = record.effort {
            let side = effort.side.isEmpty ? "" : " (\(effort.side))"
            return "\(mass(effort.load))\(convention(.weight, row: record.row)) × \(effort.reps)\(side)"
        }
        return record.measurement.flatMap { metric in record.amount.map { metric.value($0, unit: unit) } } ?? ""
    }

    private func convention(_ metric: ForecastDimension, row: PlannedExercise) -> String {
        let measure = row.variant.measurement
        if metric == .weight, case .weightReps(.perDumbbell, _) = measure { return " per dumbbell" }
        if metric == .reps, let reps = measure.repCounting, reps != .total { return " per side" }
        return ""
    }
}

struct WorkoutScoreBreakdown: View {
    let assessment: WorkoutScoreAssessment

    var body: some View {
        switch assessment.availability {
        case .unavailable(let reason):
            Text(reason).font(.caption).foregroundStyle(Palette.muted)
        case .available(let score):
            disclosure(score)
        }
    }

    private func disclosure(_ score: Int) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(assessment.components) { component in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(component.name).font(.subheadline.weight(.semibold))
                        if let points = component.points {
                            Text("\(points.formatted(.number.precision(.fractionLength(0...1)))) / \(component.maximumPoints.formatted(.number.precision(.fractionLength(0...1)))) points")
                                .font(.caption)
                        } else { Text("Unavailable").font(.caption) }
                        Text(component.detail).font(.caption).foregroundStyle(Palette.muted)
                    }
                }
                Text("Available weights are normalized. Each set’s lowest target credit counts. Effort earns full credit within one point and tapers to zero at four points.")
                    .font(.caption).foregroundStyle(Palette.muted)
            }.padding(.vertical, 7)
        } label: {
            Text("Workout score \(score) / 100").font(.subheadline.weight(.semibold)).frame(minHeight: 44)
        }.padding(.horizontal, 14).surface().tint(Palette.purple)
    }
}

struct WorkoutScoreSettings: View {
    let model: TrainingModel
    @State private var weights = WorkoutScoreWeights()
    @State private var saved = false

    var body: some View {
        DisclosureGroup("Workout score weights") {
            VStack(alignment: .leading, spacing: 10) {
                field("Prescribed work completed", value: $weights.completion)
                field("Targets met", value: $weights.targets)
                field("Effort alignment", value: $weights.effort)
                Button("Save score weights") { saved = model.updateUserData { try $0.saveScoreWeights(weights) } }
                    .buttonStyle(SecondaryButton()).disabled(!weights.valid)
                if saved { Text("Score weights saved.").font(.caption) }
            }.padding(.vertical, 8)
        }.padding(14).surface()
            .onAppear { weights = model.records.scoreWeights ?? WorkoutScoreWeights() }
            .onChange(of: weights) { saved = false }
    }

    private func field(_ label: String, value: Binding<Double>) -> some View {
        LabeledContent(label) {
            TextField(label, value: value, format: .number).keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing).frame(minHeight: 44)
        }
    }
}
