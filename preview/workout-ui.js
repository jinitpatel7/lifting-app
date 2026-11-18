import { escapeHTML as html } from './exercises.js';
import { exerciseOptions, amount, setSummary } from './routine-ui.js';
import { hasReps, measurements } from './routines.js';
import { isBarbell, loadKey, previousResult, sessionInput, sessionPlan } from './workout-log.js';
import { kilogramsPerPound } from './storage.js';
import { clockText, plateOptions, typoHint, workoutSequence, workoutTimes } from './workout-tools.js';

const action = (label, key, value, style = 'secondary') => `<button type="button" class="${style}" data-action="${key}"${value ? ` data-value="${value}"` : ''}>${html(label)}</button>`;
const select = (label, id, choices) => `<label>${html(label)}<select id="${id}" aria-label="${html(label)}">${Object.entries(choices).map(([value, text]) => `<option value="${value}">${html(text)}</option>`).join('')}</select></label>`;
const field = (label, name, value, mode = 'text') => `<label>${html(label)}<input aria-label="${html(label)}" inputmode="${mode}" data-log-field="${name}" value="${html(value)}"></label>`;
const loadTypes = ['weight', 'added', 'assistance'];
const asNumber = value => value?.trim() ? Number(value.replace(',', '.')) : NaN;
const converted = (value, source, destination) => source === destination ? value : value * (source === 'lb' ? kilogramsPerPound : 1 / kilogramsPerPound);
const short = value => Number(value.toFixed(5));

export function workoutStep(session, row, set, field, direction, unit) {
  const input = sessionInput(set, unit);
  const sameLoad = field === 'rightAmount' && loadTypes.includes(row.measurement) ? asNumber(input.amount) : 0;
  const entered = asNumber(input[field]);
  const value = Number.isFinite(entered) ? entered : sameLoad || 0;
  const profile = session.log.loadProfiles?.[loadKey(row)];
  if (field === 'amount' && isBarbell(row) && profile) {
    const options = plateOptions(profile.bar, profile.plates, converted(value, input.unit, profile.unit));
    const candidate = direction > 0 ? options?.upper : options?.lower;
    return candidate == null ? null : String(short(converted(candidate, profile.unit, input.unit)));
  }
  const step = field === 'reps' || field === 'rightReps' ? 1 :
    row.measurement === 'duration' || row.measurement === 'distance' ? 5 :
      loadTypes.includes(row.measurement) && profile?.increment ? converted(profile.increment, profile.unit, input.unit) : null;
  return step == null ? null : String(short(Math.max(0, value + step * direction)));
}

function plateText(row, input, profile) {
  if (!isBarbell(row) || !profile) return '';
  const target = asNumber(input.amount);
  if (!Number.isFinite(target)) return 'Enter a target load in the set above.';
  const options = plateOptions(profile.bar, profile.plates, converted(target, input.unit, profile.unit));
  if (!options) return '';
  if (options.exact) return options.plates.length ? `Per side: ${options.plates.join(' + ')} ${profile.unit}` : 'Empty bar.';
  const reachable = [options.lower, options.upper].filter(value => value != null).map(value => value + ' ' + profile.unit);
  return reachable.length ? 'Closest available totals: ' + reachable.join(' or ') + '.' : 'No reachable load.';
}

function restDetails(result) {
  const rest = result.actualRest;
  return [rest?.measuredSeconds == null ? '' : `Measured rest ${rest.measuredSeconds}s`,
    rest?.editedSeconds == null ? '' : `Edited rest ${rest.editedSeconds}s`].filter(Boolean).join(' · ');
}

export function updateWorkoutFields(node, session, history, row, set, exercise, unit) {
  const input = sessionInput(set, unit);
  const previous = previousResult(session, history, row, set, exercise);
  const plan = sessionInput({ ...set, input: null }, input.unit);
  const previousInput = previous ? sessionInput({ plan: { target: previous.amount, reps: { minimum: previous.reps } } }, input.unit) : {};
  plan.amount ||= previousInput.amount;
  plan.reps ||= previousInput.reps;
  plan.rightReps ||= previous?.rightReps;
  if (previous?.rightAmount) plan.rightAmount = sessionInput({ plan: { target: previous.rightAmount } }, input.unit).amount;
  plan.repRange = set.plan?.reps;
  const sided = hasReps(row.measurement) ? row.counting === 'separateSides' || (row.counting === 'perSide' && input.separateSides) : input.separateSides;
  node.querySelector('.log-typo').textContent = typoHint(sided ? input : { ...input, rightReps: '', rightAmount: '' }, plan, row);
  const calculator = node.querySelector('[data-log-plate-result]');
  if (calculator) calculator.textContent = plateText(row, input, session.log.loadProfiles?.[loadKey(row)]);
}

function quickSteps(row, profile, sided) {
  const pair = (label, field) => [-1, 1].map(direction => action(`${label} ${direction > 0 ? '+' : '−'}`, 'log-step', field + '/' + direction)).join('');
  const quantity = row.measurement === 'duration' ? 'Time' : row.measurement === 'distance' ? 'Distance' : 'Load';
  const canStep = !hasReps(row.measurement) || (loadTypes.includes(row.measurement) && (isBarbell(row) ? profile : profile?.increment));
  return `<div class="log-quick">${canStep ? pair(sided ? 'Left ' + quantity.toLowerCase() : quantity, 'amount') : ''}
    ${canStep && sided && !isBarbell(row) ? pair('Right ' + quantity.toLowerCase(), 'rightAmount') : ''}
    ${hasReps(row.measurement) ? pair(sided ? 'Left reps' : 'Reps', 'reps') : ''}
    ${sided && hasReps(row.measurement) ? pair('Right reps', 'rightReps') : ''}</div>`;
}

export function resultSummary(result, row, unit) {
  const load = amount(result.amount, unit);
  const right = amount(result.rightAmount, unit);
  const reps = result.rightReps != null ? `${result.reps} left / ${result.rightReps} right`
    : result.reps == null ? '' : `${result.reps} reps${row.counting === 'perSide' ? ' per side' : ''}`;
  return [right ? `${load} left / ${right} right` : load && `${load}${row.basis === 'perDumbbell' && row.measurement === 'weight' ? ' per dumbbell' : ''}`, reps,
    result.rir == null ? '' : `RIR ${result.rir}`, result.rpe == null ? '' : `RPE ${result.rpe}`,
    result.failure ? 'To failure' : ''].filter(Boolean).join(' · ');
}

function setRow(session, history, exercise, row, set, index, unit, nextID) {
  const input = sessionInput(set, unit);
  const previous = previousResult(session, history, row, set, exercise);
  const result = session.results.find(item => item.id === set.id);
  const badge = set.status === 'pending' ? (set.input ? 'Edited' : 'Planned') : set.status === 'completed' ? 'Completed' : 'Skipped';
  const amountLabel = ({ duration: 'Duration (seconds)', distance: 'Distance (meters)', setting: 'Machine setting',
    added: `Added load (${input.unit})`, assistance: `Assistance (${input.unit})` })[row.measurement]
    ?? (row.basis === 'perDumbbell' ? `Load per dumbbell (${input.unit})` : `Weight (${input.unit})`);
  const repBased = hasReps(row.measurement);
  const sided = repBased ? row.counting === 'separateSides' || (row.counting === 'perSide' && input.separateSides) : input.separateSides;
  const repsLabel = sided ? 'Left reps' : row.counting === 'perSide' ? 'Reps per side' : 'Reps';
  const profile = session.log.loadProfiles?.[loadKey(row)];
  const configure = loadTypes.includes(row.measurement) && exercise.sets.find(item => item.status === 'pending') === set;
  return `<div class="log-set ${badge.toLowerCase()}${nextID === set.id ? ' next-set' : ''}" data-log-set="${set.id}">
    <div class="section-top"><strong>${set.purpose === 'warm-up' ? 'Warm-up' : 'Working'} set ${index + 1}${nextID === set.id ? ' <span class="log-next-label">Next</span>' : ''}</strong><span class="log-badge">${badge}</span></div>
    ${set.plan ? `<p class="log-planned">Planned · ${html(setSummary({ ...set.plan, sets: 1 }, row, unit))}</p>` : ''}
    ${previous ? `<p class="log-previous">Previous · ${html(resultSummary(previous, row, unit))}</p>` : ''}
    ${set.status === 'pending' ? `<div class="builder-fields log-fields">
      ${row.measurement === 'bodyweight' ? '' : field(sided ? 'Left · ' + amountLabel : amountLabel, 'amount', input.amount, row.measurement === 'setting' ? 'text' : 'decimal')}
      ${hasReps(row.measurement) ? field(repsLabel, 'reps', input.reps, 'numeric') : ''}
      ${sided && repBased ? field('Right reps', 'rightReps', input.rightReps, 'numeric') : ''}
      ${sided && row.measurement !== 'bodyweight' ? field('Right · ' + amountLabel + (repBased ? ' (optional)' : ''), 'rightAmount', input.rightAmount ?? '', row.measurement === 'setting' ? 'text' : 'decimal') : ''}
      </div>${!repBased || row.counting === 'perSide' ? action(sided ? 'Use a single result' : 'Log left and right', 'log-sides', set.id) : ''}
      ${quickSteps(row, profile, sided)}
      ${configure ? `<details data-log-disclosure="gear-${set.id}"><summary>${isBarbell(row) ? 'Plate calculator' : 'Equipment increment'}</summary>
        <div class="builder-fields">
          ${isBarbell(row) ? `<label>Bar weight (${profile?.unit ?? input.unit})<input aria-label="Bar weight" inputmode="decimal" data-log-gear="bar" value="${profile?.bar ?? ''}"></label>
          <label>Available plates, weight × pairs<input aria-label="Available plates" data-log-gear="plates" placeholder="20x2, 5x1" value="${html(profile?.plates.map(plate => plate.weight + 'x' + plate.count).join(', ') ?? '')}"></label>`
          : `<label>Load step (${profile?.unit ?? input.unit})<input aria-label="Load step" inputmode="decimal" data-log-gear="increment" value="${profile?.increment ?? ''}"></label>`}
        </div>${action('Save equipment', 'log-save-equipment', set.id)}
        <p class="builder-hint" data-log-plate-result>${html(plateText(row, input, profile))}</p></details>` : ''}
      <p class="log-typo builder-hint" role="status"></p>
      <details class="log-effort" data-log-disclosure="effort-${set.id}"><summary>Actual effort</summary><div class="builder-fields">
        ${field('Actual RIR', 'rir', input.rir, 'numeric')}${field('Actual RPE', 'rpe', input.rpe, 'decimal')}
        <label class="builder-check"><input type="checkbox" data-log-field="failure" ${input.failure ? 'checked' : ''}>Reached failure</label></div>
      </details>${session.log.clock?.pausedAt ? '' : action('Complete set', 'log-complete', set.id, 'primary')}` : ''}
    ${result && set.status === 'completed' ? `<p class="log-result">Result · ${html(resultSummary(result, row, unit))}</p>${action('Undo completion', 'log-undo', set.id)}
      <details data-log-disclosure="rest-${set.id}"><summary>${restDetails(result) || 'Actual rest'}</summary>
        <label>Edited rest (seconds)<input aria-label="Edited rest (seconds)" inputmode="numeric" data-log-rest-edit value="${result.actualRest?.editedSeconds ?? ''}"></label>
      </details>` : ''}
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
  const next = workoutSequence(log, plan).find(item => item.set.status === 'pending');
  const nextEntry = plan.exercises.find(item => item.id === next?.exerciseID);
  const nextNumber = log.exercises.find(item => item.id === next?.exerciseID)?.sets.findIndex(item => item.id === next?.set.id);
  const paused = Boolean(log.clock?.pausedAt);
  const timing = workoutTimes(session, new Date().toISOString());
  return `<div class="workout-editor">
    <p class="log-progress">${session.results.length} completed · ${pending} pending</p>
    <div class="log-timing"><span>Elapsed <strong data-clock="elapsed">${clockText(timing.elapsed)}</strong></span>
      <span>Active <strong data-clock="active">${clockText(timing.active)}</strong></span>
      <span>Paused <strong data-clock="paused">${clockText(timing.paused)}</strong></span>
      <label class="builder-check"><input type="checkbox" data-log-field="trackRest" ${log.trackRest ? 'checked' : ''}>Track actual rest</label></div>
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
        ${exercise.sets.map((set, index) => setRow(session, database.sessions, exercise, row, set, index, unit, next?.set.id)).join('')}
        <div class="builder-actions">${action('Add working set', 'log-add-set', exercise.id)}${action('Add warm-up set', 'log-add-warm', exercise.id)}</div></section>`;
    }).join('')}
    ${queued.length ? `<section class="log-panel" aria-label="Busy equipment queue"><h3>Busy equipment queue</h3>
      ${queued.map(exercise => `<div class="section-top"><span>${html(plan.exercises.find(row => row.id === exercise.id)?.exercise.name)}</span>
        ${action('Resume exercise', 'log-resume', exercise.id)}</div>`).join('')}</section>` : ''}
    <p class="entry-error" role="alert" id="plan-session-error"></p>
    <div class="builder-actions">${action('Finish workout', 'plan-finish', session.id, 'primary')}${action('End early', 'log-end-early')}</div>
    <div id="log-confirmation"></div>
    <aside class="log-dock" aria-label="Workout controls">
      ${log.rest ? `<div class="log-rest-dock"><strong>${html(log.rest.rule)} <span role="timer" data-clock="rest"></span></strong>
        <div class="log-quick">${paused ? '' : action('Extend 15s', 'log-timer-extend') + action('Restart rest', 'log-timer-restart')}${action('Skip rest', 'log-timer-skip')}</div></div>` : ''}
      ${next ? `<div class="log-next"><span><strong>Next</strong> ${html(nextEntry.exercise.name)} · Set ${nextNumber + 1}</span><div class="log-quick">
        ${action('Go to next set', 'log-focus-next', next.set.id)}${paused ? '' : action('Complete next set', 'log-complete-next', next.exerciseID + '/' + next.set.id, 'primary')}</div></div>` : ''}
      <div class="log-quick">${action(paused ? 'Resume workout' : 'Pause workout', paused ? 'log-workout-resume' : 'log-workout-pause')}
        ${log.undo ? action('Undo last action', 'log-undo-last') : ''}</div>
    </aside>
  </div>`;
}

export function renderLoggedHistory(session, unit) {
  const plan = sessionPlan(session);
  const timing = workoutTimes(session, session.completedAt);
  return `<div class="saved-plan"><p>Elapsed ${clockText(timing.elapsed)} · Active ${clockText(timing.active)} · Paused ${clockText(timing.paused)}</p>${session.log.notes ? `<p>${html(session.log.notes)}</p>` : ''}
    ${session.log.exercises.map(exercise => {
      const row = plan.exercises.find(item => item.id === exercise.id);
      if (!row) return '';
      return `<div><strong>${html(row.exercise.name)}</strong>${exercise.notes ? `<small>${html(exercise.notes)}</small>` : ''}
        ${exercise.sets.map(set => {
          const completed = session.results.find(item => item.id === set.id);
          return `<small>${set.purpose === 'warm-up' ? 'Warm-up' : 'Working'} · ${completed ? `Completed · ${html(resultSummary(completed, row, unit))}`
            : set.status === 'skipped' ? 'Skipped' : 'Unfinished'}${completed && restDetails(completed) ? ' · ' + html(restDetails(completed)) : ''}</small>`;
        }).join('')}</div>`;
    }).join('')}</div>`;
}
