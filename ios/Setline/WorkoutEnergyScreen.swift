import SwiftUI

struct WorkoutEnergySummary: View {
    let session: WorkoutSession
    let records: TrainingRecords
    let edit: () -> Void

    var body: some View {
        let estimate = WorkoutEnergyEstimate.workout(session, records: records)
        VStack(alignment: .leading, spacing: 4) {
            Text(estimate?.label ?? "Calories unavailable").font(.subheadline.weight(.semibold))
            if session.completedAt != nil && !session.performedSets.isEmpty {
                Button("Calorie inputs", action: edit).buttonStyle(.borderless).frame(minHeight: 44)
            }
        }
    }
}

struct WorkoutEnergyEditor: View {
    let model: TrainingModel
    let sessionID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var category: WorkoutEnergyActivity?
    @State private var minutes: String
    @State private var validation: String?

    init(model: TrainingModel, session: WorkoutSession) {
        self.model = model
        sessionID = session.id
        _category = State(initialValue: session.energyInput?.activity)
        _minutes = State(initialValue: session.energyInput?.minutes.formatted(.number.precision(.fractionLength(0...3))) ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                if let session = model.records.sessions.first(where: { $0.id == sessionID }) {
                    let weight = model.records.bodyweight(on: session.localDate)?.mass.kilograms
                    Section(session.localDate.formatted(.dateTime.month(.wide).day().year())) {
                        Text(weight.map { "\($0.formatted(.number.precision(.fractionLength(0...2)))) kg recorded bodyweight" } ?? "No bodyweight reading on this date")
                        Picker("Activity category", selection: $category) {
                            Text("Choose a matching activity").tag(nil as WorkoutEnergyActivity?)
                            ForEach(WorkoutEnergyActivity.allCases) { value in
                                Text("\(value.title) · \(value.compendium.met.formatted()) MET").tag(Optional(value))
                            }
                        }
                        TextField("Activity minutes", text: $minutes).keyboardType(.decimalPad)
                        Text("Enter minutes for the selected activity. Leave out unrelated activity and extended idle time.")
                            .font(.caption).foregroundStyle(Palette.muted)
                        Text(WorkoutEnergyEstimate.workout(session, records: model.records)?.label ?? "Calories unavailable")
                            .font(.subheadline.weight(.semibold))
                        if session.energyInput != nil { Button("Clear inputs") { save(nil) } }
                        if let error = validation ?? model.storageError { Text(error).foregroundStyle(Palette.red) }
                    }
                    Section {
                        DisclosureGroup("Estimation method and assumptions") {
                            Text("Estimated kcal = MET × bodyweight in kg × activity hours. This uses the standard approximation of 1 kcal per kg per hour for 1 MET.")
                            Text("Gross calories include energy at rest during the entered time. Adult Compendium values are population estimates. Actual energy use varies.")
                            if let url = WorkoutEnergyEstimate.activitySource { Link("Adult Compendium activity table", destination: url) }
                            if let url = WorkoutEnergyEstimate.methodSource { Link("MET definition", destination: url) }
                        }.font(.subheadline)
                    }
                }
            }
            .navigationTitle("Workout calories")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { validate() } }
            }
        }
    }

    private func validate() {
        guard let category, let duration = try? Double(minutes, format: .number, lenient: false) else {
            validation = "Choose a matching activity category and enter activity minutes."
            return
        }
        let input = WorkoutEnergyInput(activity: category, minutes: duration)
        guard input.isValid else { validation = "Enter activity minutes greater than 0 and up to 1,440."; return }
        save(input)
    }

    private func save(_ input: WorkoutEnergyInput?) {
        validation = nil
        if model.updateUserData({ try $0.saveWorkoutEnergy(input, sessionID: sessionID) }) { dismiss() }
    }
}

private extension WorkoutEnergyEstimate {
    var label: String { "Estimated gross calories · \(kilocalories.formatted(.number.precision(.fractionLength(0)))) kcal" }
}
