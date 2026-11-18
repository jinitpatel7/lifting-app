export const proposedScoreComponents = Object.freeze([
  { name: 'Session adherence', detail: 'Consider how much of the intended work was completed. Extra sets and extra load would give no additional credit.' },
  { name: 'Target and effort agreement', detail: 'Consider whether logged work was within the intended ranges, including optional effort when it was recorded. Metrics that are missing would stay unknown.' },
  { name: 'Training context', detail: 'Judge deloads against their own prescriptions. Completed lighter sessions, planned rest and reasonable changes should have room in the design.' },
  { name: 'Evidence and safety', detail: 'Show incomplete logs separately. Allow an early stop for safety without penalty. Give no bonus for training to failure, pushing beyond the plan, or lifting more weight.' },
]);

// A policy receives the session records and their intended context. The shipped policy has no formula.
export const disabledWorkoutScorePolicy = Object.freeze({
  evaluate() {
    return { status: 'unavailable', reason: 'The scoring formula is awaiting review.', components: proposedScoreComponents };
  },
});

export function dailyWorkoutScore(day, sessions, scheduled, policy = disabledWorkoutScorePolicy) {
  return policy.evaluate({ day, sessions, scheduled });
}
