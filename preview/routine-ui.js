import { escapeHTML as html, filterExercises } from './exercises.js';
import { hasReps, measurements, newest, sessionPlan } from './routines.js';
import { kilogramsPerPound } from './storage.js';

const button = (label, action, value, style = 'secondary') => `<button type="button" class="${style}" data-action="${action}"${value ? ` data-value="${html(value)}"` : ''}>${html(label)}</button>`;
const opened = (expanded, id) => expanded.has(id) ? 'open' : '';
const choose = (values, current) => Object.entries(values).map(([value, label]) => `<option value="${html(value)}" ${value === current ? 'selected' : ''}>${html(label)}</option>`).join('');
const input = (label, field, value, numeric) => `<label>${html(label)}<input data-plan-field="${field}" value="${html(value)}"${numeric ? ` inputmode="${numeric}"` : ''}></label>`;
const select = (label, field, values, value) => `<label>${html(label)}<select aria-label="${html(label)}" data-plan-field="${field}">${choose(values, value)}</select></label>`;

function setFields(block, row, index, label, unit, expanded, removable) {
  const target = { duration: 'Duration (seconds)', distance: 'Distance (meters)', setting: 'Machine setting' }[row.measurement] ?? `Target load (${unit})`;
  return `<fieldset class="set-block" data-plan-set="${block.id}"><legend>${label} block ${index + 1}</legend>
    <div class="builder-fields">
      ${input('Sets', 'sets', block.sets, 'numeric')}
      ${hasReps(row.measurement) ? `${input('Minimum reps', 'minimum', block.minimum, 'numeric')}${input('Maximum reps', 'maximum', block.maximum, 'numeric')}` : ''}
      ${row.measurement === 'bodyweight' ? '' : input(target, 'target', block.target, row.measurement !== 'setting' && 'decimal')}
      ${input('Rest (seconds)', 'rest', block.rest, 'numeric')}
    </div>
    <details data-builder-expand="${block.id}" ${opened(expanded, block.id)}><summary>Set structure and effort</summary>
      <div class="builder-fields advanced-fields">
        ${select('Set structure', 'structure', { straight: 'Straight', dropSet: 'Drop set', restPause: 'Rest-pause' }, block.structure)}
        ${select('Target effort', 'effort', { none: 'None', rir: 'RIR', rpe: 'RPE', failure: 'To failure' }, block.effort)}
        ${['rir', 'rpe'].includes(block.effort) ? input(block.effort.toUpperCase(), 'effortValue', block.effortValue, 'decimal') : ''}
        ${hasReps(row.measurement) ? `<label class="builder-check"><input type="checkbox" data-plan-field="amrap" ${block.amrap ? 'checked' : ''}>AMRAP</label>` : ''}
      </div>
    </details>
    ${removable ? button('Remove set block', 'plan-remove-set', block.id, 'back-button') : ''}
  </fieldset>`;
}

function exerciseFields(row, index, total, unit, expanded) {
  const warmKey = `warm-${row.id}`;
  const equipmentKey = `equipment-${row.id}`;
  return `<article class="surface builder-row" data-plan-row="${row.id}">
    <div class="builder-reorder">
      <button type="button" class="routine-drag" data-drag-row="${row.id}" aria-label="Drag ${html(row.exercise.name)}">⠿</button>
      <button type="button" class="routine-drag" data-action="plan-up" data-value="${row.id}" aria-label="Move ${html(row.exercise.name)} up" ${index === 0 ? 'disabled' : ''}>↑</button>
      <button type="button" class="routine-drag" data-action="plan-down" data-value="${row.id}" aria-label="Move ${html(row.exercise.name)} down" ${index + 1 === total ? 'disabled' : ''}>↓</button>
    </div>
    <details data-builder-expand="${row.id}" ${opened(expanded, row.id)}>
      <summary><strong>${html(row.exercise.name)}</strong> <span>${row.work.length} working ${row.work.length === 1 ? 'block' : 'blocks'}${row.warm.length ? ` · ${row.warm.length} warm-up` : ''}</span></summary>
      <div class="builder-exercise">
        ${select('Track by', 'measurement', measurements, row.measurement)}
        <details data-builder-expand="${equipmentKey}" ${opened(expanded, equipmentKey)}><summary>Equipment and rep convention</summary>
          <div class="builder-fields advanced-fields">
            ${input('Equipment or machine name', 'equipmentLabel', row.equipmentLabel)}
            ${row.measurement === 'weight' ? select('Load convention', 'basis', { total: 'Total load', perDumbbell: 'Per dumbbell' }, row.basis) : ''}
            ${hasReps(row.measurement) ? select('Rep counting', 'counting', { total: 'Total reps', perSide: 'Per side', separateSides: 'Separate sides' }, row.counting) : ''}
          </div>
        </details>
        ${row.work.map((block, i) => setFields(block, row, i, 'Working', unit, expanded, row.work.length > 1)).join('')}
        ${button('Add working set block', 'plan-add-work', row.id)}
        <details data-builder-expand="${warmKey}" ${opened(expanded, warmKey)}><summary>Warm-up sets</summary>
          ${row.warm.map((block, i) => setFields(block, row, i, 'Warm-up', unit, expanded, true)).join('')}
          ${button('Add warm-up set block', 'plan-add-warm', row.id)}
        </details>
        ${button('Remove exercise', 'plan-remove-row', row.id, 'back-button')}
      </div>
    </details>
  </article>`;
}

function groupFields(group, draft, expanded) {
  return `<details class="builder-group" data-plan-group="${group.id}" data-builder-expand="${group.id}" ${opened(expanded, group.id)}>
    <summary>${group.kind} · ${group.members.length} exercises</summary>
    <div class="builder-fields advanced-fields">
      ${input('Rounds', 'rounds', group.rounds, 'numeric')}
      ${input('Rest between exercises (seconds)', 'restExercises', group.restExercises, 'numeric')}
      ${input('Rest between rounds (seconds)', 'restRounds', group.restRounds, 'numeric')}
    </div>
    <fieldset class="library-fieldset"><legend>Consecutive exercises</legend><div class="library-options">
      ${draft.exercises.map((row, index) => `<label><input type="checkbox" data-plan-member="${row.id}" ${group.members.includes(row.id) ? 'checked' : ''}
        ${draft.groups.some(other => other.id !== group.id && other.members.includes(row.id)) ? 'disabled' : ''}>${index + 1}. ${html(row.exercise.name)}</label>`).join('')}
    </div></fieldset>
    ${button('Remove group', 'plan-remove-group', group.id, 'back-button')}
  </details>`;
}

export function exerciseOptions(catalog, stored, name) {
  const exercises = filterExercises(catalog, stored, { name, muscle: '', equipment: '', pattern: '', collection: 'all' });
  return `<option value="">${exercises.length ? 'Choose exercise' : 'No matching exercises'}</option>` + exercises.map(exercise =>
    `<option value="${html(exercise.id)}">${html([exercise.name, exercise.variation].filter(Boolean).join(' · '))}</option>`).join('');
}

export function renderRoutineBuilder(builder, records, catalog, exercises, unit) {
  const { draft, expanded, sessionID } = builder;
  const categories = Object.fromEntries([['', 'Uncategorized'], ...records.categories.map(category => [category.id, category.name])]);
  const title = sessionID ? 'Edit this workout' : draft.expectedVersionID ? 'Edit routine' : 'New routine';
  return `<div class="page-heading library-heading"><h1>${title}</h1>${button('Cancel', 'plan-cancel')}</div>
    <section class="surface settings-card builder-section" aria-label="Routine information">
      <div class="builder-fields">${input('Routine name', 'name', draft.name)}${sessionID ? '' : select('Category', 'categoryID', categories, draft.categoryID)}</div>
      ${sessionID ? '<p class="builder-hint">Changes apply to this workout only.</p>' : draft.expectedVersionID ? '<p class="builder-hint">Saving creates a routine version for future workouts.</p>' : ''}
    </section>
    <section class="stack builder-section" aria-label="Planned exercises">
      <div class="section-top"><h2>Exercises</h2><span class="meta">${draft.exercises.length} planned</span></div>
      ${draft.exercises.map((row, index) => exerciseFields(row, index, draft.exercises.length, unit, expanded)).join('')}
      <div class="surface settings-card builder-fields plan-picker">
        <label>Search exercises<input type="search" id="routine-exercise-search" value="${html(builder.search)}" autocomplete="off"></label>
        <label>Exercise<select aria-label="Exercise" id="routine-exercise-choice">${exerciseOptions(catalog, exercises, builder.search)}</select></label>
        ${button('Add exercise', 'plan-add-exercise')}
      </div>
    </section>
    <details class="surface settings-card builder-section" data-builder-expand="routine-advanced" ${opened(expanded, 'routine-advanced')}><summary>Advanced routine options</summary>
      ${sessionID ? '' : `<div class="builder-fields advanced-fields"><label>New category<input id="new-routine-category"></label>${button('Create category', 'plan-category')}</div>`}
      ${draft.groups.map(group => groupFields(group, draft, expanded)).join('')}
      <div class="builder-actions">${button('Add superset', 'plan-group', 'Superset')}${button('Add circuit', 'plan-group', 'Circuit')}</div>
    </details>
    <p class="entry-error" role="alert" id="plan-error"></p>
    ${button(sessionID ? 'Save this workout' : 'Save routine', 'plan-save', null, 'primary')}`;
}

export function amount(target, unit) {
  if (!target) return '';
  if (target.kind === 'setting') return `Setting ${target.value}`;
  if (target.kind === 'duration') return `${target.value}s`;
  if (target.kind === 'distance') return `${target.value} m`;
  const value = unit === 'lb' ? target.value / kilogramsPerPound : target.value;
  const suffix = target.kind === 'added' ? ' added' : target.kind === 'assistance' ? ' assistance' : '';
  return `${Number(value.toFixed(2))} ${unit}${suffix}`;
}

export function setSummary(block, row, unit) {
  const range = block.reps && (block.reps.minimum === block.reps.maximum ? block.reps.minimum : `${block.reps.minimum}–${block.reps.maximum}`);
  const counting = { perSide: ' per side', separateSides: ' per side (logged separately)' }[row.counting] ?? '';
  const load = amount(block.target, unit);
  const effort = block.effort ? (block.effort.kind === 'failure' ? 'To failure' : `${block.effort.kind.toUpperCase()} ${block.effort.value}`) : '';
  return [range ? `${block.sets} × ${range} reps${counting}` : `${block.sets} sets`, load && `${load}${row.basis === 'perDumbbell' ? ' per dumbbell' : ''}`,
    block.rest === null ? '' : `${block.rest}s rest`, block.structure === 'dropSet' ? 'Drop set' : block.structure === 'restPause' ? 'Rest-pause' : '',
    block.amrap ? 'AMRAP' : '', effort].filter(Boolean).join(' · ');
}

export function renderPlan(plan, unit) {
  return `<div class="saved-plan">${plan.exercises.map(row => {
    const group = plan.groups.find(group => group.members[0] === row.id);
    const blocks = [...row.warm.map(block => ['Warm-up', block]), ...row.work.map(block => ['Working', block])];
    return `${group ? `<div class="plan-group-label">${html(group.kind)} · ${group.rounds} rounds · ${group.restExercises}s between exercises · ${group.restRounds}s between rounds</div>` : ''}
      <div><strong>${html(row.exercise.name)}</strong>${row.exercise.variation ? `<small>${html(row.exercise.variation)}</small>` : ''}${row.equipmentLabel ? `<small>${html(row.equipmentLabel)}</small>` : ''}
        ${blocks.map(([label, block]) => `<small>${label} · ${html(setSummary(block, row, unit))}</small>`).join('')}</div>`;
  }).join('')}</div>`;
}

export function renderPersonalRoutines(data, categoryID, unit, active, entry) {
  const categories = Object.fromEntries([['', 'All categories'], ...data.categories.map(category => [category.id, category.name])]);
  const plans = data.routines.map(newest).filter(plan => !categoryID || plan.categoryID === categoryID);
  return `<div class="page-heading library-heading"><div><p class="eyebrow">Your training library</p><h1>Routines</h1></div>${button('New routine', 'plan-new', null, 'primary')}</div>
    ${entry}${data.categories.length ? `<label class="builder-category">Filter by category<select aria-label="Filter by category" id="routine-category-filter">${choose(categories, categoryID)}</select></label>` : ''}
    <div class="stack">${plans.map(plan => `<article class="surface settings-card saved-routine">
      <h2>${html(plan.name)}</h2><p class="builder-hint">Version ${plan.revision}${plan.categoryID ? ` · ${html(categories[plan.categoryID])}` : ''}</p>
      ${renderPlan(plan, unit)}
      <div class="builder-actions">${button(active ? 'Resume workout' : 'Log workout', 'plan-start', plan.routineID, 'primary')}
        ${button('Schedule workout', 'plan-schedule', plan.routineID)}${button('Edit routine', 'plan-edit', plan.routineID)}${button('Duplicate routine', 'plan-duplicate', plan.routineID)}${button('Version history', 'plan-versions', plan.routineID)}</div>
    </article>`).join('') || `<section class="surface settings-card"><h2>${categoryID ? 'No routines in this category' : 'No saved routines'}</h2></section>`}</div>`;
}

export function renderVersions(routine, unit) {
  return `<div class="stack">${routine.versions.slice().reverse().map(version => `<details>
    <summary>Version ${version.revision} · ${html(version.name)}</summary>${renderPlan(version, unit)}</details>`).join('')}</div>`;
}

export function renderCompletedSessions(sessions, unit, active, date, renderLogged) {
  return `<div class="stack session-list">${sessions.filter(session => session.completedAt).slice().reverse().map(session => {
    const plan = sessionPlan(session);
    return `<article class="surface settings-card saved-routine"><h2>${html(plan.name)}</h2><p class="builder-hint">${html(date(session))} · ${session.results.length} recorded sets${session.endedEarly ? ' · Ended early' : ''}</p>
      ${session.log ? renderLogged(session, unit) : renderPlan(plan, unit)}${active ? '' : button('Repeat workout', 'plan-repeat', session.id)}</article>`;
  }).join('') || '<section class="surface settings-card"><h2>No completed workouts</h2><p class="builder-hint">Finished workouts will appear here.</p></section>'}</div>`;
}
