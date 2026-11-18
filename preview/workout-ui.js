import { escapeHTML as html } from './exercises.js';
import { exerciseOptions, amount, setSummary } from './routine-ui.js';
import { hasReps, measurements } from './routines.js';
import { previousResult, sessionInput, sessionPlan } from './workout-log.js';

const action = (label, key, value, style = 'secondary') => `<button type="button" class="${style}" data-action="${key}"${value ? ` data-value="${value}"` : ''}>${html(label)}</button>`;
const select = (label, id, choices) => `<label>${html(label)}<select id="${id}" aria-label="${html(label)}">${Object.entries(choices).map(([value, text]) => `<option value="${value}">${html(text)}</option>`).join('')}</select></label>`;
const field = (label, name, value, mode = 'text') => `<label>${html(label)}<input aria-label="${html(label)}" inputmode="${mode}" data-log-field="${name}" value="${html(value)}"></label>`;

export function resultSummary(result, row, unit) {
  const load = amount(result.amount, unit);
  const reps = result.rightReps != null ? `${result.reps} left / ${result.rightReps} right`
    : result.reps == null ? '' : `${result.reps} reps${row.counting === 'perSide' ? ' per side' : ''}`;
  return [load && `${load}${row.basis === 'perDumbbell' && row.measurement === 'weight' ? ' per dumbbell' : ''}`, reps,
    result.rir == null ? '' : `RIR ${result.rir}`, result.rpe == null ? '' : `RPE ${result.rpe}`,
    result.failure ? 'To failure' : ''].filter(Boolean).join(' · ');
}

function setRow(session, history, exercise, row, set, index, unit) {
  const input = sessionInput(set, unit);
  const previous = previousResult(session, history, row, set, exercise);
  const result = session.results.find(item => item.id === set.id);
  const badge = set.status === 'pending' ? (set.input ? 'Edited' : 'Planned') : set.status === 'completed' ? 'Completed' : 'Skipped';
  const amountLabel = ({ duration: 'Duration (seconds)', distance: 'Distance (meters)', setting: 'Machine setting',
    added: `Added load (${input.unit})`, assistance: `Assistance (${input.unit})` })[row.measurement]
    ?? (row.basis === 'perDumbbell' ? `Load per dumbbell (${input.unit})` : `Weight (${input.unit})`);
  const repsLabel = row.counting === 'perSide' ? 'Reps per side' : row.counting === 'separateSides' ? 'Left reps' : 'Reps';
  return `<div class="log-set ${badge.toLowerCase()}" data-log-set="${set.id}">
    <div class="section-top"><strong>${set.purpose === 'warm-up' ? 'Warm-up' : 'Working'} set ${index + 1}</strong><span class="log-badge">${badge}</span></div>
    ${set.plan ? `<p class="log-planned">Planned · ${html(setSummary({ ...set.plan, sets: 1 }, row, unit))}</p>` : ''}
    ${previous ? `<p class="log-previous">Previous · ${html(resultSummary(previous, row, unit))}</p>` : ''}
    ${set.status === 'pending' ? `<div class="builder-fields log-fields">
      ${row.measurement === 'bodyweight' ? '' : field(amountLabel, 'amount', input.amount, row.measurement === 'setting' ? 'text' : 'decimal')}
      ${hasReps(row.measurement) ? field(repsLabel, 'reps', input.reps, 'numeric') : ''}
      ${hasReps(row.measurement) && row.counting === 'separateSides' ? field('Right reps', 'rightReps', input.rightReps, 'numeric') : ''}
      </div><details class="log-effort" data-log-disclosure="effort-${set.id}"><summary>Actual effort</summary><div class="builder-fields">
        ${field('Actual RIR', 'rir', input.rir, 'numeric')}${field('Actual RPE', 'rpe', input.rpe, 'decimal')}
        <label class="builder-check"><input type="checkbox" data-log-field="failure" ${input.failure ? 'checked' : ''}>Reached failure</label></div>
      </details>${action('Complete set', 'log-complete', set.id, 'primary')}` : ''}
    ${result && set.status === 'completed' ? `<p class="log-result">Result · ${html(resultSummary(result, row, unit))}</p>${action('Undo completion', 'log-undo', set.id)}` : ''}
    ${set.status === 'skipped' ? action('Restore set', 'log-restore-set', set.id) : ''}
    <details class="log-set-options" data-log-disclosure="set-${set.id}"><summary>Set options</summary><div class="builder-actions">
      ${set.status === 'pending' ? action('Skip set', 'log-skip-set', set.id) : ''}
      ${index ? action('Move set up', 'log-set-up', set.id) : ''}
      ${index + 1 < exercise.sets.length ? action('Move set down', 'log-set-down', set.id) : ''}
      ${action('Delete set', 'log-delete-set', set.id)}</div></details>
  </div>`;
}

export function renderWorkout(session, database, catalog, exercises, unit) {
  const plan = sessionPlan(session);
  const log = session.log;
  const pending = log.exercises.flatMap(exercise => exercise.sets).filter(set => set.status === 'pending').length;
  const queued = log.exercises.filter(exercise => exercise.queuedAt).sort((a, b) => a.queuedAt.localeCompare(b.queuedAt));
  const linked = database.routines.some(routine => routine.id === plan.routineID);
  const reference = database.sessions.find(item => item.id === session.referenceID);
  return `<div class="workout-editor">
    <p class="log-progress">${session.results.length} completed · ${pending} pending</p>
    ${reference ? '<p class="log-previous">Previous results appear beside the matching sets.</p>' : ''}
    <label class="log-notes">Workout notes<textarea aria-label="Workout notes" data-log-field="sessionNotes" rows="2">${html(log.notes)}</textarea></label>
    <details class="log-panel" data-log-disclosure="add-exercise"><summary>Add exercise</summary>
      <div class="builder-fields">
        <label>Search exercises<input type="search" id="log-exercise-search" aria-label="Search exercises"></label>
        <label>Exercise<select id="log-exercise-choice" aria-label="Exercise">${exerciseOptions(catalog, exercises, '')}</select></label>
        ${select('Track by', 'log-measurement', measurements)}
        ${select('Rep counting', 'log-counting', { total: 'Total reps', perSide: 'Per side', separateSides: 'Separate sides' })}
        ${select('Load convention', 'log-basis', { total: 'Total load', perDumbbell: 'Per dumbbell' })}
        <label>Equipment or machine name<input id="log-equipment" aria-label="Equipment or machine name"></label>
      </div>${action('Add to workout', 'log-add-exercise')}</details>
    <details class="log-panel" data-log-disclosure="change-scope"><summary>Today only or update routine</summary>
      <p class="builder-hint">Set changes apply to today’s workout.</p><div class="builder-actions">
      ${action('Edit this workout', 'plan-session-edit', session.id)}${linked ? action('Update routine', 'log-update-routine') : ''}</div></details>
    ${log.exercises.filter(exercise => !exercise.queuedAt).map(exercise => {
      const row = plan.exercises.find(item => item.id === exercise.id);
      const position = log.exercises.indexOf(exercise);
      const group = plan.groups.find(group => group.members[0] === exercise.id);
      if (!row) return '';
      return `<section class="log-exercise" data-log-exercise="${exercise.id}"><h3>${html(row.exercise.name)}</h3>
        ${group ? `<p class="plan-group-label">${html(group.kind)} · ${group.rounds} rounds · ${group.restExercises}s between exercises · ${group.restRounds}s between rounds</p>` : ''}
        <label class="log-notes">Exercise notes<textarea aria-label="Exercise notes" data-log-field="exerciseNotes" rows="2">${html(exercise.notes)}</textarea></label>
        <details data-log-disclosure="exercise-${exercise.id}"><summary>Exercise options</summary><div class="builder-actions">
          ${action('Equipment busy', 'log-queue', exercise.id)}${action('Skip remaining sets', 'log-skip-exercise', exercise.id)}
          ${exercise.sets.some(set => set.status === 'skipped') ? action('Restore skipped sets', 'log-restore-exercise', exercise.id) : ''}
          ${position ? action('Move exercise up', 'log-exercise-up', exercise.id) : ''}
          ${position + 1 < log.exercises.length ? action('Move exercise down', 'log-exercise-down', exercise.id) : ''}
          ${action('Delete exercise', 'log-delete-exercise', exercise.id)}</div></details>
        ${exercise.sets.map((set, index) => setRow(session, database.sessions, exercise, row, set, index, unit)).join('')}
        <div class="builder-actions">${action('Add working set', 'log-add-set', exercise.id)}${action('Add warm-up set', 'log-add-warm', exercise.id)}</div></section>`;
    }).join('')}
    ${queued.length ? `<section class="log-panel" aria-label="Busy equipment queue"><h3>Busy equipment queue</h3>
      ${queued.map(exercise => `<div class="section-top"><span>${html(plan.exercises.find(row => row.id === exercise.id)?.exercise.name)}</span>
        ${action('Resume exercise', 'log-resume', exercise.id)}</div>`).join('')}</section>` : ''}
    <p class="entry-error" role="alert" id="plan-session-error"></p>
    <div class="builder-actions">${action('Finish workout', 'plan-finish', session.id, 'primary')}${action('End early', 'log-end-early')}</div>
    <div id="log-confirmation"></div>
  </div>`;
}

export function renderLoggedHistory(session, unit) {
  const plan = sessionPlan(session);
  return `<div class="saved-plan">${session.log.notes ? `<p>${html(session.log.notes)}</p>` : ''}
    ${session.log.exercises.map(exercise => {
      const row = plan.exercises.find(item => item.id === exercise.id);
      if (!row) return '';
      return `<div><strong>${html(row.exercise.name)}</strong>${exercise.notes ? `<small>${html(exercise.notes)}</small>` : ''}
        ${exercise.sets.map(set => {
          const completed = session.results.find(item => item.id === set.id);
          return `<small>${set.purpose === 'warm-up' ? 'Warm-up' : 'Working'} · ${completed ? `Completed · ${html(resultSummary(completed, row, unit))}`
            : set.status === 'skipped' ? 'Skipped' : 'Unfinished'}</small>`;
        }).join('')}</div>`;
    }).join('')}</div>`;
}
