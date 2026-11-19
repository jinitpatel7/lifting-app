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

test('advanced target requires two full comparable sessions and ignores special sets', () => {
  const { configure, log, suggestion } = fixture({ special: true });
  configure(rule('load', 5, { effort: 'rir', effortLimit: 2 }));
  log([{}, { reps: '8' }, { reps: '7' }, { reps: '17' }, { reps: '17', failure: true }]);
  assert.equal(suggestion().action, 'learning');
  assert.deepEqual(Object.values(suggestion().assessment), ['Reached top of range', 'Met target']);
  assert.equal(suggestion().excluded.length, 3);
  log([null, { rir: '2' }, { rir: '0' }], '2026-11-19');
  assert.match(suggestion().note, /excessive effort/);
  log([null, { rir: '' }, { rir: '3' }], '2026-11-20');
  assert.equal(suggestion().action, 'hold');
  log([null, {}, {}], '2026-11-21');
  assert.equal(suggestion().action, 'advance');
  assert.deepEqual(suggestion().changes.map(change => change.index), [0]);
  assert.equal(suggestion().changes[0].prescription.target.value, 105);
});

test('one rep is added to one set, then both sets need top-range results at the prescribed load', () => {
  const { row, configure, log, suggestion } = fixture();
  configure(rule());
  log([{}, {}], '2026-11-17');
  log([{}, { reps: '7' }]);
  const single = suggestion();
  assert.match(single.note, /Set 2.*Add one rep/);
  assert.deepEqual(single.changes[0].replacement.map(block => [block.sets, block.reps.minimum, block.target.value]), [[1, 6, 100], [1, 8, 100]]);
  log([{ amount: '105' }, {}], '2026-11-19');
  assert.equal(suggestion().action, 'hold');
  log([{}, {}], '2026-11-20');
  assert.equal(suggestion().action, 'hold');
  log([{}, {}], '2026-11-21');
  assert.equal(suggestion().changes[0].prescription.target.value, 105);
  assert.equal(row.work[0].target.value, 100);
});

test('single misses and unfinished evidence hold, then repeated difficulty can step back', () => {
  const { configure, log, suggestion } = fixture();
  configure(rule('load', 10));
  log([{ reps: '5' }, null]);
  assert.match(suggestion().note, /1 of 2 prescribed/);
  log([{ reps: '5' }, {}], '2026-11-19');
  assert.match(suggestion().note, /Hold after one miss/);
  log([{ reps: '5' }, {}], '2026-11-20');
  assert.equal(suggestion().action, 'adjust');
  assert.equal(suggestion().changes[0].prescription.target.value, 90);
  configure(rule('reps', null));
  assert.match(suggestion().note, /Remove one/);
  assert.equal(suggestion().changes[0].prescription.sets, 1);
});

test('equipment changes reset evidence and both sides must align for assistance progression', () => {
  const { store, row, version, configure, log, suggestion } = fixture({ measurement: 'assistance', equipment: 'machine', station: 'Station A', value: 15, counting: 'perSide' });
  configure(rule('assistance', 10));
  log([{ separateSides: true, rightReps: '7' }, {}]);
  assert.equal(suggestion().action, 'learning');
  log([{ separateSides: true, rightReps: '8', rightAmount: '16' }, {}], '2026-11-19');
  assert.equal(suggestion().action, 'hold');
  log([{ separateSides: true, rightReps: '8' }, {}], '2026-11-20');
  assert.equal(suggestion().action, 'hold');
  log([{}, {}], '2026-11-21');
  assert.equal(suggestion().changes[0].prescription.target.value, 5);
  assert.match(suggestion().warning, /more than 10%/);
  configure(rule('assistance', 20));
  assert.match(suggestion().note, /full available increment/);
  const edited = makeDraft(version, 'kg');
  edited.exercises[0].equipmentLabel = 'Station B';
  const updated = newest(store.saveRoutine(edited, 'kg').routines[0]);
  const changedSlot = updated.exercises[0];
  assert.equal(progressionRule(store.load(), changedSlot), null);
  assert.equal(suggestProgression(store.load(), updated, changedSlot).action, 'learning');
  assert.deepEqual(modesFor({ ...row, equipmentLabel: '' }), []);
  assert.deepEqual(modesFor({ ...row, measurement: 'setting' }), ['reps']);
});

test('duration and distance require two comparable sessions and use their own units', () => {
  for (const metric of ['duration', 'distance']) {
    const { configure, log, suggestion } = fixture({ measurement: metric, value: 25 });
    configure(rule(metric, 10));
    log([{ separateSides: true, rightAmount: '20' }, {}]);
    assert.equal(suggestion().action, 'hold');
    log([{ separateSides: true, rightAmount: '25' }, {}], '2026-11-19');
    assert.equal(suggestion().action, 'hold');
    log([{}, {}], '2026-11-20');
    assert.deepEqual(suggestion().changes[0].prescription.target, { kind: metric, value: 35 });
  }
});

test('extra sets need opt-in, a supported plateau, and room below the exercise cap', () => {
  const { configure, log, suggestion, store } = fixture();
  configure(rule('reps', null, { allowExtraSet: true, plateauSessions: 3, volumeCap: 4 }));
  for (const day of ['2026-11-18', '2026-11-19', '2026-11-20']) log([{}, {}], day);
  assert.equal(suggestion().action, 'hold');
  store.changeSchedule({ action: 'readiness', date: '2026-11-20', sleep: 4, energy: 4, soreness: 2, motivation: 4 }, '2026-11-20');
  assert.equal(suggestion().changes[0].prescription.sets, 3);
  assert.match(suggestion().note, /readiness check-in/);
  configure(rule('reps', null, { allowExtraSet: true, plateauSessions: 3, volumeCap: 2 }));
  assert.equal(suggestion().action, 'hold');
  configure(rule('reps', null));
  assert.equal(suggestion().action, 'hold');
});

test('deloads are excluded, stale reviews fail, and routine edits preserve history and schedules', () => {
  const { store, version, row, configure, log, suggestion } = fixture();
  const available = 25 * kilogramsPerPound;
  configure(rule('load', available));
  const block = store.changeSchedule({ action: 'block', name: 'Block', start: '2026-11-09', count: 2 }, '2026-11-15').programBlocks[0];
  store.changeSchedule({ action: 'blockWeek', id: block.id, date: '2026-11-16', kind: 'deload', notes: '' }, '2026-11-15');
  log([{}, {}]);
  assert.equal(suggestion().action, 'learning');
  log([{}, {}], '2026-11-23');
  assert.equal(suggestion().action, 'learning');
  const workout = log([{}, {}], '2026-11-24');
  const reviewed = suggestion();
  assert.equal(reviewed.changes[0].prescription.target.value, 100 + available);
  assert.ok(reviewed.warning);
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
  assert.equal(suggestProgression(saved, next, next.exercises[0]).action, 'learning');
});

test('dismissal persists for the evidence and an edited once decision changes exactly one workout', () => {
  const { store, version, row, configure, log, suggestion } = fixture();
  configure(rule());
  log([{}, {}], '2026-11-17');
  log([{}, {}]);
  store.acceptProgression(version.routineID, version.id, row.id, suggestion(), 'dismiss');
  assert.match(suggestion().note, /dismissed/);
  log([{}, {}], '2026-11-19');
  const edited = makeDraft(version, 'kg');
  edited.exercises[0].work[0].target = '102';
  store.acceptProgression(version.routineID, version.id, row.id, suggestion(), 'once', edited, 'kg');
  assert.match(suggestion().note, /Queued/);
  const first = store.start(version.routineID).sessions.at(-1);
  assert.equal(first.snapshot.exercises[0].work[0].target.value, 100);
  assert.equal(first.intendedPlan.exercises[0].work[0].target.value, 102);
  assert.equal(first.log.exercises[0].sets[0].plan.target.value, 102);
  store.finish(first.id, true);
  const next = store.start(version.routineID).sessions.at(-1);
  assert.equal(next.intendedPlan, null);
  assert.equal(next.log.exercises[0].sets[0].plan.target.value, 100);
  assert.equal(store.load().routines[0].versions.length, 1);
});
