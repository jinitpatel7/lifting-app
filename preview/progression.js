import { dayOf, historyRows, sessionsByDate, unlinkedStation } from './history.js';
import { programContext } from './analytics.js';
import { loadKey, sessionPlan, variantKey } from './workout-log.js';
import { kilogramsPerPound } from './storage.js';
import { dayDistance } from './schedule.js';

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
  if (rule.step != null && (!Number.isFinite(rule.step) || rule.step <= 0)) throw new Error('Enter a positive available increment.');
  if ([rule.topSessions, rule.plateauSessions].some(value => value != null && (!Number.isInteger(value) || value < 2 || value > 12)) ||
      (rule.volumeCap != null && (!Number.isInteger(rule.volumeCap) || rule.volumeCap < 1 || rule.volumeCap > 30))) {
    throw new Error('Use 2–12 sessions and a volume cap of 1–30 working sets.');
  }
  if (rule.effort === 'rir' && (!Number.isSafeInteger(rule.effortLimit) || rule.effortLimit < 0)) throw new Error('Enter a nonnegative minimum RIR.');
  if (rule.effort === 'rpe' && (!Number.isFinite(rule.effortLimit) || rule.effortLimit < 1 || rule.effortLimit > 10)) throw new Error('Enter a maximum RPE from 1 to 10.');
  return rule;
}

const sameAmount = (a, b) => a == null ? b == null : a.kind === b?.kind &&
  (typeof a.value === 'number' ? near(a.value, b.value) : a.value === b.value);
const similar = (a, b) => sameAmount(a.target, b.target) && a.reps?.maximum === b.reps?.maximum &&
  Math.abs((a.reps?.minimum ?? 0) - (b.reps?.minimum ?? 0)) <= 1;

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

const actualReps = set => Math.min(set.reps, set.rightReps ?? set.reps);
const ordinaryRow = set => set.purpose === 'working' && eligible(set.plan);
const amounts = set => [set.amount, set.rightAmount ?? set.amount];
const exactAmount = (set, plan) => !plan.target ? set.amount == null : amounts(set).every(amount => sameAmount(amount, plan.target));
const sameActual = (a, b) => a?.reps === b?.reps && a?.rightReps === b?.rightReps &&
  sameAmount(a?.amount, b?.amount) && sameAmount(a?.rightAmount, b?.rightAmount);

function effortStatus(result, plan, rule) {
  if (plan.effort?.kind === 'failure') return null;
  const key = rule.effort !== 'none' ? rule.effort : plan.effort?.kind;
  const limit = rule.effort !== 'none' ? rule.effortLimit : plan.effort?.value;
  if (['rir', 'rpe'].includes(key) && Number.isFinite(result[key])) {
    const hard = key === 'rir' ? result.rir < limit - (rule.effort === 'none' ? 1 : 0) :
      result.rpe > limit + (rule.effort === 'none' ? 1 : 0);
    if (hard) return 'hard';
  }
  if (result.failure || result.rir === 0 || result.rpe === 10) return 'hard';
  if (result.rir >= 2 || (Number.isFinite(result.rpe) && result.rpe <= 8)) return 'room';
  return null;
}

function incrementFor(row, observations) {
  for (const { session } of observations) {
    const profile = session.log?.loadProfiles?.[loadKey(row)];
    if (!profile) continue;
    const factor = profile.unit === 'lb' ? kilogramsPerPound : 1;
    if (Number.isFinite(profile.increment) && profile.increment > 0) return profile.increment * factor;
    if (row.measurement === 'weight' && row.exercise.equipment === 'barbell' && row.basis !== 'perDumbbell') {
      const plates = (profile.plates ?? []).filter(plate => plate.count > 0 && plate.weight > 0);
      if (plates.length) return 2 * Math.min(...plates.map(plate => plate.weight)) * factor;
    }
  }
  return null;
}

export function progressionWorkingSets(row, suggestion) {
  return row.work.flatMap((plan, index) => {
    const change = suggestion.changes.find(item => item.index === index);
    return change ? (change.replacement ?? [change.prescription]).map((block, position) =>
      position ? { ...block, id: crypto.randomUUID() } : block) : [plan];
  });
}

export function suggestProgression(data, version, row) {
  const key = variantKey(row);
  const ordinary = row.work.flatMap((plan, index) => eligible(plan) ? [{ plan, index }] : []);
  const planned = ordinary.flatMap(({ plan, index }) => Array.from({ length: Math.min(plan.sets, 10_000) },
    (_, position) => ({ plan, index, position })));
  const observations = [];
  let excluded = [], evidence = [], source = null;
  const assessment = {};
  const answer = (action, note, changes = [], warning = null) => {
    const bySession = observations.map(({ session, rows }) => [session.id, rows.map(set => {
      const result = set.result;
      return [set.status, result?.reps, result?.rightReps, result?.amount, result?.rightAmount, result?.rir, result?.rpe, result?.failure];
    })]);
    const fingerprint = JSON.stringify([action, changes, bySession]);
    const decision = data.progressionDecisions?.find(item => item.versionID === version.id && item.rowID === row.id);
    if (changes.length && decision?.fingerprint === fingerprint) {
      return { action: 'hold', note: decision.working ? 'Queued for the next matching workout.' : 'This recommendation was dismissed.',
        changes: [], source, evidence, excluded, assessment, warning: null, fingerprint };
    }
    return { action, note, changes, source, evidence, excluded, assessment, warning, fingerprint };
  };
  if (!modesFor(row).length || data.disabledProgression?.includes(key)) return answer('off', 'Progression is off for this exercise or needs a named equipment station.');
  if (!planned.length || planned.length > 10_000) return answer('hold', 'There are no usable straight working prescriptions to progress.');
  if (planned.some(({ plan }) => !plan.reps && !plan.target)) return answer('hold', 'Enter a measurable target for every straight working set before progressing.');
  for (const session of sessionsByDate(data.sessions).filter(item => item.completedAt)) {
    if (source && dayDistance(dayOf(session), source.day) > 90) break;
    if (programContext(data, session).kind === 'deload') continue;
    const matches = sessionPlan(session).exercises.filter(item => !unlinkedStation(item) && variantKey(item) === key);
    const entry = (session.snapshot.routineID === version.routineID && matches.find(item => item.id === row.id)) || (matches.length === 1 ? matches[0] : null);
    if (!entry) continue;
    const all = historyRows(session, entry);
    const rows = all.filter(ordinaryRow);
    if (!source) {
      source = { id: session.id, day: dayOf(session), name: sessionPlan(session).name };
      evidence = rows;
      excluded = all.filter(set => !ordinaryRow(set));
    }
    if (rows.length !== planned.length || rows.some((set, i) => !similar(planned[i].plan, set.plan))) break;
    const results = rows.map(set => set.status === 'completed' && set.result?.purpose !== 'warm-up' &&
      eligible(set.result) && hasMeasurements(set.result, row) ? set.result : null);
    observations.push({ session, rows, results });
    if (observations.length === 12) break;
  }
  if (!observations.length) return answer('learning', 'Learning your baseline. Log comparable sessions with this exercise, equipment, and prescription.');
  const existing = progressionRule(data, row);
  const availableStep = incrementFor(row, observations);
  const mode = existing?.mode ?? (availableStep && row.measurement === 'assistance' ? 'assistance' :
    availableStep && ['weight', 'added'].includes(row.measurement) ? 'load' : modesFor(row)[0]);
  const rule = { effort: 'none', ...existing, mode, step: existing?.step ?? availableStep };
  const latest = observations[0];
  latest.results.forEach((set, index) => {
    if (!set) return;
    const plan = planned[index].plan;
    assessment[latest.rows[index].order] = !meets(set, plan, false) ? 'Missed target' :
      plan.reps && meets(set, plan, true) ? 'Reached top of range' : 'Met target';
  });
  const allComplete = observation => observation.results.every(Boolean);
  const hard = observation => observation.results.some((set, i) => set && effortStatus(set, planned[i].plan, rule) === 'hard');
  const missed = observation => observation.results.some((set, i) => set && !meets(set, planned[i].plan, false));
  const struggling = observation => hard(observation) || missed(observation);
  if (!allComplete(latest)) {
    return answer('hold', `${latest.results.filter(Boolean).length} of ${planned.length} prescribed working sets have usable completed results. Hold while evidence is incomplete.`);
  }
  if (struggling(latest)) {
    if (observations.length < 2 || !allComplete(observations[1]) || !struggling(observations[1])) {
      return answer('hold', 'The latest comparable session missed a target or recorded excessive effort. Hold after one miss.');
    }
    const reductions = rule.step && mode !== 'reps' ? quantityChanges(ordinary, rule, -1) : [];
    if (reductions.length) return answer('adjust', 'Two consecutive comparable sessions missed a target or recorded excessive effort. Reduce the prescribed demand by one available increment.', reductions);
    const last = ordinary.at(-1);
    if (row.work.reduce((sum, plan) => sum + plan.sets, 0) > 1 && planned.length > 1) {
      const shorter = { ...last.plan, sets: last.plan.sets - 1 };
      return answer('adjust', 'Two consecutive comparable sessions missed a target or recorded excessive effort. Remove one straight working set.', [
        { index: last.index, prescription: shorter, replacement: shorter.sets ? [shorter] : [] },
      ]);
    }
    return answer('hold', 'Two comparable sessions showed repeated difficulty. Keep the minimum set count and review the target manually.');
  }
  if (observations.filter(allComplete).length < 2) return answer('learning', 'Learning your baseline. Log a second comparable workout with all prescribed working sets.');

  const repIndex = latest.results.findIndex((set, index) => {
    const { plan } = planned[index];
    return plan.reps && actualReps(set) >= plan.reps.minimum && actualReps(set) < plan.reps.maximum && exactAmount(set, plan);
  });
  if (repIndex >= 0) {
    const { plan, index, position } = planned[repIndex];
    const prescription = { ...plan, sets: 1, progressionFloor: plan.progressionFloor ?? plan.reps.minimum,
      reps: { ...plan.reps, minimum: actualReps(latest.results[repIndex]) + 1 } };
    const replacement = [...(position ? [{ ...plan, sets: position }] : []), prescription,
      ...(plan.sets - position - 1 ? [{ ...plan, sets: plan.sets - position - 1 }] : [])];
    return answer('advance', `Set ${repIndex + 1} met its target and has room in the rep range. Add one rep at the same load.`,
      [{ index, prescription, replacement }]);
  }
  const required = rule.topSessions ?? 2;
  const recent = observations.slice(0, required);
  const ready = recent.length === required && recent.every(observation => allComplete(observation) && !hard(observation) &&
    observation.results.every((set, i) => meets(set, planned[i].plan, true) &&
      (!massMode(mode) || exactAmount(set, planned[i].plan))));
  if (ready && mode !== 'reps' && rule.step) {
    const changes = quantityChanges(ordinary, rule, 1);
    if (changes.length) {
      const large = changes.some(({ index, prescription }) => rule.step > Math.abs(row.work[index].target.value) * 0.1 + 1e-7);
      const description = { load: 'increase load and restart at the low end of the rep range', assistance: 'reduce assistance and restart at the low end of the rep range',
        duration: 'increase duration', distance: 'increase distance' }[mode];
      return answer('advance', `${required} comparable sessions reached every target. Use the smallest recorded increment to ${description}.`, changes,
        large ? 'This increment changes the target by more than 10%. You can hold at the current target.' : null);
    }
  }
  const plateauCount = rule.plateauSessions ?? 3;
  const plateau = observations.slice(0, plateauCount);
  const volume = row.work.reduce((sum, plan) => sum + plan.sets, 0);
  const checkIn = data.readiness?.find(entry => entry.date === dayOf(latest.session));
  const goodRecovery = checkIn?.energy >= 4 && checkIn?.sleep >= 4 && checkIn?.soreness <= 2;
  const spareEffort = latest.results.every((set, i) => effortStatus(set, planned[i].plan, rule) === 'room');
  if (rule.allowExtraSet && volume < (rule.volumeCap ?? 6) && plateau.length === plateauCount &&
      plateau.every(observation => allComplete(observation) && !struggling(observation) &&
        observation.results.every((set, i) => sameActual(set, latest.results[i]))) && (spareEffort || goodRecovery)) {
    const last = ordinary.at(-1);
    return answer('advance', `Performance held steady for ${plateauCount} comparable sessions with targets met and ${spareEffort ? 'effort in reserve' : 'a supportive readiness check-in'}. Add one working set under the cap.`,
      [{ index: last.index, prescription: { ...last.plan, sets: last.plan.sets + 1 } }]);
  }
  if (ready && mode !== 'reps' && !rule.step) return answer('hold', 'Targets are met. Set an available increment before changing the target.');
  if (ready && mode !== 'reps') return answer('hold', 'A full available increment would go outside the supported target range.');
  return answer('hold', `Hold the current targets. An increase needs ${required} consecutive comparable sessions meeting the required targets.`);
}

function quantityChanges(ordinary, rule, direction) {
  return ordinary.flatMap(({ plan, index }) => {
    const prescription = adjust(plan, rule, direction);
    if (sameAmount(plan.target, prescription.target)) return [];
    if (direction > 0 && massMode(rule.mode) && plan.reps) {
      prescription.reps = { ...plan.reps, minimum: plan.progressionFloor ?? plan.reps.minimum };
    }
    return [{ index, prescription }];
  });
}

export function shownStep(step, rule, unit) {
  return massMode(rule.mode) && unit === 'lb' ? step / kilogramsPerPound : step;
}
