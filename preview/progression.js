import { dayOf, historyRows, sessionsByDate, unlinkedStation } from './history.js';
import { programContext } from './analytics.js';
import { sessionPlan, variantKey } from './workout-log.js';
import { kilogramsPerPound } from './storage.js';

export const progressionModes = { reps: 'Reps', load: 'Load', duration: 'Duration', distance: 'Distance', assistance: 'Reduced assistance' };
export const massMode = mode => mode === 'load' || mode === 'assistance';
const eligible = plan => plan && !plan.amrap && (plan.structure ?? 'straight') === 'straight';
const near = (a, b) => Math.abs(a - b) < 1e-7;

export function modesFor(row) {
  if (unlinkedStation(row)) return [];
  switch (row.measurement) {
    case 'weight': case 'added': return ['reps', 'load'];
    case 'assistance': return ['reps', 'assistance'];
    case 'duration': case 'distance': return [row.measurement];
    default: return ['reps'];
  }
}

export function progressionRule(data, row) {
  return (data.progressionRules ?? []).find(record => record.variant === variantKey(row))?.rule ?? null;
}

export function validateProgressionRule(row, rule) {
  if (!modesFor(row).includes(rule.mode) || !['top', 'minimum'].includes(rule.threshold) ||
      !['hold', 'stepBack'].includes(rule.miss) || !['none', 'rir', 'rpe'].includes(rule.effort)) {
    throw new Error('Choose a valid progression rule for this exercise.');
  }
  if (rule.mode !== 'reps' && (!Number.isFinite(rule.step) || rule.step <= 0)) throw new Error('Enter a positive available increment.');
  if (rule.effort === 'rir' && (!Number.isSafeInteger(rule.effortLimit) || rule.effortLimit < 0)) throw new Error('Enter a nonnegative minimum RIR.');
  if (rule.effort === 'rpe' && (!Number.isFinite(rule.effortLimit) || rule.effortLimit < 1 || rule.effortLimit > 10)) throw new Error('Enter a maximum RPE from 1 to 10.');
  return rule;
}

function matchingPrescription(a, b) {
  const amounts = a.target == null ? b.target == null : a.target.kind === b.target?.kind &&
    (typeof a.target.value === 'number' ? near(a.target.value, b.target.value) : a.target.value === b.target.value);
  return amounts && a.reps?.minimum === b.reps?.minimum && a.reps?.maximum === b.reps?.maximum;
}

const atLeast = (actual, target) => actual > target || near(actual, target);
function meets(set, plan, top) {
  const reps = top ? plan.reps?.maximum : plan.reps?.minimum;
  if (reps != null && (!(set.reps >= reps) || (set.rightReps != null && set.rightReps < reps))) return false;
  if (!plan.target) return true;
  const { kind, value } = plan.target;
  return [set.amount, set.rightAmount ?? set.amount].every(amount => {
    if (amount?.kind !== kind) return false;
    if (kind === 'setting') return amount.value === value;
    return kind === 'assistance' ? atLeast(value, amount.value) : atLeast(amount.value, value);
  });
}

function hasMeasurements(set, row) {
  const amountValid = amount => {
    if (row.measurement === 'bodyweight') return amount == null;
    if (amount?.kind !== row.measurement) return false;
    if (row.measurement === 'setting') return typeof amount.value === 'string' && Boolean(amount.value.trim());
    return Number.isFinite(amount.value) && (['duration', 'distance'].includes(row.measurement) ? amount.value > 0 : amount.value >= 0);
  };
  if (!amountValid(set.amount) || (set.rightAmount != null && !amountValid(set.rightAmount))) return false;
  if (['duration', 'distance'].includes(row.measurement)) return set.reps == null && set.rightReps == null;
  if (!Number.isInteger(set.reps)) return false;
  if (set.rightReps != null) return ['perSide', 'separateSides'].includes(row.counting) && Number.isInteger(set.rightReps) &&
    Math.min(set.reps, set.rightReps) >= 0 && Math.max(set.reps, set.rightReps) > 0;
  return row.counting !== 'separateSides' && set.reps > 0 && set.rightAmount == null;
}

function adjust(plan, rule, direction) {
  if (rule.mode === 'reps') {
    if (!plan.reps) return plan;
    const { minimum, maximum } = plan.reps;
    return { ...plan, reps: { minimum: Math.min(maximum, Math.max(1, minimum + direction)), maximum } };
  }
  if (!plan.target) return plan;
  const { kind, value } = plan.target;
  const candidate = value + rule.step * direction * (kind === 'assistance' ? -1 : 1);
  if (!Number.isFinite(candidate) || candidate < -1e-7 || (['duration', 'distance'].includes(kind) && candidate < 1e-7)) return plan;
  return { ...plan, target: { kind, value: near(candidate, 0) ? 0 : candidate } };
}

export function suggestProgression(data, version, row) {
  const rule = progressionRule(data, row);
  const ordinary = row.work.flatMap((plan, index) => eligible(plan) ? [{ plan, index }] : []);
  let source = null, evidence = [], excluded = [];
  const assessment = {};
  const answer = (action, note, changes = []) => ({ action, note, changes, source, evidence, excluded, assessment });
  if (!rule || !modesFor(row).includes(rule.mode)) return answer('off', 'Choose a rule for this exercise and equipment.');
  if (!ordinary.length) return answer('hold', 'There are no straight working prescriptions to progress.');
  if (ordinary.some(({ plan }) => rule.mode === 'reps' ? !plan.reps : !plan.target)) {
    return answer('hold', 'Enter a planned target for every straight working block in this routine.');
  }
  const key = variantKey(row);
  for (const session of sessionsByDate(data.sessions).filter(item => item.completedAt)) {
    const sameRoutine = session.snapshot.routineID === version.routineID;
    const matches = sessionPlan(session).exercises.filter(item => !unlinkedStation(item) && variantKey(item) === key);
    const original = sameRoutine && session.snapshot.exercises.find(item => item.id === row.id && variantKey(item) === key);
    const exact = sameRoutine && matches.find(item => item.id === row.id);
    if (original && !exact) {
      source = { id: session.id, day: dayOf(session), name: sessionPlan(session).name };
      return answer('hold', 'The last workout removed this exercise slot or changed its equipment or measurement. Log the current prescription first.');
    }
    const entry = exact || (matches.length === 1 ? matches[0] : null);
    if (entry) {
      source = { id: session.id, day: dayOf(session), name: sessionPlan(session).name };
      const rows = historyRows(session, entry);
      const included = set => set.purpose === 'working' && eligible(set.plan);
      evidence = rows.filter(included);
      excluded = rows.filter(set => !included(set));
      if (programContext(data, session).kind === 'deload') return answer('hold', 'The latest matching workout was a planned deload. Log a regular workout before progressing.');
      break;
    }
  }
  if (!source) return answer('hold', 'Log a finished workout with the same exercise, equipment, and measurement.');
  const count = ordinary.reduce((total, { plan }) => total + plan.sets, 0);
  if (count !== evidence.length || count > 10000) return answer('hold', 'The last workout used a different number of straight working sets. Log the current prescription first.');
  const planned = ordinary.flatMap(block => Array(block.plan.sets).fill(block));
  if (!evidence.every((set, i) => matchingPrescription(planned[i].plan, set.plan))) {
    return answer('hold', 'The last workout used different targets. Log the current prescription first.');
  }
  const usable = evidence.filter((set, index) => {
    if (set.status !== 'completed' || set.result?.purpose === 'warm-up' || !eligible(set.result) || !hasMeasurements(set.result, row)) return false;
    const plan = planned[index].plan;
    assessment[set.order] = !meets(set.result, plan, false) ? 'Missed target' :
      !plan.reps ? 'Met target amount' : meets(set.result, plan, true) ? 'Reached top of range' : 'Met minimum';
    return true;
  });
  if (usable.length !== count) return answer('hold', `${usable.length} of ${count} prescribed straight working sets have usable completed results. Finish all of them to assess a change.`);
  const missed = planned.filter((block, i) => !meets(usable[i].result, block.plan, false));
  const misses = missed.length;
  if (misses) {
    const changes = rule.miss === 'stepBack' ? changedTargets([...new Set(missed)], rule, -1) : [];
    return answer(changes.length ? 'adjust' : 'hold', `${misses} of ${count} sets missed a planned minimum or amount.${changes.length ? ' Your rule steps back one increment for the affected blocks.' : ' Keep the current targets.'}`, changes);
  }
  const top = rule.mode !== 'reps' && rule.threshold === 'top';
  const passing = usable.filter((set, i) => meets(set.result, planned[i].plan, top)).length;
  if (passing !== count) return answer('hold', `${passing} of ${count} sets reached the top of their rep range at the planned target. Keep the current targets.`);
  let effortNote = '';
  if (rule.effort !== 'none') {
    const recorded = usable.filter(set => Number.isFinite(set.result[rule.effort]));
    if (recorded.length === count) {
      const pass = recorded.every(({ result }) => rule.effort === 'rir' ? result.rir >= rule.effortLimit : result.rpe <= rule.effortLimit);
      const label = rule.effort.toUpperCase();
      const criterion = `${rule.effort === 'rir' ? 'at least' : 'at most'} ${rule.effortLimit} ${label}`;
      if (!pass) return answer('hold', `The sets met the performance targets, but at least one recorded ${label} missed the effort criterion of ${criterion}.`);
      effortNote = ` All ${count} ${rule.effort.toUpperCase()} readings also met your rule.`;
    } else effortNote = ` Effort was left out because only ${recorded.length} of ${count} sets recorded ${rule.effort.toUpperCase()}.`;
  }
  const changes = changedTargets(ordinary, rule, 1);
  if (!changes.length) return answer('hold', (rule.mode === 'reps' ? 'The rep minimum is already at the top of the prescribed range.' : 'A full available increment would go outside the supported target range.') + effortNote);
  const criterion = top && row.work.some(plan => plan.reps) ? 'the top of their rep ranges at the planned target' : 'their planned targets';
  return answer('advance', `All ${count} straight working sets reached ${criterion}.${effortNote}`, changes);
}

function changedTargets(ordinary, rule, direction) {
  return ordinary.flatMap(({ plan, index }) => {
    const prescription = adjust(plan, rule, direction);
    return matchingPrescription(plan, prescription) ? [] : [{ index, prescription }];
  });
}

export function shownStep(step, rule, unit) {
  return massMode(rule.mode) && unit === 'lb' ? step / kilogramsPerPound : step;
}
