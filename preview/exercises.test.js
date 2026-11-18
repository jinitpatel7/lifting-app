import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { createExerciseStore, filterExercises, renderSearchResults, substitutions } from './exercises.js';
import { muscleInvolvement, renderMuscleMap } from './muscle-map.js';

const resource = name => JSON.parse(readFileSync(new URL(`../ios/Setline/Resources/${name}`, import.meta.url), 'utf8'));
const catalog = resource('ExerciseCatalog.json');
const anatomy = resource('MuscleRegions.json');
const search = { name: '', collection: 'all', equipment: '', muscle: '', pattern: '' };
const empty = { custom: [], preferences: {} };

test('combines name, muscle, equipment and movement filters', () => {
  const results = filterExercises(catalog, empty, { ...search, name: 'BENCH press', muscle: 'chest', equipment: 'dumbbell', pattern: 'horizontalPush' });
  assert.deepEqual(results.map(exercise => exercise.name), ['Dumbbell Bench Press']);
  assert.match(renderSearchResults([], empty, search), /Your exercise library is empty/);
  assert.match(renderSearchResults(catalog, empty, { ...search, collection: 'custom' }), /No custom exercises yet/);
});

test('persists custom edits and preferences while keeping distinct variation IDs', () => {
  const values = new Map();
  const storage = { getItem: key => values.get(key) ?? null, setItem: (key, value) => values.set(key, value) };
  const store = createExerciseStore(storage);
  const first = { id: crypto.randomUUID(), name: 'Gym A press', equipment: 'machine', pattern: 'horizontalPush', variation: 'Machine A', primary: ['chest'], secondary: [] };
  store.saveExercise(first, false);
  store.togglePreference(first.id, 'favorite');
  store.saveExercise({ ...first, name: 'Renamed press', machineSetup: { seat: '007' } }, true);
  assert.throws(() => store.saveExercise({ ...first, variation: 'Machine B' }, true));
  const second = { ...first, id: crypto.randomUUID(), variation: 'Machine B' };
  store.saveExercise(second, false);
  store.togglePreference(second.id, 'excluded');
  const reopened = createExerciseStore(storage).load();
  assert.equal(reopened.custom[0].id, first.id);
  assert.equal(reopened.custom[0].machineSetup.seat, '007');
  assert.equal(filterExercises(catalog, reopened, { ...search, collection: 'favorites' })[0].name, 'Renamed press');
  assert.equal(filterExercises(catalog, reopened, { ...search, collection: 'excluded' })[0].id, second.id);
});

test('browses shared-muscle alternatives with only selected equipment and skips exclusions', () => {
  const press = catalog.find(exercise => exercise.sampleID === 'bench-press');
  const available = new Set(['dumbbell', 'bodyweight']);
  const row = catalog.find(exercise => exercise.name === 'One-Arm Dumbbell Row');
  const results = substitutions(press, catalog, available, { [row.id]: { excluded: true } });
  assert.deepEqual(results.map(exercise => exercise.name), ['Dumbbell Bench Press', 'Push-Up']);
  assert.deepEqual(substitutions(press, catalog, new Set(), {}), []);
});

test('maps workout targets with primary precedence and exposes selected region details', () => {
  const workout = resource('SampleData.json').routines[0];
  const targets = muscleInvolvement(catalog.filter(exercise => workout.exercises.some(entry => entry.id === exercise.sampleID)));
  assert.ok(targets.primary.has('shoulders'));
  assert.ok(!targets.secondary.has('shoulders'));
  assert.ok(targets.secondary.has('biceps'));
  const html = renderMuscleMap(anatomy, targets, 'chest');
  assert.match(html, /Front: Chest, primary/);
  assert.match(html, /Front: Biceps, secondary/);
  assert.match(html, /Pectoralis major/);
  assert.match(html, /Browse chest exercises/);
  const represented = new Set([...anatomy.front, ...anatomy.back].map(part => part.group));
  assert.deepEqual(represented, new Set(Object.keys(anatomy.regions)));
});
