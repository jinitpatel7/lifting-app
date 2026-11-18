import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createRoutineStore, draftExercise, makeDraft, newest } from './routines.js';
import { dayDistance, recentMuscles, scheduleEntries, scheduleWindow } from './schedule.js';

const local = key => new Date(...key.split('-').map((part, index) => Number(part) - (index === 1 ? 1 : 0)), 12);

function fixture() {
  const values = new Map();
  const storage = { getItem: key => values.get(key) ?? null, setItem: (key, value) => values.set(key, value) };
  const store = createRoutineStore(storage);
  const addRoutine = (name, muscle) => {
    const draft = makeDraft();
    draft.name = name;
    const exercise = draftExercise({ id: crypto.randomUUID(), name, primary: [muscle], secondary: ['core'] });
    Object.assign(exercise.work[0], { minimum: '5', maximum: '5' });
    draft.exercises.push(exercise);
    return newest(store.saveRoutine(draft, 'kg').routines.at(-1));
  };
  const first = addRoutine('Upper', 'chest');
  const second = addRoutine('Lower', 'quads');
  const entries = (dates, now) => scheduleEntries(store.load(), dates, now);
  const change = (action, args, today = '2026-11-18') => store.changeSchedule({ action, ...args }, today);
  return { store, storage, first, second, entries, change };
}

test('calendar days stay intact across daylight saving and respect custom and rolling starts', () => {
  assert.deepEqual(scheduleWindow('2026-11-01', { mode: 'week', weekStart: 4 }),
    ['2026-10-29', '2026-10-30', '2026-10-31', '2026-11-01', '2026-11-02', '2026-11-03', '2026-11-04']);
  assert.deepEqual(scheduleWindow('2026-03-07', { mode: 'rolling', weekStart: 1 }),
    ['2026-03-07', '2026-03-08', '2026-03-09', '2026-03-10', '2026-03-11', '2026-03-12', '2026-03-13']);
  assert.equal(dayDistance('2026-03-07', '2026-03-09'), 2);
});

test('weekday instances move and skip while the recurring rule and pinned routine survive reopening', () => {
  const { store, storage, first, entries, change } = fixture();
  change('settings', { weekStart: 5, mode: 'rolling' });
  change('weekday', { weekday: 3, start: '2026-11-18', versionID: first.id });
  const [source] = entries(['2026-11-18'], '2026-11-18');
  change('move', { key: source.key, date: source.date, destination: '2026-11-20' });
  const [origin, destination, next] = entries(['2026-11-18', '2026-11-20', '2026-11-25'], '2026-11-18');
  assert.deepEqual([origin.status, origin.destination, destination.status, next.status], ['moved', '2026-11-20', 'rescheduled', 'planned']);
  assert.equal(next.versionID, first.id);
  change('skip', { key: destination.key, date: destination.date });
  const restored = createRoutineStore(storage).load();
  assert.equal(restored.schedule[0].skippedOn, '2026-11-18');
  assert.deepEqual(restored.scheduleSettings, { weekStart: 5, mode: 'rolling' });
  assert.equal(entries(['2026-11-20'], '2026-11-20')[0].status, 'skipped');
  assert.throws(() => store.startScheduled(destination.key, destination.date, local(destination.date)), /no longer/);
  assert.equal(restored.routines.length, 2);
  assert.throws(() => store.schedule(first.routineID, '2026-02-30'), /date/);
});

test('missed rotation dates hold the step, and only explicit skip or a finished workout with sets advances it', () => {
  const { store, first, second, entries, change } = fixture();
  const start = '2026-11-18';
  change('rotation', { start, interval: 1, versions: [first.id, second.id] });
  const [missed, current] = entries([start, '2026-11-19', '2026-11-20'], '2026-11-19');
  assert.deepEqual([missed.status, missed.versionID, current.status, current.versionID], ['missed', first.id, 'planned', first.id]);
  assert.throws(() => change('skip', { key: missed.key, date: missed.date }, current.date), /no longer/);
  change('skip', { key: current.key, date: current.date }, current.date);
  const [secondStep] = entries(['2026-11-20'], current.date);
  assert.equal(secondStep.versionID, second.id);
  change('move', { key: secondStep.key, date: secondStep.date, destination: '2026-11-22' }, current.date);
  assert.equal(entries(['2026-11-21'], '2026-11-21').length, 0);
  const [moved] = entries(['2026-11-22'], '2026-11-22');
  const now = local(moved.date);
  const training = store.startScheduled(moved.key, moved.date, now).sessions.at(-1);
  const exercise = training.log.exercises[0];
  store.logChange(training.id, { action: 'complete', exerciseID: exercise.id, setID: exercise.sets[0].id }, 'kg', now.toISOString());
  assert.equal(entries(['2026-11-22'], moved.date)[0].status, 'active');
  store.finish(training.id, true, now);
  const [resolved, wrapped] = entries(['2026-11-22', '2026-11-23'], moved.date);
  assert.equal(resolved.status, 'completed');
  assert.equal(wrapped.versionID, first.id);
  const noSets = store.startScheduled(wrapped.key, wrapped.date, local(wrapped.date)).sessions.at(-1);
  store.finish(noSets.id, true, local(wrapped.date));
  assert.equal(entries(['2026-11-24'], '2026-11-24')[0].versionID, first.id);
});

test('program deload weeks attach user notes and pinned versions, and readiness never changes targets', () => {
  const { store, first, entries, change } = fixture();
  const deload = makeDraft(first);
  deload.exercises[0].work[0].minimum = '3';
  deload.exercises[0].work[0].maximum = '3';
  const chosen = newest(store.saveRoutine(deload, 'kg').routines[0]);
  const block = change('block', { name: 'November training', start: '2026-11-18', count: 3 }).programBlocks[0];
  assert.equal(block.last, '2026-12-08');
  change('blockWeek', { id: block.id, date: '2026-11-25', kind: 'deload', notes: 'Reduce reps' });
  change('blockSession', { id: block.id, date: '2026-11-25', versionID: chosen.id });
  const another = makeDraft(chosen);
  another.exercises[0].work[0].minimum = '6';
  another.exercises[0].work[0].maximum = '6';
  store.saveRoutine(another, 'kg');
  change('readiness', { date: '2026-11-18', soreness: 5, sleep: 1, energy: 1, motivation: 2 });
  const saved = store.load();
  assert.deepEqual(saved.programBlocks[0].weeks[1], { kind: 'deload', notes: 'Reduce reps' });
  const id = saved.readiness[0].id;
  change('readiness', { date: '2026-11-18', soreness: 3, sleep: 4, energy: 3, motivation: 4 });
  assert.equal(store.load().readiness[0].id, id);
  assert.throws(() => change('readiness', { date: '2026-11-19', soreness: 1, sleep: 2, energy: 3, motivation: 4 }), /local date/);
  const [entry] = entries(['2026-11-25'], '2026-11-25');
  const session = store.startScheduled(entry.key, entry.date, local(entry.date)).sessions[0];
  assert.equal(session.snapshot.id, chosen.id);
  assert.equal(session.snapshot.exercises[0].work[0].reps.minimum, 3);
});

test('recent muscles use the local session date and only slots with performed work', () => {
  const { store, first } = fixture();
  const date = '2026-11-01';
  const plan = store.schedule(first.routineID, date).schedule[0];
  const session = store.startScheduled(plan.id, date, local(date)).sessions[0];
  const noLibrary = () => null;
  assert.deepEqual(recentMuscles(store.load().sessions, date, noLibrary), {});
  const exercise = session.log.exercises[0];
  store.logChange(session.id, { action: 'complete', exerciseID: exercise.id, setID: exercise.sets[0].id }, 'kg', local(date).toISOString());
  assert.deepEqual(recentMuscles(store.load().sessions, '2026-11-02', noLibrary),
    { chest: { date, days: 1 }, core: { date, days: 1 } });
  assert.deepEqual(recentMuscles(store.load().sessions, '2026-10-31', noLibrary), {});
});
