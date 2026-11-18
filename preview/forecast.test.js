import assert from 'node:assert/strict';
import { test } from 'node:test';
import { historyDraft } from './history.js';
import { createRoutineStore, draftExercise, makeDraft, newest } from './routines.js';
import { captureForecasts, forecastExercise, forecastModel, scoreForecasts } from './forecast.js';

const at = (day, minute = '00') => new Date(`${day}T17:${minute}:00.000Z`);
const one = { id: 'work', sets: 1, reps: { minimum: 6, maximum: 10 }, target: { kind: 'weight', value: 100 }, structure: 'straight' };
const bench = { id: 'bench-slot', exercise: { id: 'bench', name: 'Bench Press', equipment: 'barbell' }, equipmentLabel: '',
  measurement: 'weight', basis: 'total', counting: 'total', warm: [], work: [one] };
const routine = { id: 'version', routineID: 'routine', name: 'Bench day', exercises: [bench], groups: [] };
const empty = { sessions: [], schedule: [], programBlocks: [] };

function sample(day, values = {}, plan = routine) {
  const row = plan.exercises[0];
  return {
    id: `sample-${day}`, snapshot: plan, localDate: day, startedAt: at(day).toISOString(), completedAt: at(day, '20').toISOString(),
    forecastEvidenceAt: at(day, '20').toISOString(), results: [{ id: `set-${day}`, exerciseID: row.id, purpose: 'working',
      reps: 8, amount: { kind: row.measurement, value: 100 }, ...values, at: at(day, '10').toISOString() }],
  };
}

const compute = (data, day, plan = routine, options = {}) => forecastExercise(data, plan, plan.exercises[0], { now: at(day), day, ...options });

test('as-of evidence excludes later completions, later sets and backfills unavailable at the cutoff', () => {
  const day = '2026-11-18';
  const a = sample('2026-11-10'), b = sample('2026-11-13'), c = sample('2026-11-15');
  const backfill = sample('2026-11-16', { reps: 30 });
  backfill.forecastEvidenceAt = at('2026-11-20').toISOString();
  const lateSet = sample('2026-11-17', { reps: 41 });
  lateSet.results[0].at = at('2026-11-18', '01').toISOString();
  const current = sample(day, { reps: 50 });
  const future = sample('2026-11-19', { reps: 60 });
  const overlap = { ...sample('2026-11-14'), completedAt: at('2026-11-18', '01').toISOString(), forecastEvidenceAt: undefined };
  const data = { ...empty, sessions: [a, b, c, backfill, lateSet, current, future, overlap] };
  assert.match(compute({ ...empty, sessions: [a, b] }, day).notes[0], /2 of 3/);
  assert.equal(compute({ ...empty, sessions: [a, b] }, day).status, 'learning');
  const forecast = compute(data, day);
  assert.equal(forecast.status, 'ready');
  assert.equal(forecast.model, forecastModel);
  assert.deepEqual(forecast.sources.map(source => source.id), [c.id, b.id, a.id]);
  assert.equal(forecast.ranges.reps.center, 8);
});

test('handles isolated outliers, breaks, planned deloads and equipment changes', () => {
  const days = ['2026-10-03', '2026-10-05', '2026-10-07', '2026-10-09', '2026-10-11', '2026-10-13'];
  const sessions = days.map((day, i) => sample(day, { reps: i === 5 ? 40 : 8 + i % 2 }));
  const deload = sample('2026-10-17', { reps: 4 });
  const program = { id: 'program', first: '2026-10-15', last: '2026-10-21', weeks: [{ kind: 'deload' }] };
  const data = { ...empty, sessions: [...sessions, deload], programBlocks: [program] };
  const recent = compute(data, '2026-10-18');
  assert.equal(recent.status, 'ready');
  assert.deepEqual(recent.sources.map(entry => entry.id), sessions.slice(0, 5).reverse().map(item => item.id));
  assert.equal(recent.previous.values.reps, 40);
  assert.ok(recent.notes.some(note => /outside the recent range/.test(note)));
  assert.ok(recent.notes.some(note => /Planned deloads/.test(note)));
  assert.equal(compute(data, '2026-10-18', routine, { deload: true }).status, 'paused');
  const afterBreak = compute(data, '2026-11-22');
  assert.equal(afterBreak.confidence, 'Limited confidence');
  assert.ok(afterBreak.ranges.weight.high > recent.ranges.weight.high);
  assert.ok(afterBreak.notes.some(note => /wider after that break/.test(note)));
  assert.equal(compute(data, '2027-03-30').status, 'learning');
  const different = { ...routine, exercises: [{ ...bench, equipmentLabel: 'Different bar setup' }] };
  const next = compute(data, '2026-10-18', different);
  assert.equal(next.status, 'learning');
  assert.ok(next.notes.some(note => /different equipment/.test(note)));
});

test('uses typed duration and distance outcomes, unilateral values, and machine labels', () => {
  for (const metric of ['duration', 'distance']) {
    const row = { ...bench, measurement: metric, work: [{ ...one, reps: null, target: { kind: metric, value: 30 } }] };
    const plan = { ...routine, exercises: [row] };
    const sessions = [10, 11, 12].map(i => sample(`2026-11-${i}`, {
      reps: null, amount: { kind: metric, value: 55 }, rightAmount: { kind: metric, value: i + 20 },
    }, plan));
    const forecast = compute({ ...empty, sessions }, '2026-11-18', plan);
    assert.deepEqual(Object.keys(forecast.ranges), [metric]);
    assert.equal(forecast.ranges[metric].center, 31);
  }
  const row = { ...bench, measurement: 'setting', equipmentLabel: 'Specific station', exercise: { ...bench.exercise, equipment: 'machine' },
    work: [{ ...one, target: { kind: 'setting', value: '007' } }] };
  const plan = { ...routine, exercises: [row] };
  const sessions = [10, 11, 12, 13].map(i => sample(`2026-11-${i}`, { amount: { kind: 'setting', value: i === 13 ? '7' : '007' } }, plan));
  const forecast = compute({ ...empty, sessions }, '2026-11-18', plan);
  assert.deepEqual(Object.keys(forecast.ranges), ['reps']);
  assert.equal(forecast.setting, '007');
  assert.equal(forecast.sources.length, 3);
  const unlinked = { ...routine, exercises: [{ ...row, equipmentLabel: '' }] };
  assert.equal(compute({ ...empty, sessions }, '2026-11-18', unlinked).status, 'paused');
});

test('uses warm-up rest and recorded effort only when enough earlier sessions match', () => {
  const row = { ...bench, warm: [{ ...one, id: 'warm', rest: 60 }],
    work: [{ ...one, rest: 120, effort: { kind: 'rir', value: 2 } }] };
  const plan = { ...routine, exercises: [row] };
  const sessions = [10, 11, 12, 13].map(i => {
    const day = `2026-11-${i}`;
    const session = sample(day, { rir: i === 13 ? null : 2, reps: i === 13 ? 11 : 8 }, plan);
    session.results.unshift({ id: 'warm-' + day, exerciseID: row.id, purpose: 'warm-up', at: at(day, '05').toISOString(),
      amount: { kind: 'weight', value: 40 }, reps: 10, actualRest: { measuredSeconds: 62, editedSeconds: 200 } });
    return session;
  });
  const forecast = compute({ ...empty, sessions }, '2026-11-18', plan);
  assert.equal(forecast.ranges.reps.center, 8);
  assert.equal(forecast.sources.length, 3);
  assert.ok(forecast.notes.some(note => /Matched measured rest/.test(note)));
  assert.ok(forecast.notes.some(note => /Matched recorded effort/.test(note)));
  assert.equal(forecast.previous.values.reps, 11);
});

test('forecasts and the previous-session benchmark survive relaunch and history corrections', () => {
  const cache = new Map();
  const storage = { getItem: key => cache.get(key) ?? null, setItem: (key, value) => cache.set(key, value) };
  const store = createRoutineStore(storage);
  const draft = makeDraft();
  draft.name = 'Benchmark day';
  const row = draftExercise({ id: 'bench', name: 'Bench Press', equipment: 'barbell' });
  Object.assign(row.work[0], { minimum: '6', maximum: '10', target: '100' });
  draft.exercises.push(row);
  const version = newest(store.saveRoutine(draft, 'kg').routines[0]);
  for (const [day, reps] of [['2026-11-01', 8], ['2026-11-08', 10], ['2026-11-15', 12], ['2026-11-18', 9]]) {
    store.schedule(version.routineID, day);
    const item = store.load().schedule.at(-1);
    const session = store.startScheduled(item.id, day, at(day)).sessions.at(-1);
    const setID = session.log.exercises[0].sets[0].id;
    store.logChange(session.id, { action: 'editSet', exerciseID: row.id, setID, field: 'reps', value: String(reps) }, 'kg', at(day, '01').toISOString());
    store.logChange(session.id, { action: 'complete', exerciseID: row.id, setID }, 'kg', at(day, '02').toISOString());
    store.finish(session.id, false, at(day, '30'));
  }
  const reopened = createRoutineStore(storage);
  const saved = reopened.load().sessions.at(-1);
  const [forecast] = saved.performanceForecasts;
  assert.equal(forecast.status, 'ready');
  assert.equal(forecast.issuedAt, at('2026-11-18').toISOString());
  assert.equal(forecast.ranges.reps.center, 10);
  assert.equal(forecast.previous.values.reps, 12);
  let [score] = scoreForecasts(reopened.load());
  assert.deepEqual(score.metrics.reps, { forecastError: 1, previousError: 3, inside: 1 });

  const source = reopened.load().sessions.at(-2);
  const correction = historyDraft(source, version, source.localDate, 'kg');
  correction.exercises[0].sets[0].input.reps = '15';
  reopened.saveHistory(correction, at('2026-11-20'));
  assert.deepEqual(reopened.load().sessions.at(-1).performanceForecasts, [forecast]);
  [score] = scoreForecasts(reopened.load());
  assert.equal(score.metrics.reps.previousError, 3);
  assert.equal(compute(reopened.load(), '2026-11-19', version).sources.some(item => item.id === source.id), false);
  assert.equal(compute(reopened.load(), '2026-11-21', version).sources.some(item => item.id === source.id), true);
  assert.equal(reopened.load().routines[0].versions.length, 1);
});

test('captures a pre-result context revision when exercise order changes', () => {
  const second = { ...bench, id: 'second-slot', exercise: { id: 'overhead', name: 'Overhead Press', equipment: 'barbell' } };
  const snapshot = { ...routine, exercises: [bench, second] };
  const day = '2026-11-18';
  const session = { ...sample(day, {}, snapshot), completedAt: null, results: [] };
  captureForecasts(empty, session, at(day));
  session.override = { ...snapshot, exercises: [second, bench] };
  captureForecasts(empty, session, at(day, '01'));
  assert.deepEqual(session.performanceForecasts.filter(item => item.rowID === bench.id).map(item => [item.revision, item.context.order]),
    [[1, 'first'], [2, 'later']]);
  session.forecastPerformedSlots = [bench.id];
  session.override = null;
  captureForecasts(empty, session, at(day, '02'));
  assert.equal(session.performanceForecasts.filter(item => item.rowID === bench.id).length, 2);
});

test('explains a meaningful shift against the previous issued forecast', () => {
  const earlier = ['2026-11-01', '2026-11-02', '2026-11-03'].map(day => sample(day, { reps: 8 }));
  const issued = compute({ ...empty, sessions: earlier }, '2026-11-05');
  assert.equal(issued.ranges.reps.center, 8);
  const training = ['2026-11-05', '2026-11-07', '2026-11-09', '2026-11-11', '2026-11-13', '2026-11-15'].map(day => sample(day, { reps: 10 }));
  training[0].performanceForecasts = [issued];
  const refreshed = compute({ ...empty, sessions: [...earlier, ...training] }, '2026-11-18');
  assert.equal(refreshed.priorRanges.reps.center, 8);
  assert.equal(refreshed.ranges.reps.center, 10);
  assert.ok(refreshed.notes.some(note => /typical estimate changed.*recent comparable results changed/.test(note)));
});
