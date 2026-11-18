const seconds = (end, start) => Math.max(0, (Date.parse(end) - Date.parse(start)) / 1000);

export function workoutTimes(session, now) {
  const clock = session.log?.clock;
  const elapsed = seconds(session.completedAt ?? now, session.startedAt);
  const paused = Math.min(elapsed, (clock?.pausedSeconds ?? 0) + (clock?.pausedAt ? seconds(session.completedAt ?? now, clock.pausedAt) : 0));
  return { elapsed, paused, active: elapsed - paused };
}

export function workoutSequence(log, plan) {
  const sequence = [];
  const byID = new Map(log.exercises.filter(exercise => !exercise.queuedAt).map(exercise => [exercise.id, exercise]));
  const grouped = new Set();
  for (const exercise of log.exercises) {
    if (grouped.has(exercise.id)) continue;
    const group = plan.groups.find(group => group.members.includes(exercise.id));
    const append = (member, set, round = null) => sequence.push({ exerciseID: member.id, set, group: round === null ? null : group, round });
    if (!group) {
      if (!exercise.queuedAt) exercise.sets.forEach(set => append(exercise, set));
      continue;
    }
    group.members.forEach(id => grouped.add(id));
    const members = group.members.map(id => byID.get(id)).filter(Boolean);
    const work = members.map(member => member.sets.filter(set => set.purpose === 'working'));
    for (const member of members) member.sets.filter(set => set.purpose !== 'working').forEach(set => append(member, set));
    const rounds = Math.min(group.rounds, Math.max(0, ...work.map(sets => sets.length)));
    for (let round = 0; round < rounds; round++) {
      members.forEach((member, index) => { if (work[index][round]) append(member, work[index][round], round); });
    }
    members.forEach((member, index) => work[index].slice(rounds).forEach(set => append(member, set)));
  }
  return sequence;
}

export function openRest(session, log, plan, set, now) {
  const sequence = workoutSequence(log, plan);
  const source = sequence.find(item => item.set.id === set.id);
  const next = sequence.find(item => item.set.status === 'pending');
  const group = source?.group && next?.group?.id === source.group.id ? source.group : null;
  const sameRound = group && next.round === source.round;
  const targetSeconds = group ? (sameRound ? group.restExercises : group.restRounds) : (set.plan?.rest ?? 90);
  const rule = group ? (sameRound ? 'Between exercises' : 'Between rounds') : (set.plan?.rest == null ? 'Default rest' : 'Set rest');
  const active = workoutTimes(session, now).active;
  log.rest = { setID: set.id, startedAt: now, countdownStartedAt: now, startedActive: active,
    countdownActive: active, extension: 0, targetSeconds, rule };
}

export function closeRest(session, log, now, reason) {
  const rest = log.rest;
  if (!rest) return;
  const result = session.results.find(result => result.id === rest.setID);
  if (result && log.trackRest) result.actualRest = { ...result.actualRest, measuredSeconds: Math.floor(Math.max(0, workoutTimes(session, now).active - rest.startedActive)),
    startedAt: rest.startedAt, endedAt: now, reason };
  log.rest = null;
}

export function restRemaining(session, now) {
  const rest = session.log?.rest;
  return rest ? Math.max(0, Math.ceil(rest.targetSeconds + rest.extension - (workoutTimes(session, now).active - rest.countdownActive))) : null;
}

export function clockText(seconds) {
  const value = Math.floor(seconds);
  return Math.floor(value / 60) + ':' + String(value % 60).padStart(2, '0');
}

const scaled = weight => Math.round(weight * 1000);
export function plateOptions(bar, entries, target) {
  if (!Number.isFinite(bar) || bar < 0 || bar > 1_000_000 || !Number.isFinite(target) || target < 0 || target > 1_000_000) return null;
  let combinations = new Map([[0, []]]);
  for (const { weight, count } of entries) {
    const next = new Map();
    for (const [sum, plates] of combinations) {
      for (let i = 0; i <= count; i++) {
        const value = sum + i * scaled(weight);
        if (!next.has(value) || next.get(value).length > plates.length + i) next.set(value, [...plates, ...Array(i).fill(weight)]);
        if (next.size > 25000) throw new Error('Use fewer plate sizes or pairs in this calculation.');
      }
    }
    combinations = next;
  }
  const values = [...combinations.keys()].map(sum => scaled(bar) + 2 * sum).sort((a, b) => a - b);
  const requested = scaled(target);
  const exact = values.includes(requested);
  const lower = values.findLast(value => value < requested);
  const upper = values.find(value => value > requested);
  return { exact, plates: exact ? combinations.get((requested - scaled(bar)) / 2).sort((a, b) => b - a) : [],
    lower: lower == null ? null : lower / 1000, upper: upper == null ? null : upper / 1000 };
}

export function parsePlates(text) {
  if (!text.trim()) return [];
  const entries = text.split(',').map(item => {
    const match = item.trim().match(/^(\d+(?:\.\d{1,3})?)\s*[x×:]\s*(\d+)$/i);
    return match && { weight: Number(match[1]), count: Number(match[2]) };
  });
  if (entries.length > 12 || entries.some(item => !item || item.weight <= 0 || item.weight > 1000 || item.count < 1 || item.count > 30)) {
    throw new Error('Enter up to 12 plate sizes as weight × pairs, for example 20x2, 5x1. Each size supports up to 30 pairs.');
  }
  return entries;
}

export function typoHint(input, reference, row) {
  const number = value => String(value ?? '').trim() ? Number(String(value).replace(',', '.')) : NaN;
  const unusual = (value, baseline, gap) => value > 0 && baseline > 0 &&
    ((value >= baseline * 2 && value - baseline >= gap) || (value <= baseline / 2 && baseline - value >= gap));
  const checks = [];
  const amountGap = row.measurement === 'duration' ? 15 : 2;
  if (['weight', 'added', 'assistance', 'duration'].includes(row.measurement) &&
      (unusual(number(input.amount), number(reference.amount), amountGap) ||
       unusual(number(input.rightAmount), number(reference.rightAmount || reference.amount), amountGap))) checks.push(row.measurement === 'duration' ? 'duration' : 'load');
  const unusualReps = (text, typical) => {
    const value = number(text);
    const range = reference.repRange;
    return !(range && value >= range.minimum && value <= range.maximum) && unusual(value, number(typical), 4);
  };
  if (unusualReps(input.reps, reference.reps) || unusualReps(input.rightReps, reference.rightReps || reference.reps)) checks.push('reps');
  return checks.length ? 'Double-check ' + checks.join(' and ') + '. You can still log this set.' : '';
}
