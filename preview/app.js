import { createBrowserStore, isDay, kilogramsPerPound, localDayKey } from './storage.js';
import { createExerciseStore, escapeHTML, exerciseEditor, readExerciseForm, renderExerciseDetail, renderLibrary,
  renderSearchResults, renderSubstitutions, renderSubstitutionResults } from './exercises.js';
import { muscleInvolvement, renderMuscleMap } from './muscle-map.js';
import { blankSet, createRoutineStore, draftExercise, makeDraft, newGroup, newest, reorder, sessionPlan } from './routines.js';
import { exerciseOptions, renderPersonalRoutines, renderPlan, renderRoutineBuilder, renderVersions } from './routine-ui.js';
import { renderWorkout, updateWorkoutFields, workoutStep } from './workout-ui.js';
import { clockText, restRemaining, workoutTimes } from './workout-tools.js';
import { loadKey, variantKey } from './workout-log.js';
import { offsetDay, recentMuscles, scheduleEntries, scheduleWindow, statusLabels } from './schedule.js';
import { readinessFields, renderMove, renderProgramWeek, renderReadiness, renderSchedulePlanner, rotationSteps, scheduleSummary } from './schedule-ui.js';
import { comparisonScopes, dayOf, historyDraft, newHistorySet, priorComparable, sessionsByDate } from './history.js';
import { calendarMonth, renderComparison, renderFinishSummary, renderHistoryEditor, renderHistoryFilters, renderHistorySessions } from './history-ui.js';
import { readAnalyticsSettings, renderAnalytics } from './analytics-ui.js';
import { programContext } from './analytics.js';
import { renderBodyweight, renderWeightTarget } from './bodyweight-ui.js';
import { createDevicePhotoStore, photoDates, requestDevicePhoto } from './device-photos.js';
import { cancelPhotoPreviews, paintPhotoPreviews, renderManagePhotos, renderPhotoComparison } from './progress-photos-ui.js';
import { readProgressionRule, renderProgressionDetail, renderProgressionList, renderWorkoutRecommendations, updateProgressionFields } from './progression-ui.js';
import { progressionRule, progressionWorkingSets, suggestProgression } from './progression.js';
import { renderForecastEvaluation, renderForecastPreview } from './forecast-ui.js';
import { renderEnergyEditor, renderScore, renderWeeklyRecap } from './recap-ui.js';
import { weeklyRecap } from './weekly-recap.js';
import { dailyWorkoutScore, defaultScoreWeights } from './workout-score.js';
import { createProfileStorage } from './portability.js';
import { createPortabilityUI } from './portability-ui.js';

const icons = {
  mark: '<path d="M3 15.5V8.5m4 10v-13m5 11v-9m5 11v-13m4 10v-7M7 12h10"/>',
  today: '<rect x="3" y="4.5" width="18" height="16" rx="3"/><path d="M7.5 3v4m9-4v4M3 9.5h18m-12 5h6m-3-3v6"/>',
  routines: '<path d="m12 3 9 5-9 5-9-5 9-5Zm-9 9 9 5 9-5M3 16l9 5 9-5"/>',
  history: '<path d="M4 4v15a1 1 0 0 0 1 1h15M8 15l4-4 3 2 5-6m-4 0h4v4"/>',
  settings: '<path d="M10 3h4l.7 2.5 2 .9 2.3-1 2 3.4-1.8 1.8v2.8l1.8 1.8-2 3.4-2.3-1-2 .9L14 21h-4l-.7-2.5-2-.9-2.3 1-2-3.4 1.8-1.8v-2.8L3 8.8l2-3.4 2.3 1 2-.9L10 3Z"/><circle cx="12" cy="12" r="3"/>',
  moon: '<path d="M20.5 14A8.7 8.7 0 0 1 10 3.5 8.7 8.7 0 1 0 20.5 14Z"/>',
  sun: '<circle cx="12" cy="12" r="4"/><path d="M12 2v2m0 16v2M4.9 4.9l1.4 1.4m11.4 11.4 1.4 1.4M2 12h2m16 0h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/>',
  calendar: '<rect x="3" y="5" width="18" height="16" rx="3"/><path d="M7 3v4m10-4v4M3 10h18"/>',
  clock: '<circle cx="12" cy="12" r="8.5"/><path d="M12 7.5V12l3 2"/>',
  dumbbell: '<rect x="3" y="7" width="4" height="10" rx="1"/><rect x="17" y="7" width="4" height="10" rx="1"/><path d="M7 12h10M1 10v4m22-4v4"/>',
  play: '<path d="m9 5 11 7-11 7V5Z" fill="currentColor" stroke-linejoin="round"/>',
  arrow: '<path d="M4 12h15m-6-6 6 6-6 6"/>',
  chevron: '<path d="m9 6 6 6-6 6"/>',
  down: '<path d="m6 9 6 6 6-6"/>',
  body: '<circle cx="12" cy="4.5" r="2"/><path d="m5 9 7 2 7-2m-7 2v4m0 0-4 6m4-6 4 6"/>',
  scale: '<rect x="4" y="4" width="16" height="16" rx="4"/><path d="M8 10a4 4 0 0 1 8 0m-4 2 1-3"/>',
  plus: '<path d="M5 12h14m-7-7v14"/>',
  pencil: '<path d="m4 16-.5 4.5L8 20 20 8l-4-4L4 16Zm10-10 4 4"/>',
  spark: '<path d="M10 3c.8 4.5 2.5 6.2 7 7-4.5.8-6.2 2.5-7 7-.8-4.5-2.5-6.2-7-7 4.5-.8 6.2-2.5 7-7Zm9 10c.3 2.4 1.1 3.2 3.5 3.5-2.4.3-3.2 1.1-3.5 3.5-.3-2.4-1.1-3.2-3.5-3.5 2.4-.3 3.2-1.1 3.5-3.5Z"/>',
  close: '<path d="m6 6 12 12M18 6 6 18"/>',
  check: '<path d="m5 12 4 4L19 6"/>',
  info: '<circle cx="12" cy="12" r="9"/><path d="M12 11v5m0-8h.01"/>',
};

const icon = (name, size = 20) => `<svg width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${icons[name]}</svg>`;
const asset = name => `/shared/${name}`;
const main = document.querySelector('#main');
const header = document.querySelector('#topbar');
const dock = document.querySelector('#dock');
const dialog = document.querySelector('#dialog');
const announcement = document.querySelector('#announcement');
const systemDark = matchMedia('(prefers-color-scheme: dark)');
const storage = createProfileStorage(localStorage);
const store = createBrowserStore(storage);
const exerciseStore = createExerciseStore(storage);
const routineStore = createRoutineStore(storage);
const photoStore = createDevicePhotoStore(window.indexedDB, storage.photoScope);
const tabs = [
  ['today', 'Today', 'Today / Log'], ['routines', 'Routines', 'Routines'],
  ['history', 'History', 'History / Progress'], ['settings', 'Settings', 'Settings'],
];

function readStorage(load, fallback) {
  try { return load(); }
  catch { return fallback; }
}

const saved = readStorage(store.loadPreferences, {});
const newExerciseQuery = (muscle = '') => ({ name: '', muscle, equipment: '', pattern: '', collection: 'all' });
const state = {
  tab: tabs.some(([id]) => `#${id}` === location.hash) ? location.hash.slice(1) : 'today',
  appearance: saved.appearance ?? 'system',
  opaque: saved.opaque === true,
  unit: saved.unit === 'lb' ? 'lb' : 'kg',
  user: readStorage(store.loadUser, { entries: {} }),
  preview: readStorage(store.loadSample, { weights: {}, active: null }),
  sampleMode: false,
  date: localDayKey(), routine: null, history: 'progress', expanded: new Set(),
  historyView: { layout: 'list', day: localDayKey(), month: localDayKey(), filters: {} },
  analyticsView: { purpose: 'working', week: null, settingsOpen: false },
  recapWeek: null,
  libraryOpen: false, exerciseDetail: null, substituteFor: null, availableEquipment: new Set(),
  exerciseQuery: newExerciseQuery(), exercises: readStorage(exerciseStore.load, { custom: [], preferences: {} }),
  muscleRegion: '', muscleView: 'planned', calendarAnchor: null,
  planRecords: readStorage(routineStore.load, { categories: [], routines: [], sessions: [], schedule: [] }),
  builder: null, routineCategory: '',
  photoLinks: [],
};

async function bundled(name) {
  try {
    const response = await fetch(asset(name));
    return response.ok ? await response.json() : null;
  } catch { return null; }
}

const [sample, catalogResource, anatomy, links] = await Promise.all([
  bundled('SampleData.json'), bundled('ExerciseCatalog.json'), bundled('MuscleRegions.json'), photoStore.list().catch(() => []),
]);
state.photoLinks = links;
const catalog = Array.isArray(catalogResource) ? catalogResource : [];
const libraryItems = () => [...catalog, ...state.exercises.custom];
const libraryExercise = id => libraryItems().find(exercise => exercise.id === id);
const personalRoutine = id => state.planRecords.routines.find(routine => routine.id === id);
const personalSession = id => state.planRecords.sessions.find(session => session.id === id);
const personalVersion = id => state.planRecords.routines.flatMap(routine => routine.versions).find(version => version.id === id);
const scheduledFor = date => scheduleEntries(state.planRecords, [date], today());
const activePersonal = () => state.sampleMode ? null : state.planRecords.sessions.find(session => !session.completedAt);
let lastLocalDay = localDayKey();

function refreshLocalCalendar() {
  const current = localDayKey();
  if (state.sampleMode || current === lastLocalDay || dialog.open) return;
  if (!state.calendarAnchor && state.date === lastLocalDay) state.date = current;
  lastLocalDay = current;
  if (state.tab === 'today') render();
}

function savePreferences() {
  const { appearance, opaque, unit } = state;
  try { store.savePreferences({ appearance, opaque, unit }); }
  catch { announce('Browser storage is unavailable. Changes are available for this visit.'); }
}

function savePreview(next) {
  store.saveSample(next);
  state.preview = next;
}

const systemTheme = () => systemDark.matches ? 'dark' : 'light';
const theme = () => state.appearance === 'system' ? systemTheme() : state.appearance;
function applyAppearance() {
  document.documentElement.dataset.theme = theme();
  document.documentElement.dataset.opaque = state.opaque;
  document.querySelector('meta[name="theme-color"]').content = theme() === 'dark' ? '#131118' : '#f6f5fa';
}

const day = key => new Date(`${key}T12:00:00Z`);
const dateLabel = (key, options) => new Intl.DateTimeFormat('en-US', { ...options, timeZone: 'UTC' }).format(day(key));
const shortDate = key => dateLabel(key, { month: 'short', day: 'numeric' });
const longDate = key => dateLabel(key, { weekday: 'long', month: 'long', day: 'numeric' });
const routineFor = id => sample?.routines.find(routine => routine.id === id);
const planned = () => state.sampleMode ? routineFor(sample.week.find(entry => entry.date === state.date)?.routineID) : null;
const today = () => state.sampleMode ? sample.today : localDayKey();
const activePreview = () => state.sampleMode ? routineFor(state.preview.active?.routineID) : null;
const bodyweightValue = () => state.sampleMode ? state.preview.weights[state.date] : state.user.entries[state.date]?.kilograms;
const kilogramsPerUnit = () => state.unit === 'lb' ? kilogramsPerPound : 1;
const displayWeight = (kg, digits = 1) => new Intl.NumberFormat('en-US', { maximumFractionDigits: digits, minimumFractionDigits: digits === 1 ? 1 : 0 }).format(kg / kilogramsPerUnit());
const displayLoad = kg => `${displayWeight(kg, Number.isInteger(kg) && state.unit === 'kg' ? 0 : 1)} ${state.unit}`;
const announce = message => { announcement.textContent = message; };

function renderHeader() {
  const destination = theme() === 'dark' ? 'light' : 'dark';
  header.innerHTML = `
    <div class="topbar-inner">
      <a class="brand" href="#today" aria-label="Setline home">
        <span class="brand-mark">${icon('mark', 23)}</span>
        <span>Setline<span class="brand-dot">.</span></span>
      </a>
      <div class="top-actions">
        ${sample ? `<button type="button" class="sample" data-action="sample-mode"
          aria-label="${state.sampleMode ? 'Sample data. Return to your data' : 'View sample data'}">
          <span></span>${state.sampleMode ? 'Sample data' : 'View sample data'}
        </button>` : ''}
        <button type="button" class="icon-button theme-button" data-action="theme"
          aria-label="Switch to ${destination} appearance" title="Switch to ${destination} appearance">
          ${icon(theme() === 'dark' ? 'sun' : 'moon', 19)}
        </button>
      </div>
    </div>`;
}

function sectionTitle(title, subtitle) {
  return `<div class="page-heading">${subtitle ? `<p class="eyebrow">${subtitle}</p>` : ''}<h1>${title}</h1></div>`;
}

function weekView() {
  const settings = state.planRecords.scheduleSettings;
  const week = state.sampleMode ? sample.week : scheduleWindow(state.calendarAnchor ?? today(), settings).map(date => ({ date }));
  const weekEntries = state.sampleMode ? [] : scheduleEntries(state.planRecords, week.map(entry => entry.date), today());
  const title = state.sampleMode ? 'This week' : settings?.mode === 'rolling' ? 'Rolling seven days' : 'Training week';
  const controls = state.sampleMode ? '' : `<div class="schedule-nav"><button type="button" class="secondary" data-action="schedule-calendar" data-value="-7">Previous</button>
    <button type="button" class="secondary" data-action="schedule-calendar" data-value="0">Today</button>
    <button type="button" class="secondary" data-action="schedule-calendar" data-value="7">Next</button>
    <button type="button" class="secondary" data-action="schedule-open">Training schedule</button></div>`;
  return `<section class="surface week" aria-labelledby="week-title"><div class="section-top"><h2 id="week-title">${title}</h2><span class="meta">${icon('calendar', 15)} ${shortDate(week[0].date)} – ${shortDate(week.at(-1).date)}</span></div><div class="days">${week.map(({ date, routineID }) => {
    const entries = weekEntries.filter(item => item.date === date);
    const routine = state.sampleMode ? routineFor(routineID) : personalVersion(entries[0]?.versionID);
    const selected = date === state.date;
    const isToday = date === today();
    const weekday = dateLabel(date, { weekday: 'short' });
    const number = day(date).getUTCDate();
    const description = entries.length ? entries.map(entry => statusLabels[entry.status] + ' ' + personalVersion(entry.versionID)?.name).join(', ') :
      routine?.name ?? (state.sampleMode ? 'rest day' : 'no workout scheduled');
    const dots = entries.length ? entries.slice(0, 3).map(entry => `<span class="day-dot schedule-${entry.status}"></span>`).join('') :
      `<span class="day-dot${routine ? ' scheduled' : ''}"></span>`;
    const label = (state.sampleMode ? '' : weekday + ' ' + number + ' · ') + longDate(date) + ', ' + description;
    return `<button class="day${selected ? ' selected' : ''}" type="button" data-action="date" data-value="${date}" aria-pressed="${selected}" ${isToday ? 'aria-current="date"' : ''} aria-label="${escapeHTML(label)}"><span class="day-name">${weekday}</span> <span class="day-number">${number}</span><span class="day-markers">${dots}</span></button>`;
  }).join('')}</div>${controls}</section>`;
}

function workoutHero(routine, label = 'Planned workout') {
  if (!routine) return `<section class="surface rest-card"><span class="tile-icon">${icon('calendar', 22)}</span><p class="eyebrow">SCHEDULE</p><h2>${state.sampleMode ? 'Rest day' : 'No workout scheduled'}</h2><p>${shortDate(state.date)}</p><a class="secondary" href="#routines">View routines ${icon('arrow', 17)}</a></section>`;
  const isActive = Boolean(activePreview());
  const artwork = routine.id === 'upper-a'
    ? `<img class="hero-image" src="${asset('workout-hero.png')}" alt="">`
    : `<div class="hero-symbol">${icon('dumbbell', 180)}</div>`;
  return `
    <section class="hero" aria-labelledby="workout-title">
      ${artwork}<div class="hero-shade"></div>
      <div class="hero-content">
        <span class="hero-label"><span></span>${label}</span>
        <div>
          <h2 id="workout-title">${routine.name}</h2>
          <p class="hero-focus">${routine.focus}</p>
        </div>
        <div class="hero-meta">
          <span>${icon('clock', 17)} ${routine.minutes} min</span>
          <span>${icon('dumbbell', 18)} ${routine.exercises.length} exercises</span>
        </div>
        <button type="button" class="primary log-button" data-action="log" data-value="${routine.id}">
          ${icon(isActive ? 'chevron' : 'play', 18)} ${isActive ? 'Resume Workout' : 'Log Workout'}
        </button>
      </div>
    </section>`;
}

function muscleMap(routine) {
  const ids = new Set(routine?.exercises.map(exercise => exercise.id) ?? []);
  const targets = muscleInvolvement(catalog.filter(exercise => ids.has(exercise.sampleID)));
  return renderMuscleMap(anatomy, targets, state.muscleRegion);
}

function bodyweight() {
  const kg = bodyweightValue();
  return `
    <section class="surface weight-card" aria-labelledby="weight-title">
      <div class="section-top">
        <div class="section-label"><span class="tile-icon small">${icon('scale', 18)}</span><h2 id="weight-title">Bodyweight</h2></div>
        <span class="meta">${state.date === today() ? 'Today' : shortDate(state.date)}</span>
      </div>
      <div class="weight-content">
        <div>
          <div class="weight-number">${kg ? displayWeight(kg) : '—'} <span>${state.unit}</span></div>
          <p>${kg ? 'Saved on this device' : 'No entry for this day'}</p>
        </div>
        <button type="button" class="secondary" data-action="weight">${icon(kg ? 'pencil' : 'plus', 17)} ${kg ? 'Edit' : 'Add entry'}</button>
      </div>
    </section>`;
}

function exerciseCard(exercise, index) {
  const previous = exercise.previous;
  const open = state.expanded.has(exercise.id);
  const thumbnail = exercise.image ? `<img src="${asset(exercise.image)}" alt="">` : icon('dumbbell', 26);
  const bestSet = previous ? `${displayLoad(previous.weightKg)} × ${previous.reps}` : '—';
  const minutes = Math.floor(exercise.restSeconds / 60);
  const seconds = exercise.restSeconds % 60;
  const rest = [minutes && `${minutes} min`, seconds && `${seconds} sec`].filter(Boolean).join(' ');
  return `
    <details class="surface exercise" data-exercise="${exercise.id}" ${open ? 'open' : ''}>
      <summary>
        <span class="exercise-title">
          <span class="exercise-image">${thumbnail}</span>
          <span>
            <span class="exercise-name" role="heading" aria-level="3">${exercise.name}</span>
            <span class="exercise-prescription">${exercise.muscles} <span aria-hidden="true">/</span> ${exercise.sets} × ${exercise.reps} reps</span>
          </span>
          <span class="exercise-chevron" title="Advanced details">${icon('down', 18)}<span class="sr-only">Advanced details</span></span>
        </span>
        <span class="exercise-stats">
          <span><span class="stat-label">Previous best set</span><strong>${bestSet}</strong></span>
          <span class="prediction"><span class="stat-label">${icon('spark', 15)} Performance forecast</span><strong>Personal workouts only</strong></span>
        </span>
      </summary>
      <div class="advanced">
        <p><strong>Set order</strong><span>${index + 1}</span></p>
        <p><strong>Target RIR</strong><span>${exercise.rir} reps in reserve</span></p>
        <p><strong>Rest</strong><span>${rest}</span></p>
      </div>
    </details>`;
}

function exercises(routine) {
  return `<section class="exercise-section" aria-labelledby="exercise-title"><div class="section-top exercise-heading"><h2 id="exercise-title">Exercises</h2><span class="count">${routine.exercises.length} planned</span></div><div class="stack">${routine.exercises.map(exerciseCard).join('')}</div></section>`;
}

function todayPage() {
  const routine = planned();
  const scheduled = state.sampleMode ? [] : scheduledFor(state.date);
  const scheduledExercises = scheduled.filter(entry => ['planned', 'rescheduled', 'active'].includes(entry.status))
    .flatMap(entry => personalVersion(entry.versionID)?.exercises ?? []).map(entry => entry.exercise.primary ? entry.exercise : libraryExercise(entry.exercise.id)).filter(Boolean);
  const context = state.sampleMode ? {} : {
    controls: `<div class="schedule-nav" role="group" aria-label="Muscle map view">${[['planned', 'Planned targets'], ['recent', 'Recent training']].map(([key, label]) =>
      `<button type="button" class="secondary" aria-pressed="${state.muscleView === key}" data-action="muscle-context" data-value="${key}">${label}</button>`).join('')}</div>`,
    ...(state.muscleView === 'recent' ? { recent: recentMuscles(state.planRecords.sessions, state.date > today() ? today() : state.date, libraryExercise),
      asOf: shortDate(state.date > today() ? today() : state.date) } : {}),
  };
  const side = state.sampleMode ? (routine ? muscleMap(routine) + bodyweight() : bodyweight() + muscleMap(null)) :
    bodyweight() + readinessCard() + renderMuscleMap(anatomy, muscleInvolvement(scheduledExercises), state.muscleRegion, context) +
    renderScore(dailyWorkoutScore(state.date, state.planRecords.sessions.filter(session => dayOf(session) === state.date), scheduled, undefined, state.planRecords.scoreWeights));
  const cards = scheduled.map(entry => {
    const version = personalVersion(entry.versionID);
    if (!version) return '';
    const summary = scheduleSummary(state.planRecords, entry, shortDate);
    const actionable = ['planned', 'rescheduled', 'missed'].includes(entry.status) && !(entry.rotationID && entry.status === 'missed');
    const label = entry.status === 'active' || activePersonal() ? 'Resume workout' : 'Start scheduled workout';
    return `<article class="surface settings-card saved-routine schedule-card schedule-${entry.status}" data-schedule-date="${entry.date}">
      <p class="eyebrow schedule-label">${summary.name}${summary.detail ? ' · ' + escapeHTML(summary.detail) : ''}</p><h2>${escapeHTML(version.name)}</h2>
      ${summary.block ? `<p class="chart-subtitle">${escapeHTML(summary.block.name)} · Week ${summary.index + 1} · ${summary.kind}${summary.notes ? ' · ' + escapeHTML(summary.notes) : ''}</p>` : ''}
      ${actionable || entry.status === 'active' ? renderPlan(version, state.unit) : ''}
      ${['planned', 'rescheduled'].includes(entry.status) ? renderForecastPreview(state.planRecords, version, entry, state.unit, dateLabel) : ''}
      ${actionable && programContext(state.planRecords, { localDate: entry.date, scheduleID: entry.id }).kind !== 'deload' ?
        renderWorkoutRecommendations(state.planRecords, version, state.unit) : ''}
      ${(actionable && (!entry.rotationID || entry.date === today())) || entry.status === 'active' ? `<button type="button" class="primary" data-action="log-start-scheduled" data-value="${entry.key}">${label}</button>` : ''}
      ${actionable ? `<div class="schedule-nav"><button type="button" class="secondary" data-action="schedule-move" data-value="${entry.key}">Move session</button>
      <button type="button" class="secondary" data-action="schedule-skip" data-value="${entry.key}">Skip session</button></div>` : ''}</article>`;
  }).join('');
  const empty = state.sampleMode ? '' : `<button type="button" class="secondary" data-action="log-start-empty">${activePersonal() ? 'Resume active workout' : 'Start empty workout'}</button>`;
  return `${sectionTitle('Today', longDate(today()))}${weekView()}<div class="dashboard"><div class="dashboard-hero stack">${cards || workoutHero(routine)}${empty}</div><div class="dashboard-side">${side}</div>${routine ? `<div class="dashboard-exercises">${exercises(routine)}</div>` : ''}</div>`;
}

function readinessCard() {
  const entry = state.planRecords.readiness?.find(item => item.date === state.date);
  return `<section class="surface settings-card"><h2>Readiness</h2>
    ${entry ? `<p class="chart-subtitle">${Object.entries(readinessFields).map(([key, name]) => name + ' ' + entry[key] + '/5').join(' · ')}</p>` :
      '<p class="chart-subtitle">Optional training context</p>'}
    ${state.date <= today() ? `<button type="button" class="secondary" data-action="schedule-readiness">${entry ? 'Edit check-in' : 'Log readiness'}</button>` : ''}</section>`;
}

function routinesPage() {
  if (state.libraryOpen) return exerciseLibraryPage();
  if (state.builder) return renderRoutineBuilder(state.builder, state.planRecords, catalog, state.exercises, state.unit);
  const entry = `<button type="button" class="surface routine-card library-entry" data-action="exercise-library">
    <span class="tile-icon">${icon('dumbbell', 22)}</span><strong>Exercise Library</strong><span class="round-arrow">${icon('chevron', 17)}</span></button>`;
  if (!state.sampleMode) return renderPersonalRoutines(state.planRecords, state.routineCategory, state.unit, activePersonal(), entry, dateLabel);
  const routine = routineFor(state.routine);
  if (routine) return `<button type="button" class="back-button" data-action="routine" data-value="">${icon('arrow', 17)} All routines</button>${sectionTitle('Routines')}<div class="dashboard"><div class="dashboard-hero">${workoutHero(routine, 'Sample routine')}</div><div class="dashboard-side">${muscleMap(routine)}</div><div class="dashboard-exercises">${exercises(routine)}</div></div>`;
  return `${sectionTitle('Routines', 'Training library')}${entry}<p class="screen-description">Sample routines show how your own workouts will appear.</p><div class="routine-grid">${sample.routines.map((item, index) => `<button class="surface routine-card" type="button" data-action="routine" data-value="${item.id}"><span class="tile-icon ${index ? 'coral' : ''}">${icon('dumbbell', 24)}</span><span class="routine-description"><strong>${item.name}</strong><span>${item.exercises.length} exercises · ${item.minutes} min</span><span>${item.primaryMuscles}</span></span><span class="round-arrow">${icon('chevron', 17)}</span></button>`).join('')}</div>`;
}

function exerciseLibraryPage() {
  const source = libraryExercise(state.substituteFor);
  const exercise = libraryExercise(state.exerciseDetail);
  const back = (label, action) => `<button type="button" class="back-button" data-action="${action}">${icon('arrow', 17)} ${label}</button>`;
  if (source && state.exerciseDetail === source.id) return back('Exercise details', 'substitution-back')
    + renderSubstitutions(source, libraryItems(), state.availableEquipment, state.exercises.preferences);
  if (exercise) return back(source ? 'Substitutions' : 'All exercises', 'exercise-back') + renderExerciseDetail(exercise, state.exercises);
  return back('All routines', 'library-back') + renderLibrary(catalog, state.exercises, state.exerciseQuery);
}

function chart() {
  const trend = sample.benchTrend;
  const points = trend.map(({ weightKg }, index) => [10 + index * 94, 117 - ((weightKg - 72.5) * 12)]);
  const line = points.map(point => point.join(',')).join(' ');
  const latest = trend.at(-1);
  return `<section class="surface chart-card"><div class="section-top"><h2>Barbell Bench Press</h2><span class="tile-icon small">${icon('history', 18)}</span></div><p class="chart-subtitle">Heaviest logged set by date</p><p class="chart-value">${displayLoad(latest.weightKg)}</p><div class="chart"><svg viewBox="0 0 302 136" role="img" aria-label="${trend.map(point => `${shortDate(point.date)}: ${displayLoad(point.weightKg)}`).join(', ')}"><defs><linearGradient id="chart-fill" x2="0" y2="1"><stop stop-color="currentColor" stop-opacity=".2"/><stop offset="1" stop-color="currentColor" stop-opacity="0"/></linearGradient></defs><path class="chart-grid" d="M0 25h302M0 60h302M0 95h302M0 130h302"/><polygon points="10,130 ${line} 292,130" fill="url(#chart-fill)"/><polyline points="${line}" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"/>${points.map(([x, y]) => `<circle cx="${x}" cy="${y}" r="4" fill="currentColor"/>`).join('')}</svg><div class="chart-dates">${trend.map(point => `<span>${shortDate(point.date)}</span>`).join('')}</div></div></section>`;
}

function historyPage() {
  const heading = sectionTitle('History', 'Training progress');
  const picker = `<div class="history-switch">${segment('history', [['progress', 'Progress'], ['sessions', 'Sessions']], state.history)}</div>`;
  const progress = state.history === 'progress';
  if (!state.sampleMode) {
    const compare = '<div class="history-photo-action"><button type="button" class="secondary" data-action="photos-compare">Compare progress photos</button></div>';
    if (!progress) return heading + picker + compare + renderHistorySessions(state.planRecords, state.historyView, state.unit, activePersonal(), dateLabel, state.photoLinks, state.user);
    const names = Object.fromEntries(Object.entries(anatomy?.regions ?? {}).map(([key, region]) => [key, region.name]));
    const recap = weeklyRecap(state.planRecords, state.user.entries, state.recapWeek ?? today(), libraryExercise, today());
    return heading + picker + compare + `<div class="stack session-list">${renderWeeklyRecap(recap, state.planRecords, state.unit, today(), names, shortDate)}
      ${renderHistoryFilters(state.planRecords.sessions, state.historyView.filters)}
      ${renderBodyweight(state.user, state.unit, shortDate)}
      <section class="surface settings-card progression-entry"><h2>Exercise progression</h2><button type="button" class="secondary" data-action="progression-open">Review progression</button></section>
      ${renderForecastEvaluation(state.planRecords, state.unit)}
      ${renderAnalytics(state.planRecords, state.historyView.filters, state.unit, state.analyticsView, libraryExercise, names, dateLabel)}</div>`;
  }
  const content = progress ? chart() : `<section class="stack session-list" aria-label="Sample sessions">${sample.history.map(entry => `<article class="surface session"><span class="tile-icon">${icon('dumbbell', 21)}</span><div><h2>${routineFor(entry.routineID).name}</h2><p>${entry.sets} sets · ${entry.minutes} min</p></div><span class="meta">${shortDate(entry.date)}</span></article>`).join('')}</section>`;
  return heading + picker + content;
}

function segment(group, values, selected) {
  return `<div class="segmented" role="group" aria-label="${group}">${values.map(([value, label]) => `<button type="button" data-action="${group}" data-value="${value}" aria-pressed="${selected === value}">${label}</button>`).join('')}</div>`;
}

function settingsPage() {
  return `${sectionTitle('Settings', 'Preferences')}
    <div class="settings-grid">
      <section class="surface settings-card">
        <div class="section-label"><span class="tile-icon small">${icon('sun', 19)}</span><h2>Appearance</h2></div>
        ${segment('appearance', [['system', 'System'], ['light', 'Light'], ['dark', 'Dark']], state.appearance)}
        <div class="setting-toggle">
          <div><strong id="transparency-label">Reduce transparency</strong><p>Use a solid background for navigation.</p></div>
          <button class="switch" type="button" role="switch" aria-checked="${state.opaque}" aria-labelledby="transparency-label" data-action="transparency"><span></span></button>
        </div>
      </section>
      <section class="surface settings-card">
        <div class="section-label"><span class="tile-icon small">${icon('scale', 19)}</span><h2>Weight units</h2></div>
        ${segment('unit', [['kg', 'Kilograms'], ['lb', 'Pounds']], state.unit)}
      </section>
      <section class="surface settings-card settings-note">
        <details><summary>Workout score weights</summary>
          <form id="score-weights" class="stack">
            ${Object.entries(defaultScoreWeights).map(([key, value]) =>
              `<label>${{ completion: 'Prescribed work completed', targets: 'Targets met', effort: 'Effort alignment' }[key]}<input name="${key}" type="number" min="0" max="100" step="any" required value="${Number(state.planRecords.scoreWeights?.[key] ?? value)}"></label>`).join('')}
            <button class="secondary" type="submit">Save score weights</button><p id="score-weights-error" class="builder-hint" role="status"></p>
          </form>
        </details>
      </section>
      <section class="surface settings-card settings-note">
        <div class="section-label"><span class="tile-icon small">${icon('info', 19)}</span><h2>Local data</h2></div>
        <p>Routines, workouts, bodyweight entries, and preferences are saved in this browser. Sample data has its own preview and storage.</p>
        <div class="builder-actions"><button class="secondary" data-action="data-open">Data portability</button><button class="secondary" data-action="data-account">Account storage</button></div>
      </section>
    </div>`;
}

function renderDock() {
  const routine = activePreview();
  const personal = activePersonal();
  const activeName = routine?.name ?? (personal ? sessionPlan(personal).name : 'Workout log');
  const status = routine ? 'Active preview' : personal ? 'Active workout' : 'No active workout';
  dock.innerHTML = `<div class="dock-inner"><button type="button" class="active-bar" data-action="active"><span class="active-icon">${icon('dumbbell', 20)}</span><span class="active-text"><strong>${escapeHTML(activeName)}</strong><span>${routine || personal ? '<span class="live-dot"></span>' : ''}<span${personal && !routine ? ' data-workout-status' : ''}>${status}</span></span></span><span class="active-arrow">${icon('chevron', 18)}</span></button><nav class="tab-bar" aria-label="Main navigation">${tabs.map(([id, title, label]) => `<a href="#${id}" ${state.tab === id ? 'aria-current="page"' : ''} aria-label="${label}">${icon(id, 21)}<span>${title}</span></a>`).join('')}</nav></div>`;
  paintWorkoutClocks();
}

function render({ scroll = false, focus = null } = {}) {
  applyAppearance();
  renderHeader();
  const pages = { today: todayPage, routines: routinesPage, history: historyPage, settings: settingsPage };
  main.innerHTML = pages[state.tab]();
  paintPhotoPreviews(main, state.photoLinks);
  renderDock();
  if (scroll) window.scrollTo(0, 0);
  if (focus) document.querySelector(focus)?.focus({ preventScroll: true });
}

let dialogAction = null;
let dialogTrigger = null;
let energyContext = null;
let exerciseDraft = null;
let progressionReview = null;
let progressionRoutineID = '';

function showDialog(type, title, body, trigger) {
  dialogAction = type;
  dialogTrigger = trigger;
  dialog.classList.toggle('workout-dialog', type === 'personal-workout');
  dialog.innerHTML = `<div class="dialog-header"><h2 id="dialog-title">${title}</h2><button type="button" class="icon-button" data-action="close" aria-label="Close">${icon('close', 20)}</button></div>${body}`;
  paintPhotoPreviews(dialog, state.photoLinks);
  if (!dialog.open) dialog.showModal();
  dialog.querySelector('[autofocus]')?.focus();
}

const portability = createPortabilityUI({ dialog, show: showDialog, storage, photos: photoStore, catalog, lookup: libraryExercise, announce,
  read: () => ({ plans: routineStore.load(), weights: store.loadUser(), library: exerciseStore.load(), photos: state.photoLinks,
    preferences: { appearance: state.appearance, opaque: state.opaque, unit: state.unit } }),
  refresh: async () => {
    state.planRecords = routineStore.load();
    state.user = store.loadUser();
    state.exercises = exerciseStore.load();
    state.photoLinks = await photoStore.list().catch(() => []);
    Object.assign(state, store.loadPreferences());
    state.unit ??= 'kg'; state.appearance ??= 'system'; state.opaque ??= false;
    state.builder = null;
    state.historyView.filters = {};
    render();
  },
});

function showWeight(trigger, date = state.date) {
  if (!isDay(date)) return;
  const value = state.sampleMode ? state.preview.weights[date] : state.user.entries[date]?.kilograms;
  const entered = value ? Math.round(value / kilogramsPerUnit() * 10) / 10 : '';
  showDialog('weight', 'Log bodyweight', `<p class="dialog-description">${state.sampleMode ? 'Sample entry · ' : ''}${longDate(date)}</p><form id="weight-form" data-day="${date}"><label for="weight-input">Bodyweight (${state.unit})</label><input id="weight-input" type="number" inputmode="decimal" name="weight" required min="0.1" step="0.1" value="${entered}" autofocus><div id="weight-error" role="alert"></div><button class="primary" type="submit">${icon('check', 19)} Save entry</button></form>`, trigger);
}

function showProgressionList(trigger, routineID = progressionRoutineID) {
  progressionRoutineID = routineID;
  progressionReview = null;
  const plans = state.planRecords.routines.filter(routine => !routineID || routine.id === routineID).map(newest);
  showDialog('progression-list', 'Exercise progression', renderProgressionList(state.planRecords, plans, dateLabel), trigger);
  focusProgressionTitle();
}

function showProgressionReview(routineID, rowID, trigger, ruleOpen = false, versionID = null) {
  const routine = personalRoutine(routineID);
  const version = versionID ? routine?.versions.find(item => item.id === versionID) : routine && newest(routine);
  const row = version?.exercises.find(item => item.id === rowID);
  if (!row) return showProgressionList(trigger);
  const suggestion = suggestProgression(state.planRecords, version, row);
  progressionReview = { routineID, version, row, suggestion };
  showDialog('progression-detail', escapeHTML(row.exercise.name),
    renderProgressionDetail(state.planRecords, version, row, suggestion, state.unit, dateLabel, ruleOpen), trigger);
  const form = dialog.querySelector('#progression-form');
  if (form) updateProgressionFields(form);
  focusProgressionTitle();
}

function focusProgressionTitle() {
  const title = dialog.querySelector('#dialog-title');
  title.tabIndex = -1;
  title.focus();
}

function handleProgressionAction(action, value, focus) {
  if (action === 'progression-open') return showProgressionList(dialog.open ? dialogTrigger : focus, value ?? '');
  if (action === 'progression-list') return showProgressionList(dialogTrigger);
  if (action === 'progression-review') {
    const [routineID, rowID, versionID] = value.split(':');
    return showProgressionReview(routineID, rowID, dialog.open ? dialogTrigger : focus, false, versionID);
  }
  if (!progressionReview) return;
  const { routineID, version, row, suggestion } = progressionReview;
  if (action === 'progression-override') {
    dialogTrigger = null;
    dialog.close();
    selectTab('routines');
    const edited = { ...version, exercises: version.exercises.map(entry =>
      entry.id === row.id ? { ...entry, work: progressionWorkingSets(row, suggestion) } : entry) };
    return openBuilder(edited, null, row.id, progressionReview);
  }
  const scope = { 'progression-once': 'once', 'progression-accept': 'routine', 'progression-dismiss': 'dismiss' }[action];
  if (!scope) return;
  try {
    state.planRecords = routineStore.acceptProgression(routineID, version.id, row.id, suggestion, scope);
    render();
    showProgressionReview(routineID, row.id, dialogTrigger, false, scope === 'routine' ? null : version.id);
    const status = document.createElement('p');
    status.className = 'builder-hint';
    status.setAttribute('role', 'status');
    status.textContent = { routine: 'Recommendation saved as a new routine version.', once: 'Queued for the next matching workout.', dismiss: 'Recommendation dismissed.' }[scope];
    dialog.querySelector('.progression-detail').prepend(status);
    announce(status.textContent);
  } catch (error) { dialog.querySelector('#progression-error').textContent = error.message; }
}

let photoContext = null;
let photoComparison = null;

function showPhotoManager(trigger) {
  showDialog('photos-manage', 'Progress photos', renderManagePhotos(state.photoLinks, photoContext, typeof window.showOpenFilePicker === 'function'), trigger);
}

function showPhotoComparison(trigger) {
  showDialog('photos-compare', 'Compare progress photos', renderPhotoComparison(state.photoLinks, photoComparison, longDate), trigger);
}

async function handlePhotoAction(action, value, focus) {
  const trigger = dialogTrigger ?? focus;
  try {
    switch (action) {
      case 'photos-compare': {
        const dates = photoDates(state.photoLinks);
        const selected = state.historyView.day;
        const second = dates.includes(selected) ? selected : dates.at(-1) ?? selected;
        const first = dates.filter(day => day < second).at(-1) ?? dates.find(day => day !== second) ?? offsetDay(second, -7);
        photoComparison = { first, second };
        return showPhotoComparison(focus);
      }
      case 'photos-manage': {
        const workout = personalSession(value);
        const day = workout ? dayOf(workout) : value;
        if (!isDay(day) || (workout && !workout.completedAt)) return;
        photoContext = { day, sessionID: workout?.id ?? null, workout: workout && sessionPlan(workout).name, returnToFinish: dialogAction === 'history-finish' };
        return showPhotoManager(trigger);
      }
      case 'photos-choose': {
        const context = photoContext;
        const handles = await window.showOpenFilePicker({
          multiple: true,
          types: [{ description: 'Photos', accept: { 'image/jpeg': ['.jpg', '.jpeg'], 'image/png': ['.png'], 'image/webp': ['.webp'],
            'image/heic': ['.heic', '.heif'], 'image/avif': ['.avif'] } }],
        });
        state.photoLinks = await photoStore.link(handles, context.day, context.sessionID);
        render();
        if (photoContext === context) showPhotoManager(trigger);
        return announce('Progress photo links saved.');
      }
      case 'photos-allow': {
        const link = state.photoLinks.find(item => item.id === value);
        await requestDevicePhoto(link?.handle);
        paintPhotoPreviews(main, state.photoLinks);
        if (dialog.open) paintPhotoPreviews(dialog, state.photoLinks);
        return;
      }
      case 'photos-remove':
      case 'photos-cancel-remove':
        photoContext.pendingRemove = action === 'photos-remove' ? value : null;
        return showPhotoManager(trigger);
      case 'photos-confirm-remove': {
        const context = photoContext;
        if (context?.pendingRemove !== value) return;
        state.photoLinks = await photoStore.unlink(value);
        context.pendingRemove = null;
        render();
        if (photoContext === context) showPhotoManager(trigger);
        return;
      }
      case 'photos-back-finish':
        photoContext = null;
        return showFinishedWorkout(personalSession(value));
    }
  } catch (error) {
    if (error.name === 'AbortError') return;
    const notice = dialog.querySelector('#photo-error');
    const message = error.name === 'NotAllowedError' || error.name === 'SecurityError' ? 'Photo access is off.' : 'The photo link could not be saved or opened.';
    if (notice) notice.textContent = message;
    else announce(message);
  }
}

let rotationDraft = [];
let historyEdit = null;
let historyComparison = null;

function openHistoryEditor(trigger) {
  const expanded = new Set([...dialog.querySelectorAll('[data-history-disclosure][open]')].map(item => item.dataset.historyDisclosure));
  const scroll = dialog.scrollTop;
  showDialog('history-edit', historyEdit.sessionID ? 'Edit workout' : 'Add missed workout',
    renderHistoryEditor(historyEdit, state.planRecords, libraryItems()), trigger);
  for (const item of dialog.querySelectorAll('[data-history-disclosure]')) item.open = expanded.has(item.dataset.historyDisclosure);
  dialog.scrollTop = scroll;
}

function openHistoryComparison(trigger) {
  const selected = personalSession(historyComparison.id);
  const candidates = sessionsByDate(state.planRecords.sessions).filter(other =>
    other.id !== selected.id && other.completedAt && comparisonScopes(selected, other).length);
  showDialog('history-compare', 'Compare sessions',
    renderComparison(selected, candidates, historyComparison.other, historyComparison.scope, state.unit), trigger);
}

function handleHistoryAction(action, value, target, focus) {
  const view = state.historyView;
  const trigger = dialogTrigger ?? focus;
  const editRow = target.closest('[data-history-exercise]');
  const exercise = historyEdit?.exercises.find(item => item.row.id === (editRow?.dataset.historyExercise ?? value));
  try {
    switch (action) {
      case 'history-layout':
        view.layout = value;
        return render({ focus });
      case 'history-day':
        view.day = value;
        return render({ focus });
      case 'history-month':
        view.month = calendarMonth(view.month, Number(value));
        view.day = view.month;
        return render({ focus });
      case 'history-clear':
        view.filters = {};
        return render();
      case 'history-add': {
        const day = view.layout === 'calendar' && view.day < localDayKey() ? view.day : localDayKey();
        historyEdit = historyDraft(null, null, day, state.unit);
        const now = new Date();
        if (day === localDayKey() && now.getHours() < 9) historyEdit.start = [now.getHours(), now.getMinutes()].map(value => String(value).padStart(2, '0')).join(':');
        return openHistoryEditor(focus);
      }
      case 'history-edit':
        historyEdit = historyDraft(personalSession(value), null, view.day, state.unit);
        return openHistoryEditor(focus);
      case 'history-add-set':
        exercise.sets.push(newHistorySet(state.unit));
        return openHistoryEditor(trigger);
      case 'history-remove-set':
        exercise.sets = exercise.sets.filter(set => set.id !== value);
        return openHistoryEditor(trigger);
      case 'history-add-exercise': {
        const read = id => dialog.querySelector('#history-' + id).value;
        const selected = libraryExercise(read('exercise-choice'));
        if (!selected) throw new Error('Choose an exercise to add.');
        const row = draftExercise(selected);
        Object.assign(row, { measurement: read('measurement'), counting: read('counting'), basis: read('basis'),
          equipmentLabel: read('equipment').trim(), work: [] });
        if (row.basis === 'perDumbbell' && selected.equipment !== 'dumbbell') throw new Error('Choose a dumbbell exercise for per-dumbbell load.');
        if (row.measurement === 'setting' && !row.equipmentLabel) throw new Error('Enter the machine name for a machine setting.');
        historyEdit.exercises.push({ row, notes: '', sets: [newHistorySet(state.unit)] });
        return openHistoryEditor(trigger);
      }
      case 'history-save': {
        const editing = Boolean(historyEdit.sessionID);
        state.planRecords = routineStore.saveHistory(historyEdit);
        const session = editing ? personalSession(historyEdit.sessionID) : state.planRecords.sessions.at(-1);
        if (view.layout === 'calendar') { view.day = dayOf(session); view.month = view.day; }
        dialog.close();
        render();
        return announce(editing ? 'Workout corrections saved.' : 'Missed workout added.');
      }
      case 'history-compare': {
        const selected = personalSession(value);
        const prior = priorComparable(selected, state.planRecords.sessions);
        historyComparison = { id: value, other: prior?.other.id, scope: prior?.exerciseID };
        return openHistoryComparison(focus);
      }
      case 'history-view-finished': {
        const selected = personalSession(value);
        view.layout = 'calendar';
        view.day = dayOf(selected);
        view.month = view.day;
        view.filters = {};
        state.history = 'sessions';
        dialogTrigger = null;
        dialog.close();
        return selectTab('history', true);
      }
    }
  } catch (error) {
    const inline = dialog.querySelector('#history-error');
    if (inline) { inline.textContent = error.message; inline.scrollIntoView({ block: 'nearest' }); }
    else planError(error, focus);
  }
}

function historyEditInput(target) {
  const read = target.type === 'checkbox' ? target.checked : target.value;
  const draftField = target.dataset.historyDraft;
  if (draftField && draftField !== 'versionID') historyEdit[draftField] = read;
  const exercise = historyEdit.exercises.find(item => item.row.id === target.closest('[data-history-exercise]')?.dataset.historyExercise);
  if (!exercise) return;
  if (target.hasAttribute('data-history-exercise-note')) exercise.notes = read;
  const setID = target.closest('[data-history-set]')?.dataset.historySet;
  const set = exercise.sets.find(item => item.id === setID);
  if (!set) return;
  if (target.dataset.historyInput) set.input[target.dataset.historyInput] = read;
  if (target.dataset.historySetField) set[target.dataset.historySetField] = read;
}

function openSchedule(trigger, section = '') {
  showDialog('schedule-planner', 'Training schedule', renderSchedulePlanner(state.planRecords, today(), state.date, rotationDraft, section), trigger);
}

function openProgram(id, index, trigger) {
  const block = state.planRecords.programBlocks.find(item => item.id === id);
  if (!block) return;
  showDialog('schedule-program', escapeHTML(block.name), renderProgramWeek(state.planRecords, block, index), trigger);
}

function handleScheduleAction(action, value, target, focus) {
  const get = id => dialog.querySelector('#' + id)?.value ?? '';
  const change = entry => { state.planRecords = routineStore.changeSchedule(entry, today()); };
  const sourceDate = target.closest('[data-schedule-date]')?.dataset.scheduleDate;
  const program = dialog.querySelector('.schedule-program');
  const trigger = dialogTrigger ?? focus;
  const saved = message => {
    dialog.close();
    render();
    announce(message);
  };
  try {
    switch (action) {
      case 'schedule-calendar': {
        state.calendarAnchor = value === '0' ? null : offsetDay(state.calendarAnchor ?? today(), Number(value));
        state.date = state.calendarAnchor ?? today();
        return render({ focus });
      }
      case 'schedule-open':
        rotationDraft = [...(state.planRecords.rotations?.find(entry => !entry.endBefore)?.versions ?? [])];
        return openSchedule(focus);
      case 'schedule-open-blocks': return openSchedule(trigger, 'blocks');
      case 'schedule-save-settings':
        change({ action: 'settings', weekStart: Number(get('schedule-week-start')), mode: get('schedule-view') });
        state.calendarAnchor = null;
        state.date = today();
        return saved('Calendar view saved.');
      case 'schedule-save-weekday':
        change({ action: 'weekday', weekday: Number(get('schedule-weekday')), versionID: get('schedule-weekday-version'), start: get('schedule-weekday-start') });
        render();
        return openSchedule(trigger, 'weekday');
      case 'schedule-end-weekday':
        change({ action: 'stopWeekday', id: value });
        render();
        return openSchedule(trigger, 'weekday');
      case 'schedule-step-add': {
        const selected = get('schedule-rotation-version');
        if (!selected) throw new Error('Choose a routine version for the next step.');
        rotationDraft.push(selected);
        dialog.querySelector('#schedule-rotation-version').value = '';
        break;
      }
      case 'schedule-step-up':
      case 'schedule-step-down': {
        const from = Number(value);
        const to = from + (action === 'schedule-step-up' ? -1 : 1);
        [rotationDraft[from], rotationDraft[to]] = [rotationDraft[to], rotationDraft[from]];
        break;
      }
      case 'schedule-step-remove': rotationDraft.splice(Number(value), 1); break;
      case 'schedule-save-rotation':
        change({ action: 'rotation', versions: rotationDraft, start: get('schedule-rotation-start'), interval: Number(get('schedule-rotation-interval')) });
        return saved('Rotation saved.');
      case 'schedule-end-rotation':
        change({ action: 'stopRotation', id: value });
        rotationDraft = [];
        render();
        return openSchedule(trigger, 'rotation');
      case 'schedule-save-block':
        change({ action: 'block', name: get('schedule-block-name'), start: get('schedule-block-start'), count: Number(get('schedule-block-count')) });
        return openProgram(state.planRecords.programBlocks.at(-1).id, 0, trigger);
      case 'schedule-open-block': return openProgram(value, 0, trigger);
      case 'schedule-save-week':
        change({ action: 'blockWeek', id: program.dataset.blockId, date: program.dataset.weekStart, kind: get('schedule-week-kind'), notes: get('schedule-week-notes') });
        return openProgram(program.dataset.blockId, Number(value), trigger);
      case 'schedule-add-block-session': {
        const date = get('schedule-program-date');
        const { blockId, weekStart, weekEnd } = program.dataset;
        if (date < weekStart || date > weekEnd) throw new Error('Choose a date within this program week.');
        const kind = get('schedule-week-kind');
        const notes = get('schedule-week-notes');
        change({ action: 'blockSession', id: blockId, date, versionID: get('schedule-program-version') });
        render();
        openProgram(blockId, Number(value), trigger);
        dialog.querySelector('#schedule-week-kind').value = kind;
        dialog.querySelector('#schedule-week-notes').value = notes;
        return;
      }
      case 'schedule-move': {
        const entry = scheduledFor(sourceDate).find(item => item.key === value);
        return showDialog('schedule-move', 'Move scheduled session', renderMove(entry, today()), focus);
      }
      case 'schedule-save-move':
        change({ action: 'move', key: value, date: sourceDate, destination: get('schedule-move-date') });
        return saved('Session rescheduled.');
      case 'schedule-skip': {
        const entry = scheduledFor(sourceDate).find(item => item.key === value);
        const hint = entry.rotationID ? 'This advances the rotation by one step.' : 'This marks the planned session as skipped.';
        return showDialog('schedule-skip', 'Skip scheduled session?', `<div class="stack" data-schedule-date="${sourceDate}"><p>${hint}</p>
          <button type="button" class="primary" data-action="schedule-confirm-skip" data-value="${escapeHTML(value)}">Confirm skip</button>
          <p id="schedule-error" class="entry-error" role="alert"></p></div>`, focus);
      }
      case 'schedule-confirm-skip':
        change({ action: 'skip', key: value, date: sourceDate });
        return saved('Session skipped.');
      case 'schedule-readiness':
        return showDialog('schedule-readiness', 'Readiness · ' + shortDate(state.date),
          renderReadiness(state.date, state.planRecords.readiness?.find(item => item.date === state.date)), focus);
      case 'schedule-save-readiness':
        change({ action: 'readiness', date: value, ...Object.fromEntries(Object.keys(readinessFields).map(key => [key, Number(get('readiness-' + key))])) });
        return saved('Readiness check-in saved.');
    }
    if (action.startsWith('schedule-step-')) {
      dialog.querySelector('#schedule-sequence').innerHTML = rotationSteps(state.planRecords, rotationDraft);
      dialog.querySelector('#schedule-error').textContent = '';
    }
  } catch (error) {
    const inline = dialog.querySelector('#schedule-error');
    if (inline) { inline.textContent = error.message; inline.scrollIntoView({ block: 'nearest' }); }
    else planError(error, focus);
  }
}

function showExerciseEditor(source, editing, trigger) {
  const draft = editing ? source : { ...source, id: crypto.randomUUID(), name: source ? `${source.name} variation` : '' };
  exerciseDraft = { draft, editing };
  showDialog('exercise', editing ? 'Edit exercise' : 'New custom exercise', exerciseEditor(draft, editing), trigger);
}

function showSession(trigger) {
  const routine = activePreview();
  let session = activePersonal();
  if (session) {
    try {
      if (!session.log) {
        state.planRecords = routineStore.prepare(session.id);
        session = activePersonal();
      }
      showDialog('personal-workout', escapeHTML(sessionPlan(session).name), workoutMarkup(session), trigger);
      paintWorkout(session);
    } catch (error) { planError(error, trigger); }
    return;
  }
  if (!routine) {
    const hint = state.sampleMode ? 'Choose a sample routine to start a workout preview.' : 'Open or create a saved routine to start a workout.';
    showDialog('idle', 'Workout log', `<p class="dialog-description">${hint}</p><div class="builder-actions"><button class="primary" type="button" data-action="choose-routine">Browse routines</button>
      ${state.sampleMode ? '' : '<button class="secondary" type="button" data-action="log-start-empty">Start empty workout</button>'}</div>`, trigger);
    return;
  }
  showDialog('active', routine.name, `<p class="dialog-description">Active workout preview · Sample routine</p><ul class="active-exercises">${routine.exercises.map(exercise => `<li><strong>${exercise.name}</strong><span>${exercise.sets} × ${exercise.reps} reps</span></li>`).join('')}</ul><p class="dialog-description">Switch to personal mode to record a workout.</p><button class="secondary end-button" type="button" data-action="end">End workout preview</button>`, trigger);
}

function workoutMarkup(session) {
  const version = personalRoutine(session.snapshot.routineID)?.versions.find(item => item.id === session.snapshot.id);
  return renderWorkout(session, state.planRecords, catalog, state.exercises, state.unit, dateLabel) +
    (programContext(state.planRecords, session).kind !== 'deload' ? renderWorkoutRecommendations(state.planRecords, version, state.unit,
      row => sessionPlan(session).exercises.some(entry => entry.id === row.id && variantKey(entry) === variantKey(row))) : '');
}

function paintWorkoutClocks() {
  const session = activePersonal();
  if (!session) return;
  const now = new Date().toISOString();
  const timing = workoutTimes(session, now);
  timing.rest = restRemaining(session, now);
  const status = dock.querySelector('[data-workout-status]');
  const text = session.log?.clock?.pausedAt ? 'Workout paused' : timing.rest == null ? 'Active workout' :
    timing.rest === 0 ? 'Rest ready' : 'Rest ' + clockText(timing.rest);
  if (status && status.textContent !== text) status.textContent = text;
  if (dialogAction !== 'personal-workout') return;
  for (const node of dialog.querySelectorAll('[data-clock]')) {
    const value = timing[node.dataset.clock];
    const label = value === 0 && node.dataset.clock === 'rest' ? 'Ready' : clockText(value);
    if (node.textContent !== label) node.textContent = label;
  }
}

function paintWorkout(session) {
  paintWorkoutClocks();
  for (const node of dialog.querySelectorAll('[data-log-set]:has(.log-typo)')) paintWorkoutRow(node, session);
}

function paintWorkoutRow(node, session) {
  const id = node.closest('[data-log-exercise]').dataset.logExercise;
  const exercise = session.log.exercises.find(item => item.id === id);
  const set = exercise.sets.find(item => item.id === node.dataset.logSet);
  const row = sessionPlan(session).exercises.find(item => item.id === id);
  updateWorkoutFields(node, session, state.planRecords.sessions, row, set, exercise, state.unit);
}

setInterval(paintWorkoutClocks, 250);
document.addEventListener('visibilitychange', paintWorkoutClocks);
setInterval(refreshLocalCalendar, 60_000);
document.addEventListener('visibilitychange', refreshLocalCalendar);

function refreshWorkout() {
  const previous = dialog.querySelector('.workout-editor');
  const actionKey = document.activeElement?.closest('.log-dock') && document.activeElement.dataset.action;
  const focusedSet = document.activeElement?.closest('[data-log-set]')?.dataset.logSet;
  const expanded = new Set([...previous.querySelectorAll('details[open]')].map(item => item.dataset.logDisclosure));
  const scroll = dialog.scrollTop;
  const session = activePersonal();
  previous.outerHTML = workoutMarkup(session);
  for (const item of dialog.querySelectorAll('details[data-log-disclosure]')) item.open = expanded.has(item.dataset.logDisclosure);
  dialog.scrollTop = scroll;
  if (actionKey) (dialog.querySelector(`.log-dock [data-action="${actionKey}"]`) ?? dialog.querySelector('.log-dock button'))?.focus({ preventScroll: true });
  else if (focusedSet) dialog.querySelector(`[data-log-set="${focusedSet}"] > button`)?.focus({ preventScroll: true });
  paintWorkout(session);
}

function finishLogger(id, early) {
  state.planRecords = routineStore.finish(id, early);
  render();
  showFinishedWorkout(personalSession(id));
  announce(early ? 'Workout saved as ended early.' : 'Workout finished.');
}

function showFinishedWorkout(session) {
  if (!session) return;
  const version = personalRoutine(session.snapshot.routineID)?.versions.find(item => item.id === session.snapshot.id);
  showDialog('history-finish', 'Workout summary', renderFinishSummary(session, state.planRecords.sessions, state.unit, dateLabel, state.user.entries, state.planRecords.scoreWeights) +
    (programContext(state.planRecords, session).kind !== 'deload' ? renderWorkoutRecommendations(state.planRecords, version, state.unit,
      row => session.results.some(set => set.exerciseID === row.id)) : '') +
    `<div class="builder-actions"><button type="button" class="secondary" data-action="data-summary" data-value="${session.id}">Share workout summary</button><button type="button" class="secondary" data-action="photos-manage" data-value="${session.id}">Add progress photos</button>
      ${state.planRecords.routines.length ? `<button type="button" class="secondary" data-action="progression-open" data-value="${personalRoutine(session.snapshot.routineID)?.id ?? ''}">Review progression</button>` : ''}</div>`, '.active-bar');
}

function openEnergyEditor(id, focus) {
  const session = personalSession(id);
  if (!session?.completedAt || !session.results.length) return;
  energyContext = { id, finish: dialogAction === 'history-finish' };
  showDialog('energy', 'Workout calories', renderEnergyEditor(session, state.user.entries, dateLabel), energyContext.finish ? dialogTrigger : focus);
}

function saveEnergyInput(input) {
  if (!energyContext) return;
  const { id, finish } = energyContext;
  try {
    state.planRecords = routineStore.saveWorkoutEnergy(id, input);
    if (finish) showFinishedWorkout(personalSession(id));
    else dialog.close();
    render();
    announce(input ? 'Calorie inputs saved.' : 'Calorie inputs cleared.');
  } catch (error) { dialog.querySelector('#energy-error').textContent = error.message; }
}

function confirmLog(message, label, action, value = '') {
  const target = dialog.querySelector('#log-confirmation');
  target.innerHTML = `<div class="log-panel"><p>${message}</p><div class="builder-actions">
    <button type="button" class="primary" data-action="${action}" data-value="${value}">${label}</button>
    <button type="button" class="secondary" data-action="log-cancel-confirmation">Cancel</button></div></div>`;
  target.scrollIntoView({ block: 'nearest' });
  target.querySelector('button').focus({ preventScroll: true });
}

function confirmEndEarly() {
  confirmLog('Save completed results and leave pending sets unfinished?', 'End early and save', 'log-confirm-end');
}

function completeWorkoutSet(exerciseID, setID) {
  const row = dialog.querySelector(`[data-log-set="${setID}"]`);
  const hint = row.querySelector('.log-typo')?.textContent;
  applyLoggerChange({ action: 'complete', exerciseID, setID });
  (dialog.querySelector('.log-dock [data-action="log-complete-next"]') ??
    dialog.querySelector('.log-dock [data-action="log-undo-last"]'))?.focus({ preventScroll: true });
  if (hint) announce(hint.replace('You can still log this set.', 'Set logged.'));
}

function applyLoggerChange(change, { refresh = true } = {}) {
  state.planRecords = routineStore.logChange(activePersonal().id, change, state.unit);
  if (refresh) refreshWorkout();
}

function handleLogAction(action, value, target, focus) {
  const session = activePersonal();
  const exerciseID = target.closest('[data-log-exercise]')?.dataset.logExercise;
  const exercise = session?.log?.exercises.find(item => item.id === (exerciseID ?? value));
  const set = exercise?.sets.find(item => item.id === value);
  const change = { exerciseID, setID: value };
  try {
    switch (action) {
      case 'log-workout-pause': return applyLoggerChange({ action: 'pause' });
      case 'log-workout-resume': return applyLoggerChange({ action: 'resume' });
      case 'log-timer-extend': return applyLoggerChange({ action: 'extendRest' });
      case 'log-timer-restart': return applyLoggerChange({ action: 'restartRest' });
      case 'log-timer-skip': return applyLoggerChange({ action: 'skipRest' });
      case 'log-undo-last': return applyLoggerChange({ action: 'undoLast' });
      case 'log-focus-next': {
        const row = dialog.querySelector(`[data-log-set="${value}"]`);
        row.tabIndex = -1;
        row.focus({ preventScroll: true });
        return row.scrollIntoView({ block: 'center' });
      }
      case 'log-complete-next': {
        const [exerciseID, setID] = value.split('/');
        return completeWorkoutSet(exerciseID, setID);
      }
      case 'log-sides': return applyLoggerChange({ ...change, action: 'editSet', field: 'separateSides', value: !set.input?.separateSides });
      case 'log-step': {
        const [field, direction] = value.split('/');
        const node = target.closest('[data-log-set]');
        const row = sessionPlan(session).exercises.find(item => item.id === exerciseID);
        const loggingSet = exercise.sets.find(item => item.id === node.dataset.logSet);
        const next = workoutStep(session, row, loggingSet, field, Number(direction), state.unit);
        if (next != null) applyLoggerChange({ action: 'editSet', exerciseID, setID: loggingSet.id, field, value: next });
        else announce('No available load in that direction.');
        return;
      }
      case 'log-save-equipment': {
        const node = target.closest('[data-log-set]');
        const row = sessionPlan(session).exercises.find(item => item.id === exerciseID);
        const profile = session.log.loadProfiles?.[loadKey(row)];
        const values = Object.fromEntries([...node.querySelectorAll('[data-log-gear]')].map(field => [field.dataset.logGear, field.value]));
        return applyLoggerChange({ action: 'loadProfile', exerciseID, unit: profile?.unit ?? set.input?.unit ?? state.unit, ...values });
      }
      case 'log-start-empty':
      case 'log-start-scheduled':
        if (!session) state.planRecords = action === 'log-start-empty' ? routineStore.startEmpty() : routineStore.startScheduled(value, target.closest('[data-schedule-date]')?.dataset.scheduleDate);
        render();
        return showSession('.active-bar');
      case 'log-save-schedule':
        state.planRecords = routineStore.schedule(value, dialog.querySelector('#schedule-date').value);
        dialog.close();
        render();
        return announce('Workout scheduled.');
      case 'log-add-exercise': {
        const chosen = libraryExercise(dialog.querySelector('#log-exercise-choice').value);
        if (!chosen) throw new Error('Choose an exercise to add.');
        const entry = draftExercise(chosen);
        entry.measurement = dialog.querySelector('#log-measurement').value;
        entry.counting = dialog.querySelector('#log-counting').value;
        entry.basis = dialog.querySelector('#log-basis').value;
        entry.equipmentLabel = dialog.querySelector('#log-equipment').value.trim();
        if (entry.basis === 'perDumbbell' && chosen.equipment !== 'dumbbell') throw new Error('Select a dumbbell exercise for per-dumbbell load.');
        if (entry.measurement === 'setting' && !entry.equipmentLabel) throw new Error('Enter a machine name for a machine setting.');
        entry.work = [];
        return applyLoggerChange({ action: 'addExercise', entry });
      }
      case 'log-complete': return completeWorkoutSet(exerciseID, value);
      case 'log-undo': return applyLoggerChange({ ...change, action: 'undo' });
      case 'log-skip-set': return applyLoggerChange({ ...change, action: 'skipSet' });
      case 'log-restore-set': return applyLoggerChange({ ...change, action: 'restoreSet' });
      case 'log-add-set':
      case 'log-add-warm': return applyLoggerChange({ action: 'addSet', exerciseID: value, purpose: action === 'log-add-warm' ? 'warm-up' : 'working' });
      case 'log-set-up':
      case 'log-set-down': return applyLoggerChange({ ...change, action: 'moveSet', direction: action === 'log-set-up' ? -1 : 1 });
      case 'log-delete-set':
        if (set.status === 'completed') return confirmLog('Delete this completed set?', 'Delete recorded set', 'log-confirm-delete-set', `${exerciseID}/${value}`);
        return applyLoggerChange({ ...change, action: 'removeSet' });
      case 'log-confirm-delete-set': {
        const [exerciseID, setID] = value.split('/');
        return applyLoggerChange({ exerciseID, setID, action: 'removeSet' });
      }
      case 'log-queue':
      case 'log-resume': return applyLoggerChange({ action: 'queue', exerciseID: value, value: action === 'log-queue' });
      case 'log-skip-exercise':
      case 'log-restore-exercise': return applyLoggerChange({ action: action === 'log-skip-exercise' ? 'skipExercise' : 'restoreExercise', exerciseID: value });
      case 'log-exercise-up':
      case 'log-exercise-down': return applyLoggerChange({ action: 'moveExercise', exerciseID: value, direction: action === 'log-exercise-up' ? -1 : 1 });
      case 'log-delete-exercise':
        if (exercise.sets.some(row => row.status === 'completed')) return confirmLog('Delete this exercise and its completed sets?', 'Delete recorded exercise', 'log-confirm-delete-exercise', value);
        return applyLoggerChange({ action: 'removeExercise', exerciseID: value });
      case 'log-confirm-delete-exercise': return applyLoggerChange({ action: 'removeExercise', exerciseID: value });
      case 'log-update-routine': return confirmLog('Use this exercise order, set rows and edited targets for future workouts?', 'Save new routine version', 'log-confirm-routine');
      case 'log-confirm-routine':
        state.planRecords = routineStore.updateRoutine(session.id);
        refreshWorkout();
        dialog.querySelector('#log-confirmation').innerHTML = '<p role="status">Routine saved for future workouts.</p>';
        return;
      case 'log-end-early': return confirmEndEarly();
      case 'log-confirm-end': return finishLogger(session.id, true);
      case 'log-cancel-confirmation': dialog.querySelector('#log-confirmation').replaceChildren(); break;
    }
  } catch (error) { planError(error, focus); }
}

function selectTab(tab, focus = false) {
  if (!tabs.some(([id]) => id === tab)) return;
  state.tab = tab;
  state.routine = null;
  state.builder = null;
  state.libraryOpen = false;
  state.exerciseDetail = null;
  state.substituteFor = null;
  if (location.hash !== `#${tab}`) history.pushState(null, '', `#${tab}`);
  render({ scroll: true, focus: focus ? '#main' : null });
}

function openBuilder(version, sessionID = null, rowID = null, progression = null) {
  state.builder = { draft: makeDraft(version, state.unit), expanded: new Set(rowID ? [rowID] : []), search: '', sessionID, progression,
    canUpdate: progression && newest(personalRoutine(progression.routineID)).id === version.id };
  render({ scroll: true, focus: rowID ? null : '#main' });
  if (rowID) main.querySelector(`[data-builder-expand="${rowID}"] > summary`)?.focus();
}

function closeBuilder() {
  const workout = state.builder.sessionID;
  state.builder = null;
  render({ scroll: true, focus: '#main' });
  if (workout) showSession('.active-bar');
}

function planError(error, trigger) {
  const inline = document.querySelector('#plan-error, #plan-session-error');
  if (inline) {
    inline.textContent = error.message;
    if (trigger) inline.scrollIntoView({ block: 'nearest' });
  }
  else showDialog('error', 'Routine', `<p class="dialog-description">${escapeHTML(error.message)}</p>`, trigger);
}

function handlePlanAction(action, value, focus) {
  const builder = state.builder;
  const draft = builder?.draft;
  let redraw = true;
  try {
    switch (action) {
      case 'plan-new': return openBuilder();
      case 'plan-edit': return openBuilder(newest(personalRoutine(value)));
      case 'plan-cancel': return closeBuilder();
      case 'plan-duplicate':
        state.planRecords = routineStore.duplicate(value);
        announce('Routine duplicated.');
        break;
      case 'plan-versions': {
        const routine = personalRoutine(value);
        return showDialog('routine-versions', 'Version history', renderVersions(routine, state.unit), focus);
      }
      case 'plan-start':
        if (!activePersonal()) {
          state.planRecords = routineStore.start(value);
          render();
        }
        return showSession(focus);
      case 'plan-schedule': {
        const version = newest(personalRoutine(value));
        return showDialog('schedule', `Schedule ${escapeHTML(version.name)}`, `<div class="builder-fields">
          <label>Workout date<input type="date" id="schedule-date" value="${localDayKey()}"></label>
          <button type="button" class="primary" data-action="log-save-schedule" data-value="${value}">Schedule</button></div>
          <p class="entry-error" role="alert" id="plan-session-error"></p>`, focus);
      }
      case 'plan-repeat':
        state.planRecords = routineStore.repeat(value);
        render();
        return showSession('.active-bar');
      case 'plan-finish':
        if (activePersonal().log.exercises.some(exercise => exercise.sets.some(set => set.status === 'pending'))) return confirmEndEarly();
        return finishLogger(value, false);
      case 'plan-session-edit': {
        const session = personalSession(value);
        dialogTrigger = null;
        dialog.close();
        selectTab('routines');
        return openBuilder(sessionPlan(session), session.id);
      }
      case 'plan-save':
        if (builder.progression) {
          const { routineID, version, row, suggestion } = builder.progression;
          state.planRecords = routineStore.acceptProgression(routineID, version.id, row.id, suggestion, value, draft, state.unit);
          closeBuilder();
          return announce(value === 'once' ? 'Edited recommendation queued for the next matching workout.' : 'Edited recommendation saved as a new routine version.');
        }
        state.planRecords = builder.sessionID ? routineStore.editSession(builder.sessionID, draft, state.unit) : routineStore.saveRoutine(draft, state.unit);
        if (!builder.sessionID && state.routineCategory) state.routineCategory = draft.categoryID;
        closeBuilder();
        return announce(builder.sessionID ? 'Workout updated.' : 'Routine saved.');
      case 'plan-category': {
        const category = { id: crypto.randomUUID(), name: document.querySelector('#new-routine-category').value.trim() };
        state.planRecords = routineStore.addCategory(category);
        draft.categoryID = category.id;
        break;
      }
      case 'plan-add-exercise': {
        const exercise = libraryExercise(document.querySelector('#routine-exercise-choice').value);
        if (!exercise) throw new Error('Choose an exercise to add.');
        const row = draftExercise(exercise);
        draft.exercises.push(row);
        builder.expanded.add(row.id);
        builder.search = '';
        break;
      }
      case 'plan-remove-row':
        draft.exercises = draft.exercises.filter(row => row.id !== value);
        draft.groups = draft.groups.map(group => ({ ...group, members: group.members.filter(id => id !== value) }))
          .filter(group => group.members.length >= 2);
        break;
      case 'plan-up':
      case 'plan-down': {
        const index = draft.exercises.findIndex(row => row.id === value);
        const adjacent = draft.exercises[index + (action === 'plan-up' ? -1 : 1)];
        if (adjacent) reorder(draft.exercises, value, adjacent.id);
        break;
      }
      case 'plan-add-work':
      case 'plan-add-warm': {
        const row = draft.exercises.find(item => item.id === value);
        (action === 'plan-add-work' ? row.work : row.warm).push(blankSet());
        break;
      }
      case 'plan-remove-set':
        for (const row of draft.exercises) {
          if (row.work.length > 1) row.work = row.work.filter(block => block.id !== value);
          row.warm = row.warm.filter(block => block.id !== value);
        }
        break;
      case 'plan-group': {
        const group = newGroup(value);
        draft.groups.push(group);
        builder.expanded.add(group.id);
        break;
      }
      case 'plan-remove-group': draft.groups = draft.groups.filter(group => group.id !== value); break;
      default: redraw = false;
    }
    if (redraw) render({ focus });
  } catch (error) { planError(error, focus); }
}

render();

systemDark.addEventListener('change', () => { applyAppearance(); renderHeader(); });
window.addEventListener('hashchange', () => selectTab(location.hash.slice(1) || 'today'));
main.addEventListener('toggle', event => {
  const expanded = event.target.dataset.builderExpand;
  if (expanded && state.builder && event.target.isConnected) {
    if (event.target.open) state.builder.expanded.add(expanded);
    else state.builder.expanded.delete(expanded);
    return;
  }
  if (!event.target.matches('details[data-exercise]')) return;
  const { open, dataset: { exercise } } = event.target;
  if (open) state.expanded.add(exercise);
  else state.expanded.delete(exercise);
}, true);

main.addEventListener('input', event => {
  const target = event.target;
  if (state.builder && target.id === 'routine-exercise-search') {
    state.builder.search = target.value;
    document.querySelector('#routine-exercise-choice').innerHTML = exerciseOptions(catalog, state.exercises, target.value);
    return;
  }
  if (state.builder && target.dataset.planField && target.tagName === 'INPUT' && target.type !== 'checkbox') {
    planField(target)[target.dataset.planField] = target.value;
    return;
  }
  if (event.target.id !== 'exercise-search') return;
  state.exerciseQuery.name = event.target.value;
  document.querySelector('#exercise-results').innerHTML = renderSearchResults(catalog, state.exercises, state.exerciseQuery);
});

main.addEventListener('change', event => {
  const target = event.target;
  if (target.hasAttribute('data-history-filter')) {
    state.historyView.filters[target.dataset.historyFilter] = target.value;
    return render({ focus: `[data-history-filter="${target.dataset.historyFilter}"]` });
  }
  if (target.id === 'routine-category-filter') {
    state.routineCategory = target.value;
    render({ focus: '#routine-category-filter' });
  } else if (state.builder && target.dataset.planMember) {
    const group = planField(target);
    if (target.checked) group.members.push(target.dataset.planMember);
    else group.members = group.members.filter(id => id !== target.dataset.planMember);
    render({ focus: `[data-plan-group="${group.id}"] [data-plan-member="${target.dataset.planMember}"]` });
  } else if (state.builder && target.dataset.planField) {
    const field = target.dataset.planField;
    const record = planField(target);
    record[field] = target.type === 'checkbox' ? target.checked : target.value;
    if (field === 'measurement' || field === 'basis') {
      for (const block of [...record.work, ...record.warm]) {
        block.target = '';
        block.originalTarget = null;
        block.originalText = '';
      }
      render({ focus: `[data-plan-row="${record.id}"] [data-plan-field="${field}"]` });
    } else if (field === 'effort') {
      record.effortValue = '';
      render({ focus: `[data-plan-set="${record.id}"] [data-plan-field="effort"]` });
    }
  } else if (target.id === 'muscle-region-picker') {
    state.muscleRegion = target.value;
    render({ focus: '#muscle-region-picker' });
  } else if (target.hasAttribute('data-exercise-filter')) {
    state.exerciseQuery[target.dataset.exerciseFilter] = target.value;
    document.querySelector('#exercise-results').innerHTML = renderSearchResults(catalog, state.exercises, state.exerciseQuery);
  } else if (target.hasAttribute('data-available-equipment')) {
    if (target.checked) state.availableEquipment.add(target.value);
    else state.availableEquipment.delete(target.value);
    document.querySelector('#substitution-results').innerHTML = renderSubstitutionResults(libraryExercise(state.substituteFor), libraryItems(),
      state.availableEquipment, state.exercises.preferences);
  }
});

function planField(target) {
  const draft = state.builder.draft;
  const groupID = target.closest('[data-plan-group]')?.dataset.planGroup;
  if (groupID) return draft.groups.find(group => group.id === groupID);
  const rowID = target.closest('[data-plan-row]')?.dataset.planRow;
  if (!rowID) return draft;
  const row = draft.exercises.find(entry => entry.id === rowID);
  const blockID = target.closest('[data-plan-set]')?.dataset.planSet;
  return blockID ? [...row.warm, ...row.work].find(block => block.id === blockID) : row;
}

let drag = null;
main.addEventListener('pointerdown', event => {
  const handle = event.target.closest('[data-drag-row]');
  if (!handle || event.button !== 0 || !state.builder) return;
  handle.setPointerCapture(event.pointerId);
  drag = { id: handle.dataset.dragRow, pointer: event.pointerId };
});

main.addEventListener('pointermove', event => {
  if (!drag || event.pointerId !== drag.pointer) return;
  main.querySelector('.drop-target')?.classList.remove('drop-target');
  document.elementFromPoint(event.clientX, event.clientY)?.closest('[data-plan-row]')?.classList.add('drop-target');
});

main.addEventListener('pointerup', event => {
  if (!drag || event.pointerId !== drag.pointer) return;
  const target = document.elementFromPoint(event.clientX, event.clientY)?.closest('[data-plan-row]');
  const from = drag.id;
  drag = null;
  main.querySelector('.drop-target')?.classList.remove('drop-target');
  if (!target || !state.builder || from === target.dataset.planRow) return;
  reorder(state.builder.draft.exercises, from, target.dataset.planRow);
  render({ focus: `[data-drag-row="${from}"]` });
  announce('Exercise moved.');
});

main.addEventListener('pointercancel', () => {
  drag = null;
  main.querySelector('.drop-target')?.classList.remove('drop-target');
});

function selectMuscle(target) {
  const { muscleRegion, muscleSide } = target.dataset;
  state.muscleRegion = muscleRegion;
  render({ focus: `[data-muscle-region="${muscleRegion}"][data-muscle-side="${muscleSide}"]` });
}

main.addEventListener('keydown', event => {
  const target = event.target.closest('[data-muscle-region]');
  if (target && (event.key === 'Enter' || event.key === ' ')) {
    event.preventDefault();
    selectMuscle(target);
  }
});

main.addEventListener('error', event => {
  if (!event.target.matches?.('[data-demonstration]')) return;
  const placeholder = document.createElement('p');
  placeholder.className = 'media-placeholder';
  placeholder.textContent = 'No demonstration media available';
  event.target.replaceWith(placeholder);
}, true);

document.addEventListener('click', event => {
  const region = event.target.closest('[data-muscle-region]');
  if (region) {
    selectMuscle(region);
    return;
  }
  const link = event.target.closest('a[href]');
  const tab = link?.getAttribute('href').slice(1);
  if (tabs.some(([id]) => id === tab) && !event.metaKey && !event.ctrlKey && !event.shiftKey && !event.altKey) {
    event.preventDefault();
    selectTab(tab, true);
    return;
  }

  const target = event.target.closest('button[data-action]');
  if (!target) return;
  const { action, value } = target.dataset;
  const focus = `[data-action="${action}"]${value === undefined ? '' : `[data-value="${value}"]`}`;
  if (action.startsWith('data-')) { void portability.action(action.slice(5), value, dialog.open ? dialogTrigger ?? focus : focus); return; }
  if (action.startsWith('plan-')) {
    handlePlanAction(action, value, focus);
    return;
  }
  if (action.startsWith('log-')) {
    handleLogAction(action, value, target, focus);
    return;
  }
  if (action.startsWith('schedule-')) {
    handleScheduleAction(action, value, target, focus);
    return;
  }
  if (action.startsWith('history-')) {
    handleHistoryAction(action, value, target, focus);
    return;
  }
  if (action.startsWith('photos-')) {
    void handlePhotoAction(action, value, focus);
    return;
  }
  if (action.startsWith('progression-')) {
    handleProgressionAction(action, value, focus);
    return;
  }
  if (action.startsWith('analytics-')) {
    const view = state.analyticsView;
    if (action === 'analytics-save') {
      try {
        state.planRecords = routineStore.saveAnalytics(readAnalyticsSettings(main.querySelector('#analytics-options')));
        view.settingsOpen = true;
        render({ focus });
        announce('Analytics settings saved.');
      } catch (error) {
        main.querySelector('#analytics-error').textContent = error.message;
      }
    } else {
      if (action === 'analytics-purpose') view.purpose = value;
      if (action === 'analytics-week') {
        view.week = value === '0' ? localDayKey() : offsetDay(view.week ?? state.historyView.filters.to ?? localDayKey(), Number(value));
      }
      view.settingsOpen = main.querySelector('.analytics-options')?.open ?? false;
      render({ focus });
    }
    return;
  }
  switch (action) {
    case 'energy-edit': openEnergyEditor(value, focus); break;
    case 'energy-clear': saveEnergyInput(null); break;
    case 'recap-week': {
      const direction = Number(value);
      const day = offsetDay(state.recapWeek ?? today(), direction);
      state.recapWeek = day >= today() ? null : day;
      render({ focus: direction > 0 && !state.recapWeek ? '[data-action="recap-week"][data-value="-7"]' : focus });
      break;
    }
    case 'theme': state.appearance = theme() === 'dark' ? 'light' : 'dark'; savePreferences(); render({ focus }); break;
    case 'appearance': state.appearance = value; savePreferences(); render({ focus }); break;
    case 'transparency': state.opaque = !state.opaque; savePreferences(); render({ focus }); break;
    case 'unit': state.unit = value; savePreferences(); render({ focus }); break;
    case 'date': state.date = value; render({ focus }); break;
    case 'muscle-context': state.muscleView = value; render({ focus }); break;
    case 'exercise-library':
      selectTab('routines');
      state.libraryOpen = true;
      state.exerciseQuery = newExerciseQuery(value);
      render({ scroll: true, focus: '#main' });
      break;
    case 'library-back': state.libraryOpen = false; render({ scroll: true, focus: '#main' }); break;
    case 'exercise-detail': state.exerciseDetail = value; render({ scroll: true, focus: '#main' }); break;
    case 'exercise-back': state.exerciseDetail = state.substituteFor; render({ scroll: true, focus: '#main' }); break;
    case 'exercise-substitute':
      state.substituteFor = value;
      state.availableEquipment = new Set();
      render({ scroll: true, focus: '#main' });
      break;
    case 'substitution-back': state.substituteFor = null; render({ scroll: true, focus: '#main' }); break;
    case 'exercise-favorite':
    case 'exercise-exclude':
      try {
        state.exercises = exerciseStore.togglePreference(value, action === 'exercise-favorite' ? 'favorite' : 'excluded');
        render({ focus });
      } catch {
        showDialog('error', 'Exercise preference', '<p class="dialog-description">The preference could not be saved in this browser.</p>', focus);
      }
      break;
    case 'exercise-add': showExerciseEditor(null, false, focus); break;
    case 'exercise-edit': showExerciseEditor(libraryExercise(value), true, focus); break;
    case 'exercise-variation': showExerciseEditor(libraryExercise(value), false, focus); break;
    case 'sample-mode':
      state.sampleMode = !state.sampleMode;
      state.date = today();
      state.calendarAnchor = null;
      state.routine = null;
      state.builder = null;
      state.history = 'progress';
      render({ scroll: true, focus });
      break;
    case 'routine': state.routine = value || null; render({ scroll: true, focus: '#main' }); break;
    case 'history': state.history = value; render({ focus }); break;
    case 'weight': showWeight(focus, value || state.date); break;
    case 'weight-history': {
      const date = main.querySelector('#history-weight-date');
      if (date.value && date.reportValidity()) showWeight(focus, date.value);
      break;
    }
    case 'weight-target': showDialog('weight-target', 'Bodyweight target', renderWeightTarget(state.user.targetKgPerWeek, state.unit), focus); break;
    case 'log':
      try {
        if (!activePreview()) {
          savePreview({ ...state.preview, active: { routineID: value } });
          render();
        }
        showSession(focus);
      } catch {
        showDialog('error', 'Sample preview', '<p class="dialog-description">The sample workout could not be saved in this browser.</p>', focus);
      }
      break;
    case 'active': showSession(focus); break;
    case 'close': dialog.close(); break;
    case 'choose-routine': dialogTrigger = null; dialog.close(); selectTab('routines', true); break;
    case 'end':
      try {
        savePreview({ ...state.preview, active: null });
        dialog.close();
        render();
        announce('Workout preview ended.');
      } catch {
        showDialog('error', 'Sample preview', '<p class="dialog-description">The sample workout could not be ended in this browser.</p>', dialogTrigger);
      }
      break;
  }
});

dialog.addEventListener('close', () => {
  portability.closed();
  const trigger = dialogTrigger;
  const wasWorkout = dialogAction === 'personal-workout';
  dialogAction = null;
  dialogTrigger = null;
  exerciseDraft = null;
  historyEdit = null;
  historyComparison = null;
  photoContext = null;
  photoComparison = null;
  progressionReview = null;
  energyContext = null;
  cancelPhotoPreviews(dialog);
  if (wasWorkout && activePersonal() && state.tab === 'today') render();
  if (trigger) document.querySelector(trigger)?.focus({ preventScroll: true });
});
dialog.addEventListener('change', event => {
  if (dialogAction === 'portability') { void portability.change(event); return; }
  const field = event.target;
  if (dialogAction === 'progression-detail' && field.form?.id === 'progression-form') {
    updateProgressionFields(field.form);
    return;
  }
  if (dialogAction === 'photos-compare') {
    const side = field.dataset.photoDate;
    const selection = field.dataset.photoChoice;
    if (side && isDay(field.value)) { photoComparison[side] = field.value; photoComparison[side + 'ID'] = null; }
    else if (selection) photoComparison[selection + 'ID'] = field.value;
    else return;
    showPhotoComparison(dialogTrigger);
    dialog.querySelector(side ? `[data-photo-date="${side}"]` : `[data-photo-choice="${selection}"]`)?.focus();
    return;
  }
  if (dialogAction === 'history-edit') {
    if (field.dataset.historyDraft === 'versionID') {
      const base = historyDraft(null, personalVersion(field.value), historyEdit.day, state.unit);
      historyEdit = { ...historyEdit, versionID: field.value, exercises: base.exercises };
      openHistoryEditor(dialogTrigger);
    } else if (field.dataset.historySetField === 'status' || field.dataset.historyInput === 'separateSides') {
      historyEditInput(field);
      const id = field.closest('[data-history-set]').dataset.historySet;
      openHistoryEditor(dialogTrigger);
      const row = [...dialog.querySelectorAll('[data-history-set]')].find(item => item.dataset.historySet === id);
      row?.querySelector(field.dataset.historySetField ? '[data-history-set-field]' : '[data-history-input="separateSides"]')?.focus({ preventScroll: true });
    } else if (field.id === 'history-exercise-choice') {
      const selected = libraryExercise(field.value);
      if (selected) dialog.querySelector('#history-measurement').value = selected.equipment ? 'weight' : 'bodyweight';
    }
    return;
  }
  if (dialogAction === 'history-compare') {
    if (field.id === 'history-other') { historyComparison.other = field.value; historyComparison.scope = ''; }
    if (field.id === 'history-scope') historyComparison.scope = field.value;
    openHistoryComparison(dialogTrigger);
    dialog.querySelector('#' + field.id)?.focus();
    return;
  }
  if (dialogAction === 'schedule-program' && field.id === 'schedule-block-week') {
    openProgram(field.closest('.schedule-program').dataset.blockId, Number(field.value), dialogTrigger);
    dialog.querySelector('#schedule-block-week').focus();
    return;
  }
  if (dialogAction === 'personal-workout' && field.hasAttribute('data-log-rest-edit')) {
    try { applyLoggerChange({ action: 'editRest', setID: field.closest('[data-log-set]').dataset.logSet, value: field.value }); }
    catch (error) { planError(error); }
    return;
  }
  if (dialogAction === 'personal-workout' && field.id === 'log-exercise-choice') {
    const chosen = libraryExercise(field.value);
    if (chosen) dialog.querySelector('#log-measurement').value = chosen.equipment ? 'weight' : 'bodyweight';
    return;
  }
  if (dialogAction !== 'exercise' || !field.checked || !['primary', 'secondary'].includes(field.name)) return;
  const other = field.name === 'primary' ? 'secondary' : 'primary';
  for (const input of field.form.elements) {
    if (input.name === other && input.value === field.value) input.checked = false;
  }
});

dialog.addEventListener('input', event => {
  if (dialogAction === 'history-edit' && historyEdit) {
    historyEditInput(event.target);
    return;
  }
  if (dialogAction !== 'personal-workout') return;
  const target = event.target;
  if (target.id === 'log-exercise-search') {
    dialog.querySelector('#log-exercise-choice').innerHTML = exerciseOptions(catalog, state.exercises, target.value);
    return;
  }
  const field = target.dataset.logField;
  if (!field) return;
  const exerciseID = target.closest('[data-log-exercise]')?.dataset.logExercise;
  const row = target.closest('[data-log-set]');
  const action = row ? 'editSet' : field;
  try {
    applyLoggerChange({ action, exerciseID, setID: row?.dataset.logSet, field,
      value: target.type === 'checkbox' ? target.checked : target.value }, { refresh: false });
    if (row) {
      row.classList.replace('planned', 'edited');
      row.querySelector('.log-badge').textContent = 'Edited';
      paintWorkoutRow(row, activePersonal());
    }
    dialog.querySelector('#plan-session-error').textContent = '';
  } catch (error) { planError(error); }
});
main.addEventListener('submit', event => {
  if (event.target.id !== 'score-weights') return;
  event.preventDefault();
  const output = event.target.querySelector('#score-weights-error');
  try {
    const values = new FormData(event.target);
    const weights = Object.fromEntries(Object.keys(defaultScoreWeights).map(key => [key, Number(values.get(key))]));
    state.planRecords = routineStore.saveScoreWeights(weights);
    output.textContent = 'Score weights saved.';
  } catch (error) { output.textContent = error.message; }
});
dialog.addEventListener('submit', event => {
  if (dialogAction === 'portability') { void portability.submit(event); return; }
  if (dialogAction === 'energy' && event.target.id === 'energy-form') {
    event.preventDefault();
    const values = new FormData(event.target);
    saveEnergyInput({ activity: values.get('activity'), minutes: Number(values.get('minutes').trim().replace(',', '.')) });
    return;
  }
  if (dialogAction === 'progression-detail' && event.target.id === 'progression-form' && progressionReview) {
    event.preventDefault();
    const { routineID, version, row } = progressionReview;
    try {
      const rule = readProgressionRule(event.target, state.unit, progressionRule(state.planRecords, row));
      state.planRecords = routineStore.saveProgressionRule(routineID, version.id, row.id, rule);
      showProgressionReview(routineID, row.id, dialogTrigger, true, version.id);
      dialog.querySelector('#progression-form button')?.focus();
      announce('Progression rule saved.');
    } catch (error) { dialog.querySelector('#progression-rule-error').textContent = error.message; }
    return;
  }
  if (dialogAction === 'weight-target') {
    event.preventDefault();
    const input = dialog.querySelector('#weight-target-input');
    if (!input.reportValidity()) return;
    try {
      const unchanged = input.value === event.target.dataset.original;
      const value = unchanged ? state.user.targetKgPerWeek : input.value ? input.valueAsNumber * kilogramsPerUnit() : null;
      state.user = store.saveWeightTarget(value);
      dialog.close();
      render();
      announce('Target rate saved.');
    } catch (error) { dialog.querySelector('#weight-target-error').textContent = error.message; }
    return;
  }
  if (dialogAction === 'exercise' && exerciseDraft) {
    event.preventDefault();
    const { draft, editing } = exerciseDraft;
    try {
      const exercise = readExerciseForm(event.target, draft, editing);
      state.exercises = exerciseStore.saveExercise(exercise, editing);
      state.exerciseDetail = exercise.id;
      state.substituteFor = null;
      dialogTrigger = null;
      dialog.close();
      render({ scroll: true, focus: '#main' });
      announce('Exercise saved.');
    } catch (error) {
      dialog.querySelector('.entry-error').textContent = error.message || 'The exercise could not be saved.';
    }
    return;
  }
  if (dialogAction !== 'weight') return;
  event.preventDefault();
  const input = dialog.querySelector('#weight-input');
  if (!input.reportValidity()) return;
  const value = input.valueAsNumber;
  if (!Number.isFinite(value) || value <= 0) return;
  const date = event.target.dataset.day;
  const existing = state.sampleMode ? state.preview.weights[date] : state.user.entries[date]?.kilograms;
  const kilograms = existing && Math.round(existing / kilogramsPerUnit() * 10) / 10 === value
    ? existing : value * kilogramsPerUnit();
  try {
    if (state.sampleMode) {
      savePreview({ ...state.preview, weights: { ...state.preview.weights, [date]: kilograms } });
    } else {
      state.user = store.saveWeight(date, kilograms);
    }
    dialog.close();
    render();
    announce('Bodyweight saved.');
  } catch {
    dialog.querySelector('#weight-error').textContent = 'Your entry could not be saved in this browser.';
  }
});

document.addEventListener('visibilitychange', () => {
  if (document.visibilityState !== 'visible') return;
  paintPhotoPreviews(main, state.photoLinks);
  if (dialog.open) paintPhotoPreviews(dialog, state.photoLinks);
});
