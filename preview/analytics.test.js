import assert from 'node:assert/strict';
import { test } from 'node:test';
import { analyticsDefaults, estimatedMax, exerciseAnalytics, weeklyAnalytics } from './analytics.js';
import { compareSessions, sessionMetrics, setVolume } from './history.js';
import { createRoutineStore } from './routines.js';

const bar = { id: 'bench', exercise: { id: 'press', name: 'Press', equipment: 'barbell', primary: ['chest'], secondary: ['triceps', 'chest'] },
  counting: 'total', basis: 'total', measurement: 'weight', equipmentLabel: '', warm: [{ sets: 1 }], work: [{ sets: 3 }] };
const load = (row, value, reps, extra) => ({
  id: crypto.randomUUID(), exerciseID: row.id, purpose: 'working', amount: { kind: row.measurement, value }, reps, ...extra,
});
const version = (exercises, id = 'version-one') => ({ id, routineID: 'upper', revision: 1, exercises, groups: [] });
function session(date, exercises, results, options = {}) {
  const { versionID, ...rest } = options;
  return { id: crypto.randomUUID(), localDate: date, startedAt: date + 'T13:00:00Z', completedAt: date + 'T14:00:00Z',
    snapshot: version(exercises, versionID), results, ...rest };
}
const database = (sessions, extra) => ({ sessions, schedule: [], routines: [], programBlocks: [], ...extra });

test('varied sets sum volume and reps once and keep working records from warm-ups', () => {
  const first = session('2026-11-01', [bar], [load(bar, 100, 5), load(bar, 80, 8), load(bar, 50, 10, { purpose: 'warm-up' })]);
  const second = session('2026-11-03', [bar], [load(bar, 100, 7), load(bar, 95, 5)]);
  const db = database([second, first]);
  const [chart] = exerciseAnalytics(db);
  assert.deepEqual(chart.points.map(point => point.values.volume), [1140, 1175]);
  assert.deepEqual(chart.points.map(point => point.values.reps), [13, 12]);
  assert.equal(chart.points[0].values.load, 100);
  assert.ok(Math.abs(chart.points[0].values.estimate - 116.6666666667) < 1e-6);
  assert.equal(chart.records.heaviest.reps, 7);
  assert.equal(chart.records.byLoad.find(entry => entry.load === 100).reps, 7);
  assert.equal(chart.records.byReps.find(entry => entry.reps === 5).load, 100);
  const [warmUps] = exerciseAnalytics(db, {}, 'warm-up');
  assert.equal(warmUps.points[0].values.volume, 500);
  assert.equal(warmUps.points[0].values.estimate, undefined);
  assert.equal(estimatedMax(bar, load(bar, 112, 1)), 112);
  assert.equal(estimatedMax(bar, load(bar, 80, 11)), null);
});

test('unilateral records keep the load and reps paired by side', () => {
  const dumbbell = { ...bar, basis: 'perDumbbell', counting: 'perSide', exercise: { ...bar.exercise, equipment: 'dumbbell' } };
  const asymmetric = load(dumbbell, 20, 8, { rightReps: 10, rightAmount: { kind: 'weight', value: 15 } });
  const onlyRight = load(dumbbell, 30, 0, { rightReps: 4, rightAmount: { kind: 'weight', value: 17 } });
  const [trend] = exerciseAnalytics(database([session('2026-11-03', [dumbbell], [asymmetric, onlyRight])]));
  assert.equal(trend.points[0].values.volume, 378);
  assert.equal(trend.points[0].values.reps, 22);
  assert.equal(trend.points[0].values.load, 20);
  assert.equal(trend.points[0].values.estimate, undefined);
  assert.deepEqual(trend.records.byReps.map(({ load, reps, side }) => [load, reps, side]), [[17, 4, 'Right'], [20, 8, 'Left'], [15, 10, 'Right']]);
  assert.equal(setVolume(load(dumbbell, 20, 8), { ...dumbbell, counting: 'total' }), 320);
  assert.equal(setVolume(load(dumbbell, 20, 8), dumbbell), 320);
  assert.equal(setVolume(load(dumbbell, 20, 0, { rightReps: 8 }), dumbbell), 160);
});

test('station identities partition charts, comparisons, and records, and settings stay out of weight', () => {
  const stationA = { ...bar, exercise: { ...bar.exercise, equipment: 'machine' }, equipmentLabel: 'A' };
  const stationB = { ...stationA, equipmentLabel: 'B' };
  const unknown = { ...stationA, equipmentLabel: '' };
  const setting = { ...stationA, measurement: 'setting' };
  const first = session('2026-11-01', [stationA], [load(stationA, 70, 5)]);
  const second = session('2026-11-03', [stationB], [load(stationB, 90, 5)], { versionID: 'version-two' });
  const third = session('2026-11-04', [unknown], [load(unknown, 95, 5)]);
  const fourth = session('2026-11-05', [unknown], [load(unknown, 100, 6)]);
  const fifth = session('2026-11-06', [setting], [load(setting, '8', 5)]);
  const charts = exerciseAnalytics(database([first, second, third, fourth, fifth]));
  assert.equal(charts.length, 5);
  const newest = charts.find(chart => chart.row.equipmentLabel === 'B');
  assert.equal(newest.points[0].values.volume, 450);
  assert.ok(newest.points[0].events.includes('Equipment changed'));
  assert.ok(newest.points[0].events.includes('Routine version changed'));
  assert.equal(newest.points[0].values.estimate, undefined);
  assert.equal(sessionMetrics(second).volume, null);
  assert.equal(compareSessions(second, first, 'press').volumeChange, null);
  assert.equal(compareSessions(fourth, third, 'press').repsChange, null);
  const dial = charts.find(chart => chart.row.measurement === 'setting');
  assert.equal(dial.points[0].values.load, undefined);
  assert.equal(dial.points[0].values.volume, undefined);
  assert.equal(dial.points[0].values.reps, 5);
  assert.equal(dial.records.heaviest, undefined);
});

test('weekly counts use calendar plans once and tally each role and set purpose separately', () => {
  const duration = { ...bar, id: 'plank', exercise: { id: 'plank', name: 'Plank', primary: ['core'], secondary: [] },
    measurement: 'duration', warm: [], work: [{ sets: 1 }] };
  const distance = { ...duration, id: 'walk', exercise: { ...duration.exercise, id: 'walk', name: 'Walk' }, measurement: 'distance' };
  const trained = session('2026-11-18', [bar, duration, distance], [
    load(bar, 90, 6), load(bar, 65, 4, { purpose: 'warm-up' }),
    load(duration, 20, null, { rightAmount: { kind: 'duration', value: 15 } }),
    load(distance, 240, null),
  ], { scheduleID: 'done' });
  const db = database([trained], {
    scheduleSettings: { weekStart: 2, mode: 'rolling' },
    schedule: [{ id: 'done', versionID: 'version-one', date: '2026-11-18' },
      { id: 'moved', versionID: 'version-one', date: '2026-11-21', moves: ['2026-11-19'] }],
    routines: [{ id: 'upper', versions: [trained.snapshot] }],
  });
  const report = weeklyAnalytics(db, '2026-11-18', {}, undefined, '2026-11-18');
  assert.equal(report.days[0], '2026-11-17');
  assert.deepEqual(report.planned, { working: 10, 'warm-up': 2 });
  assert.deepEqual(report.performed, { working: 3, 'warm-up': 1 });
  assert.deepEqual(report.muscles.get('chest'), { working: { direct: 1, indirect: 0 }, 'warm-up': { direct: 1, indirect: 0 } });
  assert.deepEqual(report.muscles.get('triceps'), { working: { direct: 0, indirect: 1 }, 'warm-up': { direct: 0, indirect: 1 } });
  assert.deepEqual(report.totals, { workouts: 1, volume: 540, duration: 35, distance: 240 });
  const trends = exerciseAnalytics(db);
  assert.equal(trends.find(chart => chart.row.id === 'plank').points[0].values.duration, 35);
  assert.equal(trends.find(chart => chart.row.id === 'walk').points[0].values.distance, 240);
});

test('plateau rules honor thresholds, deloads, and resets after gaps and program boundaries', () => {
  const date = day => '2026-11-' + String(day).padStart(2, '0');
  const days = [1, 3, 5, 7].map(day => session(date(day), [bar], [load(bar, 100, 5)]));
  const block = { id: 'fall', first: date(1), last: date(23), name: 'Strength', weeks: { 1: { kind: 'deload' } } };
  const db = database(days, { programBlocks: [block] });
  assert.deepEqual(exerciseAnalytics(db)[0].plateau, { state: 'flag', change: 0, count: 4 });
  assert.equal(exerciseAnalytics(db, {}, 'working', { ...analyticsDefaults, plateauEnabled: false })[0].plateau, null);
  days.at(-1).results[0] = load(bar, 103, 5);
  assert.equal(exerciseAnalytics(db)[0].plateau, null);
  assert.equal(exerciseAnalytics(db, {}, 'working', { ...analyticsDefaults, plateauPercent: 4 })[0].plateau.state, 'flag');
  days.push(session(date(8), [bar], [load(bar, 70, 5)]));
  const [deload] = exerciseAnalytics(db);
  assert.deepEqual(deload.plateau, { state: 'deload' });
  assert.ok(deload.points.at(-1).events.includes('Deload · Strength'));
  days.push(session(date(24), [bar], [load(bar, 101, 5)]));
  const [after] = exerciseAnalytics(db);
  assert.equal(after.plateau, null);
  assert.ok(after.points.at(-1).events.includes('Program ended'));
  assert.ok(after.points.at(-1).events.includes('Training break · 16 days between logs'));
});

test('analytics preferences persist and validate without writing invalid settings', () => {
  const records = new Map();
  const files = { getItem: key => records.get(key) ?? null, setItem: (key, value) => records.set(key, value) };
  const store = createRoutineStore(files);
  const settings = { ...analyticsDefaults, visible: ['reps', 'volume'], dashboard: ['plan', 'distance'], plateauSessions: 6 };
  store.saveAnalytics(settings);
  assert.throws(() => store.saveAnalytics({ ...settings, plateauPercent: 0 }), /threshold/);
  assert.deepEqual(createRoutineStore(files).load().analyticsSettings, settings);
});
