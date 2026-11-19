import { escapeHTML as html } from './exercises.js';
import { comparisonScopes, compareSessions, dayOf, equipmentKey, equipmentName, historyFilter, historyRows,
  priorComparable, sessionMetrics, sessionStatus } from './history.js';
import { completedCounts, plannedCounts } from './analytics.js';
import { bodyweightOn } from './bodyweight-ui.js';
import { photoDates } from './device-photos.js';
import { renderPhotoArea } from './progress-photos-ui.js';
import { offsetDay, weekdayOf } from './schedule.js';
import { renderPlan, setSummary } from './routine-ui.js';
import { hasReps, measurements } from './routines.js';
import { kilogramsPerPound, localDayKey } from './storage.js';
import { sessionPlan } from './workout-log.js';
import { resultSummary } from './workout-ui.js';
import { clockText, workoutTimes } from './workout-tools.js';
import { renderForecastArchive } from './forecast-ui.js';
import { renderSessionEnergy } from './recap-ui.js';

const button = (name, action, value = '', extra = '') => `<button type="button" class="secondary" data-action="${action}" data-value="${html(value)}" ${extra}>${html(name)}</button>`;
const option = (value, label, current) => `<option value="${html(value)}"${value === current ? ' selected' : ''}>${html(label)}</option>`;
const options = (items, selected) => [...items].map(([value, label]) => option(value, label, selected)).join('');
const select = (label, attrs, body) => `<label>${html(label)}<select aria-label="${html(label)}" ${attrs}>${body}</select></label>`;
const field = (label, attrs, value, type = 'text') =>
  `<label>${html(label)}<input type="${type}" aria-label="${html(label)}" ${attrs} value="${html(value)}"></label>`;
const text = (label, attrs, value) => `<label>${html(label)}<textarea rows="2" aria-label="${html(label)}" ${attrs}>${html(value)}</textarea></label>`;
const errors = '<p id="history-error" class="entry-error" role="alert"></p>';
const changeText = value => (value > 0 ? '+' : value < 0 ? '−' : '') + Math.abs(value);
const mass = (kg, unit) => new Intl.NumberFormat('en-US', { maximumFractionDigits: 2 }).format(unit === 'lb' ? kg / kilogramsPerPound : kg);
const versionText = session => session.snapshot.revision > 0 ? 'Version ' + session.snapshot.revision : 'Standalone workout';

export function renderHistoryFilters(sessions, filter) {
  const rows = sessions.flatMap(session => sessionPlan(session).exercises);
  const routines = new Map(sessions.filter(session => session.snapshot.revision > 0).map(session => [session.snapshot.routineID, session.snapshot.name]));
  const exercises = new Map(rows.map(row => [row.exercise.id, row.exercise.name]));
  const gear = new Map(rows.map(row => [equipmentKey(row), equipmentName(row)]));
  return `<details class="surface settings-card history-filters" ${Object.values(filter).some(Boolean) ? 'open' : ''}><summary>Filters</summary><div class="builder-fields">
    ${select('Routine', 'data-history-filter="routine"', option('', 'All routines', filter.routine) + options(routines, filter.routine))}
    ${select('Exercise', 'data-history-filter="exercise"', option('', 'All exercises', filter.exercise) + options(exercises, filter.exercise))}
    ${select('Equipment', 'data-history-filter="equipment"', option('', 'All equipment', filter.equipment) + options(gear, filter.equipment))}
    ${field('From date', 'data-history-filter="from"', filter.from, 'date')}${field('Through date', 'data-history-filter="to"', filter.to, 'date')}
    </div>${button('Clear filters', 'history-clear')}</details>`;
}

export function calendarMonth(day, shift = 0) {
  const base = new Date(day.slice(0, 7) + '-01T00:00:00Z');
  base.setUTCMonth(base.getUTCMonth() + shift);
  return base.toISOString().slice(0, 10);
}

export function renderHistoryCalendar(sessions, month, day, format, photos, readings) {
  const first = calendarMonth(month);
  const last = offsetDay(calendarMonth(first, 1), -1);
  const items = [];
  const status = new Map();
  const linked = new Set(photoDates(photos));
  for (const session of sessions) {
    const date = dayOf(session);
    const prior = status.get(date) ?? [];
    status.set(date, [...prior, sessionStatus(session)]);
  }
  for (let offset = 0; offset < (weekdayOf(first) + 6) % 7; offset++) items.push('<span aria-hidden="true"></span>');
  for (let date = first; date <= last; date = offsetDay(date, 1)) {
    const workouts = status.get(date) ?? [];
    const count = workouts.filter(item => item === 'Completed').length;
    const rest = workouts.length - count;
    const visible = String(Number(date.slice(8)));
    const label = visible + ' · ' + format(date, { weekday: 'long', month: 'long', day: 'numeric' }) +
      (workouts.length ? ', ' + [count ? count + ' completed' : '', rest ? rest + ' incomplete' : ''].filter(Boolean).join(', ') : ', no workouts') +
      (linked.has(date) ? ', progress photos' : '') + (readings[date] ? ', bodyweight reading' : '');
    items.push(`<button type="button" class="history-day" data-action="history-day" data-value="${date}" aria-label="${html(label)}" aria-pressed="${date === day}" ${date === localDayKey() ? 'aria-current="date"' : ''}>
      <span>${visible}</span><span class="history-day-dots" aria-hidden="true">${count ? '<i class="has-completed"></i>' : ''}${rest ? '<i class="has-incomplete"></i>' : ''}
      ${linked.has(date) ? '<i class="has-photo"></i>' : ''}${readings[date] ? '<i class="has-weight"></i>' : ''}</span></button>`);
  }
  return `<section class="surface settings-card history-month"><div class="section-top"><h2>${format(first, { month: 'long', year: 'numeric' })}</h2>
    <div class="builder-actions">${button('Previous month', 'history-month', '-1')}${button('Next month', 'history-month', '1')}</div></div>
    <div class="history-days">${['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'].map(name => `<span class="history-weekday">${name}</span>`).join('')}${items.join('')}</div></section>`;
}

export function renderHistoryMetrics(metrics, unit, showDuration = true) {
  return `<dl class="history-metrics"><div><dt>Completed sets</dt><dd>${metrics.count}</dd></div>
    ${showDuration ? `<div><dt>Duration</dt><dd>${metrics.duration == null ? 'Unrecorded' : clockText(metrics.duration)}</dd></div>` : ''}
    ${metrics.volume != null ? `<div><dt>Logged volume</dt><dd>${mass(metrics.volume, unit)} ${unit}·reps</dd></div>` : ''}</dl>`;
}

function historyExercise(session, row, unit, compact) {
  const record = session.log?.exercises.find(exercise => exercise.id === row.id);
  const rows = historyRows(session, row);
  return `<div class="history-exercise"><h4>${html(row.exercise.name)}</h4><p class="builder-hint">${html(equipmentName(row))}</p>
    ${record?.notes ? `<p>${html(record.notes)}</p>` : ''}
    ${rows.length ? `<ol class="history-results">${rows.map(set =>
      `<li><strong>${set.purpose === 'warm-up' ? 'Warm-up' : 'Set'} ${set.order}</strong>
      ${!compact && set.plan ? `<span>Prescription · ${html(setSummary({ ...set.plan, sets: 1 }, row, unit))}</span>` : ''}
      <span>${set.result ? 'Performed · ' + html(resultSummary(set.result, row, unit)) : set.status === 'skipped' ? 'Skipped' : 'Unfinished'}</span>
      ${set.result?.actualRest?.measuredSeconds != null || set.result?.actualRest?.editedSeconds != null ? `<span>${[
        set.result.actualRest.measuredSeconds == null ? '' : `Measured rest ${set.result.actualRest.measuredSeconds}s`,
        set.result.actualRest.editedSeconds == null ? '' : `Edited rest ${set.result.actualRest.editedSeconds}s`].filter(Boolean).join(' · ')}</span>` : ''}</li>`).join('')}</ol>` :
      '<p class="builder-hint">No performed sets.</p>'}</div>`;
}

export function historyCard(session, unit, active, photos, dateLabel, entries) {
  const plan = sessionPlan(session);
  return `<article class="surface settings-card saved-routine history-card"><h3>${html(plan.name)}</h3>
    <p class="history-status ${sessionStatus(session) === 'Completed' ? 'is-complete' : ''}">${sessionStatus(session)} · ${versionText(session)}</p>
    <p class="builder-hint">${html(dateLabel(dayOf(session)))} · ${session.results.length} recorded sets${session.endedEarly ? ' · Ended early' : ''}</p>
    ${session.completedAt && session.durationKnown !== false && session.log ? `<p class="builder-hint history-time">${historyTime(session)}</p>` : ''}
    ${planTally(session)}
    ${session.log?.notes ? `<p>${html(session.log.notes)}</p>` : ''}
    ${plan.exercises.map(row => historyExercise(session, row, unit, false)).join('')}
    ${renderForecastArchive(session, unit, dateLabel)}
    ${session.completedAt ? renderSessionEnergy(session, entries) : ''}
    ${session.snapshot.revision > 0 ? `<details><summary>Original routine prescription</summary>${renderPlan(session.snapshot, unit)}</details>` : ''}
    <section class="history-photos"><h4>Progress photos</h4>${renderPhotoArea(photos, dayOf(session), session.id, Boolean(session.completedAt))}</section>
    <div class="builder-actions">${session.completedAt ? button('Edit workout', 'history-edit', session.id) +
      button('Compare sessions', 'history-compare', session.id) + button('Share workout summary', 'data-summary', session.id) + (active ? '' : button('Repeat workout', 'plan-repeat', session.id)) :
      button('Resume workout', 'active')}</div></article>`;
}

function planTally(session, exercise = '') {
  const planned = plannedCounts(session.snapshot, { exercise });
  const performed = completedCounts(session, { exercise });
  return `<p class="builder-hint">Working sets · ${performed.working} completed · ${planned.working} originally planned<br>
    Warm-ups · ${performed['warm-up']} completed · ${planned['warm-up']} originally planned</p>`;
}

function historyTime(session) {
  const times = workoutTimes(session, session.completedAt);
  return `Elapsed ${clockText(times.elapsed)} · Active ${clockText(times.active)} · Paused ${clockText(times.paused)}`;
}

export function renderHistorySessions(data, state, unit, active, format, photos, user) {
  const filtered = historyFilter(data.sessions, state.filters);
  const calendar = state.layout === 'calendar';
  const recent = filtered.filter(session => !calendar || dayOf(session) === state.day);
  const dateLabel = date => format(date, { year: 'numeric', month: 'short', day: 'numeric' });
  return `<div class="stack session-list history-content">${renderHistoryFilters(data.sessions, state.filters)}
    <div class="builder-actions" role="group" aria-label="Workout history layout">
      ${button('Chronological list', 'history-layout', 'list', `aria-pressed="${!calendar}"`)}
      ${button('Calendar', 'history-layout', 'calendar', `aria-pressed="${calendar}"`)}
      ${button('Add missed workout', 'history-add')}</div>
    ${calendar ? renderHistoryCalendar(filtered, state.month, state.day, format, photos, user.entries) : ''}
    ${calendar ? `<h2>${html(dateLabel(state.day))}</h2><section class="surface settings-card history-date-details"><h3>Date details</h3>
      ${bodyweightOn(user.entries[state.day], state.day, unit)}
      <h4>Date progress photos</h4>${renderPhotoArea(photos, state.day, null, state.day <= localDayKey())}</section>` : ''}
    ${recent.length ? recent.map(session => historyCard(session, unit, active, photos, dateLabel, user.entries)).join('') :
      `<section class="surface settings-card"><h3>${calendar ? 'No workouts on this date' : 'No matching workouts'}</h3><p class="builder-hint">${Object.values(state.filters).some(Boolean) ? 'Try adjusting your filters.' : 'Recorded workouts appear here.'}</p></section>`}
  </div>`;
}

function changeSummary(comparison, unit, duration) {
  const setChange = comparison.left.count - comparison.right.count;
  const seconds = comparison.left.duration == null || comparison.right.duration == null ? null : comparison.left.duration - comparison.right.duration;
  const vol = comparison.volumeChange;
  const sign = value => value > 0 ? '+' : value < 0 ? '−' : '';
  return `<div class="history-changes"><p>Set count change · ${changeText(setChange)}</p>
    ${duration && seconds != null ? `<p>Duration change · ${sign(seconds)}${clockText(Math.abs(seconds))}</p>` : ''}
    ${comparison.repsChange != null ? `<p>Comparable reps change · ${changeText(comparison.repsChange)}</p>` : ''}
    ${vol != null ? `<p>Comparable volume change · ${sign(vol)}${mass(Math.abs(vol), unit)} ${unit}·reps</p>` : '<p>Comparable logged volume unavailable</p>'}
    ${comparison.orderChanged ? '<p class="history-flag">Exercise order differed</p>' : ''}
    ${comparison.equipmentChanged ? '<p class="history-flag">Equipment differed</p>' : ''}
    ${comparison.exercisesChanged ? '<p class="history-flag">Exercise selection differed</p>' : ''}</div>`;
}

export function renderFinishSummary(session, sessions, unit, dateLabel, entries) {
  const prior = priorComparable(session, sessions);
  return `<div class="stack history-summary"><p class="history-status">${sessionStatus(session)}</p>${renderHistoryMetrics(sessionMetrics(session), unit)}
    ${prior ? `<section class="log-panel"><h3>Since the previous ${prior.exerciseID ? 'comparable exercise' : 'workout with this routine'}</h3>
      <p>${html(sessionPlan(prior.other).name)} · ${dayOf(prior.other)}</p>
      ${changeSummary(compareSessions(session, prior.other, prior.exerciseID), unit, !prior.exerciseID)}</section>` :
      '<p class="builder-hint">No prior comparable session.</p>'}
    ${renderForecastArchive(session, unit, dateLabel)}${renderSessionEnergy(session, entries)}${button('View in history', 'history-view-finished', session.id)}</div>`;
}

export function renderComparison(session, candidates, selectedID, scopeID, unit) {
  const other = candidates.find(item => item.id === selectedID) ?? candidates[0];
  if (!other) return '<p>No other finished sessions use this routine or any of its exercises.</p>';
  const scopes = comparisonScopes(session, other);
  const scope = scopes.find(item => item.id === scopeID) ?? scopes[0];
  const stats = compareSessions(session, other, scope.id);
  const side = (item, metrics, label) => `<section class="log-panel history-compare-side"><h3>${label} · ${html(sessionPlan(item).name)}</h3>
    <p>${dayOf(item)} · ${versionText(item)} · ${sessionStatus(item)}</p>${renderHistoryMetrics(metrics, unit, !scope.id)}
    ${planTally(item, scope.id)}
    ${sessionPlan(item).exercises.filter(row => !scope.id || row.exercise.id === scope.id).map(row => historyExercise(item, row, unit, true)).join('')}</section>`;
  return `<div class="stack history-comparison">
    <div class="builder-fields">${select('Compare with', 'id="history-other"', options(candidates.map(item => [item.id, dayOf(item) + ' · ' + sessionPlan(item).name + ' · ' + versionText(item)]), other.id))}
    ${select('Compare by', 'id="history-scope"', options(scopes.map(item => [item.id, item.name]), scope.id))}</div>
    ${changeSummary(stats, unit, !scope.id)}<div class="history-compare-grid">${side(session, stats.left, 'Selected')}${side(other, stats.right, 'Comparison')}</div></div>`;
}

const amountLabel = { weight: 'Weight', added: 'Added load', assistance: 'Assistance', duration: 'Duration (seconds)', distance: 'Distance (meters)', setting: 'Machine setting' };
function historyEditableSet(row, set, index) {
  const measurement = row.measurement;
  const reps = hasReps(measurement);
  const sided = row.counting === 'separateSides' || set.input.separateSides;
  const input = set.input;
  const label = (amountLabel[measurement] ?? '') + (['weight', 'added', 'assistance'].includes(measurement) ? ' (' + input.unit + ')' : '');
  const typed = (title, key, mode = 'decimal') => field(title, `data-history-input="${key}" inputmode="${mode}"`, input[key]);
  return `<div class="history-set-editor log-panel" data-history-set="${html(set.id)}"><strong>${set.purpose === 'warm-up' ? 'Warm-up set' : 'Set'} ${index + 1}</strong>
    ${set.plan ? `<p class="builder-hint">Prescription · ${html(setSummary({ ...set.plan, sets: 1 }, row, input.unit))}</p>` : ''}
    ${select('Set status', 'data-history-set-field="status"', options(Object.entries({ pending: 'Unfinished', completed: 'Performed', skipped: 'Skipped' }), set.status))}
    ${set.status === 'completed' ? `<div class="builder-fields">${measurement !== 'bodyweight' ? typed(sided ? 'Left ' + label : label, 'amount', measurement === 'setting' ? 'text' : 'decimal') : ''}
      ${reps ? typed(sided ? 'Left reps' : row.counting === 'perSide' ? 'Reps per side' : 'Reps', 'reps', 'numeric') : ''}
      ${reps && sided ? typed('Right reps', 'rightReps', 'numeric') : ''}
      ${sided && measurement !== 'bodyweight' ? typed('Right ' + label, 'rightAmount', measurement === 'setting' ? 'text' : 'decimal') : ''}</div>
      ${(row.counting === 'perSide' || !reps) ? `<label class="builder-check"><input type="checkbox" data-history-input="separateSides" ${input.separateSides ? 'checked' : ''}>Log left and right</label>` : ''}
      <details data-history-disclosure="effort-${html(set.id)}"><summary>Actual effort</summary><div class="builder-fields">${typed('Actual RIR', 'rir', 'numeric')}
      ${typed('Actual RPE', 'rpe')}</div><label class="builder-check"><input type="checkbox" data-history-input="failure" ${input.failure ? 'checked' : ''}>Reached failure</label></details>` : ''}
    ${!set.plan ? button('Remove set', 'history-remove-set', set.id) : ''}</div>`;
}

export function renderHistoryEditor(draft, data, library) {
  const versions = data.routines.flatMap(routine => routine.versions.slice().reverse()).map(item => [item.id, item.name + ' · v' + item.revision]);
  return `<div class="stack history-editor">${draft.sessionID ? '<p class="builder-hint">Correct recorded results and notes. The original routine prescription stays with the workout.</p>' : `<div class="builder-fields">
    ${select('Routine template', 'data-history-draft="versionID"', option('', 'Standalone workout', draft.versionID) + options(versions, draft.versionID))}
    ${draft.versionID ? '' : field('Workout name', 'data-history-draft="name"', draft.name)}
    ${field('Workout date', 'data-history-draft="day" max="' + localDayKey() + '"', draft.day, 'date')}
    ${field('Start time', 'data-history-draft="start"', draft.start, 'time')}
    ${field('Duration in minutes (optional)', 'data-history-draft="minutes" inputmode="decimal"', draft.minutes)}</div>`}
    ${text('Workout notes', 'data-history-draft="notes"', draft.notes)}
    <label class="builder-check"><input type="checkbox" data-history-draft="incomplete" ${draft.incomplete ? 'checked' : ''}>Mark as incomplete</label>
    ${draft.exercises.map(exercise => `<section class="log-panel" data-history-exercise="${exercise.row.id}"><h3>${html(exercise.row.exercise.name)}</h3>
      <p class="builder-hint">${html(equipmentName(exercise.row))}</p>${text('Exercise notes', 'data-history-exercise-note', exercise.notes)}
      ${exercise.sets.map((set, index) => historyEditableSet(exercise.row, set, index)).join('')}
      ${button('Add set', 'history-add-set', exercise.row.id)}</section>`).join('')}
    <details class="log-panel" data-history-disclosure="exercise-add"><summary>Add exercise</summary><div class="builder-fields">
      ${select('Exercise to add', 'id="history-exercise-choice"', option('', 'Choose an exercise', '') + options(library.map(item => [item.id, item.name]), ''))}
      ${select('Track by', 'id="history-measurement"', options(Object.entries(measurements), 'weight'))}
      ${select('Rep counting', 'id="history-counting"', options(Object.entries({ total: 'Total reps', perSide: 'Equal per side', separateSides: 'Separate left and right' }), 'total'))}
      ${select('Load convention', 'id="history-basis"', options(Object.entries({ total: 'Total load', perDumbbell: 'Per dumbbell' }), 'total'))}
      ${field('Equipment or machine name', 'id="history-equipment"', '')}</div>${button('Add to workout', 'history-add-exercise')}</details>
    ${errors}<button type="button" class="primary" data-action="history-save">${draft.sessionID ? 'Save corrections' : 'Save missed workout'}</button></div>`;
}
