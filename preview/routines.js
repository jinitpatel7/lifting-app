import { kilogramsPerPound, localDayKey } from './storage.js';

const storageKey = 'setline-personal-routines-v1';
const uuid = () => crypto.randomUUID();

export const measurements = { weight: 'Weight and reps', bodyweight: 'Bodyweight', added: 'Added load', assistance: 'Assistance',
  duration: 'Duration', distance: 'Distance', setting: 'Machine setting' };
export const hasReps = measurement => !['duration', 'distance'].includes(measurement);
export const sessionPlan = session => session.override ?? session.snapshot;
export const newest = routine => routine.versions.at(-1);
export const blankSet = () => ({ id: uuid(), sets: '1', minimum: '', maximum: '', target: '', rest: '',
  structure: 'straight', amrap: false, effort: 'none', effortValue: '' });

export function draftExercise(exercise) {
  const { id, name, equipment = null, variation = '' } = exercise;
  return { id: uuid(), exercise: { id, name, equipment, variation }, equipmentLabel: '', basis: 'total', counting: 'total',
    measurement: equipment ? 'weight' : 'bodyweight', warm: [], work: [blankSet()] };
}

export function newGroup(kind) {
  return { id: uuid(), kind, members: [], rounds: '3', restExercises: '0', restRounds: '0' };
}

function whole(input, label, minimum) {
  const value = Number(input);
  if (String(input).trim() === '' || !Number.isSafeInteger(value) || value < minimum) {
    throw new Error(`${label} must be a whole number of ${minimum} or more.`);
  }
  return value;
}

function optionalNumber(input, label, minimum) {
  const value = Number(input);
  if (!Number.isFinite(value) || value < minimum) throw new Error(`Enter a valid ${label.toLowerCase()}.`);
  return value;
}

function setPrescription(set, measurement, unit) {
  const sets = whole(set.sets, 'Set count', 1);
  const amrap = hasReps(measurement) && set.amrap;
  let reps = null;
  if (hasReps(measurement) && (!amrap || set.minimum !== '' || set.maximum !== '')) {
    const minimum = whole(set.minimum, 'Minimum reps', 1);
    reps = { minimum, maximum: whole(set.maximum || set.minimum, 'Maximum reps', minimum) };
  }
  const rest = set.rest === '' ? null : whole(set.rest, 'Rest', 0);
  let effort = null;
  if (set.effort === 'failure') effort = { kind: 'failure' };
  if (set.effort === 'rir') effort = { kind: 'rir', value: whole(set.effortValue, 'RIR', 0) };
  if (set.effort === 'rpe') {
    const value = optionalNumber(set.effortValue, 'RPE', 1);
    if (value > 10) throw new Error('Enter target RPE from 1 to 10.');
    effort = { kind: 'rpe', value };
  }
  const text = String(set.target).trim();
  let target = null;
  if (text && measurement !== 'bodyweight') {
    if (text === set.originalText && set.originalTarget?.kind === measurement) {
      target = set.originalTarget;
    } else if (measurement === 'setting') {
      target = { kind: measurement, value: text };
    } else {
      const value = optionalNumber(text, measurements[measurement], 0);
      if (!hasReps(measurement) && value === 0) throw new Error(`${measurements[measurement]} must be greater than zero.`);
      const physicalLoad = hasReps(measurement) && unit === 'lb' ? value * kilogramsPerPound : value;
      target = { kind: measurement, value: physicalLoad };
    }
  }
  return { id: set.id, sets, reps, target, rest, structure: set.structure, amrap, effort };
}

export function validatedPlan(draft, unit) {
  const name = draft.name.trim();
  if (!name || !draft.exercises.length) throw new Error('Enter a routine name and add an exercise.');
  if (new Set(draft.exercises.map(row => row.id)).size !== draft.exercises.length) throw new Error('Each exercise needs its own slot.');
  const exercises = draft.exercises.map(row => {
    const { id, exercise, equipmentLabel, measurement, basis, counting, warm, work } = row;
    if (!Object.hasOwn(measurements, measurement) || !work.length) throw new Error(`Choose a measurement and working set for ${exercise.name}.`);
    if (measurement === 'setting' && !equipmentLabel.trim()) throw new Error(`Enter the machine name for ${exercise.name}.`);
    if (measurement === 'weight' && basis === 'perDumbbell' && exercise.equipment !== 'dumbbell') {
      throw new Error('Use per-dumbbell load with a dumbbell exercise.');
    }
    try {
      return { id, exercise, equipmentLabel: equipmentLabel.trim(), measurement, basis, counting,
        warm: warm.map(set => setPrescription(set, measurement, unit)), work: work.map(set => setPrescription(set, measurement, unit)) };
    } catch (error) { throw new Error(`${exercise.name}: ${error.message}`); }
  });
  const occupied = new Set();
  const groups = draft.groups.map(group => {
    const ids = new Set(group.members);
    const positions = exercises.flatMap((row, index) => ids.has(row.id) ? [index] : []);
    if (ids.size !== group.members.length || ids.size < 2 || (group.kind === 'Superset' && ids.size !== 2)
      || positions.length !== ids.size || positions.at(-1) - positions[0] + 1 !== positions.length
      || [...ids].some(id => occupied.has(id))) {
      throw new Error('Choose two adjacent exercises for a superset or two or more for a circuit. Each exercise can belong to one group.');
    }
    for (const id of ids) occupied.add(id);
    return { ...group, members: positions.map(index => exercises[index].id), rounds: whole(group.rounds, 'Rounds', 1),
      restExercises: whole(group.restExercises, 'Rest between exercises', 0), restRounds: whole(group.restRounds, 'Rest between rounds', 0) };
  });
  return { name, categoryID: draft.categoryID || null, exercises, groups };
}

export function makeDraft(version, unit) {
  if (!version) return { routineID: uuid(), expectedVersionID: null, name: '', categoryID: '', exercises: [], groups: [] };
  const draftSet = set => {
    const isLoad = ['weight', 'added', 'assistance'].includes(set.target?.kind);
    const value = isLoad && unit === 'lb' ? set.target.value / kilogramsPerPound : set.target?.value;
    const formatted = typeof value === 'number' ? String(Number(value.toFixed(6))) : (value ?? '');
    return { ...set, sets: String(set.sets), minimum: String(set.reps?.minimum ?? ''), maximum: String(set.reps?.maximum ?? ''),
      target: formatted, rest: String(set.rest ?? ''), effort: set.effort?.kind ?? 'none', effortValue: String(set.effort?.value ?? ''),
      originalTarget: set.target, originalText: formatted };
  };
  return { routineID: version.routineID, expectedVersionID: version.id, name: version.name, categoryID: version.categoryID ?? '',
    exercises: version.exercises.map(row => ({ ...row, warm: row.warm.map(draftSet), work: row.work.map(draftSet) })),
    groups: version.groups.map(group => ({ ...group, members: [...group.members], rounds: String(group.rounds),
      restExercises: String(group.restExercises), restRounds: String(group.restRounds) })) };
}

export function reorder(items, fromID, toID) {
  const from = items.findIndex(item => item.id === fromID);
  const to = items.findIndex(item => item.id === toID);
  if (from < 0 || to < 0 || from === to) return;
  const [item] = items.splice(from, 1);
  items.splice(to, 0, item);
}

export function createRoutineStore(storage) {
  function load() {
    const raw = storage.getItem(storageKey);
    if (raw === null) return { categories: [], routines: [], sessions: [] };
    const data = JSON.parse(raw);
    if (![data?.categories, data?.routines, data?.sessions].every(Array.isArray)) throw new Error('Routine storage could not be read.');
    return data;
  }

  function save(change) {
    const data = load();
    change(data);
    storage.setItem(storageKey, JSON.stringify(data));
    return data;
  }

  function addSession(data, snapshot, referenceID = null) {
    if (data.sessions.some(session => !session.completedAt)) throw new Error('Finish the active workout before starting another.');
    const now = new Date();
    data.sessions.push({ id: uuid(), snapshot, override: null, referenceID, startedAt: now.toISOString(),
      localDate: localDayKey(now), completedAt: null, results: [] });
  }

  return {
    load,
    addCategory(category) {
      return save(data => {
        if (!category.name.trim()) throw new Error('Enter a category name.');
        if (data.categories.some(item => item.name.localeCompare(category.name, undefined, { sensitivity: 'base' }) === 0)) {
          throw new Error('A category with that name already exists.');
        }
        data.categories.push(category);
      });
    },
    saveRoutine(draft, unit) {
      return save(data => {
        const plan = validatedPlan(draft, unit);
        if (plan.categoryID && !data.categories.some(category => category.id === plan.categoryID)) throw new Error('Choose a saved category.');
        const routine = data.routines.find(item => item.id === draft.routineID);
        const prior = routine && newest(routine);
        if ((prior?.id ?? null) !== draft.expectedVersionID) throw new Error('This routine changed. Reopen it before saving an edit.');
        const { name, categoryID, exercises, groups } = prior ?? {};
        if (prior && JSON.stringify(plan) === JSON.stringify({ name, categoryID, exercises, groups })) return;
        const version = { ...plan, id: uuid(), routineID: draft.routineID, revision: (prior?.revision ?? 0) + 1, createdAt: new Date().toISOString() };
        if (routine) routine.versions.push(version);
        else data.routines.push({ id: draft.routineID, versions: [version] });
      });
    },
    duplicate(routineID) {
      return save(data => {
        const routine = data.routines.find(item => item.id === routineID);
        if (!routine) throw new Error('Routine not found.');
        const copy = structuredClone(newest(routine));
        const ids = new Map();
        for (const row of copy.exercises) {
          const id = uuid();
          ids.set(row.id, id);
          row.id = id;
          for (const set of [...row.warm, ...row.work]) set.id = uuid();
        }
        copy.groups = copy.groups.map(group => ({ ...group, id: uuid(), members: group.members.map(id => ids.get(id)) }));
        const id = uuid();
        data.routines.push({ id, versions: [{ ...copy, name: `${copy.name} copy`, id: uuid(), routineID: id, revision: 1, createdAt: new Date().toISOString() }] });
      });
    },
    start(routineID) {
      return save(data => {
        const routine = data.routines.find(item => item.id === routineID);
        if (!routine) throw new Error('Routine not found.');
        addSession(data, newest(routine));
      });
    },
    repeat(sessionID) {
      return save(data => {
        const session = data.sessions.find(item => item.id === sessionID && item.completedAt);
        if (!session) throw new Error('Choose a completed workout to repeat.');
        addSession(data, sessionPlan(session), sessionID);
      });
    },
    editSession(sessionID, draft, unit) {
      return save(data => {
        const session = data.sessions.find(item => item.id === sessionID && !item.completedAt);
        if (!session) throw new Error('This workout is already complete.');
        const prior = sessionPlan(session);
        const plan = validatedPlan(draft, unit);
        const identity = row => row && [row.exercise.id, row.measurement, row.equipmentLabel, row.basis, row.counting].join('\u0000');
        if (session.results.some(result => identity(prior.exercises.find(row => row.id === result.exerciseID)) !==
          identity(plan.exercises.find(row => row.id === result.exerciseID)))) {
          throw new Error('Keep the exercise and measurement for sets already logged in this workout.');
        }
        session.override = { ...prior, ...plan, categoryID: prior.categoryID };
      });
    },
    finish(sessionID) {
      return save(data => {
        const session = data.sessions.find(item => item.id === sessionID && !item.completedAt);
        if (!session) throw new Error('This workout is already complete.');
        session.completedAt = new Date().toISOString();
      });
    },
  };
}
