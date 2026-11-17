import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createBrowserStore, kilogramsPerPound, localDayKey } from './storage.js';

function memoryStorage() {
  const values = new Map();
  return {
    getItem: key => values.get(key) ?? null,
    setItem: (key, value) => values.set(key, value),
  };
}

test('migrates the existing weight, keeps the sample active state separate, and preserves IDs after reopening', () => {
  const storage = memoryStorage();
  const date = '2026-11-17';
  const legacy = JSON.stringify({ weights: { [date]: 82.4 }, active: { routineID: 'upper-a' }, unit: 'lb' });
  storage.setItem('setline-preview-v1', legacy);
  const store = createBrowserStore(storage);
  const entry = store.loadUser().entries[date];
  assert.equal(entry.kilograms, 82.4);
  assert.deepEqual(store.loadSample(), { weights: {}, active: { routineID: 'upper-a' } });
  assert.equal(store.loadPreferences().unit, 'lb');

  store.saveSample({ weights: { [date]: 65 }, active: null });
  const reopened = createBrowserStore(storage);
  assert.deepEqual(reopened.loadUser().entries[date], entry);
  reopened.saveWeight(date, 180 * kilogramsPerPound);
  const updated = createBrowserStore(storage).loadUser().entries[date];
  assert.equal(updated.id, entry.id);
  assert.equal(updated.createdAt, entry.createdAt);
  assert.equal(updated.kilograms / kilogramsPerPound, 180);
  assert.equal(reopened.loadSample().weights[date], 65);
  assert.equal(storage.getItem('setline-preview-v1'), legacy);
});

test('rejects invalid dates, amounts and newer schemas without replacing data', () => {
  const storage = memoryStorage();
  const store = createBrowserStore(storage);
  assert.throws(() => store.saveWeight('2026-02-30', 80));
  assert.throws(() => store.saveWeight('2026-11-17', 0));
  const future = JSON.stringify({ schemaVersion: 99, entries: {} });
  storage.setItem('setline-user-weights-v2', future);
  assert.throws(() => store.saveWeight('2026-11-17', 80));
  assert.equal(storage.getItem('setline-user-weights-v2'), future);
});

test('keeps the previous entry after a failing write', () => {
  const storage = memoryStorage();
  const date = '2026-11-17';
  createBrowserStore(storage).saveWeight(date, 80);
  const readOnly = createBrowserStore({ ...storage, setItem() { throw new Error('Storage unavailable'); } });
  assert.throws(() => readOnly.saveWeight(date, 81));
  assert.equal(createBrowserStore(storage).loadUser().entries[date].kilograms, 80);
});

test('formats the device calendar date independent of UTC rollover', () => {
  assert.equal(localDayKey(new Date(2026, 10, 17, 23, 59)), '2026-11-17');
  assert.equal(localDayKey(new Date(2026, 10, 18, 0, 1)), '2026-11-18');
});
