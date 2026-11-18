import { programContext } from './analytics.js';
import { dayOf, equipmentName, historyRows, unlinkedStation } from './history.js';
import { dayDistance } from './schedule.js';
import { sessionPlan, variantKey } from './workout-log.js';

export const forecastModel = 'recent-median-v1';
const minimum = 3;
const windowSize = 8;
const mass = ['weight', 'added', 'assistance'];
const floors = { weight: 0.5, added: 0.5, assistance: 0.5, reps: 1, duration: 2, distance: 2 };
const isStraight = set => (set?.structure ?? 'straight') === 'straight' && !set?.amrap;
const stamp = value => Date.parse(value);
const position = index => index === 0 ? 'first' : 'later';

function contextFor(row, plan, log) {
  const logged = log?.exercises.find(entry => entry.id === row.id);
  const fromLog = logged?.sets.filter(set => set.purpose === 'working' && set.status !== 'skipped' && set.plan).map(set => set.plan);
  const block = (fromLog ?? row.work).find(isStraight);
  return {
    order: position(plan.exercises.findIndex(entry => entry.id === row.id)),
    target: block?.target ?? null, reps: block?.reps ?? null, rest: block?.rest ?? null, effort: block?.effort ?? null,
    warmRest: row.warm.at(-1)?.rest ?? null,
    specialOnly: Boolean(row.work.length && row.work.every(block => !isStraight(block)) && !block),
  };
}

function metrics(result, row) {
  const values = {};
  const kind = row.measurement;
  const amount = item => item?.kind === kind && Number.isFinite(item.value) && item.value >= 0 ? item.value : null;
  if (mass.includes(kind) || kind === 'duration' || kind === 'distance') {
    const left = amount(result.amount);
    const right = result.rightAmount == null ? left : amount(result.rightAmount);
    if (left == null || right == null || (!mass.includes(kind) && (left === 0 || right === 0))) return null;
    values[kind] = kind === 'assistance' ? Math.max(left, right) : Math.min(left, right);
  }
  if (kind !== 'duration' && kind !== 'distance') {
    if (!Number.isInteger(result.reps) || result.reps < 0 || (row.counting === 'separateSides' && result.rightReps == null) ||
      (result.rightReps != null && (!Number.isInteger(result.rightReps) || result.rightReps < 0))) return null;
    values.reps = Math.min(result.reps, result.rightReps ?? result.reps);
  }
  if (kind === 'setting' && (result.amount?.kind !== 'setting' || typeof result.amount.value !== 'string')) return null;
  return values;
}

function actual(session, row) {
  const positions = new Map(sessionPlan(session).exercises.map((entry, index) => [entry.id, index]));
  const ordered = session.results.filter(result => Number.isFinite(stamp(result.at))).slice().sort((a, b) => stamp(a.at) - stamp(b.at) ||
    (positions.get(a.exerciseID) ?? 0) - (positions.get(b.exerciseID) ?? 0) || (a.order ?? 0) - (b.order ?? 0));
  const logged = historyRows(session, row);
  const result = ordered.find(item => {
    if (item.exerciseID !== row.id) return false;
    const saved = logged.find(set => set.result === item);
    return (item.purpose ?? saved?.purpose ?? 'working') === 'working' && isStraight(item) && isStraight(saved?.plan);
  });
  if (!result) return null;
  const values = metrics(result, row);
  if (!values) return null;
  const before = ordered.slice(0, ordered.indexOf(result));
  const prior = before.at(-1);
  return {
    values, result, order: before.some(item => item.exerciseID !== row.id) ? 'later' : 'first',
    priorRest: prior?.exerciseID === row.id ? prior.actualRest?.measuredSeconds ?? null : null,
  };
}

function observations(data, row, plan, cutoff) {
  const key = variantKey(row);
  const result = [];
  let deloads = 0, otherSetup = false;
  for (const session of data.sessions) {
    if (!(stamp(session.startedAt) < cutoff && stamp(session.completedAt) < cutoff) ||
        (session.forecastEvidenceAt && !(stamp(session.forecastEvidenceAt) < cutoff))) continue;
    const prior = sessionPlan(session);
    const matches = prior.exercises.filter(entry => !unlinkedStation(entry) && variantKey(entry) === key);
    const sameSlot = prior.routineID === plan.routineID ? matches.find(entry => entry.id === row.id) : null;
    const entry = sameSlot ?? (matches.length === 1 ? matches[0] : null);
    if (!entry) {
      otherSetup ||= prior.exercises.some(item => item.exercise.id === row.exercise.id && variantKey(item) !== key);
      continue;
    }
    const performance = actual(session, entry);
    if (!performance || !(stamp(performance.result.at) < cutoff)) continue;
    if (programContext(data, session).kind === 'deload') { deloads++; continue; }
    result.push({ ...performance, id: session.id, at: session.startedAt, day: dayOf(session), context: contextFor(entry, prior, session.log) });
  }
  return { result: result.sort((a, b) => stamp(b.at) - stamp(a.at) || a.id.localeCompare(b.id)), deloads, otherSetup };
}

const quantile = (values, fraction) => {
  const sorted = values.slice().sort((a, b) => a - b);
  const slot = (sorted.length - 1) * fraction;
  return sorted[Math.floor(slot)] + (sorted[Math.ceil(slot)] - sorted[Math.floor(slot)]) * (slot % 1);
};

const sameBand = (a, b) => a?.minimum === b?.minimum && a?.maximum === b?.maximum;
const sameTarget = (a, b) => a?.kind === b?.kind && (typeof a?.value === 'number' ? Math.abs(a.value - b.value) < 0.001 : a?.value === b?.value);
const matchesEffort = (aim, result) => aim.kind === 'failure' ? result.failure === true :
  Number.isFinite(result[aim.kind]) && Math.abs(result[aim.kind] - aim.value) <= 1;

function priorForecast(data, row, cutoff) {
  return data.sessions.flatMap(session => session.performanceForecasts ?? []).filter(item => item.variant === variantKey(row) &&
    item.status === 'ready' && stamp(item.issuedAt) < cutoff).sort((a, b) => stamp(b.issuedAt) - stamp(a.issuedAt))[0];
}

export function forecastExercise(data, plan, row, { now, day, deload = false, log }) {
  const cutoff = now.getTime();
  const context = contextFor(row, plan, log);
  const latest = priorForecast(data, row, cutoff);
  const forecast = {
    model: forecastModel, rowID: row.id, variant: variantKey(row), name: row.exercise.name, equipment: equipmentName(row),
    measurement: row.measurement, basis: row.basis, counting: row.counting, issuedAt: now.toISOString(), context, status: 'learning',
    sources: [], notes: [], ranges: {}, previous: null, priorRanges: latest?.ranges ?? null,
  };
  const note = text => forecast.notes.push(text);
  if (unlinkedStation(row) || context.specialOnly || deload) {
    forecast.status = 'paused';
    note(deload ? 'A planned deload changes the training intent. This forecast is paused.' : unlinkedStation(row) ?
      'Name this machine or cable station to start its own baseline.' : 'This method uses straight working sets. Special sets have no estimate.');
    return forecast;
  }
  const history = observations(data, row, plan, cutoff);
  let candidates = history.result;
  let varied = false;
  const prefer = (filter, match, mixed) => {
    const subset = candidates.filter(filter);
    if (subset.length >= minimum) { candidates = subset; note(match); }
    else { note(mixed); varied = true; }
  };
  if (row.measurement === 'setting') {
    const setting = context.target?.value ?? candidates[0]?.result.amount?.value;
    candidates = candidates.filter(item => item.result.amount.value === setting);
    forecast.setting = setting ?? null;
    if (setting != null) note(`Only results at machine setting ${setting} are comparable.`);
  }
  const last = candidates[0];
  const age = last ? dayDistance(last.day, day) : 0;
  candidates = candidates.filter(item => dayDistance(item.day, day) < 120);
  if (candidates.length < minimum || age >= 120) {
    forecast.sources = candidates.slice(0, windowSize).map(item => ({ id: item.id, day: item.day, setID: item.result.id }));
    note(age >= 120 ? 'The last comparable result is at least 120 days old. A fresh result is needed.' :
      `${candidates.length} of ${minimum} recent comparable sessions logged.`);
    if (history.otherSetup) note('Results on different equipment or tracking conventions have a separate baseline.');
    if (history.deloads) note('Planned deloads are outside the baseline.');
    return forecast;
  }
  prefer(item => item.order === context.order, `Matched workouts where this exercise went ${context.order}.`, 'Exercise order varied in the available history.');
  if (context.reps) prefer(item => sameBand(item.context.reps, context.reps), 'Matched the prescribed rep range.', 'Prescribed rep ranges varied.');
  if (context.target && mass.includes(row.measurement)) {
    prefer(item => sameTarget(item.result.amount, context.target) && sameTarget(item.result.rightAmount ?? item.result.amount, context.target),
      'Matched actual sets at the planned load or assistance.', 'Too few sets used the planned load or assistance. The range reflects nearby training history.');
  }
  if (context.rest != null) prefer(item => item.context.rest != null && Math.abs(item.context.rest - context.rest) <= 15,
    'Matched similar prescribed rest.', 'Prescribed rest varied or was missing.');
  if (context.warmRest != null) prefer(item => item.priorRest != null && Math.abs(item.priorRest - context.warmRest) <= 15,
    'Matched measured rest before the first working set to the planned warm-up rest.', 'Measured rest before the first working set was too sparse or varied.');
  if (context.effort) prefer(item => matchesEffort(context.effort, item.result),
    'Matched recorded effort near the prescribed effort.', 'Recorded effort was too sparse or varied to narrow this estimate.');

  const window = candidates.slice(0, windowSize);
  const previous = last;
  const keys = Object.keys(previous.values);
  const clean = window.length < 5 ? window : window.filter(item => keys.every(key => {
    const values = window.map(sample => sample.values[key]);
    const low = quantile(values, 0.25), high = quantile(values, 0.75);
    const fence = Math.max(3 * (high - low), floors[key]);
    return item.values[key] >= low - fence && item.values[key] <= high + fence;
  }));
  const used = clean.length >= minimum ? clean : window;
  const gap = dayDistance(used[0].day, day);
  const spread = gap >= 21;
  if (used.length < window.length) note(`${window.length - used.length} isolated result${window.length - used.length === 1 ? ' was' : 's were'} outside the recent range and left out.`);
  if (spread) note(`The last result used was ${gap} days ago. The range is wider after that break.`);
  if (history.deloads) note('Planned deloads were left out of the baseline.');
  forecast.status = 'ready';
  forecast.confidence = used.length >= 6 && !varied && !spread ? 'More comparable history' : 'Limited confidence';
  forecast.previous = { id: previous.id, day: previous.day, values: previous.values };
  forecast.sources = used.map(item => ({ id: item.id, day: item.day, setID: item.result.id }));
  for (const key of keys) {
    const values = used.map(item => item.values[key]);
    const center = quantile(values, 0.5);
    const low = quantile(values, used.length >= 5 ? 0.1 : 0);
    const high = quantile(values, used.length >= 5 ? 0.9 : 1);
    const width = Math.min(Number.MAX_VALUE, Math.max(floors[key], Math.abs(center - low), Math.abs(high - center)) * (spread ? 1.5 : 1));
    forecast.ranges[key] = key === 'reps' ? { center: Math.round(center), low: Math.max(0, Math.floor(center - width)), high: Math.ceil(center + width) } :
      { center, low: Math.max(0, center - width), high: Math.min(Number.MAX_VALUE, center + width) };
  }
  if (latest) {
    const contextChanged = JSON.stringify(latest.context) !== JSON.stringify(context);
    const centersChanged = keys.some(key => Math.abs((latest.ranges[key]?.center ?? forecast.ranges[key].center) - forecast.ranges[key].center) >= floors[key]);
    if (centersChanged) note(contextChanged ? 'The typical estimate changed since the last saved forecast as the planned context or available results changed.' :
      'The typical estimate changed since the last saved forecast because the recent comparable results changed.');
    const widthChanged = keys.some(key => {
      const old = latest.ranges[key], current = forecast.ranges[key];
      return old && Math.abs((current.high - current.low) - (old.high - old.low)) >= floors[key];
    });
    if (!spread && widthChanged) {
      note(contextChanged ? 'The ranges changed after the planned context or evidence changed.' : 'The ranges changed because recent comparable results were more or less variable.');
    }
  }
  return forecast;
}

export function captureForecasts(data, session, now, { deload } = {}) {
  if (session.completedAt || now.getTime() < stamp(session.startedAt)) return;
  const plan = sessionPlan(session);
  const pausedForDeload = deload ?? programContext(data, session).kind === 'deload';
  for (const row of plan.exercises) {
    if (session.forecastPerformedSlots?.includes(row.id) || session.results.some(set => set.exerciseID === row.id)) continue;
    const archived = session.performanceForecasts?.filter(item => item.rowID === row.id) ?? [];
    const last = archived.at(-1);
    const context = contextFor(row, plan, session.log);
    if (last?.variant === variantKey(row) && JSON.stringify(last.context) === JSON.stringify(context)) continue;
    const forecast = forecastExercise(data, plan, row, { now, day: dayOf(session), deload: pausedForDeload, log: session.log });
    (session.performanceForecasts ??= []).push({ ...forecast, id: `${row.id}:${archived.length + 1}`, revision: archived.length + 1 });
  }
}

export function scoreForecasts(data) {
  const groups = new Map();
  for (const session of data.sessions) {
    if (!session.completedAt || !session.performanceForecasts?.length || programContext(data, session).kind === 'deload') continue;
    for (const row of sessionPlan(session).exercises) {
      const outcome = actual(session, row);
      if (!outcome) continue;
      const latest = session.performanceForecasts.filter(item => item.rowID === row.id && stamp(item.issuedAt) <= stamp(outcome.result.at)).at(-1);
      if (latest?.status !== 'ready' || !latest.previous || variantKey(row) !== latest.variant || outcome.order !== latest.context.order ||
        (row.measurement === 'setting' && latest.setting !== outcome.result.amount?.value)) continue;
      const key = JSON.stringify([latest.model, latest.variant, latest.setting ?? null]);
      if (!groups.has(key)) groups.set(key, { name: latest.name, equipment: latest.equipment, model: latest.model,
        measurement: latest.measurement, basis: latest.basis, counting: latest.counting, setting: latest.setting, key, count: 0, metrics: {} });
      const group = groups.get(key);
      group.count++;
      for (const [metric, expected] of Object.entries(latest.ranges)) {
        const actualValue = outcome.values[metric];
        const score = group.metrics[metric] ??= { forecastError: 0, previousError: 0, inside: 0 };
        score.forecastError += Math.abs(actualValue - expected.center);
        score.previousError += Math.abs(actualValue - latest.previous.values[metric]);
        score.inside += actualValue >= expected.low && actualValue <= expected.high ? 1 : 0;
      }
    }
  }
  return [...groups.values()].map(group => ({ ...group, metrics: Object.fromEntries(Object.entries(group.metrics).map(([key, metric]) =>
    [key, { ...metric, forecastError: metric.forecastError / group.count, previousError: metric.previousError / group.count }])) }));
}
