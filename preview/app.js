import { createBrowserStore, kilogramsPerPound, localDayKey } from './storage.js';
import { createExerciseStore, escapeHTML, exerciseEditor, readExerciseForm, renderExerciseDetail, renderLibrary,
  renderSearchResults, renderSubstitutions, renderSubstitutionResults } from './exercises.js';
import { muscleInvolvement, renderMuscleMap } from './muscle-map.js';

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
const storage = {
  getItem: key => localStorage.getItem(key),
  setItem: (key, value) => localStorage.setItem(key, value),
};
const store = createBrowserStore(storage);
const exerciseStore = createExerciseStore(storage);
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
  libraryOpen: false, exerciseDetail: null, substituteFor: null, availableEquipment: new Set(),
  exerciseQuery: newExerciseQuery(), exercises: readStorage(exerciseStore.load, { custom: [], preferences: {} }),
  muscleRegion: '',
};

async function bundled(name) {
  try {
    const response = await fetch(asset(name));
    return response.ok ? await response.json() : null;
  } catch { return null; }
}

const [sample, catalogResource, anatomy] = await Promise.all([
  bundled('SampleData.json'), bundled('ExerciseCatalog.json'), bundled('MuscleRegions.json'),
]);
const catalog = Array.isArray(catalogResource) ? catalogResource : [];
const libraryItems = () => [...catalog, ...state.exercises.custom];
const libraryExercise = id => libraryItems().find(exercise => exercise.id === id);

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
  const monday = day(today());
  monday.setUTCDate(monday.getUTCDate() - ((monday.getUTCDay() + 6) % 7));
  const week = state.sampleMode ? sample.week : Array.from({ length: 7 }, (_, index) => {
    const date = new Date(monday);
    date.setUTCDate(date.getUTCDate() + index);
    return { date: date.toISOString().slice(0, 10) };
  });
  return `<section class="surface week" aria-labelledby="week-title"><div class="section-top"><h2 id="week-title">This week</h2><span class="meta">${icon('calendar', 15)} ${shortDate(week[0].date)} – ${shortDate(week.at(-1).date)}</span></div><div class="days">${week.map(({ date, routineID }) => {
    const routine = routineFor(routineID);
    const selected = date === state.date;
    const isToday = date === today();
    const description = routine?.name ?? (state.sampleMode ? 'rest day' : 'no workout scheduled');
    return `<button class="day${selected ? ' selected' : ''}" type="button" data-action="date" data-value="${date}" aria-pressed="${selected}" ${isToday ? 'aria-current="date"' : ''} aria-label="${longDate(date)}, ${description}"><span class="day-name">${dateLabel(date, { weekday: 'short' })}</span><span class="day-number">${day(date).getUTCDate()}</span><span class="day-dot${routine ? ' scheduled' : ''}"></span></button>`;
  }).join('')}</div></section>`;
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
          <span class="prediction"><span class="stat-label">${icon('spark', 15)} Future prediction</span><strong>Coming later</strong></span>
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
  const side = routine ? muscleMap(routine) + bodyweight() : bodyweight() + muscleMap(null);
  return `${sectionTitle('Today', longDate(today()))}${weekView()}<div class="dashboard"><div class="dashboard-hero">${workoutHero(routine)}</div><div class="dashboard-side">${side}</div>${routine ? `<div class="dashboard-exercises">${exercises(routine)}</div>` : ''}</div>`;
}

function emptyCard(title, copy, symbol) {
  return `<section class="surface settings-card"><div class="section-label"><span class="tile-icon small">${icon(symbol, 19)}</span><h2>${title}</h2></div><p class="chart-subtitle">${copy}</p></section>`;
}

function routinesPage() {
  if (state.libraryOpen) return exerciseLibraryPage();
  const entry = `<button type="button" class="surface routine-card library-entry" data-action="exercise-library">
    <span class="tile-icon">${icon('dumbbell', 22)}</span><strong>Exercise Library</strong><span class="round-arrow">${icon('chevron', 17)}</span></button>`;
  if (!state.sampleMode) return `${sectionTitle('Routines', 'Your training library')}${entry}${emptyCard('No saved routines', 'Your routines will appear here.', 'routines')}`;
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
    if (!progress) return heading + picker + emptyCard('No completed workouts', 'Finished workouts will appear here.', 'clock');
    const bodyweight = Object.values(state.user.entries).sort((a, b) => b.day.localeCompare(a.day));
    const entries = bodyweight.length ? `
      <section class="surface settings-card" aria-labelledby="bodyweight-history">
        <div class="section-label"><span class="tile-icon small">${icon('scale', 18)}</span><h2 id="bodyweight-history">Bodyweight history</h2></div>
        <ul class="active-exercises">${bodyweight.map(entry => `
          <li><time datetime="${entry.day}">${dateLabel(entry.day, { year: 'numeric', month: 'short', day: 'numeric' })}</time>
          <strong>${displayWeight(entry.kilograms)} ${state.unit}</strong></li>`).join('')}</ul>
      </section>` : '';
    return heading + picker + `<div class="stack session-list">${emptyCard('Recorded sets', 'Results from completed workouts will appear here.', 'history')}${entries}</div>`;
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
        <div class="section-label"><span class="tile-icon small">${icon('info', 19)}</span><h2>Local data</h2></div>
        <p>Bodyweight entries and preferences are saved in this browser. Sample data has its own preview and storage.</p>
      </section>
    </div>`;
}

function renderDock() {
  const routine = activePreview();
  dock.innerHTML = `<div class="dock-inner"><button type="button" class="active-bar" data-action="active"><span class="active-icon">${icon('dumbbell', 20)}</span><span class="active-text"><strong>${routine?.name ?? 'Workout log'}</strong><span>${routine ? '<span class="live-dot"></span>Active preview' : 'No active workout'}</span></span><span class="active-arrow">${icon('chevron', 18)}</span></button><nav class="tab-bar" aria-label="Main navigation">${tabs.map(([id, title, label]) => `<a href="#${id}" ${state.tab === id ? 'aria-current="page"' : ''} aria-label="${label}">${icon(id, 21)}<span>${title}</span></a>`).join('')}</nav></div>`;
}

function render({ scroll = false, focus = null } = {}) {
  applyAppearance();
  renderHeader();
  const pages = { today: todayPage, routines: routinesPage, history: historyPage, settings: settingsPage };
  main.innerHTML = pages[state.tab]();
  renderDock();
  if (scroll) window.scrollTo(0, 0);
  if (focus) document.querySelector(focus)?.focus({ preventScroll: true });
}

let dialogAction = null;
let dialogTrigger = null;
let exerciseDraft = null;

function showDialog(type, title, body, trigger) {
  dialogAction = type;
  dialogTrigger = trigger;
  dialog.innerHTML = `<div class="dialog-header"><h2 id="dialog-title">${title}</h2><button type="button" class="icon-button" data-action="close" aria-label="Close">${icon('close', 20)}</button></div>${body}`;
  if (!dialog.open) dialog.showModal();
  dialog.querySelector('[autofocus]')?.focus();
}

function showWeight(trigger) {
  const value = bodyweightValue();
  const entered = value ? Math.round(value / kilogramsPerUnit() * 10) / 10 : '';
  showDialog('weight', 'Log bodyweight', `<p class="dialog-description">${state.sampleMode ? 'Sample entry · ' : ''}${longDate(state.date)}</p><form id="weight-form"><label for="weight-input">Bodyweight (${state.unit})</label><input id="weight-input" type="number" inputmode="decimal" name="weight" required min="0.1" step="0.1" value="${entered}" autofocus><div id="weight-error" role="alert"></div><button class="primary" type="submit">${icon('check', 19)} Save entry</button></form>`, trigger);
}

function showExerciseEditor(source, editing, trigger) {
  const draft = editing ? source : { ...source, id: crypto.randomUUID(), name: source ? `${source.name} variation` : '' };
  exerciseDraft = { draft, editing };
  showDialog('exercise', editing ? 'Edit exercise' : 'New custom exercise', exerciseEditor(draft, editing), trigger);
}

function showSession(trigger) {
  const routine = activePreview();
  if (!routine) {
    const hint = state.sampleMode ? 'Choose a sample routine to start a workout preview.' : 'Open a saved routine in the iPhone app to start a workout.';
    showDialog('idle', 'Workout log', `<p class="dialog-description">${hint}</p><button class="primary" type="button" data-action="choose-routine">Browse routines</button>`, trigger);
    return;
  }
  showDialog('active', routine.name, `<p class="dialog-description">Active workout preview · Sample routine</p><ul class="active-exercises">${routine.exercises.map(exercise => `<li><strong>${exercise.name}</strong><span>${exercise.sets} × ${exercise.reps} reps</span></li>`).join('')}</ul><p class="dialog-description">Set logging and session history will be available in a later stage.</p><button class="secondary end-button" type="button" data-action="end">End workout preview</button>`, trigger);
}

function selectTab(tab, focus = false) {
  if (!tabs.some(([id]) => id === tab)) return;
  state.tab = tab;
  state.routine = null;
  state.libraryOpen = false;
  state.exerciseDetail = null;
  state.substituteFor = null;
  if (location.hash !== `#${tab}`) history.pushState(null, '', `#${tab}`);
  render({ scroll: true, focus: focus ? '#main' : null });
}

render();

systemDark.addEventListener('change', () => { applyAppearance(); renderHeader(); });
window.addEventListener('hashchange', () => selectTab(location.hash.slice(1) || 'today'));
main.addEventListener('toggle', event => {
  if (!event.target.matches('details[data-exercise]')) return;
  const { open, dataset: { exercise } } = event.target;
  if (open) state.expanded.add(exercise);
  else state.expanded.delete(exercise);
}, true);

main.addEventListener('input', event => {
  if (event.target.id !== 'exercise-search') return;
  state.exerciseQuery.name = event.target.value;
  document.querySelector('#exercise-results').innerHTML = renderSearchResults(catalog, state.exercises, state.exerciseQuery);
});

main.addEventListener('change', event => {
  const target = event.target;
  if (target.id === 'muscle-region-picker') {
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
  switch (action) {
    case 'theme': state.appearance = theme() === 'dark' ? 'light' : 'dark'; savePreferences(); render({ focus }); break;
    case 'appearance': state.appearance = value; savePreferences(); render({ focus }); break;
    case 'transparency': state.opaque = !state.opaque; savePreferences(); render({ focus }); break;
    case 'unit': state.unit = value; savePreferences(); render({ focus }); break;
    case 'date': state.date = value; render({ focus }); break;
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
      state.routine = null;
      state.history = 'progress';
      render({ scroll: true, focus });
      break;
    case 'routine': state.routine = value || null; render({ scroll: true, focus: '#main' }); break;
    case 'history': state.history = value; render({ focus }); break;
    case 'weight': showWeight(focus); break;
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
  const trigger = dialogTrigger;
  dialogAction = null;
  dialogTrigger = null;
  exerciseDraft = null;
  if (trigger) document.querySelector(trigger)?.focus({ preventScroll: true });
});
dialog.addEventListener('change', event => {
  const field = event.target;
  if (dialogAction !== 'exercise' || !field.checked || !['primary', 'secondary'].includes(field.name)) return;
  const other = field.name === 'primary' ? 'secondary' : 'primary';
  for (const input of field.form.elements) {
    if (input.name === other && input.value === field.value) input.checked = false;
  }
});
dialog.addEventListener('submit', event => {
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
  const existing = bodyweightValue();
  const kilograms = existing && Math.round(existing / kilogramsPerUnit() * 10) / 10 === value
    ? existing : value * kilogramsPerUnit();
  try {
    if (state.sampleMode) {
      savePreview({ ...state.preview, weights: { ...state.preview.weights, [state.date]: kilograms } });
    } else {
      state.user = store.saveWeight(state.date, kilograms);
    }
    dialog.close();
    render();
    announce('Bodyweight saved.');
  } catch {
    dialog.querySelector('#weight-error').textContent = 'Your entry could not be saved in this browser.';
  }
});
