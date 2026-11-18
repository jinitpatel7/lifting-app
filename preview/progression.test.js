import assert from 'node:assert/strict';
import { test } from 'node:test';
import { blankSet, createRoutineStore, draftExercise, makeDraft, newest } from './routines.js';
import { historyDraft } from './history.js';
import { modesFor, progressionRule, suggestProgression } from './progression.js';
import { kilogramsPerPound } from './storage.js';

const now = new Date('2026-11-26T20:00:00Z');
const rule = (mode = 'load', step = 5, options = {}) => ({ mode, step, threshold: 'top', miss: 'hold', effort: 'none', effortLimit: null, ...options });

function fixture({ measurement = 'weight', equipment = 'barbell', station = '', value = 100, special = false, counting = 'total' } = {}) {
  const data = new Map();
  const store = createRoutineStore({ getItem: key => data.get(key) ?? null, setItem: (key, value) => data.set(key, value) });
  const draft = makeDraft();
  draft.name = 'Primary workout';
  const exercise = draftExercise({ id: 'lift', name: 'Lift', equipment });
  exercise.measurement = measurement;
  exercise.equipmentLabel = station;
  exercise.counting = counting;
  Object.assign(exercise.work[0], { sets: '2', minimum: '6', maximum: '8', target: String(value) });
  if (special) {
    exercise.warm.push({ ...blankSet(), minimum: '4', target: '40' });
    exercise.work.push({ ...blankSet(), minimum: '6', maximum: '8', target: String(value), amrap: true },
      { ...blankSet(), minimum: '6', maximum: '8', target: String(value), structure: 'dropSet' });
  }
  draft.exercises.push(exercise);
  const version = newest(store.saveRoutine(draft, 'kg').routines[0]);
  const row = version.exercises[0];
  const configure = value => store.saveProgressionRule(version.routineID, version.id, row.id, value);
  const suggestion = () => suggestProgression(store.load(), version, row);
  function log(values, date = '2026-11-18', template = version) {
    const active = historyDraft(null, template, date, 'kg');
    active.exercises[0].sets.forEach((set, index) => {
      if (!values[index]) return;
      set.status = 'completed';
      Object.assign(set.input, { amount: String(value), reps: '8' }, values[index]);
    });
    return store.saveHistory(active, now).sessions.at(-1);
  }
  return { store, version, row, configure, suggestion, log };
}

test('load requires all straight sets at the top by default, handles effort coverage and excludes special sets', () => {
  const { configure, log, suggestion } = fixture({ special: true });
  configure(rule('load', 5, { effort: 'rir', effortLimit: 2 }));
  log([{}, { reps: '8' }, { reps: '7' }, { reps: '17' }, { reps: '17', failure: true }]);
  assert.equal(suggestion().action, 'hold');
  assert.match(suggestion().note, /1 of 2/);
  assert.deepEqual(Object.values(suggestion().assessment), ['Reached top of range', 'Met minimum']);
  assert.equal(suggestion().excluded.length, 3);
  log([null, { rir: '2' }, { rir: '0' }], '2026-11-19');
  assert.match(suggestion().note, /recorded RIR missed/);
  log([null, { rir: '' }, { rir: '0' }], '2026-11-20');
  assert.equal(suggestion().action, 'advance');
  assert.match(suggestion().note, /only 1 of 2/);
  assert.deepEqual(suggestion().changes.map(change => change.index), [0]);
  assert.equal(suggestion().changes[0].prescription.target.value, 105);
  configure(rule('load', 5, { threshold: 'minimum' }));
  log([null, { reps: '7' }, { reps: '6' }], '2026-11-21');
  assert.equal(suggestion().action, 'advance');
});

test('a measured miss can step back one increment; unfinished rows hold targets', () => {
  const { configure, log, suggestion } = fixture();
  configure(rule('load', 10, { miss: 'stepBack' }));
  log([{ reps: '5' }, null]);
  assert.equal(suggestion().action, 'hold');
  assert.match(suggestion().note, /1 of 2 prescribed/);
  log([{ reps: '5' }, { amount: '99' }], '2026-11-19');
  assert.equal(suggestion().action, 'adjust');
  assert.equal(suggestion().changes[0].prescription.target.value, 90);
});

test('equipment identities and unilateral results gate rep and assistance progression', () => {
  const { store, row, version, configure, log, suggestion } = fixture({ measurement: 'assistance', equipment: 'machine', station: 'Station A', value: 15, counting: 'perSide' });
  configure(rule('assistance', 10));
  log([{ separateSides: true, rightReps: '7' }, {}]);
  assert.equal(suggestion().action, 'hold');
  log([{ separateSides: true, rightReps: '8', rightAmount: '16' }, {}], '2026-11-19');
  assert.equal(suggestion().action, 'hold');
  log([{ separateSides: true, rightReps: '8', rightAmount: '14' }, {}], '2026-11-20');
  assert.equal(suggestion().action, 'advance');
  assert.equal(suggestion().changes[0].prescription.target.value, 5);
  configure(rule('assistance', 20));
  assert.match(suggestion().note, /full available increment/);
  configure(rule('reps', null));
  assert.deepEqual(suggestion().changes[0].prescription.reps, { minimum: 7, maximum: 8 });
  const edited = makeDraft(version, 'kg');
  edited.exercises[0].equipmentLabel = 'Station B';
  const updated = newest(store.saveRoutine(edited, 'kg').routines[0]);
  const changedSlot = updated.exercises[0];
  assert.equal(progressionRule(store.load(), changedSlot), null);
  store.saveProgressionRule(updated.routineID, updated.id, changedSlot.id, rule('assistance', 5));
  assert.match(suggestProgression(store.load(), updated, changedSlot).note, /same exercise, equipment, and measurement/);
  assert.deepEqual(modesFor({ ...row, equipmentLabel: '' }), []);
  assert.deepEqual(modesFor({ ...row, measurement: 'setting' }), ['reps']);
});

test('duration and distance use their own units and require each logged side to hit its prescription', () => {
  for (const metric of ['duration', 'distance']) {
    const { configure, log, suggestion } = fixture({ measurement: metric, value: 25 });
    configure(rule(metric, 10));
    log([{ separateSides: true, rightAmount: '20' }, {}]);
    assert.equal(suggestion().action, 'hold');
    log([{ separateSides: true, rightAmount: '25' }, {}], '2026-11-19');
    assert.deepEqual(suggestion().changes[0].prescription.target, { kind: metric, value: 35 });
  }
});

test('deloads hold progression and edits recalculate before an explicit, versioned acceptance', () => {
  const { store, version, row, configure, log, suggestion } = fixture();
  const available = 25 * kilogramsPerPound;
  configure(rule('load', available));
  const block = store.changeSchedule({ action: 'block', name: 'Block', start: '2026-11-09', count: 2 }, '2026-11-15').programBlocks[0];
  store.changeSchedule({ action: 'blockWeek', id: block.id, date: '2026-11-16', kind: 'deload', notes: '' }, '2026-11-15');
  log([{}, {}]);
  assert.match(suggestion().note, /planned deload/);
  const workout = log([{}, {}], '2026-11-23');
  const reviewed = suggestion();
  assert.equal(reviewed.changes[0].prescription.target.value, 100 + available);
  assert.equal(store.load().routines[0].versions.length, 1);
  store.schedule(version.routineID, '2026-11-25');
  let edit = historyDraft(workout, null, workout.localDate, 'kg');
  edit.exercises[0].sets[0].input.reps = '5';
  store.saveHistory(edit, now);
  assert.throws(() => store.acceptProgression(version.routineID, version.id, row.id, reviewed), /suggestion changed/);
  assert.equal(suggestion().action, 'hold');
  edit = historyDraft(store.load().sessions.at(-1), null, workout.localDate, 'kg');
  edit.exercises[0].sets[0].input.reps = '8';
  store.saveHistory(edit, now);
  const saved = store.acceptProgression(version.routineID, version.id, row.id, suggestion());
  assert.equal(saved.routines[0].versions.length, 2);
  assert.equal(saved.schedule.at(-1).versionID, version.id);
  assert.equal(saved.sessions.at(-1).snapshot.exercises[0].work[0].target.value, 100);
  assert.equal(saved.sessions.at(-1).results[0].amount.value, 100);
  const next = newest(saved.routines[0]);
  assert.match(suggestProgression(saved, next, next.exercises[0]).note, /different targets/);
});
