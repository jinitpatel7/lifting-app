import { dayOf, equipmentKey, externalLoad, historyFilter, historyVariantKey, isStation, matchesHistoryRow, setReps, setVolume, unlinkedStation } from './history.js';
import { dayDistance, scheduleEntries, scheduleVersion, scheduleWindow } from './schedule.js';
import { sessionPlan } from './workout-log.js';
import { localDayKey } from './storage.js';

export const metrics = { load: 'Load', reps: 'Reps', volume: 'Logged volume', duration: 'Duration', distance: 'Distance', estimate: 'Estimated 1RM' };
export const dashboardStats = { workouts: 'Workouts with logged sets', sets: 'Working sets', plan: 'Planned vs completed',
  volume: 'Free-weight and added-load volume', duration: 'Logged exercise duration', distance: 'Logged distance' };
export const analyticsDefaults = { visible: Object.keys(metrics), dashboard: ['workouts', 'plan'],
  plateauEnabled: true, plateauMetric: 'estimate', plateauSessions: 4, plateauPercent: 2, breakDays: 14 };
export const estimateHelp = 'Epley uses load × (1 + reps ÷ 30) for 2–10 reps. A single uses its recorded load. Setline estimates only bilateral free-weight working sets. The estimate assumes a hard set and varies with effort, technique, and exercise.';
export const estimateSource = 'https://efyc.fahce.unlp.edu.ar/article/download/efyce222/15809?inline=1';
export const normalizedAnalytics = settings => ({ ...analyticsDefaults, ...settings });

export function validateAnalytics(settings) {
  if (!settings.visible.every(key => Object.hasOwn(metrics, key)) || !settings.dashboard.every(key => Object.hasOwn(dashboardStats, key)) ||
      !Object.hasOwn(metrics, settings.plateauMetric) || !Number.isInteger(settings.plateauSessions) || settings.plateauSessions < 3 || settings.plateauSessions > 12 ||
      !Number.isFinite(settings.plateauPercent) || settings.plateauPercent < 0.1 || settings.plateauPercent > 25 ||
      !Number.isInteger(settings.breakDays) || settings.breakDays < 7 || settings.breakDays > 90) {
    throw new Error('Use 3–12 sessions, a 0.1–25% improvement threshold, and 7–90 days for a training break.');
  }
  return { ...settings, visible: [...new Set(settings.visible)], dashboard: [...new Set(settings.dashboard)] };
}

export function estimatedMax(row, set, purpose = set.purpose) {
  const load = externalLoad(set.amount);
  if (row.measurement !== 'weight' || set.amount?.kind !== 'weight' || !['barbell', 'dumbbell', 'kettlebell'].includes(row.exercise.equipment) ||
      row.counting !== 'total' || set.rightReps != null || set.rightAmount != null || purpose === 'warm-up' ||
      !load || !Number.isInteger(set.reps) || set.reps < 1 || set.reps > 10) return null;
  const estimate = set.reps === 1 ? load : load * (1 + set.reps / 30);
  return Number.isFinite(estimate) ? estimate : null;
}

export function loggedPurpose(session, row, set, position) {
  if (set.purpose) return set.purpose === 'warm-up' ? 'warm-up' : 'working';
  const recorded = session.log?.exercises.find(item => item.id === row.id)?.sets.find(item => item.id === set.id);
  if (recorded?.purpose) return recorded.purpose;
  const warmups = row.warm.reduce((count, block) => count + block.sets, 0);
  return (set.order ?? position + 1) <= warmups ? 'warm-up' : 'working';
}

const sum = (before, value) => Number.isFinite(value) && Number.isFinite((before ?? 0) + value) ? (before ?? 0) + value : before;
const maximum = (before, value) => Number.isFinite(value) ? Math.max(before ?? value, value) : before;
const quantity = (set, kind) => set.amount?.kind === kind && Number.isFinite(set.amount.value) ?
  set.amount.value + (set.rightAmount?.kind === kind && Number.isFinite(set.rightAmount.value) ? set.rightAmount.value : 0) : null;

function setValues(row, set, purpose) {
  const magnitude = amount => externalLoad(amount) ?? (amount?.kind === 'assistance' ? amount.value : null);
  const load = set.reps === 0 ? null : magnitude(set.amount);
  const right = set.rightReps === 0 ? null : magnitude(set.rightAmount) ?? (set.rightReps > 0 ? magnitude(set.amount) : null);
  return {
    load: maximum(load, right), reps: setReps(set, row), volume: unlinkedStation(row) ? null : setVolume(set, row),
    duration: quantity(set, 'duration'), distance: quantity(set, 'distance'), estimate: estimatedMax(row, set, purpose),
  };
}

const maxMetrics = ['load', 'estimate'];
function mergeValues(old, values) {
  for (const key of Object.keys(metrics)) {
    old[key] = (maxMetrics.includes(key) ? maximum : sum)(old[key], values[key]);
  }
}

function efforts(row, set, date) {
  const load = externalLoad(set.amount);
  if (load == null || set.reps == null || unlinkedStation(row)) return [];
  if (set.rightReps != null) return [
    { load, reps: set.reps, side: 'Left', date },
    { load: externalLoad(set.rightAmount) ?? load, reps: set.rightReps, side: 'Right', date },
  ].filter(effort => effort.reps > 0);
  return [{ load, reps: set.reps, side: row.counting === 'perSide' ? 'Per side' : '', date }];
}

function recordsFor(attempts) {
  const byLoad = new Map(), byReps = new Map();
  let heaviest;
  for (const point of attempts) {
    const loadKey = JSON.stringify([Math.round(point.load * 1e8) / 1e8, point.side]);
    const repKey = JSON.stringify([point.reps, point.side]);
    if (!heaviest || heaviest.load < point.load || (heaviest.load === point.load && heaviest.reps < point.reps)) heaviest = point;
    if (!byLoad.has(loadKey) || point.reps > byLoad.get(loadKey).reps) byLoad.set(loadKey, point);
    if (!byReps.has(repKey) || point.load > byReps.get(repKey).load) byReps.set(repKey, point);
  }
  return { heaviest, byLoad: [...byLoad.values()].sort((a, b) => b.load - a.load), byReps: [...byReps.values()].sort((a, b) => a.reps - b.reps) };
}

export function programContext(data, session) {
  const date = dayOf(session);
  const entry = (data.schedule ?? []).find(item => item.id === session.scheduleID);
  const blocks = data.programBlocks ?? [];
  const possible = blocks.filter(block => block.first <= date && date <= block.last);
  const block = (entry?.blockID && blocks.find(block => block.id === entry.blockID)) || (possible.length === 1 ? possible[0] : null);
  if (!block) return { id: '', name: '', week: -1, kind: '' };
  const anchor = entry?.blockID === block.id ? (entry.moves?.[0] ?? entry.date) : date;
  const index = Math.floor(dayDistance(block.first, anchor) / 7);
  return { id: block.id, name: block.name, week: index, kind: block.weeks?.[index]?.kind ?? 'training' };
}

export function plateauFor(samples, settings, row) {
  if (!settings.plateauEnabled) return null;
  const latest = samples.at(-1);
  if (latest?.context.kind === 'deload') return { state: 'deload' };
  if (row.measurement === 'assistance' && settings.plateauMetric === 'load') return null;
  const eligible = [];
  for (const item of samples) {
    const previous = eligible.at(-1);
    if (item.reset || (previous && dayDistance(previous.date, item.date) >= settings.breakDays)) eligible.length = 0;
    if (item.context.kind !== 'deload' && Number.isFinite(item.values[settings.plateauMetric])) eligible.push(item);
  }
  const window = eligible.slice(-settings.plateauSessions);
  const baseline = window[0]?.values[settings.plateauMetric];
  if (window.length < settings.plateauSessions || !(baseline > 0) || latest !== eligible.at(-1)) return null;
  const best = Math.max(...window.slice(1).map(item => item.values[settings.plateauMetric]));
  const change = (best - baseline) / baseline * 100;
  return change + 1e-9 < settings.plateauPercent ? { state: 'flag', change, count: window.length } : null;
}

export function exerciseAnalytics(data, filter = {}, purpose = 'working', preference = analyticsDefaults) {
  const settings = normalizedAnalytics(preference);
  const variants = new Map();
  const previousGear = new Map();
  const contextBySession = new Map();
  const exerciseRevisions = new Map();
  for (const session of historyFilter(data.sessions.filter(session => session.completedAt), {}).reverse()) {
    const date = dayOf(session);
    const rows = sessionPlan(session).exercises;
    const context = programContext(data, session);
    const applicable = (!filter.from || date >= filter.from) && (!filter.to || date <= filter.to) &&
      (!filter.routine || session.snapshot.routineID === filter.routine);
    const setsByID = new Map();
    for (const set of session.results) {
      const sets = setsByID.get(set.exerciseID) ?? [];
      sets.push(set);
      setsByID.set(set.exerciseID, sets);
    }
    const gearByExercise = new Map(), samples = new Map();
    for (const row of rows) {
      const sets = setsByID.get(row.id)?.filter((set, index) => loggedPurpose(session, row, set, index) === purpose);
      if (!sets?.length) continue;
      const id = row.exercise.id;
      const gear = gearByExercise.get(id) ?? new Set();
      gear.add(equipmentKey(row));
      gearByExercise.set(id, gear);
      const key = historyVariantKey(row, session.id);
      const sample = samples.get(key) ?? { date, context, row, values: {}, efforts: [], routine: session.snapshot.routineID,
        version: session.snapshot.id, scoped: applicable && matchesHistoryRow(row, filter) };
      for (const set of sets) {
        mergeValues(sample.values, setValues(row, set, purpose));
        sample.efforts.push(...efforts(row, set, date));
      }
      samples.set(key, sample);
    }
    for (const [key, sample] of samples) {
      const row = sample.row;
      const previous = contextBySession.get(key);
      const events = [];
      const programChanged = previous ? previous.context.id !== context.id : Boolean(context.id);
      const priorVersion = exerciseRevisions.get(JSON.stringify([row.exercise.id, sample.routine]));
      const versionChanged = priorVersion != null && priorVersion !== sample.version;
      const gap = previous ? dayDistance(previous.date, date) : 0;
      const gear = [...gearByExercise.get(row.exercise.id)].sort().join(';');
      const olderGear = previousGear.get(row.exercise.id);
      if (programChanged) events.push(context.id ? 'Program · ' + context.name : 'Program ended');
      if (versionChanged) events.push('Routine version changed');
      if (context.kind === 'deload' && (!previous || previous.context.kind !== 'deload' || previous.context.week !== context.week || programChanged)) {
        events.push('Deload · ' + context.name);
      }
      const gearChanged = olderGear != null && gear !== olderGear;
      if (gearChanged) events.push('Equipment changed');
      if (gap >= settings.breakDays) events.push('Training break · ' + gap + ' days between logs');
      contextBySession.set(key, sample);
      if (!sample.scoped) continue;
      const data = variants.get(key) ?? { key, row, points: [], samples: [], attempts: [] };
      const point = data.points.at(-1)?.date === date ? data.points.at(-1) : { date, values: {}, events: [] };
      if (data.points.at(-1) !== point) data.points.push(point);
      mergeValues(point.values, sample.values);
      point.events = [...new Set([...point.events, ...events])];
      data.samples.push({ ...sample, reset: programChanged || versionChanged || gearChanged || gap >= settings.breakDays });
      data.attempts.push(...sample.efforts);
      variants.set(key, data);
    }
    for (const [id, gear] of gearByExercise) {
      previousGear.set(id, [...gear].sort().join(';'));
      exerciseRevisions.set(JSON.stringify([id, session.snapshot.routineID]), session.snapshot.id);
    }
  }
  return [...variants.values()].map(({ attempts, samples, ...set }) => ({ ...set,
    records: recordsFor(attempts), plateau: purpose === 'working' && !unlinkedStation(set.row) ? plateauFor(samples, settings, set.row) : null }));
}

export function plannedCounts(version, filter = {}) {
  const counts = { working: 0, 'warm-up': 0 };
  if (!version || (filter.routine && version.routineID !== filter.routine)) return counts;
  for (const row of version.exercises.filter(row => matchesHistoryRow(row, filter))) {
    counts.working += row.work.reduce((total, set) => total + set.sets, 0);
    counts['warm-up'] += row.warm.reduce((total, set) => total + set.sets, 0);
  }
  return counts;
}

export function completedCounts(session, filter = {}) {
  const counts = { working: 0, 'warm-up': 0 };
  for (const row of sessionPlan(session).exercises.filter(row => matchesHistoryRow(row, filter))) {
    session.results.filter(set => set.exerciseID === row.id).forEach((set, index) => {
      counts[loggedPurpose(session, row, set, index)]++;
    });
  }
  return counts;
}

export function weeklyAnalytics(data, anchor, filter = {}, lookup = () => null, today = localDayKey()) {
  const days = scheduleWindow(anchor, { ...data.scheduleSettings, mode: 'week' });
  const inRange = date => days.includes(date) && (!filter.from || date >= filter.from) && (!filter.to || date <= filter.to);
  const planned = { working: 0, 'warm-up': 0 };
  const performed = { working: 0, 'warm-up': 0 };
  const muscles = new Map();
  const totals = { workouts: 0, volume: null, duration: null, distance: null };
  const addPlan = version => {
    const counts = plannedCounts(version, filter);
    planned.working += counts.working;
    planned['warm-up'] += counts['warm-up'];
  };
  for (const entry of scheduleEntries(data, days.filter(inRange), today)) {
    if (entry.status !== 'moved') addPlan(scheduleVersion(data, entry.versionID));
  }
  for (const session of historyFilter(data.sessions, filter).filter(session => inRange(dayOf(session)))) {
    if (!session.scheduleID) addPlan(session.snapshot);
    let hasSets = false;
    for (const row of sessionPlan(session).exercises.filter(row => matchesHistoryRow(row, filter))) {
      const profile = row.exercise.primary ? row.exercise : lookup(row.exercise.id);
      const direct = new Set(profile?.primary ?? []);
      const indirect = new Set((profile?.secondary ?? []).filter(muscle => !direct.has(muscle)));
      for (const [index, set] of session.results.filter(set => set.exerciseID === row.id).entries()) {
        hasSets = true;
        const purpose = loggedPurpose(session, row, set, index);
        performed[purpose]++;
        if (purpose === 'working') {
          totals.volume = sum(totals.volume, isStation(row) ? null : setVolume(set, row));
          totals.duration = sum(totals.duration, quantity(set, 'duration'));
          totals.distance = sum(totals.distance, quantity(set, 'distance'));
        }
        for (const [role, groups] of [['direct', direct], ['indirect', indirect]]) for (const muscle of groups) {
          const summary = muscles.get(muscle) ?? { working: { direct: 0, indirect: 0 }, 'warm-up': { direct: 0, indirect: 0 } };
          summary[purpose][role]++;
          muscles.set(muscle, summary);
        }
      }
    }
    if (hasSets) totals.workouts++;
  }
  return { days, planned, performed, muscles, totals };
}
