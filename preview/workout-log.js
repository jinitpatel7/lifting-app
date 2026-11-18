import { kilogramsPerPound } from './storage.js';
import { closeRest, openRest, parsePlates, plateOptions, workoutTimes } from './workout-tools.js';

const uuid = () => crypto.randomUUID();
export const sessionPlan = session => session.override ?? session.snapshot;
export const variantKey = row => row && JSON.stringify([row.exercise.id, row.exercise.equipment ?? '', row.measurement, row.equipmentLabel, row.basis, row.counting]);
const hasReps = row => !['duration', 'distance'].includes(row.measurement);
const loadKinds = ['weight', 'added', 'assistance'];
const blank = (purpose = 'working', plan = null) => ({ id: uuid(), purpose, plan, status: 'pending', input: null });
export const loadKey = row => JSON.stringify([row.exercise.equipment, row.equipmentLabel || row.exercise.id, row.measurement, row.basis]);
export const isBarbell = row => row.exercise.equipment === 'barbell' && row.measurement === 'weight' && row.basis !== 'perDumbbell';

export function sessionInput(set, unit) {
  if (set.input) return set.input;
  const { target, reps } = set.plan ?? {};
  const amount = target && loadKinds.includes(target.kind) && unit === 'lb' ? target.value / kilogramsPerPound : target?.value;
  return { unit, amount: String(amount ?? ''), reps: String(reps?.minimum ?? ''), rightReps: String(reps?.minimum ?? ''), rir: '', rpe: '', failure: false };
}

function fromPlan(row) {
  const expand = (blocks, purpose) => blocks.flatMap(block => Array.from({ length: block.sets }, () => blank(purpose, block)));
  const count = [...row.warm, ...row.work].reduce((sum, block) => sum + block.sets, 0);
  if (count > 10000) throw new Error('Reduce this exercise’s set count before logging.');
  return { id: row.id, notes: '', queuedAt: null, sets: [...expand(row.warm, 'warm-up'), ...expand(row.work, 'working')] };
}

export function workoutLog(session) {
  return session.log ?? { notes: '', exercises: sessionPlan(session).exercises.map(row => {
    const exercise = fromPlan(row);
    session.results.filter(result => result.exerciseID === row.id).forEach((result, index) => {
      const slot = exercise.sets[result.order ? result.order - 1 : index];
      if (slot) Object.assign(slot, { id: result.id ?? slot.id, status: 'completed' });
      else exercise.sets.push({ ...blank(result.purpose), id: result.id ?? uuid(), status: 'completed' });
    });
    return exercise;
  }) };
}

export function repeatLog(log) {
  return { notes: '', trackRest: log.trackRest, loadProfiles: log.loadProfiles,
    exercises: log.exercises.map(exercise => ({ ...exercise, notes: '', queuedAt: null,
    sets: exercise.sets.map(set => blank(set.purpose, set.plan)) })) };
}

function number(text, name, minimum, integer = false) {
  const value = Number(String(text).trim().replace(',', '.'));
  if (!String(text).trim() || !Number.isFinite(value) || value < minimum || (integer && !Number.isSafeInteger(value))) {
    throw new Error(`Enter a valid ${name}.`);
  }
  return value;
}

function actualAmount(input, row) {
  if (row.measurement === 'bodyweight') return null;
  if (row.measurement === 'setting') {
    if (!input.amount.trim()) throw new Error('Enter a machine setting.');
    return { kind: 'setting', value: input.amount.trim() };
  }
  let value = number(input.amount, 'performance value', 0);
  if (!hasReps(row) && value === 0) throw new Error('Enter a value greater than zero.');
  if (loadKinds.includes(row.measurement) && input.unit === 'lb') value *= kilogramsPerPound;
  return { kind: row.measurement, value };
}

export function performedResult(input, row, set, now) {
  const amount = actualAmount(input, row);
  const sided = hasReps(row) && (row.counting === 'separateSides' || (row.counting === 'perSide' && input.separateSides));
  const sidedTimeOrDistance = !hasReps(row) && input.separateSides;
  const reps = hasReps(row) ? number(input.reps, 'rep count', sided ? 0 : 1, true) : null;
  const rightReps = sided ? number(input.rightReps, 'right rep count', 0, true) : null;
  const rightAmount = sidedTimeOrDistance || (sided && input.rightAmount?.trim()) ?
    actualAmount({ ...input, amount: input.rightAmount ?? '' }, row) : null;
  if (reps === 0 && rightReps === 0) throw new Error('Enter at least one completed rep.');
  const rir = input.rir === '' ? null : number(input.rir, 'RIR', 0, true);
  const rpe = input.rpe === '' ? null : number(input.rpe, 'RPE', 1);
  if (rpe > 10) throw new Error('Enter RPE from 1 to 10.');
  return { id: set.id, exerciseID: row.id, amount, rightAmount, reps, rightReps, rir, rpe, failure: input.failure,
    purpose: set.purpose, structure: set.plan?.structure ?? 'straight', amrap: set.plan?.amrap ?? false, at: now };
}

function keepingGroups(groups, exercises) {
  const ids = exercises.map(row => row.id);
  return groups.flatMap(group => {
    const positions = group.members.map(id => ids.indexOf(id)).sort((a, b) => a - b);
    if (positions[0] < 0 || positions.at(-1) - positions[0] + 1 !== positions.length) return [];
    return [{ ...group, members: positions.map(index => ids[index]) }];
  });
}

const undoable = ['complete', 'removeSet', 'removeExercise', 'skipSet', 'skipExercise', 'moveSet', 'moveExercise', 'skipRest'];

export function applyWorkoutChange(session, change, unit, now = new Date().toISOString()) {
  const log = workoutLog(session);
  session.log = log;
  const plan = sessionPlan(session);
  let exercises = plan.exercises;
  const exercise = log.exercises.find(item => item.id === change.exerciseID);
  const row = exercises.find(item => item.id === change.exerciseID);
  const set = exercise?.sets.find(item => item.id === change.setID);
  const move = (items, item) => {
    const from = items.indexOf(item);
    const to = from + change.direction;
    if (from >= 0 && Math.abs(change.direction) === 1 && items[to]) [items[from], items[to]] = [items[to], items[from]];
  };
  const { action } = change;
  if (action === 'undoLast') {
    if (!log.undo) return;
    const { exercises, results, override, rest } = log.undo;
    Object.assign(log, { exercises, rest, undo: null });
    Object.assign(session, { results, override });
    return;
  }
  if (action === 'pause' || action === 'resume') {
    const clock = log.clock ??= { pausedSeconds: 0, pausedAt: null };
    if (action === 'pause') clock.pausedAt ??= now;
    else Object.assign(clock, { pausedSeconds: workoutTimes(session, now).paused, pausedAt: null });
    return;
  }
  if (action === 'trackRest') { log.trackRest = change.value; return; }
  if (action === 'extendRest' || action === 'restartRest') {
    if (!log.rest || log.clock?.pausedAt) return;
    if (action === 'extendRest') {
      const spent = workoutTimes(session, now).active - log.rest.countdownActive;
      log.rest.extension = Math.max(log.rest.extension, spent - log.rest.targetSeconds) + 15;
    } else Object.assign(log.rest, { countdownActive: workoutTimes(session, now).active, countdownStartedAt: now, extension: 0 });
    if (log.undo?.action !== 'complete') log.undo = null;
    return;
  }
  if (action === 'loadProfile') {
    if (!row || !loadKinds.includes(row.measurement)) return;
    const profiles = log.loadProfiles ??= {};
    const key = loadKey(row);
    const bar = change.bar?.trim() ? number(change.bar, 'bar weight', 0) : null;
    const increment = change.increment?.trim() ? number(change.increment, 'equipment increment', 0.001) : null;
    const plates = isBarbell(row) ? parsePlates(change.plates ?? '') : [];
    if (isBarbell(row) && (bar == null || bar > 1_000_000)) throw new Error('Enter a valid bar weight.');
    if (increment > 1_000_000) throw new Error('Enter a valid equipment increment.');
    if (bar != null) plateOptions(bar, plates, bar);
    profiles[key] = { unit: change.unit, bar, plates, increment };
    return;
  }
  if (action === 'editRest') {
    const result = session.results.find(item => item.id === change.setID);
    if (!result) return;
    const editedSeconds = change.value.trim() ? number(change.value, 'actual rest in seconds', 0, true) : null;
    if (editedSeconds != null || result.actualRest?.measuredSeconds != null) result.actualRest = { ...result.actualRest, editedSeconds };
    else delete result.actualRest;
    log.undo = null;
    return;
  }
  if (action === 'complete' && (set?.status !== 'pending' || exercise.queuedAt)) return;
  if (action === 'complete' && log.clock?.pausedAt) throw new Error('Resume the workout before completing a set.');
  if (action === 'skipRest' && !log.rest) return;
  const previousUndo = log.undo;
  log.undo = undoable.includes(action) ? structuredClone({ action, exercises: log.exercises, results: session.results,
    override: session.override, rest: log.rest ?? null }) : action === 'sessionNotes' ? log.undo : null;
  if (action === 'skipRest') { closeRest(session, log, now, 'skipped'); return; }
  if (action === 'sessionNotes') log.notes = change.value;
  else if (action === 'addExercise') {
    const entry = change.entry;
    exercises = [...exercises, entry];
    log.exercises.push({ id: entry.id, notes: '', queuedAt: null, sets: [blank()] });
  } else {
    if (!row || !exercise) throw new Error('This exercise is no longer in the workout.');
    switch (action) {
      case 'exerciseNotes': exercise.notes = change.value; break;
      case 'queue': exercise.queuedAt = change.value ? now : null; break;
      case 'removeExercise':
        if (exercise.sets.some(item => item.id === log.rest?.setID)) log.rest = null;
        log.exercises = log.exercises.filter(item => item !== exercise);
        exercises = exercises.filter(item => item !== row);
        break;
      case 'moveExercise': {
        move(log.exercises, exercise);
        const lookup = new Map(exercises.map(entry => [entry.id, entry]));
        exercises = log.exercises.map(entry => lookup.get(entry.id));
        break;
      }
      case 'skipExercise':
      case 'restoreExercise':
        exercise.queuedAt = null;
        for (const item of exercise.sets) {
          if (action === 'skipExercise' && item.status === 'pending') item.status = 'skipped';
          if (action === 'restoreExercise' && item.status === 'skipped') item.status = 'pending';
        }
        break;
      case 'addSet': exercise.sets.push(blank(change.purpose)); break;
      default:
        if (!set) throw new Error('This set is no longer in the workout.');
        switch (action) {
          case 'editSet':
            if (set.status === 'pending') {
              set.input = { ...sessionInput(set, unit), [change.field]: change.value };
              if (change.field === 'separateSides' && change.value) set.input.rightReps = set.input.reps;
            }
            break;
          case 'removeSet':
            if (log.rest?.setID === set.id) log.rest = null;
            exercise.sets = exercise.sets.filter(item => item !== set);
            break;
          case 'moveSet': move(exercise.sets, set); break;
          case 'skipSet': if (set.status === 'pending') set.status = 'skipped'; break;
          case 'restoreSet': if (set.status === 'skipped') set.status = 'pending'; break;
          case 'undo':
            if (set.status === 'completed') {
              set.status = 'pending';
              if (log.rest?.setID === set.id && previousUndo?.action === 'complete') {
                session.results = previousUndo.results;
                log.rest = previousUndo.rest;
              } else if (log.rest?.setID === set.id) log.rest = null;
            }
            break;
          case 'complete': {
            const input = sessionInput(set, unit);
            const result = performedResult(input, row, set, now);
            closeRest(session, log, now, 'nextSet');
            session.results.push(result);
            set.input = input;
            set.status = 'completed';
            openRest(session, log, plan, set, now);
            break;
          }
        }
    }
  }
  if (exercises !== plan.exercises) session.override = { ...plan, exercises, groups: keepingGroups(plan.groups, exercises) };
  session.log = log;
  synchronizeResults(session);
}

export function synchronizeResults(session) {
  const byID = new Map(session.results.map(result => [result.id, result]));
  session.results = session.log.exercises.flatMap(exercise => exercise.sets.flatMap((set, index) => {
    const result = byID.get(set.id);
    return set.status === 'completed' && result ? [{ ...result, order: index + 1 }] : [];
  }));
}

export function reconcileLog(session, prior, next) {
  if (!session.log) return;
  session.log.undo = null;
  session.log.exercises = next.exercises.map(row => {
    const log = session.log.exercises.find(entry => entry.id === row.id);
    const old = prior.exercises.find(entry => entry.id === row.id);
    if (!log || variantKey(old) !== variantKey(row)) return fromPlan(row);
    if (JSON.stringify([old.warm, old.work]) !== JSON.stringify([row.warm, row.work])) {
      const replacements = fromPlan(row).sets;
      log.sets = log.sets.flatMap((set, index) => set.status !== 'pending' || set.input ? [set] : replacements.slice(index, index + 1))
        .concat(replacements.slice(log.sets.length));
    }
    return log;
  });
  synchronizeResults(session);
}

export function routineFromLog(session) {
  const plan = sessionPlan(session);
  const log = workoutLog(session);
  if (!plan.exercises.length) throw new Error('Keep an exercise before updating the routine.');
  const exercises = plan.exercises.map(row => {
    const sets = log.exercises.find(exercise => exercise.id === row.id)?.sets ?? [];
    function blocks(purpose) {
      const result = [];
      for (const set of sets.filter(set => set.purpose === purpose)) {
        const block = { id: set.plan?.id ?? set.id, sets: 1, reps: null, target: null, rest: null,
          effort: null, amrap: false, structure: 'straight', ...set.plan };
        block.sets = 1;
        if (set.input) {
          const before = sessionInput({ ...set, input: null }, set.input.unit);
          if (set.input.amount && set.input.amount !== before.amount) block.target = actualAmount(set.input, row);
          if (hasReps(row) && (set.input.reps !== before.reps || set.input.rightReps !== before.rightReps)) {
            const sided = row.counting === 'separateSides' || set.input.separateSides;
            const left = number(set.input.reps, 'rep target', sided ? 0 : 1, true);
            const right = sided ? number(set.input.rightReps, 'right rep target', 0, true) : left;
            if (left === 0 && right === 0) throw new Error('Enter at least one rep target.');
            const maximum = Math.max(left, right);
            block.reps = { minimum: Math.min(left, right) || maximum, maximum };
          }
        }
        if (hasReps(row) && !block.reps && !block.amrap) throw new Error('Enter valid rep targets for added sets before updating the routine.');
        const { sets: _sets, id: _id, ...meaning } = block;
        const prior = result.at(-1);
        if (prior) {
          const { sets: _count, id: _priorID, ...priorMeaning } = prior;
          if (JSON.stringify(meaning) === JSON.stringify(priorMeaning)) { prior.sets++; continue; }
        }
        result.push(block);
      }
      return result;
    }
    const work = blocks('working');
    if (!work.length) throw new Error('Keep a working set for each exercise before updating the routine.');
    return { ...row, warm: blocks('warm-up'), work };
  });
  return { exercises, groups: plan.groups };
}

export function previousResult(session, history, row, set, exercise) {
  const index = exercise.sets.filter(item => item.purpose === set.purpose).indexOf(set);
  const completed = history.filter(item => item.completedAt)
    .sort((left, right) => right.startedAt.localeCompare(left.startedAt));
  const reference = completed.find(item => item.id === session.referenceID);
  const older = completed.filter(item => item !== reference && (!session.startedAt || item.startedAt <= session.startedAt));
  for (const item of [...(reference ? [reference] : []), ...older]) {
    const matches = sessionPlan(item).exercises.filter(candidate => variantKey(candidate) === variantKey(row));
    const match = matches.find(candidate => candidate.id === row.id) ?? matches[0];
    const previous = item.log?.exercises.find(exercise => exercise.id === match?.id);
    if (previous) {
      const slot = previous.sets.filter(candidate => candidate.purpose === set.purpose)[index];
      const result = slot && item.results.find(result => result.id === slot.id);
      if (result) return result;
      if (item === reference) return null;
      continue;
    }
    const results = item.results.filter(result => result.exerciseID === match?.id && (result.purpose ?? 'working') === set.purpose);
    if (results[index]) return results[index];
    if (item === reference && match) return null;
  }
  return null;
}
