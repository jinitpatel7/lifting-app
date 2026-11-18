import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createRoutineStore, draftExercise, makeDraft, newest, sessionPlan } from './routines.js';
import { previousResult } from './workout-log.js';

function fixture() {
  const memory = new Map();
  const storage = { getItem: key => memory.get(key) ?? null, setItem: (key, value) => memory.set(key, value) };
  const store = createRoutineStore(storage);
  const draft = makeDraft();
  draft.name = 'Strength day';
  for (const name of ['Bench', 'Row']) {
    const entry = draftExercise({ id: crypto.randomUUID(), name, equipment: 'barbell' });
    Object.assign(entry.work[0], { sets: '3', minimum: '6', maximum: '8', target: '80', effort: 'rir', effortValue: '2' });
    draft.exercises.push(entry);
  }
  const data = store.saveRoutine(draft, 'kg');
  return { store, storage, version: newest(data.routines[0]) };
}

test('scheduled workout restores notes and edits, and completion is deliberate and reversible', () => {
  const { store, storage, version } = fixture();
  const scheduled = store.schedule(version.routineID, '2026-11-18').schedule[0];
  const session = store.startScheduled(scheduled.id).sessions[0];
  const [bench, row] = session.log.exercises;
  const [one, two, three] = bench.sets;
  const change = (action, values) => store.logChange(session.id, { action, ...values }, 'kg').sessions[0];
  assert.equal(session.snapshot.id, version.id);
  assert.equal(session.scheduleID, scheduled.id);
  assert.deepEqual(session.results, []);
  change('sessionNotes', { value: 'Late session' });
  change('exerciseNotes', { exerciseID: bench.id, value: 'Paused reps' });
  change('editSet', { exerciseID: bench.id, setID: one.id, field: 'amount', value: '82.5' });
  change('editSet', { exerciseID: bench.id, setID: one.id, field: 'rir', value: '1' });
  change('editSet', { exerciseID: bench.id, setID: one.id, field: 'rpe', value: '9' });
  change('queue', { exerciseID: row.id, value: true });
  const restored = createRoutineStore(storage).load().sessions[0];
  assert.equal(restored.log.notes, 'Late session');
  assert.equal(restored.log.exercises[0].notes, 'Paused reps');
  assert.equal(restored.log.exercises[0].sets[0].input.amount, '82.5');
  assert.equal(restored.log.exercises[1].sets[0].status, 'pending');
  assert.ok(restored.log.exercises[1].queuedAt);
  assert.deepEqual(restored.results, []);
  const result = change('complete', { exerciseID: bench.id, setID: one.id }).results[0];
  assert.deepEqual([result.amount.value, result.reps, result.rir, result.rpe], [82.5, 6, 1, 9]);
  assert.deepEqual(change('undo', { exerciseID: bench.id, setID: one.id }).results, []);
  change('complete', { exerciseID: bench.id, setID: one.id });
  change('skipSet', { exerciseID: bench.id, setID: two.id });
  const finished = store.finish(session.id, true).sessions[0];
  assert.equal(finished.endedEarly, true);
  assert.deepEqual(finished.log.exercises[0].sets.map(set => [set.id, set.status]), [[one.id, 'completed'], [two.id, 'skipped'], [three.id, 'pending']]);
  assert.equal(finished.results.length, 1);
  assert.throws(() => change('undo', { exerciseID: bench.id, setID: one.id }), /already complete/);
});

test('today-only edits, routine promotion, and repeat preserve identities and completed history', () => {
  const { store, version } = fixture();
  const session = store.start(version.routineID).sessions[0];
  const [bench, row] = session.log.exercises;
  const [target, removed] = bench.sets;
  const change = (action, values) => store.logChange(session.id, { action, ...values }, 'kg');
  change('moveExercise', { exerciseID: row.id, direction: -1 });
  change('removeSet', { exerciseID: bench.id, setID: removed.id });
  change('editSet', { exerciseID: bench.id, setID: target.id, field: 'reps', value: '9' });
  assert.deepEqual(newest(store.load().routines[0]), version);
  const updated = store.updateRoutine(session.id);
  assert.deepEqual(updated.routines[0].versions[0], version);
  assert.deepEqual(newest(updated.routines[0]).exercises.map(entry => entry.exercise.name), ['Row', 'Bench']);
  assert.equal(newest(updated.routines[0]).exercises[1].work[0].reps.minimum, 9);
  change('complete', { exerciseID: bench.id, setID: target.id });
  const completed = store.finish(session.id, true).sessions[0];
  const all = store.repeat(session.id).sessions;
  const repeated = all[1];
  assert.deepEqual(all[0], completed);
  assert.deepEqual(completed.snapshot, version);
  assert.equal(repeated.referenceID, session.id);
  assert.deepEqual(repeated.results, []);
  const repeatedBench = repeated.log.exercises[1];
  assert.equal(repeatedBench.sets.length, 2);
  assert.ok(repeatedBench.sets.every(set => set.status === 'pending' && set.input === null));
  assert.equal(previousResult(repeated, all, sessionPlan(repeated).exercises[1], repeatedBench.sets[0], repeatedBench).reps, 9);
});

test('empty workout validates typed measurements and keeps settings as labels', () => {
  const { store } = fixture();
  const session = store.startEmpty().sessions[0];
  const change = (action, values) => store.logChange(session.id, { action, ...values }, 'lb').sessions[0];
  assert.deepEqual(session.log.exercises, []);
  for (const [measurement, value, expected] of [['duration', '45', 45], ['distance', '250', 250], ['setting', '007', '007']]) {
    const entry = draftExercise({ id: crypto.randomUUID(), name: measurement, equipment: 'machine' });
    Object.assign(entry, { measurement, equipmentLabel: 'Station A', work: [] });
    const set = change('addExercise', { entry }).log.exercises.at(-1).sets[0];
    assert.throws(() => change('complete', { exerciseID: entry.id, setID: set.id }), /enter/i);
    change('editSet', { exerciseID: entry.id, setID: set.id, field: 'amount', value });
    if (measurement === 'setting') change('editSet', { exerciseID: entry.id, setID: set.id, field: 'reps', value: '8' });
    const result = change('complete', { exerciseID: entry.id, setID: set.id }).results.at(-1);
    assert.deepEqual(result.amount, { kind: measurement, value: expected });
  }
  assert.equal(store.finish(session.id).sessions[0].endedEarly, false);
});

test('a skipped previous row does not borrow the result from the next set', () => {
  const { store, version } = fixture();
  const older = store.start(version.routineID).sessions[0];
  const olderBench = older.log.exercises[0];
  store.logChange(older.id, { action: 'complete', exerciseID: olderBench.id, setID: olderBench.sets[0].id }, 'kg');
  store.finish(older.id, true);
  const first = store.start(version.routineID).sessions.at(-1);
  const bench = first.log.exercises[0];
  store.logChange(first.id, { action: 'skipSet', exerciseID: bench.id, setID: bench.sets[0].id }, 'kg');
  store.logChange(first.id, { action: 'complete', exerciseID: bench.id, setID: bench.sets[1].id }, 'kg');
  store.finish(first.id, true);
  const { sessions } = store.repeat(first.id);
  const repeated = sessions.at(-1);
  const entry = repeated.log.exercises[0];
  const row = sessionPlan(repeated).exercises[0];
  assert.equal(previousResult(repeated, sessions, row, entry.sets[0], entry), null);
  assert.equal(previousResult(repeated, sessions, row, entry.sets[1], entry).order, 2);
});
