export const equipmentNames = Object.freeze({ bodyweight: 'Bodyweight', barbell: 'Barbell', dumbbell: 'Dumbbell',
  cable: 'Cable', machine: 'Machine', kettlebell: 'Kettlebell', band: 'Band', other: 'Other' });
export const patternNames = Object.freeze({ horizontalPush: 'Horizontal push', verticalPush: 'Vertical push',
  horizontalPull: 'Horizontal pull', verticalPull: 'Vertical pull', squat: 'Squat', hinge: 'Hinge',
  elbowFlexion: 'Elbow flexion', elbowExtension: 'Elbow extension', kneeFlexion: 'Knee flexion',
  ankleExtension: 'Ankle extension', carry: 'Carry', core: 'Core', other: 'Other' });
export const muscleNames = Object.freeze({ chest: 'Chest', shoulders: 'Shoulders', biceps: 'Biceps', triceps: 'Triceps',
  forearms: 'Forearms', core: 'Abdominals', traps: 'Upper back', lats: 'Lats', lowerBack: 'Lower back', glutes: 'Glutes',
  quads: 'Quadriceps', hamstrings: 'Hamstrings', calves: 'Calves', shins: 'Shins', adductors: 'Inner thighs' });
const machineFields = { seat: 'Seat position', attachment: 'Attachment', incline: 'Incline', handle: 'Handle' };
const key = 'setline-exercise-library-v1';

export const escapeHTML = value => String(value ?? '').replace(/[&<>"']/g, char => ({
  '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
})[char]);
const labelEquipment = exercise => equipmentNames[exercise.equipment ?? 'bodyweight'];
const listed = (exercise, selected) => [...(exercise.primary ?? []), ...(exercise.secondary ?? [])].includes(selected);
const folded = text => text.normalize('NFD').replace(/\p{M}/gu, '').toLowerCase();

export function createExerciseStore(storage) {
  function load() {
    const json = storage.getItem(key);
    if (json === null) return { custom: [], preferences: {} };
    const saved = JSON.parse(json);
    if (!Array.isArray(saved?.custom) || !saved.preferences || typeof saved.preferences !== 'object') {
      throw new Error('Exercise library storage could not be read.');
    }
    return saved;
  }
  function commit(state) {
    storage.setItem(key, JSON.stringify(state));
    return state;
  }
  return {
    load,
    saveExercise(exercise, editing) {
      const state = load();
      const index = state.custom.findIndex(entry => entry.id === exercise.id);
      if (editing && index === -1) throw new Error('This custom exercise could not be found.');
      if (!exercise.name.trim()) throw new Error('Enter an exercise name.');
      if (index >= 0) {
        const previous = state.custom[index];
        if (previous.equipment !== exercise.equipment || previous.variation !== exercise.variation) {
          throw new Error('Create a variation to change the equipment or variation name.');
        }
        state.custom[index] = { ...exercise, createdAt: previous.createdAt, updatedAt: new Date().toISOString() };
      } else {
        state.custom.push({ ...exercise, createdAt: new Date().toISOString() });
      }
      return commit(state);
    },
    togglePreference(id, field) {
      const state = load();
      const previous = state.preferences[id] ?? {};
      state.preferences[id] = { ...previous, [field]: previous[field] !== true };
      return commit(state);
    },
  };
}

export function filterExercises(catalog, stored, query) {
  const keyword = folded(query.name.trim());
  const customIDs = new Set(stored.custom.map(exercise => exercise.id));
  return [...catalog, ...stored.custom].filter(exercise => {
    const preference = stored.preferences[exercise.id] ?? {};
    return (query.collection === 'excluded' ? preference.excluded === true : preference.excluded !== true)
      && (query.collection !== 'favorites' || preference.favorite)
      && (query.collection !== 'custom' || customIDs.has(exercise.id))
      && (!keyword || folded(exercise.name).includes(keyword))
      && (!query.muscle || listed(exercise, query.muscle))
      && (!query.equipment || (exercise.equipment ?? 'bodyweight') === query.equipment)
      && (!query.pattern || exercise.pattern === query.pattern);
  }).sort((a, b) => a.name.localeCompare(b.name));
}

export function substitutions(source, exercises, available, preferences) {
  const targets = [...source.primary, ...source.secondary];
  return exercises.filter(exercise => exercise.id !== source.id && preferences[exercise.id]?.excluded !== true
    && available.has(exercise.equipment ?? 'bodyweight') && targets.some(muscle => listed(exercise, muscle)))
    .sort((a, b) => {
      const overlap = exercise => exercise.primary.filter(group => source.primary.includes(group)).length;
      return overlap(b) - overlap(a) || a.name.localeCompare(b.name);
    });
}

function options(entries, value, placeholder) {
  const values = placeholder ? { '': placeholder, ...entries } : entries;
  return Object.entries(values).map(([id, label]) => `<option value="${id}" ${id === value ? 'selected' : ''}>${escapeHTML(label)}</option>`).join('');
}

function exerciseRows(results, preferences, source) {
  return results.map(exercise => {
    const preference = preferences[exercise.id] ?? {};
    const metadata = [labelEquipment(exercise), patternNames[exercise.pattern], exercise.variation].filter(Boolean).join(' · ');
    const overlap = source ? Object.keys(muscleNames).filter(group => listed(source, group) && listed(exercise, group)) : [];
    return `<button type="button" class="surface routine-card library-row" data-action="exercise-detail" data-value="${escapeHTML(exercise.id)}">
      <span class="routine-description"><strong>${escapeHTML(exercise.name)}</strong><span>${escapeHTML(metadata)}</span>
      ${overlap.length ? `<span>${overlap.map(group => muscleNames[group]).join(' · ')}</span>` : ''}</span>
      <span class="library-flags">${preference.favorite ? '<span aria-label="Favorite">★</span>' : ''}${preference.excluded ? '<span>Excluded</span>' : ''}<span aria-hidden="true">›</span></span>
    </button>`;
  }).join('');
}

export function renderSearchResults(catalog, stored, query) {
  const results = filterExercises(catalog, stored, query);
  if (results.length) return exerciseRows(results, stored.preferences);
  const searching = query.name.trim() || query.muscle || query.equipment || query.pattern;
  const emptyTitle = catalog.length + stored.custom.length === 0 ? 'Your exercise library is empty'
    : searching ? 'No matching exercises'
      : ({ custom: 'No custom exercises yet', favorites: 'No favorites yet', excluded: 'No excluded exercises' }[query.collection] ?? 'No matching exercises');
  const action = !searching && (query.collection === 'custom' || catalog.length + stored.custom.length === 0)
    ? '<button type="button" class="secondary" data-action="exercise-add">Add custom exercise</button>' : '';
  return `<div class="surface settings-card library-empty"><h2>${emptyTitle}</h2>
    ${searching ? '<p>Try a different name or change your filters.</p>' : ''}${action}</div>`;
}

export function renderLibrary(catalog, stored, query) {
  return `<div class="page-heading library-heading"><div><p class="eyebrow">Training library</p><h1>Exercise Library</h1></div>
    <button type="button" class="primary" data-action="exercise-add">Add custom exercise</button></div>
    <div class="surface settings-card library-filters">
      <label class="library-search">Search by name<input id="exercise-search" type="search" value="${escapeHTML(query.name)}" autocomplete="off" placeholder="e.g. Bench press"></label>
      <label>Collection<select aria-label="Collection" data-exercise-filter="collection">${options({ all: 'All', favorites: 'Favorites', custom: 'Custom', excluded: 'Excluded' }, query.collection)}</select></label>
      <label>Muscle group<select aria-label="Muscle group" data-exercise-filter="muscle">${options(muscleNames, query.muscle, 'All muscles')}</select></label>
      <label>Equipment<select aria-label="Equipment" data-exercise-filter="equipment">${options(equipmentNames, query.equipment, 'All equipment')}</select></label>
      <label>Movement pattern<select aria-label="Movement pattern" data-exercise-filter="pattern">${options(patternNames, query.pattern, 'All patterns')}</select></label>
    </div>
    <section class="stack library-results" id="exercise-results" aria-label="Exercise results">${renderSearchResults(catalog, stored, query)}</section>`;
}

export function renderExerciseDetail(exercise, stored) {
  const preference = stored.preferences[exercise.id] ?? {};
  const custom = stored.custom.some(record => record.id === exercise.id);
  const muscles = groups => groups?.map(group => muscleNames[group]).filter(Boolean).join(', ') || 'None listed';
  const machine = Object.entries(machineFields).filter(([field]) => exercise.machineSetup?.[field]);
  const id = escapeHTML(exercise.id);
  const card = (title, content) => `<section class="surface settings-card library-info"><h2>${title}</h2>${content}</section>`;
  const definition = (title, value) => `<div><dt>${title}</dt><dd>${escapeHTML(value)}</dd></div>`;
  const media = exercise.demonstration;
  const supportedMedia = { image: /\.(png|jpe?g|webp)$/i, video: /\.(mp4|mov)$/i };
  const usable = /^[a-zA-Z0-9_-]+\.[a-zA-Z0-9]+$/.test(media?.resource ?? '')
    && Object.hasOwn(supportedMedia, media.kind) && supportedMedia[media.kind].test(media.resource);
  const demonstration = usable ? (media.kind === 'image'
    ? `<img class="exercise-media" src="/shared/${media.resource}" alt="Exercise demonstration image" data-demonstration>`
    : `<video class="exercise-media" src="/shared/${media.resource}" controls playsinline data-demonstration aria-label="Exercise demonstration video"></video>`)
    : '<p class="media-placeholder">No demonstration media available</p>';
  return `<div class="page-heading"><p class="eyebrow">${escapeHTML([labelEquipment(exercise), patternNames[exercise.pattern], exercise.variation].filter(Boolean).join(' · '))}</p>
    <h1>${escapeHTML(exercise.name)}</h1></div>
    <div class="library-actions">
      <button type="button" class="secondary" data-action="exercise-favorite" data-value="${id}" aria-pressed="${preference.favorite === true}">★ Favorite</button>
      <button type="button" class="secondary" data-action="exercise-exclude" data-value="${id}" aria-pressed="${preference.excluded === true}">Exclude from browsing</button>
      ${custom ? `<button type="button" class="secondary" data-action="exercise-edit" data-value="${id}">Edit custom exercise</button>` : ''}
      <button type="button" class="secondary" data-action="exercise-variation" data-value="${id}">Create a variation</button>
      <button type="button" class="primary" data-action="exercise-substitute" data-value="${id}">Browse substitutions</button>
    </div>
    <div class="settings-grid library-details">
      ${card('Setup and technique', `<dl>${definition('Setup', exercise.setup || 'No setup instructions yet')}${definition('Technique cues', exercise.cues || 'No technique cues yet')}</dl>`)}
      ${card('Muscles', `<dl>${definition('Primary', muscles(exercise.primary))}${definition('Secondary', muscles(exercise.secondary))}</dl>`)}
      ${machine.length ? card('Equipment setup', `<dl>${machine.map(([field, label]) => definition(label, exercise.machineSetup[field])).join('')}</dl>`) : ''}
      ${card('Demonstration', demonstration)}
    </div>`;
}

export function renderSubstitutionResults(source, exercises, available, preferences) {
  const matches = substitutions(source, exercises, available, preferences);
  return matches.length ? exerciseRows(matches, preferences, source)
    : `<div class="surface settings-card library-empty"><h2>${available.size ? 'No matching substitutions' : 'Select available equipment'}</h2>
      <p>${available.size ? 'Try another equipment option.' : 'Choose what you have available to browse exercises with shared muscles.'}</p></div>`;
}

export function renderSubstitutions(source, exercises, available, preferences) {
  const equipment = Object.entries(equipmentNames).map(([id, label]) => `<label><input type="checkbox" data-available-equipment value="${id}" ${available.has(id) ? 'checked' : ''}>${label}</label>`).join('');
  return `<div class="page-heading"><p class="eyebrow">${escapeHTML(source.name)}</p><h1>Substitutions</h1></div>
    <fieldset class="surface settings-card library-fieldset"><legend>Available equipment</legend><div class="library-options">${equipment}</div></fieldset>
    <section class="stack library-results" id="substitution-results" aria-label="Substitution results">${renderSubstitutionResults(source, exercises, available, preferences)}</section>`;
}

export function exerciseEditor(exercise = {}, editing = false) {
  const field = (name, label, value, extra = '') => `<label>${label}<input name="${name}" value="${escapeHTML(value)}" ${extra}></label>`;
  const checkboxes = (name, selected) => Object.entries(muscleNames).map(([id, label]) =>
    `<label><input type="checkbox" name="${name}" value="${id}" ${selected?.includes(id) ? 'checked' : ''}>${label}</label>`).join('');
  const locked = editing ? 'disabled' : '';
  return `<form id="exercise-form" class="exercise-form">
    ${field('name', 'Name', exercise.name, 'required autofocus maxlength="100"')}
    <div class="exercise-form-grid">
      <label>Equipment<select aria-label="Equipment" name="equipment" ${locked}>${options(equipmentNames, exercise.equipment ?? 'bodyweight')}</select></label>
      <label>Movement pattern<select aria-label="Movement pattern" name="pattern">${options(patternNames, exercise.pattern ?? 'other')}</select></label>
    </div>
    ${field('variation', 'Variation or machine name', exercise.variation, `${locked} maxlength="120"`)}
    <label>Setup instructions<textarea aria-label="Setup instructions" name="setup" rows="3">${escapeHTML(exercise.setup)}</textarea></label>
    <label>Technique cues<textarea aria-label="Technique cues" name="cues" rows="3">${escapeHTML(exercise.cues)}</textarea></label>
    <fieldset class="library-fieldset"><legend>Primary muscles</legend><div class="library-options">${checkboxes('primary', exercise.primary)}</div></fieldset>
    <fieldset class="library-fieldset"><legend>Secondary muscles</legend><div class="library-options">${checkboxes('secondary', exercise.secondary)}</div></fieldset>
    <fieldset class="library-fieldset"><legend>Machine or equipment setup</legend>
      <div class="exercise-form-grid">${Object.entries(machineFields).map(([name, label]) => field(name, label, exercise.machineSetup?.[name])).join('')}</div>
    </fieldset>
    <p class="entry-error" role="alert"></p><button class="primary" type="submit">Save exercise</button>
  </form>`;
}

export function readExerciseForm(form, draft, editing) {
  const values = new FormData(form);
  const text = field => String(values.get(field) ?? '').trim();
  const primary = values.getAll('primary');
  return { id: draft.id, name: text('name'), equipment: editing ? draft.equipment : text('equipment'),
    variation: editing ? draft.variation : text('variation'), pattern: text('pattern'),
    setup: text('setup'), cues: text('cues'), primary, secondary: values.getAll('secondary').filter(group => !primary.includes(group)),
    machineSetup: Object.fromEntries(Object.keys(machineFields).map(name => [name, text(name)])),
    demonstration: draft.demonstration };
}
