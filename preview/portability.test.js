import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createServer } from 'node:http';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createAccountHandler } from './account-server.mjs';
import { createExerciseStore } from './exercises.js';
import { createRoutineStore, draftExercise, makeDraft, newest } from './routines.js';
import { createBrowserStore, kilogramsPerPound } from './storage.js';
import { addImportedRoutine, backupDefaults, bodyweightCSV, createProfileStorage, makeBackup, parseDataFile, routineFile, validateBackup, workoutsCSV } from './portability.js';

const now = new Date('2026-11-20T17:00:00Z');
const memory = () => {
  const data = new Map();
  return { getItem: key => data.get(key) ?? null, setItem: (key, value) => data.set(key, value) };
};

function fixture() {
  const backing = memory();
  const storage = createProfileStorage(backing);
  const weights = createBrowserStore(storage);
  const plans = createRoutineStore(storage);
  const library = createExerciseStore(storage);
  const press = { id: crypto.randomUUID(), name: 'Dumbbell press', equipment: 'dumbbell', variation: '', setup: 'Private setup note' };
  library.saveExercise(press, false);
  const draft = makeDraft();
  draft.name = 'Push';
  const row = draftExercise(press);
  row.basis = 'perDumbbell'; row.counting = 'separateSides';
  Object.assign(row.work[0], { minimum: '5', maximum: '7', target: '50' });
  draft.exercises.push(row);
  const version = newest(plans.saveRoutine(draft, 'lb').routines[0]);
  plans.schedule(version.routineID, '2026-11-20');
  const entry = plans.load().schedule[0];
  let active = plans.startScheduled(entry.id, entry.date, now).sessions[0];
  const set = active.log.exercises[0].sets[0];
  const changes = { amount: '22.7', rightAmount: '20', reps: '6', rightReps: '5', rir: '1' };
  for (const [field, value] of Object.entries(changes)) {
    plans.logChange(active.id, { action: 'editSet', exerciseID: row.id, setID: set.id, field, value }, 'kg');
  }
  plans.logChange(active.id, { action: 'sessionNotes', value: '=Private note' }, 'kg');
  plans.logChange(active.id, { action: 'complete', exerciseID: row.id, setID: set.id }, 'kg', '2026-11-20T17:01:00Z');
  plans.finish(active.id, false, new Date('2026-11-20T17:30:00Z'));
  active = plans.load().sessions[0];
  weights.saveWeight('2026-11-20', 176 * kilogramsPerPound);
  weights.saveWeightTarget(0.4);
  weights.savePreferences({ appearance: 'dark', opaque: true, unit: 'lb' });
  weights.saveSample({ weights: { '2026-11-20': 100 }, active: 'sample-a' });
  const photo = { id: crypto.randomUUID(), day: active.localDate, sessionID: active.id, name: 'photo.png', createdAt: now.toISOString(), handle: { bytes: 'photo content' } };
  const profile = { plans: plans.load(), library: library.load(), weights: weights.loadUser(), preferences: weights.loadPreferences(), photos: [photo] };
  return { storage, weights, plans, library, profile, version, press };
}

test('versioned backups restore durable relationships, settings, and mixed units without duplicating records', () => {
  const source = fixture();
  const file = makeBackup(source.profile, { ...backupDefaults, photos: true }, now);
  assert.doesNotMatch(JSON.stringify(file), /photo content|"handle"|sample-a/);
  const payload = validateBackup(parseDataFile(JSON.stringify(file)));
  assert.deepEqual(payload.photos[0].sessionID, source.profile.plans.sessions[0].id);
  const other = fixture();
  const restore = () => other.storage.replace(payload, 'exchanged');
  restore(); restore();
  assert.deepEqual(other.plans.load(), source.profile.plans);
  assert.deepEqual(other.weights.loadPreferences(), source.profile.preferences);
  assert.deepEqual(other.weights.loadSample(), { weights: { '2026-11-20': 100 }, active: 'sample-a' });
  const restored = other.plans.load().sessions[0];
  assert.equal(restored.snapshot.exercises[0].work[0].target.value, 50 * kilogramsPerPound);
  assert.equal(restored.results[0].amount.value, 22.7);
  assert.equal(restored.results[0].rightAmount.value, 20);
  assert.equal(other.weights.loadUser().entries['2026-11-20'].kilograms, 176 * kilogramsPerPound);
});

test('malformed envelopes, broken relationships and duplicate IDs are rejected before writes', () => {
  const { profile, plans } = fixture();
  const good = makeBackup(profile);
  assert.throws(() => parseDataFile('{broken'), /valid JSON/);
  assert.throws(() => validateBackup({ ...good, version: 99 }), /unsupported/);
  assert.throws(() => validateBackup({ ...good, platform: 'ios' }), /iPhone/);
  const invalid = change => { const copy = structuredClone(good); change(copy.payload); return copy; };
  assert.throws(() => validateBackup(invalid(data => data.plans.sessions.push(data.plans.sessions[0]))), /duplicate/);
  assert.throws(() => validateBackup(invalid(data => { data.plans.schedule[0].versionID = 'missing'; })), /missing routine/);
  assert.throws(() => validateBackup(invalid(data => { data.plans.sessions[0].results[0].amount.kind = 'setting'; })), /performed set/);
  assert.throws(() => validateBackup(invalid(data => { data.weights.entries['2026-11-20'].kilograms = '176'; })), /bodyweight/);
  assert.deepEqual(plans.load(), profile.plans);
});

test('CSV separates typed loads and dates and selective exports redact personal details', () => {
  const { profile } = fixture();
  const csv = workoutsCSV(profile.plans);
  assert.match(csv, /"weight_kg","right_weight_kg","added_load_kg"/);
  assert.match(csv, /"perDumbbell","separateSides","1","working","completed","6","5","22.7","20"/);
  assert.doesNotMatch(csv, /Private note|actual_rir/);
  assert.match(workoutsCSV(profile.plans, { notes: true, effort: true }), /"'=Private note"/);
  assert.match(bodyweightCSV(profile.weights), /"local_date","bodyweight_kg"/);
  const clean = makeBackup(profile, { notes: false, bodyweight: false, readiness: false, forecasts: false, photos: false });
  const exported = JSON.stringify(clean);
  assert.doesNotMatch(exported, /Private|targetKgPerWeek|performanceForecasts|photo.png/);
  assert.deepEqual(validateBackup(clean).weights.entries, {});
  assert.equal(profile.plans.sessions[0].log.notes, '=Private note');
});

test('routine exchange remaps private IDs and rejects a second equivalent import', () => {
  const { version, press } = fixture();
  const exchange = routineFile(version, false, () => press);
  assert.doesNotMatch(JSON.stringify(exchange), /Private|createdAt|schedule|sessions/);
  const blank = createRoutineStore(memory()).load();
  const library = { custom: [], preferences: {} };
  const result = addImportedRoutine(exchange, blank, library, [], now);
  const imported = newest(result.plans.routines[0]);
  assert.notEqual(imported.id, version.id);
  assert.notEqual(imported.exercises[0].exercise.id, press.id);
  assert.equal(imported.exercises[0].work[0].target.value, 50 * kilogramsPerPound);
  assert.equal(addImportedRoutine(exchange, result.plans, result.library, [], now), null);
});

test('optional account backups are explicit, authenticated, private across users, and persisted encrypted', async () => {
  const directory = mkdtempSync(join(tmpdir(), 'setline-account-test-'));
  let handler = createAccountHandler({ directory, port: 4173 });
  const server = createServer((request, response) => handler(request, response, request.url));
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const host = `http://127.0.0.1:${server.address().port}`;
  const request = (path, method = 'GET', token, data, origin) => fetch(host + '/api/' + path, { method,
    headers: { ...(token && { Authorization: `Bearer ${token}` }), ...(data && { 'Content-Type': 'application/json' }), ...(origin && { Origin: origin }) },
    body: data ? JSON.stringify(data) : undefined });
  try {
    const password = 'Test password for fixture only';
    const signup = async name => {
      const response = await request('account/register', 'POST', null, { username: name, password });
      assert.equal(response.status, 201);
      return (await response.json()).token;
    };
    assert.equal((await request('backup/preview')).status, 401);
    assert.equal((await request('account/register', 'POST', null, { username: 'weak', password: 'short' })).status, 400);
    const alice = await signup('alice');
    const bob = await signup('bob');
    assert.equal((await request('backup/preview', 'GET', alice)).status, 404);
    const { profile } = fixture();
    const file = makeBackup(profile);
    assert.equal((await request('backup/preview', 'PUT', alice, { ...file, version: 99 })).status, 400);
    assert.equal((await request('backup/preview', 'PUT', alice, file, 'https://unexpected.example')).status, 403);
    assert.equal((await request('backup/preview', 'PUT', alice, file)).status, 200);
    assert.equal((await request('backup/preview', 'GET', bob)).status, 404);
    assert.deepEqual((await (await request('backup/preview', 'GET', alice)).json()).backup, file);
    const raw = readFileSync(join(directory, 'accounts.sqlite'));
    assert.equal(raw.includes(Buffer.from('Private note')), false);
    assert.equal(raw.includes(Buffer.from(password)), false);
    assert.equal(raw.includes(Buffer.from(alice)), false);
    handler.close();
    handler = createAccountHandler({ directory, port: 4173 });
    assert.deepEqual((await (await request('backup/preview', 'GET', alice)).json()).backup, file);
    assert.equal((await request('account/sign-out', 'POST', alice)).status, 204);
    assert.equal((await request('backup/preview', 'GET', alice)).status, 401);
    const response = await request('account/sign-in', 'POST', null, { username: 'alice', password });
    assert.equal(response.status, 200);
    const renewed = (await response.json()).token;
    assert.equal((await request('backup/preview', 'DELETE', renewed)).status, 204);
    assert.equal((await request('backup/preview', 'GET', renewed)).status, 404);
  } finally {
    await new Promise(resolve => server.close(resolve));
    handler.close();
    rmSync(directory, { recursive: true, force: true });
  }
});
