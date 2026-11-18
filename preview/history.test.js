import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createRoutineStore, draftExercise, makeDraft, newest } from './routines.js';
import { comparisonScopes, compareSessions, equipmentKey, historyDraft, historyFilter, loadProgress,
  newHistorySet, priorComparable, sessionMetrics, sessionStatus } from './history.js';
import { previousResult, sessionPlan, variantKey } from './workout-log.js';

function fixture() {
  const data = new Map();
  const storage = { getItem: key => data.get(key) ?? null, setItem: (key, value) => data.set(key, value) };
  const store = createRoutineStore(storage);
  const draft = makeDraft();
  draft.name = 'Upper strength';
  for (const name of ['Bench', 'Row']) {
    const entry = draftExercise({ id: crypto.randomUUID(), name, equipment: 'barbell' });
    entry.equipmentLabel = name === 'Bench' ? 'Bar A' : 'Bar B';
    Object.assign(entry.work[0], { minimum: '5', maximum: '5', target: '70' });
    draft.exercises.push(entry);
  }
  const version = newest(store.saveRoutine(draft, 'kg').routines[0]);
  return { store, storage, data, version };
}

const now = new Date(2026, 10, 18, 18);
function logHistory(store, version, date, loads) {
  const draft = historyDraft(null, version, date, 'kg');
  draft.minutes = '42';
  draft.exercises.forEach((item, index) => {
    item.sets[0].status = 'completed';
    Object.assign(item.sets[0].input, { amount: String(loads[index]), reps: '5' });
  });
  return store.saveHistory(draft, now).sessions.at(-1);
}

test('a standalone missed workout keeps its selected local date and contains only entered actuals', () => {
  const { store, storage } = fixture();
  const draft = historyDraft(null, null, '2026-11-01', 'kg');
  draft.name = 'Sunday training';
  draft.start = '07:45';
  draft.notes = 'Added from notebook';
  const entry = draftExercise({ id: crypto.randomUUID(), name: 'Push-up' });
  entry.work = [];
  const set = newHistorySet('kg');
  draft.exercises.push({ row: entry, notes: 'Slow tempo', sets: [set] });
  assert.throws(() => store.saveHistory(draft, now), /performed/);
  assert.equal(store.load().sessions.length, 0);
  set.status = 'completed';
  set.input.reps = '20';
  const session = store.saveHistory(draft, now).sessions[0];
  const restored = createRoutineStore(storage).load().sessions[0];
  assert.equal(restored.id, session.id);
  assert.equal(restored.localDate, '2026-11-01');
  assert.deepEqual(restored.snapshot.exercises, []);
  assert.equal(restored.log.exercises[0].sets[0].plan, null);
  assert.equal(restored.results[0].reps, 20);
  assert.equal(restored.log.notes, 'Added from notebook');
  assert.deepEqual(sessionMetrics(restored), { count: 1, duration: null, volume: null });
  assert.equal(sessionStatus(restored), 'Completed');
  assert.deepEqual(historyFilter([restored], { from: '2026-11-02', to: '2026-11-04' }), []);
});

test('correcting a load keeps the original prescription and refreshes metrics, trends, and predictions', () => {
  const { store, data, version } = fixture();
  const session = logHistory(store, version, '2026-11-09', [90, 55]);
  const key = [...data.keys()].find(value => value.includes('personal-routines'));
  const before = store.load();
  before.predictions = [{ id: 'affected', variant: variantKey(version.exercises[0]), sourceSessionIDs: [session.id] },
    { id: 'keep', variant: 'other', sourceSessionIDs: ['elsewhere'] }];
  data.set(key, JSON.stringify(before));
  assert.equal(sessionMetrics(session).volume, 725);
  const draft = historyDraft(session, null, session.localDate, 'kg');
  draft.notes = 'Corrected setup';
  draft.exercises[0].sets[0].input.amount = '82.5';
  const saved = store.saveHistory(draft, now);
  const corrected = saved.sessions[0];
  assert.deepEqual(corrected.snapshot, session.snapshot);
  assert.equal(corrected.log.exercises[0].sets[0].plan.target.value, 70);
  assert.equal(corrected.results[0].amount.value, 82.5);
  assert.equal(corrected.results[0].id, session.results[0].id);
  assert.equal(corrected.results[0].at, session.results[0].at);
  assert.equal(sessionMetrics(corrected).volume, 687.5);
  assert.equal(loadProgress(saved.sessions).find(entry => entry.row.exercise.name === 'Bench').peak, 82.5);
  assert.deepEqual(saved.predictions.map(entry => entry.id), ['keep']);
});

test('comparing routine versions flags order and equipment changes and uses only matching variants for volume delta', () => {
  const { store, version } = fixture();
  const previous = logHistory(store, version, '2026-11-09', [80, 60]);
  const draft = makeDraft(version);
  draft.exercises[0].equipmentLabel = 'Bar C';
  draft.exercises.reverse();
  const changed = newest(store.saveRoutine(draft, 'kg').routines[0]);
  const current = logHistory(store, changed, '2026-11-12', [65, 85]);
  const comparison = compareSessions(current, previous);
  assert.equal(comparison.orderChanged, true);
  assert.equal(comparison.equipmentChanged, true);
  assert.equal(comparison.volumeChange, 25);
  assert.equal(priorComparable(current, store.load().sessions).other.id, previous.id);
  assert.equal(comparisonScopes(current, previous)[0].name, 'Same routine');
  const benchID = version.exercises[0].exercise.id;
  assert.equal(compareSessions(current, previous, benchID).volumeChange, null);
  assert.deepEqual(historyFilter([current, previous], { routine: version.routineID, exercise: benchID, equipment: equipmentKey(version.exercises[0]) }).map(entry => entry.id),
    [previous.id]);
});

test('skipped sets show an incomplete result and assistance does not contribute external-load volume', () => {
  const { store } = fixture();
  const draft = historyDraft(null, null, '2026-11-01', 'lb');
  draft.name = 'Pull-ups';
  const row = draftExercise({ id: crypto.randomUUID(), name: 'Assisted pull-up', equipment: 'machine' });
  row.measurement = 'assistance';
  row.work = [];
  const performed = newHistorySet('lb');
  Object.assign(performed, { status: 'completed' });
  Object.assign(performed.input, { amount: '25', reps: '10' });
  const skipped = newHistorySet('lb');
  skipped.status = 'skipped';
  draft.exercises.push({ row, notes: '', sets: [performed, skipped] });
  const session = store.saveHistory(draft, now).sessions[0];
  assert.equal(sessionStatus(session), 'Incomplete');
  assert.equal(sessionMetrics(session).volume, null);
  assert.deepEqual(loadProgress([session]), []);
});

test('backfilling an older workout does not replace the latest previous performance', () => {
  const { store, version } = fixture();
  logHistory(store, version, '2026-11-12', [80, 60]);
  logHistory(store, version, '2026-10-05', [65, 45]);
  const slot = store.schedule(version.routineID, '2026-11-18').schedule[0];
  const { sessions } = store.startScheduled(slot.id, slot.date, now);
  const current = sessions.at(-1);
  const logged = current.log.exercises[0];
  const previous = previousResult(current, sessions, sessionPlan(current).exercises[0], logged.sets[0], logged);
  assert.equal(previous.amount.value, 80);
});
