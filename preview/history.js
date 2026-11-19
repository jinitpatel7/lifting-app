import { isDay, kilogramsPerPound, localDayKey } from './storage.js';
import { performedResult, rememberScoreSlots, sessionInput, sessionPlan, variantKey, workoutLog } from './workout-log.js';
import { workoutTimes } from './workout-tools.js';

const uuid = () => crypto.randomUUID();
export const externalLoad = amount => ['weight', 'added'].includes(amount?.kind) && Number.isFinite(amount.value) ? amount.value : null;
export const equipmentKey = row => [row.exercise.equipment ?? 'bodyweight', row.equipmentLabel || ''].join('|');
export const equipmentName = row => row.equipmentLabel || (row.exercise.equipment ? row.exercise.equipment[0].toUpperCase() + row.exercise.equipment.slice(1) : 'Bodyweight');
export const isStation = row => ['machine', 'cable'].includes(row.exercise.equipment);
export const unlinkedStation = row => isStation(row) && !row.equipmentLabel?.trim();
export const historyVariantKey = (row, sessionID) => unlinkedStation(row) ? JSON.stringify([variantKey(row), sessionID, row.id]) : variantKey(row);
export const matchesHistoryRow = (row, filter) => (!filter.exercise || row.exercise.id === filter.exercise) &&
  (!filter.equipment || equipmentKey(row) === filter.equipment);
export const sessionsByDate = sessions => [...sessions].sort((a, b) =>
  dayOf(b).localeCompare(dayOf(a)) || b.startedAt.localeCompare(a.startedAt));
export const dayOf = session => session.localDate ?? localDayKey(new Date(session.startedAt));

export function historyRows(session, row) {
  const results = session.results.filter(set => set.exerciseID === row.id);
  const logged = session.log?.exercises.find(entry => entry.id === row.id);
  if (logged) return logged.sets.map((set, index) => ({ ...set, order: index + 1, result: results.find(result => result.id === set.id) }));
  const targets = [...row.warm.map(block => ['warm-up', block]), ...row.work.map(block => ['working', block])]
    .flatMap(([purpose, plan]) => Array.from({ length: Math.min(plan.sets, 10000) }, () => ({ purpose, plan })));
  const ordered = new Map(results.map((set, index) => [set.order ?? index + 1, set]));
  const orders = [...new Set([...targets.map((_, index) => index + 1), ...ordered.keys()])].sort((a, b) => a - b);
  return orders.map(order => {
    const result = ordered.get(order);
    const target = targets[order - 1];
    return { order, id: result?.id ?? row.id + ':' + order, purpose: target?.purpose ?? result?.purpose ?? 'working',
      plan: target?.plan, result, status: result ? 'completed' : 'pending' };
  });
}

export function sessionStatus(session) {
  if (!session.completedAt) return 'In progress · Incomplete';
  return session.endedEarly || !session.results.length || sessionPlan(session).exercises.some(row =>
    historyRows(session, row).some(set => set.status !== 'completed')) ? 'Incomplete' : 'Completed';
}

export function historyFilter(sessions, filter) {
  return sessionsByDate(sessions).filter(session => {
    const date = dayOf(session);
    if ((filter.from && date < filter.from) || (filter.to && date > filter.to) ||
        (filter.routine && filter.routine !== session.snapshot.routineID)) return false;
    if (!filter.exercise && !filter.equipment) return true;
    return sessionPlan(session).exercises.some(row => matchesHistoryRow(row, filter));
  });
}

export function setReps(set, row) {
  if (set.reps == null) return null;
  return set.rightReps != null ? set.reps + set.rightReps : set.reps * (row.counting === 'perSide' ? 2 : 1);
}

export function setVolume(set, row) {
  const left = externalLoad(set.amount);
  if (left == null || set.reps == null) return null;
  const right = externalLoad(set.rightAmount) ?? left;
  const volume = set.rightReps != null ? left * set.reps + right * set.rightReps :
    left * setReps(set, row) * (row.basis === 'perDumbbell' && (row.counting ?? 'total') === 'total' ? 2 : 1);
  return Number.isFinite(volume) ? volume : null;
}

export function sessionMetrics(session, exerciseID, variants) {
  const rows = sessionPlan(session).exercises.filter(row => (!exerciseID || row.exercise.id === exerciseID) &&
    (!variants || variants.has(historyVariantKey(row, session.id))));
  const byID = new Map(rows.map(row => [row.id, row]));
  const sets = session.results.filter(set => byID.has(set.exerciseID));
  const allowStation = Boolean(exerciseID && new Set(rows.map(row => historyVariantKey(row, session.id))).size === 1);
  const volumes = sets.flatMap(set => {
    const row = byID.get(set.exerciseID);
    const value = !isStation(row) || (allowStation && !unlinkedStation(row)) ? setVolume(set, row) : null;
    return value == null ? [] : [value];
  });
  const duration = session.completedAt && session.durationKnown !== false ? workoutTimes(session, session.completedAt).elapsed : null;
  return { count: sets.length, duration, volume: volumes.length ? volumes.reduce((total, value) => total + value, 0) : null };
}

export function comparisonScopes(left, right) {
  const a = sessionPlan(left).exercises;
  const ids = new Set(sessionPlan(right).exercises.map(row => row.exercise.id));
  const sameRoutine = left.snapshot.revision > 0 && left.snapshot.routineID === right.snapshot.routineID;
  return [...(sameRoutine ? [{ id: '', name: 'Same routine' }] : []),
    ...new Map(a.filter(row => ids.has(row.exercise.id)).map(row => [row.exercise.id, { id: row.exercise.id, name: row.exercise.name }])).values()];
}

export function compareSessions(left, right, exerciseID = '') {
  const scope = session => sessionPlan(session).exercises.filter(row => !exerciseID || row.exercise.id === exerciseID);
  const a = scope(left);
  const b = scope(right);
  const shared = new Set(a.map(row => row.exercise.id).filter(id => b.some(row => row.exercise.id === id)));
  const order = rows => rows.filter(row => shared.has(row.exercise.id)).map(row => row.exercise.id).join('|');
  const equipment = (rows, id) => [...new Set(rows.filter(row => row.exercise.id === id).map(equipmentKey))].sort().join(';');
  const performed = (session, rows) => new Set(rows.filter(row => session.results.some(set => set.exerciseID === row.id)).map(row => historyVariantKey(row, session.id)));
  const bKeys = performed(right, b);
  const compatible = new Set([...performed(left, a)].filter(key => bKeys.has(key)));
  const leftMetrics = sessionMetrics(left, exerciseID);
  const rightMetrics = sessionMetrics(right, exerciseID);
  const matchingVolumeLeft = sessionMetrics(left, exerciseID, compatible).volume;
  const matchingVolumeRight = sessionMetrics(right, exerciseID, compatible).volume;
  const reps = (session, rows) => {
    const relevant = new Map(rows.filter(row => compatible.has(historyVariantKey(row, session.id))).map(row => [row.id, row]));
    const counts = session.results.filter(set => relevant.has(set.exerciseID) && set.reps != null).map(set => setReps(set, relevant.get(set.exerciseID)));
    return counts.length ? counts.reduce((a, b) => a + b, 0) : null;
  };
  const leftReps = reps(left, a), rightReps = reps(right, b);
  return {
    left: leftMetrics, right: rightMetrics,
    orderChanged: !exerciseID && order(a) !== order(b),
    equipmentChanged: [...shared].some(id => equipment(a, id) !== equipment(b, id)),
    exercisesChanged: !exerciseID && JSON.stringify([...new Set(a.map(row => row.exercise.id))].sort()) !==
      JSON.stringify([...new Set(b.map(row => row.exercise.id))].sort()),
    volumeChange: matchingVolumeLeft == null || matchingVolumeRight == null ? null : matchingVolumeLeft - matchingVolumeRight,
    repsChange: leftReps == null || rightReps == null ? null : leftReps - rightReps,
  };
}

export function priorComparable(session, sessions) {
  const older = sessionsByDate(sessions).filter(other => other.id !== session.id && other.completedAt &&
    other.startedAt < session.startedAt && other.results.length);
  for (const other of older) {
    if (comparisonScopes(session, other).some(scope => scope.id === '')) return { other, exerciseID: '' };
  }
  const actual = new Set(session.results.map(result => result.exerciseID));
  const rows = sessionPlan(session).exercises.filter(row => actual.has(row.id));
  for (const other of older) {
    const previous = sessionPlan(other).exercises.find(row => other.results.some(result => result.exerciseID === row.id) &&
      rows.some(current => historyVariantKey(current, session.id) === historyVariantKey(row, other.id)));
    if (previous) return { other, exerciseID: previous.exercise.id };
  }
  return null;
}

const displayAmount = (amount, unit) => amount == null ? '' :
  String(['weight', 'added', 'assistance'].includes(amount.kind) && unit === 'lb' ? amount.value / kilogramsPerPound : amount.value);
function resultInput(result, unit) {
  if (!result) return sessionInput({}, unit);
  return { unit, amount: displayAmount(result.amount, unit), rightAmount: displayAmount(result.rightAmount, unit),
    reps: String(result.reps ?? ''), rightReps: String(result.rightReps ?? ''), rir: String(result.rir ?? ''),
    rpe: String(result.rpe ?? ''), failure: Boolean(result.failure), separateSides: result.rightReps != null || result.rightAmount != null };
}

export function historyDraft(session, template, day, unit) {
  const version = session ? session.snapshot : template;
  const source = session ?? { snapshot: version ?? { exercises: [], groups: [] }, results: [] };
  return { sessionID: session?.id, versionID: template?.id ?? '', day: session ? dayOf(session) : day, start: '09:00',
    name: version?.name ?? '', minutes: '', notes: session?.log?.notes ?? '', incomplete: session?.endedEarly === true, unit,
    exercises: sessionPlan(source).exercises.map(row => ({
      row, notes: session?.log?.exercises.find(log => log.id === row.id)?.notes ?? '',
      sets: historyRows(source, row).map(set => ({ ...set, id: set.result?.id ?? set.id,
        status: set.status, input: resultInput(set.result, unit) })),
    })) };
}

export function newHistorySet(unit) {
  return { id: uuid(), purpose: 'working', status: 'pending', input: resultInput(null, unit) };
}

export function saveHistoryEntry(data, draft, now = new Date()) {
  const original = draft.sessionID && data.sessions.find(session => session.id === draft.sessionID);
  if (draft.sessionID && !original?.completedAt) throw new Error('Choose a finished workout to edit.');
  const zone = Intl.DateTimeFormat().resolvedOptions().timeZone;
  let session = original;
  if (!session) {
    if (!isDay(draft.day) || !/^\d\d:\d\d$/.test(draft.start)) throw new Error('Enter a valid workout date and start time.');
    const start = new Date(draft.day + 'T' + draft.start);
    const matches = !Number.isNaN(start.valueOf()) && localDayKey(start) === draft.day &&
      [start.getHours(), start.getMinutes()].map(value => String(value).padStart(2, '0')).join(':') === draft.start;
    const minutes = draft.minutes.trim() === '' ? null : Number(draft.minutes.replace(',', '.'));
    if (!matches || (minutes != null && (!Number.isFinite(minutes) || minutes < 0 || minutes > 1440))) throw new Error('Enter a valid local start time and a duration up to 24 hours.');
    const end = new Date(start.getTime() + (minutes ?? 0) * 60_000);
    if (end > now) throw new Error('The workout must have ended by now.');
    const selected = data.routines.flatMap(routine => routine.versions).find(item => item.id === draft.versionID);
    if (draft.versionID && !selected) throw new Error('Choose an existing routine version.');
    const name = draft.name.trim();
    if (!name && !selected) throw new Error('Name the workout or choose a routine.');
    session = { id: uuid(), snapshot: selected ?? { id: uuid(), routineID: uuid(), revision: 0, name, exercises: [], groups: [] },
      startedAt: start.toISOString(), completedAt: end.toISOString(), localDate: draft.day, timeZone: zone,
      durationKnown: minutes != null, finishedLocalDate: localDayKey(end, zone), results: [] };
  }
  const plan = sessionPlan(session);
  const priorEvidence = JSON.stringify([plan.exercises, session.results]);
  rememberScoreSlots(session);
  const canonical = new Map(plan.exercises.map(row => [row.id, row]));
  const added = draft.exercises.filter(exercise => !canonical.has(exercise.row.id)).map(exercise => exercise.row);
  for (const row of added) canonical.set(row.id, row);
  if (added.length) session.override = { ...plan, exercises: [...plan.exercises, ...added] };
  const priorResults = new Map(session.results.map(result => [result.id, result]));
  const results = [];
  const log = workoutLog(session);
  const exercises = draft.exercises.map(({ row: inputRow, notes, sets }) => {
    const row = canonical.get(inputRow.id);
    const old = historyRows(session, row);
    const existing = log.exercises.find(item => item.id === row.id);
    const rows = sets.map((set, index) => {
      const saved = old.find(item => item.id === set.id);
      const performed = priorResults.get(set.id) ?? saved?.result;
      const target = saved?.plan ?? set.plan ?? null;
      if (set.status === 'completed') {
        const unchanged = performed && JSON.stringify(resultInput(performed, set.input.unit)) === JSON.stringify(set.input);
        const result = unchanged ? performed : performedResult(set.input, row, { ...set, plan: target }, performed?.at ?? session.completedAt);
        results.push({ ...performed, ...result, id: set.id, order: index + 1 });
      }
      return { id: set.id, purpose: set.purpose, plan: target, input: set.status === 'completed' ? set.input : null, status: set.status };
    });
    return { ...existing, id: row.id, notes, queuedAt: null, sets: rows };
  });
  if (!original && !results.length) throw new Error('Mark at least one set as performed and enter its results.');
  session.endedEarly = draft.incomplete;
  session.results = results;
  session.log = { ...log, notes: draft.notes, exercises, rest: null, undo: null };
  rememberScoreSlots(session);
  if (!original || priorEvidence !== JSON.stringify([sessionPlan(session).exercises, results])) session.forecastEvidenceAt = now.toISOString();
  if (!original) data.sessions.push(session);
}

export function invalidateHistoryPredictions(before, after, predictions) {
  if (!predictions?.length) return predictions;
  const previous = new Map(before.filter(session => session.completedAt).map(session => [session.id, session]));
  const changedIDs = new Set();
  const changedVariants = new Set();
  const facts = session => session && JSON.stringify([dayOf(session), session.results, sessionPlan(session).exercises.map(variantKey)]);
  for (const session of after.filter(session => session.completedAt)) {
    const old = previous.get(session.id);
    if (facts(old) === facts(session)) continue;
    changedIDs.add(session.id);
    for (const source of [old, session].filter(Boolean)) for (const row of sessionPlan(source).exercises) {
      if (source.results.some(set => set.exerciseID === row.id)) changedVariants.add(variantKey(row));
    }
  }
  return predictions.filter(item => !changedVariants.has(item.variant) && !item.sourceSessionIDs?.some(id => changedIDs.has(id)));
}
