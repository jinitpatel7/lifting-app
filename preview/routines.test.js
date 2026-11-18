import assert from 'node:assert/strict';
import { test } from 'node:test';
import { blankSet, createRoutineStore, draftExercise, makeDraft, newGroup, newest, reorder, sessionPlan, validatedPlan } from './routines.js';

const row = name => {
  const exercise = draftExercise({ id: crypto.randomUUID(), name, equipment: 'barbell' });
  Object.assign(exercise.work[0], { minimum: '5', maximum: '6', target: '100', sets: '3', rest: '120' });
  return exercise;
};

function scenario() {
  const values = new Map();
  const storage = { getItem: key => values.get(key) ?? null, setItem: (key, value) => values.set(key, value) };
  const store = createRoutineStore(storage);
  const category = { id: crypto.randomUUID(), name: 'Strength' };
  store.addCategory(category);
  const draft = makeDraft();
  draft.name = 'A session';
  draft.categoryID = category.id;
  draft.exercises = [row('Bench'), row('Row'), row('Squat')];
  draft.exercises[0].warm = [{ ...blankSet(), minimum: '10', target: '45' }];
  Object.assign(draft.exercises[0].work[0], { amrap: true, structure: 'dropSet', effort: 'failure' });
  const group = { ...newGroup('Superset'), members: draft.exercises.slice(0, 2).map(item => item.id), restRounds: '90' };
  draft.groups = [group];
  return { store, storage, draft, values };
}

test('creates, reorders, versions and duplicates a categorized routine with grouped set blocks', () => {
  const { store, draft, storage } = scenario();
  let data = store.saveRoutine(draft, 'lb');
  const first = newest(data.routines[0]);
  assert.equal(first.exercises[0].warm[0].target.value, 45 * 0.45359237);
  assert.equal(first.exercises[0].work[0].amrap, true);
  assert.equal(first.exercises[0].work[0].effort.kind, 'failure');
  assert.equal(first.exercises[0].work[0].structure, 'dropSet');
  const changed = makeDraft(first, 'kg');
  assert.equal(store.saveRoutine(changed, 'kg').routines[0].versions.length, 1);
  reorder(changed.exercises, changed.exercises[1].id, changed.exercises[0].id);
  changed.groups[0].kind = 'Circuit';
  changed.groups[0].members.push(changed.exercises[2].id);
  data = store.saveRoutine(changed, 'kg');
  assert.deepEqual(data.routines[0].versions[0], first);
  assert.deepEqual(newest(data.routines[0]).exercises.map(item => item.exercise.name), ['Row', 'Bench', 'Squat']);
  assert.deepEqual(newest(data.routines[0]).groups[0].members, changed.exercises.map(row => row.id));
  assert.throws(() => store.saveRoutine(changed, 'kg'), /routine changed/i);
  data = store.duplicate(draft.routineID);
  const copy = newest(data.routines[1]);
  assert.equal(copy.name, 'A session copy');
  assert.equal(copy.revision, 1);
  assert.equal(copy.categoryID, draft.categoryID);
  assert.notEqual(copy.groups[0].id, first.groups[0].id);
  assert.notEqual(copy.exercises[0].id, changed.exercises[0].id);
  assert.deepEqual(copy.groups[0].members, copy.exercises.map(row => row.id));
  assert.deepEqual(createRoutineStore(storage).load(), data);
});

test('retains finished sessions and prior results when a workout is repeated and edited', () => {
  const { store, draft, values } = scenario();
  store.saveRoutine(draft, 'kg');
  const active = store.start(draft.routineID).sessions[0];
  const changed = makeDraft(sessionPlan(active), 'kg');
  changed.name = 'This workout only';
  const edited = store.editSession(active.id, changed, 'kg');
  assert.equal(newest(edited.routines[0]).name, 'A session');
  assert.equal(edited.sessions[0].snapshot.name, 'A session');
  assert.equal(sessionPlan(edited.sessions[0]).name, 'This workout only');
  const completed = store.finish(active.id);
  completed.sessions[0].results.push({ exerciseID: changed.exercises[0].id, reps: 5, amount: { kind: 'weight', value: 112 } });
  values.set('setline-personal-routines-v1', JSON.stringify(completed));
  const repeat = store.repeat(active.id);
  assert.deepEqual(repeat.sessions[0], completed.sessions[0]);
  assert.equal(repeat.sessions[1].referenceID, active.id);
  assert.deepEqual(repeat.sessions[1].results, []);
  assert.equal(repeat.sessions[1].snapshot.name, 'This workout only');
  assert.throws(() => store.editSession(active.id, changed, 'kg'), /already complete/);
});

test('rejects malformed groups and keeps time, distance and machine settings distinct from weight', () => {
  const { draft } = scenario();
  draft.groups[0].members[1] = draft.exercises[2].id;
  assert.throws(() => validatedPlan(draft, 'kg'), /adjacent/);
  draft.groups = [];
  draft.exercises[0].measurement = 'setting';
  draft.exercises[0].equipmentLabel = 'Station A';
  draft.exercises[0].work[0].target = '007';
  draft.exercises[1].measurement = 'duration';
  draft.exercises[1].work[0].target = '25';
  draft.exercises[2].measurement = 'distance';
  draft.exercises[2].work[0].target = '800';
  const plan = validatedPlan(draft, 'lb');
  assert.deepEqual(plan.exercises.map(item => item.work[0].target), [
    { kind: 'setting', value: '007' }, { kind: 'duration', value: 25 }, { kind: 'distance', value: 800 },
  ]);
});
