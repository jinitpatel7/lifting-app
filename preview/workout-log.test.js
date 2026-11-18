import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createRoutineStore, draftExercise, makeDraft, newGroup, newest, sessionPlan } from './routines.js';
import { previousResult } from './workout-log.js';
import { parsePlates, plateOptions, restRemaining, typoHint, workoutSequence, workoutTimes } from './workout-tools.js';
import { workoutStep } from './workout-ui.js';

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

test('superset timing survives interruption, freezes during a pause, and measures rest independently of edits', () => {
  const { store, storage, version } = fixture();
  const draft = makeDraft(version);
  draft.groups = [{ ...newGroup(), kind: 'superset', members: draft.exercises.map(row => row.id), rounds: '2', restExercises: '20', restRounds: '75' }];
  store.saveRoutine(draft, 'kg');
  const session = store.start(version.routineID).sessions[0];
  const [a, b] = session.log.exercises;
  const time = offset => new Date(Date.parse(session.startedAt) + offset * 1000).toISOString();
  const change = (action, at, values) => store.logChange(session.id, { action, ...values }, 'kg', time(at)).sessions[0];
  const complete = (exercise, index, at) => change('complete', at, { exerciseID: exercise.id, setID: exercise.sets[index].id });
  change('trackRest', 0, { value: true });
  const first = complete(a, 0, 5);
  assert.equal(first.log.rest.targetSeconds, 20);
  assert.equal(workoutSequence(first.log, sessionPlan(first)).find(item => item.set.status === 'pending').exerciseID, b.id);
  change('extendRest', 10);
  const paused = change('pause', 15);
  assert.equal(restRemaining(paused, time(300)), 25);
  const reopened = createRoutineStore(storage).load().sessions[0];
  assert.equal(reopened.log.rest.startedAt, time(5));
  assert.deepEqual(workoutTimes(reopened, time(300)), { elapsed: 300, paused: 285, active: 15 });
  assert.throws(() => complete(b, 0, 300), /resume/i);
  change('resume', 300);
  assert.equal(restRemaining(change('restartRest', 302), time(305)), 17);
  change('editRest', 305, { setID: a.sets[0].id, value: '22' });
  const next = complete(b, 0, 310);
  assert.equal(next.log.rest.targetSeconds, 75);
  assert.equal(next.results.find(item => item.id === a.sets[0].id).actualRest.measuredSeconds, 20);
  assert.equal(next.results.find(item => item.id === a.sets[0].id).actualRest.editedSeconds, 22);
  const skipped = change('skipRest', 312);
  assert.equal(skipped.results.find(item => item.id === b.sets[0].id).actualRest.reason, 'skipped');
  const restored = change('undoLast', 312);
  assert.equal(restored.log.rest.setID, b.sets[0].id);
  assert.equal(restored.results.find(item => item.id === b.sets[0].id).actualRest, undefined);
});

test('plate totals and configured increments respect available equipment and units', () => {
  const plates = parsePlates('20x1, 5x1, 2.5x1');
  assert.deepEqual(plateOptions(20, plates, 75), { exact: true, plates: [20, 5, 2.5], lower: 70, upper: null });
  assert.deepEqual(plateOptions(20, plates, 65), { exact: true, plates: [20, 2.5], lower: 60, upper: 70 });
  assert.equal(plateOptions(20, plates, 40).exact, false);
  assert.throws(() => parsePlates('5x31'));
  const { store } = fixture();
  const session = store.startEmpty().sessions[0];
  const change = (action, values) => store.logChange(session.id, { action, ...values }, 'lb').sessions[0];
  const entry = draftExercise({ id: crypto.randomUUID(), name: 'Dumbbell row', equipment: 'dumbbell' });
  Object.assign(entry, { basis: 'perDumbbell', counting: 'perSide', work: [] });
  const set = change('addExercise', { entry }).log.exercises[0].sets[0];
  const edit = (field, value) => change('editSet', { exerciseID: entry.id, setID: set.id, field, value });
  change('loadProfile', { exerciseID: entry.id, increment: '5', unit: 'lb' });
  edit('amount', '50');
  edit('reps', '7');
  edit('separateSides', true);
  edit('rightReps', '5');
  edit('rightAmount', '45');
  const current = store.load().sessions[0];
  const row = sessionPlan(current).exercises[0];
  assert.equal(workoutStep(current, row, current.log.exercises[0].sets[0], 'amount', 1, 'lb'), '55');
  const completed = change('complete', { exerciseID: entry.id, setID: set.id }).results[0];
  assert.deepEqual([completed.reps, completed.rightReps], [7, 5]);
  assert.ok(completed.rightAmount.value < completed.amount.value);
  change('removeExercise', { exerciseID: entry.id });
  const restored = change('undoLast');
  assert.deepEqual(restored.results[0], completed);
  assert.equal(restored.log.rest.setID, set.id);
  assert.match(typoHint({ amount: '500', reps: '55' }, { amount: '50', reps: '8' }, row), /load and reps/);
  assert.match(typoHint({ amount: '400' }, { amount: '40' }, { measurement: 'duration' }), /duration/);
});

test('a circuit honors zero rest, routes around queued equipment, and uses set rest after the final round', () => {
  const { store, version } = fixture();
  const draft = makeDraft(version);
  const carry = draftExercise({ id: crypto.randomUUID(), name: 'Carry', equipment: 'dumbbell' });
  Object.assign(carry.work[0], { sets: '2', minimum: '6', maximum: '8', target: '20', rest: '45' });
  draft.exercises.push(carry);
  draft.exercises.slice(0, 2).forEach(row => { row.work[0].sets = '2'; });
  draft.groups = [{ ...newGroup('circuit'), members: draft.exercises.map(row => row.id), rounds: '2', restExercises: '0', restRounds: '50' }];
  store.saveRoutine(draft, 'kg');
  const session = store.start(version.routineID).sessions[0];
  const [a, b, c] = session.log.exercises;
  const change = (action, values) => store.logChange(session.id, { action, ...values }, 'kg').sessions[0];
  const complete = (exercise, index) => change('complete', { exerciseID: exercise.id, setID: exercise.sets[index].id });
  change('queue', { exerciseID: b.id, value: true });
  assert.equal(complete(a, 0).log.rest.targetSeconds, 0);
  assert.equal(complete(c, 0).log.rest.targetSeconds, 50);
  assert.equal(complete(a, 1).log.rest.targetSeconds, 0);
  const final = complete(c, 1);
  assert.equal(final.log.rest.targetSeconds, 45);
  assert.deepEqual(final.log.exercises[1].sets.map(set => set.status), ['pending', 'pending']);
  assert.equal(final.results.some(set => set.actualRest), false);
});

test('a timed unilateral set requires and preserves an independent result for each side', () => {
  const { store } = fixture();
  const session = store.startEmpty().sessions[0];
  const entry = draftExercise({ id: crypto.randomUUID(), name: 'Side plank' });
  Object.assign(entry, { measurement: 'duration', work: [] });
  const change = (action, values) => store.logChange(session.id, { action, exerciseID: entry.id, ...values }, 'kg').sessions[0];
  const setID = change('addExercise', { entry }).log.exercises[0].sets[0].id;
  change('editSet', { setID, field: 'amount', value: '45' });
  change('editSet', { setID, field: 'separateSides', value: true });
  assert.throws(() => change('complete', { setID }), /enter/i);
  change('editSet', { setID, field: 'rightAmount', value: '35' });
  const [result] = change('complete', { setID }).results;
  assert.deepEqual([result.amount.value, result.rightAmount.value, result.reps], [45, 35, null]);
});
