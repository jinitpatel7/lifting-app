import Foundation

struct WorkoutScoreContext {
    let date: WorkoutDate
    let sessions: [WorkoutSession]
    let schedule: [ScheduleOccurrence]
}

struct WorkoutScoreAssessment {
    enum Availability { case unavailable(reason: String), available(summary: String) }

    struct Component: Identifiable {
        let name: String
        let detail: String
        var id: String { name }
    }

    let availability: Availability
    let proposedComponents: [Component]
}

protocol WorkoutScorePolicy {
    func evaluate(_ context: WorkoutScoreContext) -> WorkoutScoreAssessment
}

struct DisabledWorkoutScore: WorkoutScorePolicy {
    func evaluate(_ context: WorkoutScoreContext) -> WorkoutScoreAssessment {
        WorkoutScoreAssessment(availability: .unavailable(reason: "The scoring formula is awaiting review."), proposedComponents: [
            .init(name: "Session adherence", detail: "Consider how much of the intended work was completed. Extra sets and extra load would give no additional credit."),
            .init(name: "Target and effort agreement", detail: "Consider whether logged work was within the intended ranges, including optional effort when it was recorded. Metrics that are missing would stay unknown."),
            .init(name: "Training context", detail: "Judge deloads against their own prescriptions. Completed lighter sessions, planned rest and reasonable changes should have room in the design."),
            .init(name: "Evidence and safety", detail: "Show incomplete logs separately. Allow an early stop for safety without penalty. Give no bonus for training to failure, pushing beyond the plan, or lifting more weight.")
        ])
    }
}

enum DailyWorkoutScore {
    static func assessment(on day: WorkoutDate, records: TrainingRecords, today: WorkoutDate,
                           policy: any WorkoutScorePolicy = DisabledWorkoutScore()) -> WorkoutScoreAssessment {
        let context = WorkoutScoreContext(date: day, sessions: records.sessions.filter { $0.localDate == day },
            schedule: records.scheduled(on: [day], today: today))
        return policy.evaluate(context)
    }
}
