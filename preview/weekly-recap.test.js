import assert from 'node:assert/strict';
import { test } from 'node:test';
import { historyDraft } from './history.js';
import { blankSet, createRoutineStore, draftExercise, makeDraft, newest } from './routines.js';
import { weeklyRecap } from './weekly-recap.js';
import { workoutEnergy } from './workout-energy.js';
import { dailyWorkoutScore, prescribedTargetCredit, workoutScore } from './workout-score.js';

const today = '2026-11-20';
const date = (day, minute = '00') => new Date(`${day}T17:${minute}:00Z`);
const weight = (day, kilograms) => ({ day, kilograms });
const readings = Object.fromEntries([
  weight('2026-11-15', 82), weight('2026-11-17', 80), weight('2026-11-20', 78), weight('2026-11-21', 150),
].map(reading => [reading.day, reading]));

function fixture() {
  const data = new Map();
  const storage = { getItem: key => data.get(key) ?? null, setItem: (key, value) => data.set(key, value) };
  const store = createRoutineStore(storage);
  const draft = makeDraft();
  draft.name = 'Strength';
  const row = draftExercise({ id: 'bench', name: 'Bench press', equipment: 'barbell', primary: ['chest'], secondary: ['triceps', 'chest'] });
  Object.assign(row.work[0], { minimum: '5', target: '80' });
  row.warm.push({ ...blankSet(), minimum: '5', target: '30' });
  draft.exercises.push(row);
  const version = newest(store.saveRoutine(draft, 'kg').routines[0]);
  function schedule(day) {
    store.schedule(version.routineID, day);
    return store.load().schedule.at(-1).id;
  }
  function log(day, load, done = true) {
    const id = schedule(day);
    const session = store.startScheduled(id, day, date(day)).sessions.at(-1);
    const [warm, work] = session.log.exercises[0].sets;
    const complete = (set, minute) => store.logChange(session.id, { action: 'complete', exerciseID: row.id, setID: set.id }, 'kg', date(day, minute).toISOString());
    complete(warm, '01');
    if (done) {
      store.logChange(session.id, { action: 'editSet', exerciseID: row.id, setID: work.id, field: 'amount', value: String(load) }, 'kg', date(day, '02').toISOString());
      complete(work, '03');
    }
    store.finish(session.id, !done, date(day, '30'));
    return store.load().sessions.at(-1);
  }
  return { store, version, schedule, log, storage };
}

test('recaps separate calendar adherence, incomplete work, logged volume, deloads and pinned next targets', () => {
  const { store, version, schedule, log } = fixture();
  log('2026-11-10', 80);
  const moved = schedule('2026-11-16');
  store.changeSchedule({ action: 'move', key: moved, date: '2026-11-16', destination: '2026-11-26' }, today);
  log('2026-11-17', 90);
  log('2026-11-18', 0, false);
  const skipped = schedule('2026-11-19');
  store.changeSchedule({ action: 'skip', key: skipped, date: '2026-11-19' }, today);
  const block = store.changeSchedule({ action: 'block', name: 'Base phase', start: '2026-11-20', count: 2 }, today).programBlocks[0];
  store.changeSchedule({ action: 'blockWeek', id: block.id, date: today, kind: 'deload', notes: '' }, today);
  store.changeSchedule({ action: 'blockSession', id: block.id, date: '2026-11-21', versionID: version.id }, today);
  const manual = historyDraft(null, version, '2026-11-19', 'kg');
  manual.exercises[0].sets.forEach(set => {
    set.status = 'completed'; Object.assign(set.input, { amount: '30', reps: '5' });
  });
  store.saveHistory(manual, date(today));
  const edited = makeDraft(version, 'kg');
  edited.exercises[0].work[0].target = '85';
  store.saveRoutine(edited, 'kg');
  const report = weeklyRecap(store.load(), readings, today, undefined, today);
  assert.deepEqual(report.jobs, { planned: 4, scheduled: 1, unscheduled: 1, incomplete: 1, scheduledIncomplete: 1,
    skipped: 1, missed: 0, pending: 1, deload: 1 });
  assert.deepEqual(report.deloads, ['Base phase']);
  assert.deepEqual(report.training.muscles.get('chest'), { working: { direct: 2, indirect: 0 }, 'warm-up': { direct: 3, indirect: 0 } });
  assert.equal(report.training.muscles.get('triceps').working.indirect, 2);
  assert.equal(report.training.totals.volume, 600);
  assert.equal(report.records[0].kind, 'Heaviest load');
  assert.equal(report.records[0].effort.load, 90);
  assert.equal(report.changes[0].previous.values.weight, 90);
  assert.equal(report.changes[0].current.values.weight, 30);
  assert.equal(report.weight.initial.smoothed, 81);
  assert.equal(report.weight.latest.smoothed, 80);
  assert.equal(report.next.entry.date, '2026-11-21');
  assert.equal(report.next.plan.id, version.id);
  assert.equal(report.next.plan.exercises[0].work[0].target.value, 80);
});

test('history corrections recalculate records, volume and comparison while preserving stored forecasts and calorie inputs', () => {
  const { store, version, log, storage } = fixture();
  log('2026-11-10', 80);
  const current = log('2026-11-17', 90);
  store.saveWorkoutEnergy(current.id, { activity: 'variedResistance', minutes: 30 });
  assert.equal(weeklyRecap(store.load(), {}, today, undefined, today).energy.count, 0);
  assert.equal(weeklyRecap(store.load(), readings, today, undefined, today).energy.total, 140);
  assert.equal(weeklyRecap(store.load(), readings, today, undefined, today).records.length, 1);
  const correction = historyDraft(store.load().sessions.at(-1), version, current.localDate, 'kg');
  correction.exercises[0].sets[1].input.amount = '75';
  store.saveHistory(correction, date(today));

  const reopened = createRoutineStore(storage).load();
  assert.deepEqual(reopened.sessions.at(-1).performanceForecasts, current.performanceForecasts);
  assert.deepEqual(reopened.sessions.at(-1).energyInput, { activity: 'variedResistance', minutes: 30 });
  const report = weeklyRecap(reopened, readings, today, undefined, today);
  assert.equal(report.records.length, 0);
  assert.equal(report.training.totals.volume, 375);
  assert.equal(report.changes[0].previous.values.weight, 80);
  assert.equal(report.changes[0].current.values.weight, 75);
  assert.equal(report.jobs.scheduled, 1);
  assert.equal(report.energy.total, 140);
});

test('calories stay unavailable without explicit inputs and are independent of lifted weight', () => {
  assert.equal(workoutEnergy({ activity: 'variedResistance', minutes: 30 }, 80).kilocalories, 140);
  assert.equal(workoutEnergy({ activity: 'vigorousLifting', minutes: 30 }, 80).kilocalories, 240);
  assert.equal(workoutEnergy({ activity: 'squatDeadlift', minutes: 30 }, 80).code, '02052');
  assert.equal(workoutEnergy({ activity: 'squatDeadlift', minutes: 30 }), null);
  assert.equal(workoutEnergy({ activity: '', minutes: 30 }, 80), null);
  assert.equal(workoutEnergy({ activity: 'squatDeadlift', minutes: 0 }, 80), null);
  assert.equal(workoutEnergy({ activity: 'squatDeadlift', minutes: 1441 }, 80), null);
  assert.equal(workoutEnergy(null, 80), null);
});

test('a corrected incomplete session counts as complete and completed deloads remain valid work', () => {
  const { store, version, log } = fixture();
  log('2026-11-10', 80);
  const incomplete = log('2026-11-17', 0, false);
  const block = store.changeSchedule({ action: 'block', name: 'Deload phase', start: '2026-11-18', count: 2 }, today).programBlocks[0];
  store.changeSchedule({ action: 'blockWeek', id: block.id, date: today, kind: 'deload', notes: '' }, today);
  log('2026-11-19', 45);
  const before = weeklyRecap(store.load(), {}, today, undefined, today);
  assert.equal(before.jobs.scheduled, 1);
  assert.equal(before.jobs.deload, 1);
  assert.equal(before.jobs.scheduledIncomplete, 1);
  const correction = historyDraft(incomplete, version, incomplete.localDate, 'kg');
  correction.incomplete = false;
  const set = correction.exercises[0].sets[1];
  set.status = 'completed'; Object.assign(set.input, { amount: '75', reps: '5' });
  store.saveHistory(correction, date(today));
  const after = weeklyRecap(store.load(), {}, today, undefined, today);
  assert.equal(after.jobs.scheduled, 2);
  assert.equal(after.jobs.incomplete, 0);
  assert.equal(after.jobs.deload, 1);
  assert.equal(after.training.totals.volume, 600);
  assert.equal(after.changes[0].current.day, '2026-11-17');
});

test('the scoring policy uses saved workout evidence and accepts a separate policy', () => {
  const { store, log } = fixture();
  const session = log('2026-11-17', 90);
  assert.equal(dailyWorkoutScore(today, [], []).status, 'unavailable');
  const result = dailyWorkoutScore(session.localDate, [session], store.load().schedule);
  assert.equal(result.score, 100);
  assert.equal(result.components[2].points, null);
  const draft = historyDraft(session, null, session.localDate, 'kg');
  draft.exercises[0].sets[1].input.amount = '40';
  store.saveHistory(draft, date(today));
  assert.equal(workoutScore(store.load().sessions[0]).score, 85);
  assert.equal(workoutScore(session, store.saveScoreWeights({ completion: 0, targets: 100, effort: 0 }).scoreWeights).score, 100);
  const custom = dailyWorkoutScore(today, [], [], { evaluate: context => context.day });
  assert.equal(custom, today);
});

test('score excludes extra and warm-up rows, counts missing prescribed work, and tapers effort', () => {
  const { version, log } = fixture();
  const session = structuredClone(log('2026-11-17', 80));
  const row = session.snapshot.exercises[0];
  const first = session.results[1];
  row.work[0] = { ...row.work[0], sets: 2, reps: { minimum: 5, maximum: 8 }, effort: { kind: 'rir', value: 3 } };
  first.reps = 7;
  first.rir = 1;
  session.scoreSlots[row.id].push('missing');
  session.log.exercises[0].sets.push({ id: 'extra', purpose: 'working', plan: row.work[0], status: 'completed' });
  session.results.push({ ...first, id: 'extra', reps: 20, rir: 3 });
  const scored = workoutScore(session);
  assert.equal(scored.score, 65);
  assert.match(scored.components[0].detail, /1 of 2/);
  assert.equal(scored.components[2].points, 10.000000000000002);
  session.snapshot.revision = 0;
  assert.equal(workoutScore(session).status, 'unavailable');
  assert.equal(version.revision, 1);
});

test('target scoring uses the limiting side and preserves measurement direction and type', () => {
  const amount = (kind, value) => ({ kind, value });
  const options = [
    [{ reps: 8, rightReps: 4, amount: amount('weight', 100) }, { reps: { minimum: 5 }, target: amount('weight', 50) }, 0.8],
    [{ amount: amount('assistance', 20), rightAmount: amount('assistance', 40) }, { target: amount('assistance', 20) }, 0.5],
    [{ amount: amount('duration', 15) }, { target: amount('duration', 30) }, 0.5],
    [{ amount: amount('distance', 110) }, { target: amount('distance', 100) }, 1],
    [{ amount: amount('weight', 4) }, { target: amount('setting', '4') }, 0],
  ];
  for (const [result, plan, expected] of options) assert.equal(prescribedTargetCredit(result, plan), expected);
});

test('a workout-only warm-up edit keeps the original working slot scoreable', () => {
  const { store, version, schedule } = fixture();
  const day = '2026-11-20';
  const session = store.startScheduled(schedule(day), day, date(day)).sessions.at(-1);
  const row = version.exercises[0];
  const original = session.scoreSlots[row.id][0];
  const draft = makeDraft(version, 'kg');
  draft.exercises[0].warm.push({ ...blankSet(), minimum: '3', target: '60' });
  const edited = store.editSession(session.id, draft, 'kg').sessions.at(-1);
  assert.deepEqual(edited.log.exercises[0].sets.map(set => set.purpose), ['warm-up', 'warm-up', 'working']);
  assert.equal(edited.log.exercises[0].sets.at(-1).id, original);
  store.logChange(session.id, { action: 'complete', exerciseID: row.id, setID: original }, 'kg', date(day, '02').toISOString());
  const saved = store.finish(session.id, true, date(day, '03')).sessions.at(-1);
  assert.equal(workoutScore(saved).score, 100);
});

test('the recap follows the configured start, does not look ahead in history and identifies a distant upcoming weekday plan', () => {
  const { store, version, log } = fixture();
  log('2026-11-17', 90);
  store.changeSchedule({ action: 'settings', weekStart: 0, mode: 'rolling' }, today);
  store.changeSchedule({ action: 'weekday', weekday: 1, versionID: version.id, start: '2027-03-03' }, today);
  const report = weeklyRecap(store.load(), {}, '2026-11-12', undefined, today);
  assert.equal(report.first, '2026-11-08');
  assert.equal(report.last, '2026-11-14');
  assert.equal(report.training.totals.volume, null);
  assert.equal(report.records.length, 0);
  assert.equal(report.next.entry.date, '2027-03-08');
});
