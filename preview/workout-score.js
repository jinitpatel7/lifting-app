import { historyRows, sessionsByDate } from './history.js';
import { sessionPlan, variantKey } from './workout-log.js';

export const defaultScoreWeights = Object.freeze({ completion: 60, targets: 25, effort: 15 });
export function validateScoreWeights(weights) {
  const values = Object.keys(defaultScoreWeights).map(key => weights?.[key]);
  if (!values.every(value => Number.isFinite(value) && value >= 0 && value <= 100) || !values.some(value => value > 0)) {
    throw new Error('Enter weights from 0 to 100, with at least one greater than zero.');
  }
  return weights;
}

const working = set => set.purpose === 'working' && set.plan;
const cap = value => Math.max(0, Math.min(1, value));
const usable = value => Number.isFinite(value) && value >= 0;
function amountCredit(actual, target) {
  if (actual?.kind !== target.kind) return 0;
  if (target.kind === 'setting') return Number(actual.value === target.value);
  if (!usable(actual.value)) return 0;
  if (target.kind === 'assistance') return actual.value <= target.value + 1e-7 ? 1 : cap(target.value / actual.value);
  return actual.value >= target.value - 1e-7 ? 1 : cap(actual.value / target.value);
}

export function prescribedTargetCredit(result, plan) {
  const marks = [];
  if (plan.reps) {
    marks.push(usable(result.reps) ? cap(result.reps / plan.reps.minimum) : 0);
    if (result.rightReps != null) marks.push(cap(result.rightReps / plan.reps.minimum));
  }
  if (plan.target) {
    marks.push(amountCredit(result.amount, plan.target));
    if (result.rightAmount != null) marks.push(amountCredit(result.rightAmount, plan.target));
  }
  return marks.length ? Math.min(...marks) : null;
}

function effortCredit(result, effort) {
  if (!effort || !['rir', 'rpe'].includes(effort.kind) || !usable(result[effort.kind])) return null;
  return cap(1 - Math.max(0, Math.abs(result[effort.kind] - effort.value) - 1) / 3);
}

const unavailable = reason => ({ status: 'unavailable', reason, components: [] });

export function workoutScore(session, weights = defaultScoreWeights) {
  if (!session?.completedAt) return unavailable('Finish a planned workout to see its score.');
  if (session.snapshot.revision <= 0 || !session.snapshot.exercises.length) {
    return unavailable('This workout started without a saved routine plan.');
  }
  weights ??= defaultScoreWeights;
  validateScoreWeights(weights);
  let prescribed = 0, completed = 0;
  const targets = [], efforts = [];
  const current = sessionPlan(session);
  for (const row of (session.intendedPlan ?? session.snapshot).exercises) {
    const equivalent = current.exercises.find(item => item.id === row.id && variantKey(item) === variantKey(row));
    const rows = equivalent ? historyRows(session, equivalent) : [];
    const byID = new Map(rows.map(set => [set.id, set]));
    const ids = session.scoreSlots?.[row.id] ?? rows.filter(working).map(set => set.id);
    let index = 0;
    for (const plan of row.work) {
      for (let set = 0; set < Math.min(plan.sets, 10_000); set++) {
        prescribed++;
        const earned = byID.get(ids[index++]);
        if (earned?.purpose !== 'working' || earned.status !== 'completed' || !earned.result) continue;
        completed++;
        const target = prescribedTargetCredit(earned.result, plan);
        if (target != null) targets.push(target);
        const effort = effortCredit(earned.result, plan.effort);
        if (effort != null) efforts.push(effort);
      }
    }
  }
  if (!prescribed) return unavailable('This workout has no prescribed working sets.');
  const mean = values => values.length ? values.reduce((sum, value) => sum + value, 0) / values.length : null;
  const parts = [
    { key: 'completion', name: 'Prescribed work completed', value: completed / prescribed,
      detail: `${completed} of ${prescribed} prescribed working sets completed.` },
    { key: 'targets', name: 'Targets met', value: mean(targets),
      detail: targets.length ? `${targets.length} completed sets with prescribed targets.` : 'No completed sets with applicable targets.' },
    { key: 'effort', name: 'Effort alignment', value: mean(efforts),
      detail: efforts.length ? `${efforts.length} sets with corresponding prescribed and actual RIR or RPE.` : 'No matching prescribed and recorded RIR or RPE.' },
  ];
  const total = parts.reduce((sum, part) => sum + (part.value == null ? 0 : weights[part.key]), 0);
  if (!total) return unavailable('The enabled score components need more logged information.');
  const components = parts.map(part => ({ ...part, weight: part.value == null ? 0 : weights[part.key] / total,
    points: part.value == null ? null : 100 * part.value * weights[part.key] / total }));
  const score = Math.round(components.reduce((sum, part) => sum + (part.points ?? 0), 0));
  return { status: 'available', score, summary: `Workout score ${score} / 100`, components };
}

export const workoutScorePolicy = Object.freeze({
  evaluate({ sessions, weights }) {
    return workoutScore(sessionsByDate(sessions.filter(session => session.completedAt))[0], weights);
  },
});

export function dailyWorkoutScore(day, sessions, scheduled, policy = workoutScorePolicy, weights = defaultScoreWeights) {
  return policy.evaluate({ day, sessions, scheduled, weights });
}
