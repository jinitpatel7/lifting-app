import assert from 'node:assert/strict';
import { test } from 'node:test';
import { bodyweightTrend } from './bodyweight.js';
import { createBrowserStore, kilogramsPerPound } from './storage.js';
import { photoDates, photosOn, readDevicePhoto, requestDevicePhoto } from './device-photos.js';

test('bodyweight averages only actual readings within the trailing seven local dates', () => {
  const entries = [
    { day: '2026-11-08', kilograms: 78 }, { day: '2026-11-03', kilograms: 82 },
    { day: '2026-11-01', kilograms: 80 }, { day: '2026-11-15', kilograms: 81 },
  ];
  const trend = () => bodyweightTrend(entries).map(point => [point.day, point.kilograms, point.smoothed]);
  assert.deepEqual(trend(), [
    ['2026-11-01', 80, null], ['2026-11-03', 82, 81], ['2026-11-08', 78, 80], ['2026-11-15', 81, null],
  ]);
  entries[1].kilograms = 84;
  assert.deepEqual(trend().map(point => point[2]), [null, 82, 81, null]);
  assert.equal(bodyweightTrend(entries, '2026-11-08').length, 3);
});

test('editing a reading preserves its identity and a signed target uses canonical mass', () => {
  const values = new Map();
  const storage = { getItem: key => values.get(key) ?? null, setItem: (key, value) => values.set(key, value) };
  const store = createBrowserStore(storage);
  const day = '2026-11-12';
  const original = store.saveWeight(day, 80).entries[day];
  store.saveWeightTarget(-2 * kilogramsPerPound);
  store.saveWeight(day, 175 * kilogramsPerPound);
  const reopened = createBrowserStore(storage).loadUser();
  assert.equal(reopened.entries[day].id, original.id);
  assert.equal(reopened.entries[day].createdAt, original.createdAt);
  assert.equal(reopened.entries[day].kilograms / kilogramsPerPound, 175);
  assert.equal(reopened.targetKgPerWeek / kilogramsPerPound, -2);
  assert.throws(() => store.saveWeightTarget(Infinity));
  assert.equal(store.saveWeightTarget(0).targetKgPerWeek, 0);
  assert.equal(store.saveWeightTarget(null).targetKgPerWeek, undefined);
  assert.deepEqual(store.loadSample().weights, {});
});

test('linked photo reads distinguish permission loss, deletion and unavailable originals', async () => {
  let permission = 'prompt';
  const image = new File(['test'], 'photo.png', { type: 'image/png' });
  let reads = 0;
  const handle = {
    queryPermission: async () => permission,
    requestPermission: async () => { permission = 'granted'; return permission; },
    getFile: async () => { reads++; return image; },
  };
  assert.equal((await readDevicePhoto(handle)).state, 'denied');
  assert.equal(reads, 0);
  await requestDevicePhoto(handle);
  assert.deepEqual(await readDevicePhoto(handle), { state: 'ready', file: image });
  permission = 'denied';
  assert.equal((await readDevicePhoto(handle)).state, 'denied');
  permission = 'granted';
  for (const [error, state] of [['NotFoundError', 'missing'], ['NotReadableError', 'unavailable'], ['NotAllowedError', 'denied']]) {
    handle.getFile = async () => { throw new DOMException(error, error); };
    assert.equal((await readDevicePhoto(handle)).state, state);
  }
  handle.getFile = async () => new File([], 'photo.png', { type: 'image/png' });
  assert.equal((await readDevicePhoto(handle)).state, 'unavailable');
});

test('photo calendar dates group workout and date-only references without changing their subjects', () => {
  const links = [
    { id: 'workout', day: '2026-11-18', sessionID: 'session' },
    { id: 'date', day: '2026-11-18', sessionID: null },
    { id: 'other', day: '2026-11-12', sessionID: null },
  ];
  assert.deepEqual(photoDates(links), ['2026-11-12', '2026-11-18']);
  assert.deepEqual(photosOn(links, '2026-11-18').map(link => link.sessionID), ['session', null]);
  assert.deepEqual(photosOn(links, '2026-11-19'), []);
});
