import { isDay } from './storage.js';
import { equipmentName, dayOf, historyRows } from './history.js';
import { sessionPlan } from './workout-log.js';
import { validateAnalytics } from './analytics.js';

export const dataFileLimit = 20 * 1024 * 1024;
const profileKey = 'setline-restored-profile-v1';
const keys = { plans: 'setline-personal-routines-v1', weights: 'setline-user-weights-v2', library: 'setline-exercise-library-v1', preferences: 'setline-preferences-v1' };
const profileKeys = new Set(Object.values(keys));
export const backupDefaults = { notes: true, bodyweight: true, readiness: true, forecasts: true, photos: false };
export const shareDefaults = { notes: false, bodyweight: false, effort: false, sets: true };
const measurements = ['weight', 'added', 'assistance', 'bodyweight', 'duration', 'distance', 'setting'];
const gears = ['barbell', 'dumbbell', 'cable', 'machine', 'kettlebell', 'band', 'other'];
const sides = ['total', 'perSide', 'separateSides'];
const object = value => value != null && typeof value === 'object' && !Array.isArray(value);
const dateTime = value => typeof value === 'string' && Number.isFinite(Date.parse(value));
const uid = value => typeof value === 'string' && /^[a-zA-Z0-9_-]{1,128}$/.test(value) && !['__proto__', 'constructor', 'prototype'].includes(value);
const nonnegative = n => Number.isFinite(n) && n >= 0;
const text = (value, maximum = 4000) => typeof value === 'string' && value.length <= maximum;
const whole = (n, min = 1, max = 10000) => Number.isSafeInteger(n) && n >= min && n <= max;

function require(condition, issue) {
  if (!condition) throw new Error(issue);
}

function unique(items, label, key = 'id') {
  require(Array.isArray(items), `The ${label} list is missing or invalid.`);
  const values = new Set();
  for (const entry of items) {
    require(object(entry) && uid(entry[key]) && !values.has(entry[key]), `The ${label} list contains a duplicate or invalid identifier.`);
    values.add(entry[key]);
  }
  return values;
}

function validateAmount(amount, kind, optional = true) {
  if (amount == null) return optional;
  if (!object(amount) || amount.kind !== kind || kind === 'bodyweight') return false;
  if (kind === 'setting') return text(amount.value, 1000) && !!amount.value.trim();
  return nonnegative(amount.value) && (!['duration', 'distance'].includes(kind) || amount.value > 0);
}

function validateExercise(exercise) {
  require(object(exercise) && uid(exercise.id) && text(exercise.name, 240) && exercise.name.trim() &&
    (exercise.equipment == null || gears.includes(exercise.equipment)), 'An exercise name, identity or equipment type is invalid.');
  for (const field of ['primary', 'secondary']) if (exercise[field] != null) {
    require(Array.isArray(exercise[field]) && exercise[field].every(value => typeof value === 'string'), 'Exercise muscle groups are invalid.');
  }
}

function validatePlan(plan, named = true) {
  require(object(plan) && text(plan.name, 240) && plan.name.trim(), 'A routine name is missing or too long.');
  const ids = unique(plan.exercises, 'exercise slots');
  require(!named || ids.size > 0, 'A saved routine needs at least one exercise.');
  for (const row of plan.exercises) {
    validateExercise(row.exercise);
    require(measurements.includes(row.measurement) && sides.includes(row.counting ?? 'total') &&
      ['total', 'perDumbbell'].includes(row.basis ?? 'total') && text(row.equipmentLabel ?? '', 240), 'An exercise measurement or loading convention is invalid.');
    require(row.measurement !== 'setting' || row.equipmentLabel?.trim(), 'Machine settings need a named machine.');
    require(row.measurement !== 'weight' || row.basis !== 'perDumbbell' || row.exercise.equipment === 'dumbbell', 'Per-dumbbell loading needs dumbbells.');
    require(Array.isArray(row.warm) && Array.isArray(row.work) && (!named || row.work.length), 'A routine has missing set prescriptions.');
    unique([...row.warm, ...row.work], 'set prescriptions');
    let count = 0;
    for (const block of [...row.warm, ...row.work]) {
      require(whole(block.sets) && (count += block.sets) <= 10000 && validateAmount(block.target, row.measurement) &&
        (block.rest == null || whole(block.rest, 0, Number.MAX_SAFE_INTEGER)) &&
        (block.structure == null || ['straight', 'dropSet', 'restPause'].includes(block.structure)), 'A set prescription is invalid.');
      if (block.reps != null) require(!['duration', 'distance'].includes(row.measurement) && whole(block.reps.minimum, 1, Number.MAX_SAFE_INTEGER) &&
        whole(block.reps.maximum, block.reps.minimum, Number.MAX_SAFE_INTEGER), 'A rep range is invalid.');
      if (block.effort != null) require(block.effort.kind === 'failure' || (block.effort.kind === 'rir' && whole(block.effort.value, 0, Number.MAX_SAFE_INTEGER)) ||
        (block.effort.kind === 'rpe' && nonnegative(block.effort.value) && block.effort.value >= 1 && block.effort.value <= 10), 'A target effort is invalid.');
    }
  }
  unique(plan.groups, 'groups');
  const used = new Set();
  for (const group of plan.groups) {
    const positions = Array.isArray(group.members) ? group.members.map(id => plan.exercises.findIndex(row => row.id === id)).sort((a, b) => a - b) : [];
    require(['Superset', 'Circuit'].includes(group.kind) && (group.kind === 'Superset' ? positions.length === 2 : positions.length >= 2) &&
      positions[0] >= 0 && positions.every((value, i) => value === positions[0] + i) && group.members.every(id => !used.has(id)) &&
      whole(group.rounds, 1, Number.MAX_SAFE_INTEGER) && whole(group.restExercises, 0, Number.MAX_SAFE_INTEGER) &&
      whole(group.restRounds, 0, Number.MAX_SAFE_INTEGER), 'A superset or circuit has invalid members or timing.');
    group.members.forEach(id => used.add(id));
  }
}

function validatePlans(plans) {
  require(object(plans), 'Workout and routine data is missing.');
  const categoryIDs = unique(plans.categories, 'routine categories');
  const routineIDs = unique(plans.routines, 'routines');
  const versions = new Map();
  for (const routine of plans.routines) {
    unique(routine.versions, 'routine versions');
    require(routine.versions.length > 0, 'A routine has no versions.');
    routine.versions.forEach((plan, index) => {
      validatePlan(plan);
      require(!versions.has(plan.id) && plan.routineID === routine.id && plan.revision === index + 1 &&
        (!plan.categoryID || categoryIDs.has(plan.categoryID)), 'A routine version has a duplicate identifier or a missing relationship.');
      versions.set(plan.id, plan);
    });
  }
  const schedules = unique(plans.schedule, 'scheduled workouts');
  const blocks = unique(plans.programBlocks ?? [], 'program blocks');
  const rotations = unique(plans.rotations ?? [], 'rotations');
  if (plans.scheduleSettings != null) require(whole(plans.scheduleSettings.weekStart, 0, 6) &&
    ['week', 'rolling'].includes(plans.scheduleSettings.mode), 'Training calendar settings are invalid.');
  if (plans.analyticsSettings != null) {
    require(Array.isArray(plans.analyticsSettings.visible) && Array.isArray(plans.analyticsSettings.dashboard), 'Analytics settings are invalid.');
    validateAnalytics(plans.analyticsSettings);
  }
  if (plans.progressionRules != null) require(Array.isArray(plans.progressionRules) && plans.progressionRules.every(item =>
    object(item) && typeof item.variant === 'string' && object(item.rule)), 'Progression settings are invalid.');
  unique(plans.weekdayRules ?? [], 'weekday assignments');
  for (const plan of plans.schedule) require(isDay(plan.date) && versions.has(plan.versionID) &&
    (!plan.blockID || blocks.has(plan.blockID)) && (!plan.rotationID || rotations.has(plan.rotationID)), 'A scheduled workout has a missing routine or program.');
  for (const rule of plans.weekdayRules ?? []) require(isDay(rule.start) && whole(rule.weekday, 0, 6) && versions.has(rule.versionID), 'A weekday assignment is invalid.');
  for (const rule of plans.rotations ?? []) require(isDay(rule.start) && whole(rule.interval) && Array.isArray(rule.versions) && rule.versions.length > 0 &&
    rule.versions.every(id => versions.has(id)), 'A rotation has invalid routine assignments.');
  for (const block of plans.programBlocks ?? []) require(isDay(block.first) && isDay(block.last) && block.first <= block.last, 'A program has invalid dates.');
  const sessions = unique(plans.sessions, 'workouts');
  const active = plans.sessions.filter(item => !item.completedAt);
  require(active.length <= 1, 'The backup contains multiple active workouts.');
  for (const session of plans.sessions) {
    validatePlan(session.snapshot, false);
    if (session.override != null) validatePlan(session.override, false);
    require(dateTime(session.startedAt) && isDay(dayOf(session)) && (session.completedAt == null ||
      (dateTime(session.completedAt) && Date.parse(session.completedAt) >= Date.parse(session.startedAt))) &&
      (!session.scheduleID || schedules.has(session.scheduleID)) && (!session.referenceID || sessions.has(session.referenceID)) &&
      (!session.snapshot.revision || (routineIDs.has(session.snapshot.routineID) && versions.has(session.snapshot.id))), 'A workout has invalid dates or a missing relationship.');
    const rows = new Map(sessionPlan(session).exercises.map(row => [row.id, row]));
    const results = unique(session.results, 'performed sets');
    for (const set of session.results) {
      const row = rows.get(set.exerciseID);
      require(row && dateTime(set.at) && validateAmount(set.amount, row.measurement, row.measurement === 'bodyweight') &&
        validateAmount(set.rightAmount, row.measurement) && (set.reps == null || whole(set.reps, 0, Number.MAX_SAFE_INTEGER)) &&
        (set.rightReps == null || whole(set.rightReps, 0, Number.MAX_SAFE_INTEGER)), 'A performed set does not match its workout exercise.');
    }
    if (session.log) {
      require(text(session.log.notes ?? '', 100_000), 'Workout notes are invalid.');
      unique(session.log.exercises, 'logged exercise slots');
      const loggedSets = new Set();
      for (const row of session.log.exercises) {
        require(rows.has(row.id) && text(row.notes ?? '', 100_000), 'A logged exercise has invalid notes or no matching workout slot.');
        unique(row.sets, 'workout set rows');
        for (const set of row.sets) {
          require(!loggedSets.has(set.id) && ['pending', 'skipped', 'completed'].includes(set.status) &&
            (set.status === 'completed') === results.has(set.id), 'A logged set has inconsistent completion data.');
          if (set.input != null) require(object(set.input) && ['kg', 'lb'].includes(set.input.unit) &&
            ['amount', 'rightAmount', 'reps', 'rightReps', 'rir', 'rpe'].every(field => set.input[field] == null || text(set.input[field], 1000)), 'A saved set input is invalid.');
          loggedSets.add(set.id);
        }
      }
      require([...results].every(id => loggedSets.has(id)), 'A performed set has no matching log row.');
    }
    if (session.performanceForecasts != null) {
      uniqueForecasts(session.performanceForecasts);
      for (const item of session.performanceForecasts) require(item.sources.every(source => sessions.has(source.id)), 'A forecast has missing source history.');
    }
  }
  const checkins = unique(plans.readiness ?? [], 'readiness check-ins');
  if (checkins.size) require(new Set(plans.readiness.map(entry => entry.date)).size === checkins.size &&
    plans.readiness.every(entry => isDay(entry.date)), 'Readiness check-ins have duplicate or invalid dates.');
  return sessions;
}

function uniqueForecasts(items) {
  require(Array.isArray(items) && new Set(items.map(item => item?.id)).size === items.length && items.every(item =>
    object(item) && text(item.id, 180) && uid(item.rowID) && dateTime(item.issuedAt) && Array.isArray(item.sources) &&
    Array.isArray(item.notes) && object(item.ranges) && Object.values(item.ranges).every(range =>
      object(range) && nonnegative(range.low) && nonnegative(range.center) && nonnegative(range.high) && range.low <= range.high)), 'A saved forecast is invalid.');
}

function scrubPersonalNotes(value) {
  if (Array.isArray(value)) return value.forEach(scrubPersonalNotes);
  if (!object(value)) return;
  for (const [key, field] of Object.entries(value)) {
    if (['notes', 'setup', 'cues'].includes(key) && typeof field === 'string') value[key] = '';
    else if (key === 'machineSetup' && object(field)) value[key] = {};
    else if (key === 'notes' && Array.isArray(field) && !value.model) value[key] = [];
    else scrubPersonalNotes(field);
  }
}

export function photoMetadata(link) {
  return { id: link.id, day: link.day, sessionID: link.sessionID ?? null, name: link.name, createdAt: link.createdAt };
}

export function makeBackup(profile, options = backupDefaults, now = new Date()) {
  const data = structuredClone({ plans: profile.plans, weights: { ...profile.weights, schemaVersion: 2 }, library: profile.library,
    preferences: profile.preferences, photos: options.photos ? profile.photos.map(photoMetadata) : [] });
  if (!options.notes) scrubPersonalNotes(data);
  if (!options.bodyweight) data.weights = { schemaVersion: 2, entries: {} };
  if (!options.readiness) data.plans.readiness = [];
  if (!options.forecasts) {
    delete data.plans.predictions;
    for (const session of data.plans.sessions) delete session.performanceForecasts;
  }
  return { format: 'setline-backup', version: 1, platform: 'preview', createdAt: now.toISOString(), payload: data };
}

export function parseDataFile(source) {
  require(typeof source === 'string' && new TextEncoder().encode(source).length <= dataFileLimit, 'Choose a file up to 20 MB.');
  try { return JSON.parse(source.replace(/^\uFEFF/, '')); } catch { throw new Error('This file is not valid JSON.'); }
}

export function validateBackup(file) {
  require(file?.format === 'setline-backup' && file.version === 1, 'This Setline backup version is unsupported.');
  require(file.platform === 'preview', 'This backup was made for the iPhone app. Restore it there.');
  require(dateTime(file.createdAt) && object(file.payload), 'The backup header is invalid.');
  const { plans, weights, library, preferences, photos } = file.payload;
  const sessions = validatePlans(plans);
  require(weights?.schemaVersion === 2 && object(weights.entries), 'Bodyweight data is invalid.');
  unique(Object.values(weights.entries), 'bodyweight readings');
  for (const [day, entry] of Object.entries(weights.entries)) require(isDay(day) && day === entry.day && entry.kilograms > 0 &&
    Number.isFinite(entry.kilograms) && dateTime(entry.createdAt) && dateTime(entry.updatedAt), 'A bodyweight reading is invalid.');
  require(weights.targetKgPerWeek == null || Number.isFinite(weights.targetKgPerWeek), 'The bodyweight target is invalid.');
  require(object(library) && object(library.preferences), 'Exercise library preferences are invalid.');
  require(Object.values(library.preferences).every(object), 'Exercise library preferences are invalid.');
  unique(library.custom, 'custom exercises');
  library.custom.forEach(validateExercise);
  require(object(preferences) && ['system', 'light', 'dark'].includes(preferences.appearance) && ['kg', 'lb'].includes(preferences.unit) &&
    typeof preferences.opaque === 'boolean', 'Display preferences are invalid.');
  unique(photos, 'device photo references');
  photos.forEach(link => require(isDay(link.day) && (!link.sessionID || sessions.has(link.sessionID)) && text(link.name, 4000) &&
    dateTime(link.createdAt) && Object.keys(link).every(key => ['id', 'day', 'sessionID', 'name', 'createdAt'].includes(key)), 'A device photo reference is invalid.'));
  return file.payload;
}

export function createProfileStorage(storage) {
  const profile = () => {
    const raw = storage.getItem(profileKey);
    return raw ? JSON.parse(raw) : null;
  };
  return {
    getItem(key) { return (profileKeys.has(key) ? profile()?.records[key] : null) ?? storage.getItem(key); },
    setItem(key, value) {
      const restored = profileKeys.has(key) && profile();
      if (!restored) storage.setItem(key, value);
      else storage.setItem(profileKey, JSON.stringify({ ...restored, records: { ...restored.records, [key]: value } }));
    },
    photoScope() { return profile()?.photoScope ?? null; },
    replace(data, photoScope) {
      const records = Object.fromEntries(Object.entries(keys).map(([name, key]) => [key, JSON.stringify(data[name])]));
      storage.setItem(profileKey, JSON.stringify({ records, photoScope }));
      // The restored profile is the commit point. Remove superseded byte copies where possible.
      try {
        for (const key of Object.values(keys)) storage.removeItem?.(key);
        const legacy = storage.getItem('setline-preview-v1');
        if (legacy) {
          const { active } = JSON.parse(legacy);
          storage.setItem('setline-preview-v1', JSON.stringify({ active: active ?? null }));
        }
      } catch { /* The committed profile still wins over legacy storage. */ }
    },
    importRoutine(data) {
      const prior = profile();
      const records = Object.fromEntries(Object.values(keys).map(key => [key, prior?.records[key] ?? storage.getItem(key)]));
      records[keys.plans] = JSON.stringify(data.plans);
      records[keys.library] = JSON.stringify(data.library);
      storage.setItem(profileKey, JSON.stringify({ records, photoScope: prior?.photoScope ?? null }));
    },
  };
}

const csvCell = cell => {
  const raw = String(cell ?? '');
  const value = typeof cell === 'string' && /^[\s\u0000-\u001f]*[=+\-@\t\r\n]/.test(raw) ? "'" + raw : raw;
  return '"' + value.replaceAll('"', '""') + '"';
};
const toCSV = rows => rows.map(row => row.map(csvCell).join(',')).join('\r\n') + '\r\n';

export function bodyweightCSV(weights) {
  return toCSV([['local_date', 'bodyweight_kg'], ...Object.values(weights.entries).sort((a, b) => a.day.localeCompare(b.day)).map(item => [item.day, item.kilograms])]);
}

export function workoutsCSV(plans, options = shareDefaults) {
  const header = ['session_id', 'local_date', 'workout', 'completed_at', 'exercise', 'equipment', 'measurement', 'load_basis', 'rep_counting',
    'set', 'purpose', 'status', 'reps', 'right_reps', 'weight_kg', 'right_weight_kg', 'added_load_kg', 'right_added_load_kg', 'assistance_kg',
    'right_assistance_kg', 'duration_s', 'right_duration_s', 'distance_m', 'right_distance_m', 'machine_setting'];
  if (options.effort) header.push('actual_rir', 'actual_rpe', 'to_failure');
  if (options.notes) header.push('session_notes', 'exercise_notes');
  const rows = [header];
  for (const session of plans.sessions) {
    const plan = sessionPlan(session);
    const start = [session.id, dayOf(session), plan.name, session.completedAt];
    if (!plan.exercises.length) { rows.push(start.concat(Array(header.length - start.length).fill(''))); continue; }
    for (const row of plan.exercises) for (const set of historyRows(session, row)) {
      const result = set.result;
      const amounts = ['weight', 'added', 'assistance', 'duration', 'distance'].flatMap(kind =>
        [result?.amount, result?.rightAmount].map(amount => amount?.kind === kind ? amount.value : null));
      const record = [...start, row.exercise.name, equipmentName(row), row.measurement, row.basis, row.counting,
        set.order, set.purpose, set.status, result?.reps, result?.rightReps, ...amounts,
        result?.amount?.kind === 'setting' ? result.amount.value : null];
      if (options.effort) record.push(result?.rir, result?.rpe, result?.failure);
      if (options.notes) record.push(session.log?.notes, session.log?.exercises.find(item => item.id === row.id)?.notes);
      rows.push(record);
    }
  }
  return toCSV(rows);
}

export function routineFile(version, includeNotes = false, lookup = () => null) {
  const exercises = version.exercises.map(row => {
    const exercise = { ...row.exercise, ...lookup(row.exercise.id), id: row.exercise.id, name: row.exercise.name, equipment: row.exercise.equipment ?? null };
    const portable = Object.fromEntries(['id', 'name', 'equipment', 'variation', 'pattern', 'primary', 'secondary',
      ...(includeNotes ? ['setup', 'cues', 'machineSetup'] : [])].filter(key => exercise[key] !== undefined).map(key => [key, exercise[key]]));
    return { id: row.id, exercise: portable, equipmentLabel: row.equipmentLabel ?? '', measurement: row.measurement, basis: row.basis ?? 'total',
      counting: row.counting ?? 'total', warm: row.warm, work: row.work };
  });
  return { format: 'setline-routine', version: 1, name: version.name, exercises, groups: version.groups };
}

export function validateRoutine(file) {
  require(file?.format === 'setline-routine' && file.version === 1, 'This Setline routine file is unsupported.');
  validatePlan(file);
  return file;
}

function routineFingerprint(plan) {
  const set = ({ sets, reps, target, rest, structure, amrap, effort }) => [sets, reps ? [reps.minimum, reps.maximum] : null,
    target ? [target.kind, target.value] : null, rest ?? null, structure ?? 'straight', !!amrap, effort ? [effort.kind, effort.value ?? null] : null];
  return JSON.stringify([plan.name.trim(), plan.exercises.map(row => [row.exercise.name.trim(), row.exercise.equipment ?? null, row.exercise.variation ?? '',
    row.equipmentLabel ?? '', row.measurement, row.basis ?? 'total', row.counting ?? 'total', row.warm.map(set), row.work.map(set)]),
    plan.groups.map(group => [group.kind, group.members.map(id => plan.exercises.findIndex(row => row.id === id)).sort((a, b) => a - b),
      group.rounds, group.restExercises, group.restRounds])]);
}

export function addImportedRoutine(file, plans, library, catalog, now = new Date()) {
  validateRoutine(file);
  if (plans.routines.some(routine => routineFingerprint(routine.versions.at(-1)) === routineFingerprint(file))) return null;
  const output = structuredClone({ plans, library });
  const slots = new Map(), resolved = new Map(), created = now.toISOString();
  const exercises = file.exercises.map(row => {
    const incoming = row.exercise;
    let exercise = resolved.get(incoming.id);
    if (!exercise) {
      const known = [...catalog, ...output.library.custom].find(item => item.id.toLowerCase() === incoming.id.toLowerCase());
      if (known && (known.equipment ?? null) === (incoming.equipment ?? null) && (known.variation ?? '') === (incoming.variation ?? '')) exercise = known;
      else {
        exercise = { id: crypto.randomUUID(), name: incoming.name, equipment: incoming.equipment ?? null, variation: incoming.variation ?? '',
          pattern: incoming.pattern ?? 'other', primary: incoming.primary ?? [], secondary: incoming.secondary ?? [],
          setup: incoming.setup ?? '', cues: incoming.cues ?? '', machineSetup: incoming.machineSetup ?? {}, createdAt: created };
        output.library.custom.push(exercise);
      }
      resolved.set(incoming.id, exercise);
    }
    const id = crypto.randomUUID();
    slots.set(row.id, id);
    const blocks = rows => rows.map(set => ({ id: crypto.randomUUID(), sets: set.sets, reps: set.reps ?? null, target: set.target ?? null,
      rest: set.rest ?? null, structure: set.structure ?? 'straight', amrap: Boolean(set.amrap), effort: set.effort ?? null }));
    return { id, equipmentLabel: row.equipmentLabel ?? '', measurement: row.measurement, basis: row.basis ?? 'total', counting: row.counting ?? 'total',
      exercise: { id: exercise.id, name: incoming.name, equipment: exercise.equipment ?? null, variation: exercise.variation ?? '',
        primary: incoming.primary ?? exercise.primary ?? [], secondary: incoming.secondary ?? exercise.secondary ?? [] }, warm: blocks(row.warm), work: blocks(row.work) };
  });
  const groups = file.groups.map(group => ({ ...group, id: crypto.randomUUID(), members: group.members.map(id => slots.get(id)) }));
  const routineID = crypto.randomUUID();
  output.plans.routines.push({ id: routineID, versions: [{ id: crypto.randomUUID(), routineID, name: file.name.trim(), categoryID: null,
    createdAt: created, revision: 1, exercises, groups }] });
  return output;
}
