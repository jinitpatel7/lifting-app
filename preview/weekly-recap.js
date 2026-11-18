import { exerciseAnalytics, programContext, weeklyAnalytics } from './analytics.js';
import { bodyweightTrend } from './bodyweight.js';
import { comparableWorkingResult } from './forecast.js';
import { dayOf, equipmentName, historyVariantKey, sessionStatus, unlinkedStation } from './history.js';
import { dayDistance, offsetDay, scheduleEntries, scheduleVersion } from './schedule.js';
import { localDayKey } from './storage.js';
import { workoutEnergy } from './workout-energy.js';
import { sessionPlan } from './workout-log.js';

const epsilon = 1e-7;
const greater = (a, b) => a > b + epsilon;

function personalRecords(data, finished, first, last) {
  if (!finished.some(session => dayOf(session) >= first)) return [];
  const history = { ...data, sessions: finished };
  const prior = new Map(exerciseAnalytics(history, { to: offsetDay(first, -1) }).map(item => [item.key, item]));
  return exerciseAnalytics(history, { from: first, to: last }).flatMap(item => {
    const earlier = prior.get(item.key);
    if (!earlier) return [];
    const title = { key: item.key, name: item.row.exercise.name, equipment: equipmentName(item.row),
      perDumbbell: item.row.measurement === 'weight' && item.row.basis === 'perDumbbell' };
    const { heaviest, byLoad, byReps } = item.records;
    if (heaviest && earlier.records.heaviest && greater(heaviest.load, earlier.records.heaviest.load)) {
      return [{ ...title, kind: 'Heaviest load', date: heaviest.date, effort: heaviest }];
    }
    const bestReps = byLoad.find(target => earlier.records.byLoad.some(old => old.side === target.side &&
      Math.abs(old.load - target.load) < epsilon && target.reps > old.reps));
    if (bestReps) return [{ ...title, kind: 'Most reps at this load', date: bestReps.date, effort: bestReps }];
    const bestLoad = byReps.find(target => earlier.records.byReps.some(old => old.side === target.side &&
      old.reps === target.reps && greater(target.load, old.load)));
    if (bestLoad) return [{ ...title, kind: 'Heaviest at this rep count', date: bestLoad.date, effort: bestLoad }];
    for (const metric of ['duration', 'distance']) {
      const old = earlier.points.flatMap(point => point.values[metric] == null ? [] : [point.values[metric]]);
      const best = item.points.filter(point => point.values[metric] != null).reduce((best, point) =>
        !best || point.values[metric] > best.values[metric] ? point : best, null);
      if (old.length && best && old.every(value => greater(best.values[metric], value))) {
        return [{ ...title, kind: metric === 'duration' ? 'Most working-set time in a day' : 'Most working-set distance in a day',
          date: best.date, metric, value: best.values[metric] }];
      }
    }
    return [];
  });
}

function comparableChanges(finished, start) {
  const groups = new Map();
  for (const session of finished.slice().sort((a, b) => a.startedAt.localeCompare(b.startedAt))) {
    const accepted = new Set();
    for (const row of sessionPlan(session).exercises) {
      if (unlinkedStation(row)) continue;
      const result = comparableWorkingResult(session, row);
      if (!result) continue;
      const setting = row.measurement === 'setting' ? result.result.amount?.value : null;
      const key = JSON.stringify([historyVariantKey(row, session.id), result.order, setting]);
      if (accepted.has(key)) continue;
      accepted.add(key);
      const value = { day: dayOf(session), values: result.values };
      const series = groups.get(key) ?? { key, row, setting };
      if (value.day >= start && series.latest) series.pair = { previous: series.latest, current: value };
      series.latest = value;
      groups.set(key, series);
    }
  }
  return [...groups.values()].flatMap(({ key, row, setting, pair }) => {
    if (!pair || !Object.keys(pair.current.values).some(metric => Math.abs(pair.current.values[metric] - pair.previous.values[metric]) >= epsilon)) return [];
    return [{ key, name: row.exercise.name, equipment: equipmentName(row), basis: row.basis, counting: row.counting, setting, ...pair }];
  });
}

function nextScheduled(data, today) {
  const days = Array.from({ length: 90 }, (_, index) => offsetDay(today, index));
  const distant = data.schedule.filter(item => dayDistance(today, item.date) >= days.length).map(item => item.date);
  for (const rule of [...(data.weekdayRules ?? []), ...(data.rotations ?? [])]) {
    if (dayDistance(today, rule.start) >= days.length) distant.push(...Array.from({ length: 7 }, (_, index) => offsetDay(rule.start, index)));
  }
  for (const entry of scheduleEntries(data, [...days, ...distant], today)) {
    if (!['planned', 'rescheduled'].includes(entry.status)) continue;
    const plan = scheduleVersion(data, entry.versionID);
    if (plan) return { entry, plan };
  }
  return null;
}

export function weeklyRecap(data, entries, anchor, lookup, today = localDayKey()) {
  const training = weeklyAnalytics(data, anchor, { to: today }, lookup, today);
  const [first] = training.days;
  const last = training.days.at(-1);
  const cutoff = last < today ? last : today;
  const scheduled = scheduleEntries(data, training.days, today).filter(item => item.status !== 'moved');
  const past = data.sessions.filter(session => dayOf(session) <= cutoff);
  const local = past.filter(session => dayOf(session) >= first);
  const linked = new Map(data.sessions.filter(session => session.scheduleID && dayOf(session) <= today).map(session => [session.scheduleID, session]));
  const completed = session => session && sessionStatus(session) === 'Completed';
  const jobs = {
    planned: scheduled.length,
    scheduled: scheduled.filter(item => completed(linked.get(item.id))).length,
    unscheduled: local.filter(session => !session.scheduleID && completed(session)).length,
    incomplete: local.filter(session => !completed(session)).length,
    scheduledIncomplete: scheduled.filter(item => linked.has(item.id) && !completed(linked.get(item.id))).length,
    skipped: scheduled.filter(item => item.status === 'skipped').length,
    missed: scheduled.filter(item => item.status === 'missed').length,
    pending: scheduled.filter(item => ['planned', 'rescheduled'].includes(item.status)).length,
    deload: scheduled.filter(item => programContext(data, { localDate: item.date, scheduleID: item.id }).kind === 'deload').length,
  };
  const finished = past.filter(session => session.completedAt && programContext(data, session).kind !== 'deload');
  const deloads = (data.programBlocks ?? []).filter(block => training.days.some(day => day >= block.first && day <= block.last &&
    block.weeks?.[Math.floor(dayDistance(block.first, day) / 7)]?.kind === 'deload')).map(block => block.name);
  const readings = bodyweightTrend(Object.values(entries), cutoff).filter(point => point.day >= first);
  const trend = readings.filter(point => point.smoothed != null);
  const eligibleEnergy = local.filter(session => session.completedAt && session.results.length);
  const calories = eligibleEnergy.flatMap(session => {
    const estimate = workoutEnergy(session.energyInput, entries[dayOf(session)]?.kilograms);
    return estimate ? [estimate.kilocalories] : [];
  });
  return { first, last, cutoff, training, jobs, deloads, records: personalRecords(data, finished, first, cutoff), changes: comparableChanges(finished, first),
    weight: { count: readings.length, latest: trend.at(-1), initial: trend.length > 1 ? trend[0] : null },
    energy: { count: calories.length, total: calories.reduce((sum, value) => sum + value, 0), eligible: eligibleEnergy.length },
    next: nextScheduled(data, today) };
}
