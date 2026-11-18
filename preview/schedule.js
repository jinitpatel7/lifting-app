import { isDay, localDayKey } from './storage.js';
import { sessionPlan } from './workout-log.js';

export const weekdays = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
export const weekKinds = { training: 'Training', progression: 'Progression', deload: 'Deload' };
const dayMs = 86_400_000;
export const weekdayOf = date => new Date(date + 'T00:00:00Z').getUTCDay();
export const dayDistance = (from, to) => (Date.parse(to) - Date.parse(from)) / dayMs;
export const offsetDay = (date, offset) => new Date(Date.parse(date) + offset * dayMs).toISOString().slice(0, 10);
export const scheduleVersion = (data, id) => data.routines.flatMap(routine => routine.versions).find(version => version.id === id);

export function scheduleWindow(anchor, settings) {
  const start = settings?.mode === 'rolling' ? anchor : offsetDay(anchor, -((weekdayOf(anchor) - (settings?.weekStart ?? 1) + 7) % 7));
  return Array.from({ length: 7 }, (_, index) => offsetDay(start, index));
}

function disposition(entry, sessions, today) {
  const workout = sessions.find(session => session.scheduleID === entry.id);
  if (workout) return workout.completedAt ? 'completed' : 'active';
  if (entry.skippedOn) return 'skipped';
  if (entry.date < today) return 'missed';
  return entry.moves?.length ? 'rescheduled' : 'planned';
}

export const statusLabels = { planned: 'Planned', completed: 'Completed', active: 'In progress', skipped: 'Skipped',
  missed: 'Missed', rescheduled: 'Rescheduled', moved: 'Rescheduled' };
const later = (a, b) => a > b ? a : b;

export function scheduleEntries(data, dates, today = localDayKey()) {
  const days = new Set(dates);
  const occupied = new Set(data.schedule.map(entry => entry.sourceKey).filter(Boolean));
  const result = [];
  for (const entry of data.schedule) {
    const status = disposition(entry, data.sessions, today);
    if (days.has(entry.date)) result.push({ ...entry, key: entry.id, status });
    for (const former of new Set(entry.moves ?? [])) {
      if (days.has(former) && former !== entry.date) result.push({ ...entry, date: former, destination: entry.date, key: entry.id + ':moved:' + former, status: 'moved' });
    }
  }
  for (const rule of data.weekdayRules ?? []) {
    for (const date of days) {
      const key = 'weekday:' + rule.id + ':' + date;
      if (date >= rule.start && (!rule.endBefore || date < rule.endBefore) && weekdayOf(date) === rule.weekday && !occupied.has(key)) {
        result.push({ key, sourceKey: key, date, versionID: rule.versionID, status: date < today ? 'missed' : 'planned', virtual: true });
      }
    }
  }
  for (const rotation of data.rotations ?? []) {
    const materialized = data.schedule.filter(entry => entry.rotationID === rotation.id);
    const decisions = materialized.flatMap(entry => {
      if (entry.skippedOn) return [later(entry.date, entry.skippedOn)];
      const workout = data.sessions.find(session => session.scheduleID === entry.id && session.completedAt && session.results.length);
      return workout ? [later(entry.date, workout.finishedLocalDate ?? workout.localDate)] : [];
    });
    const cadenceOnOrAfter = start => {
      const remainder = dayDistance(rotation.start, start) % rotation.interval;
      return offsetDay(start, remainder ? rotation.interval - remainder : 0);
    };
    let upcoming = cadenceOnOrAfter(later(today, rotation.start));
    const keyFor = date => 'rotation:' + rotation.id + ':' + date;
    const displacement = date => materialized.reduce((end, entry) =>
      entry.moves?.length && entry.moves[0] <= date && date <= entry.date ? later(end, entry.date) : end, '');
    for (let until = displacement(upcoming); until || occupied.has(keyFor(upcoming)); until = displacement(upcoming)) {
      upcoming = until ? cadenceOnOrAfter(offsetDay(until, 1)) : offsetDay(upcoming, rotation.interval);
    }
    const holdsNext = materialized.some(entry => ['planned', 'rescheduled', 'active'].includes(disposition(entry, data.sessions, today)));
    for (const date of days) {
      const key = keyFor(date);
      if (date < rotation.start || (rotation.endBefore && date >= rotation.endBefore) ||
          dayDistance(rotation.start, date) % rotation.interval !== 0 || occupied.has(key)) continue;
      if (date >= today && (holdsNext || date !== upcoming)) continue;
      if (displacement(date)) continue;
      const step = decisions.filter(when => when <= date).length % rotation.versions.length;
      result.push({ key, sourceKey: key, date, versionID: rotation.versions[step], rotationID: rotation.id,
        status: date < today ? 'missed' : 'planned', virtual: true, step });
    }
  }
  return result.sort((a, b) => a.date.localeCompare(b.date));
}

export function scheduleEntry(data, key, date, today) {
  if (!isDay(date)) throw new Error('Choose a valid workout date.');
  const entry = scheduleEntries(data, [date], today).find(item => item.key === key);
  if (!entry || !['planned', 'rescheduled', 'missed'].includes(entry.status) || (entry.rotationID && entry.status === 'missed')) {
    throw new Error('This scheduled workout can no longer be changed. Open the current schedule.');
  }
  if (!entry.virtual) return data.schedule.find(item => item.id === entry.id);
  const { status, key: ignored, virtual, step, ...value } = entry;
  const record = { ...value, id: crypto.randomUUID(), createdAt: new Date().toISOString() };
  data.schedule.push(record);
  return record;
}

export function applyScheduleChange(data, change, today = localDayKey()) {
  const { action } = change;
  const validVersion = id => Boolean(scheduleVersion(data, id));
  const badDate = day => !isDay(day);
  switch (action) {
    case 'settings':
      if (!weekdays[change.weekStart] || !['week', 'rolling'].includes(change.mode)) throw new Error('Choose a training-week start and calendar view.');
      data.scheduleSettings = { weekStart: change.weekStart, mode: change.mode };
      break;
    case 'weekday':
      if (!validVersion(change.versionID) || !weekdays[change.weekday] || badDate(change.start)) throw new Error('Choose a saved routine, weekday, and start date.');
      if (!data.weekdayRules.some(rule => rule.weekday === change.weekday && rule.versionID === change.versionID && !rule.endBefore)) {
        data.weekdayRules.push({ id: crypto.randomUUID(), weekday: change.weekday, versionID: change.versionID, start: change.start });
      }
      break;
    case 'stopWeekday': {
      const rule = data.weekdayRules.find(rule => rule.id === change.id && !rule.endBefore);
      if (rule) rule.endBefore = today;
      break;
    }
    case 'rotation':
      if (!change.versions.length || !change.versions.every(validVersion) || badDate(change.start) ||
          (change.start < today && data.rotations.some(item => !item.endBefore)) ||
          !Number.isInteger(change.interval) || change.interval < 1 || change.interval > 30) throw new Error('Choose a start date, a cadence of 1–30 days, and an ordered routine sequence.');
      for (const rotation of data.rotations.filter(item => !item.endBefore)) rotation.endBefore = today;
      data.rotations.push({ id: crypto.randomUUID(), start: change.start, interval: change.interval, versions: change.versions });
      break;
    case 'stopRotation': {
      const rotation = data.rotations.find(item => item.id === change.id && !item.endBefore);
      if (rotation) rotation.endBefore = today;
      break;
    }
    case 'move': {
      if (badDate(change.destination) || change.destination < today || change.destination === change.date) throw new Error('Choose a different date, today or later.');
      const entry = scheduleEntry(data, change.key, change.date, today);
      entry.moves = [...entry.moves ?? [], entry.date];
      entry.date = change.destination;
      break;
    }
    case 'skip':
      scheduleEntry(data, change.key, change.date, today).skippedOn = today;
      break;
    case 'block': {
      const name = change.name.trim();
      if (!name || badDate(change.start) || !Number.isInteger(change.count) || change.count < 2 || change.count > 52) {
        throw new Error('Enter a program name, start date, and 2–52 weeks.');
      }
      data.programBlocks.push({ id: crypto.randomUUID(), name, first: change.start, last: offsetDay(change.start, change.count * 7 - 1), weeks: {} });
      break;
    }
    case 'blockWeek':
    case 'blockSession': {
      const block = data.programBlocks.find(item => item.id === change.id);
      if (!block || badDate(change.date) || change.date < block.first || change.date > block.last) throw new Error('Choose a date within the program block.');
      const week = Math.floor(dayDistance(block.first, change.date) / 7);
      if (action === 'blockWeek') {
        if (!Object.hasOwn(weekKinds, change.kind)) throw new Error('Choose a week type.');
        block.weeks[week] = { kind: change.kind, notes: change.notes.trim() };
      } else {
        if (!validVersion(change.versionID)) throw new Error('Choose a saved routine version.');
        data.schedule.push({ id: crypto.randomUUID(), date: change.date, versionID: change.versionID, blockID: block.id });
      }
      break;
    }
    case 'readiness': {
      const { soreness, sleep, energy, motivation, date } = change;
      if (badDate(date) || date > today || ![soreness, sleep, energy, motivation].every(value => Number.isInteger(value) && value >= 1 && value <= 5)) {
        throw new Error('Enter all four ratings from 1 to 5 on a local date through today.');
      }
      const prior = data.readiness.find(item => item.date === date);
      const entry = { ...prior, id: prior?.id ?? crypto.randomUUID(), date, soreness, sleep, energy, motivation, updatedAt: new Date().toISOString() };
      data.readiness = [...data.readiness.filter(item => item.date !== date), entry];
      break;
    }
  }
}

export function recentMuscles(sessions, asOf, lookup) {
  const result = {};
  for (const session of sessions) {
    if (session.localDate > asOf) continue;
    const actual = new Set(session.results.map(set => set.exerciseID));
    for (const row of sessionPlan(session).exercises.filter(entry => actual.has(entry.id))) {
      const details = row.exercise.primary ? row.exercise : lookup(row.exercise.id);
      for (const muscle of [...details?.primary ?? [], ...details?.secondary ?? []]) {
        if (!result[muscle] || result[muscle].date < session.localDate) {
          result[muscle] = { date: session.localDate, days: dayDistance(session.localDate, asOf) };
        }
      }
    }
  }
  return result;
}
