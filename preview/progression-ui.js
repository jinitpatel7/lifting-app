import { escapeHTML as html } from './exercises.js';
import { equipmentName } from './history.js';
import { setSummary } from './routine-ui.js';
import { kilogramsPerPound } from './storage.js';
import { resultSummary } from './workout-ui.js';
import { massMode, modesFor, progressionModes, progressionRule, shownStep, suggestProgression } from './progression.js';

const button = (text, action, value = '', css = 'secondary') => `<button type="button" class="${css}" data-action="progression-${action}" data-value="${html(value)}">${text}</button>`;
const label = { off: 'Rule off', hold: 'Hold targets', advance: 'Progress', adjust: 'Step back' };
const effortOptions = { none: 'Off', rir: 'Minimum RIR', rpe: 'Maximum RPE' };
const options = (list, selected) => Object.entries(list).map(([id, name]) => `<option value="${id}" ${id === selected ? 'selected' : ''}>${html(name)}</option>`).join('');
const select = (title, name, list, selected) => `<label for="progression-${name}">${title}<select id="progression-${name}" aria-label="${title}" name="${name}">${options(list, selected)}</select></label>`;
const formatNumber = value => value == null ? '' : Number(value.toFixed(6));

export function renderProgressionList(data, versions, dayLabel) {
  if (!versions.length) return '<p>Save a routine to configure progression for its exercises.</p>';
  return `<div class="stack"><p class="builder-hint">Review rules and suggestions for the current version of each routine.</p>
    ${versions.map(version => `<section class="log-panel stack"><h3>${html(version.name)}</h3>${version.exercises.map((row, index) => {
      const suggestion = suggestProgression(data, version, row);
      const name = row.exercise.name + (version.exercises.filter(entry => entry.exercise.id === row.exercise.id).length > 1 ? ` · Exercise ${index + 1}` : '');
      return `<div class="progression-item"><div><strong>${html(name)}</strong><p class="builder-hint">${html(equipmentName(row))} · ${label[suggestion.action]}${suggestion.source ? ' · ' + html(dayLabel(suggestion.source.day)) : ''}</p></div>
      <button type="button" class="secondary" data-action="progression-review" data-value="${version.routineID}:${row.id}" aria-label="Review ${html(name)} in ${html(version.name)}">Review</button></div>`;
    }).join('')}</section>`).join('')}</div>`;
}

export function renderProgressionDetail(data, version, row, suggestion, unit, dayLabel, ruleOpen = false) {
  const rule = progressionRule(data, row);
  const modes = modesFor(row);
  const stepUnit = row.measurement === 'duration' ? 'seconds' : row.measurement === 'distance' ? 'meters' : unit;
  const stepBasis = row.basis === 'perDumbbell' && row.measurement === 'weight' ? ' per dumbbell' : '';
  const modeOptions = Object.fromEntries([['off', 'Off'], ...modes.map(mode => [mode, progressionModes[mode]])]);
  const evidenceList = sets => `<ol class="history-results">${sets.map(set => `<li><strong>${set.purpose === 'warm-up' ? 'Warm-up' : 'Set'} ${set.order}${set.plan?.amrap || set.result?.amrap ? ' · AMRAP' : ''}${(set.result?.structure ?? set.plan?.structure) === 'dropSet' ? ' · Drop set' : (set.result?.structure ?? set.plan?.structure) === 'restPause' ? ' · Rest-pause' : ''}</strong>
    ${set.plan ? `<span>Prescribed · ${html(setSummary({ ...set.plan, sets: 1 }, row, unit, 4))}</span>` : ''}
    <span>${set.result ? 'Actual · ' + html(resultSummary(set.result, row, unit, 4)) : set.status === 'skipped' ? 'Skipped' : 'Unfinished'}</span>
    ${suggestion.assessment[set.order] ? `<span class="progression-assessment">${suggestion.assessment[set.order]}</span>` : ''}</li>`).join('')}</ol>`;
  return `<div class="stack progression-detail"><p class="builder-hint">${html(version.name)} · Version ${version.revision} · ${html(equipmentName(row))}</p>
    ${modes.length ? `<details class="log-panel" ${ruleOpen || !rule ? 'open' : ''}><summary>Progression rule</summary>
    <form id="progression-form" class="stack"><div class="builder-fields">
      ${select('Progression method', 'mode', modeOptions, rule?.mode ?? 'off')}
      <label for="progression-step">Available increment (${stepUnit}${stepBasis})<input id="progression-step" name="step" inputmode="decimal" value="${rule ? formatNumber(shownStep(rule.step ?? 0, rule, unit)) || '' : ''}"></label>
      ${select('Reps required to increase load or reduce assistance', 'threshold', { top: 'Top of each rep range', minimum: 'Minimum of each rep range' }, rule?.threshold ?? 'top')}
      ${select('When a minimum target is missed', 'miss', { hold: 'Hold targets', stepBack: 'Step back one increment' }, rule?.miss ?? 'hold')}
      ${select('Use recorded effort', 'effort', effortOptions, rule?.effort ?? 'none')}
      <label for="progression-effort-limit">Effort threshold<input id="progression-effort-limit" name="effortLimit" inputmode="decimal" value="${formatNumber(rule?.effortLimit)}"></label></div>
      <p class="builder-hint">Reps progression raises the minimum by one within the prescribed range after every straight working set meets its target. Load, duration, distance, and assistance use the full increment you enter. Effort is used when all eligible sets record the selected metric.</p>
      <p id="progression-rule-error" class="entry-error" role="alert"></p><button type="submit" class="secondary">Save rule</button></form></details>` : '<p>Name the specific machine or cable station in the routine to use progression for this exercise.</p>'}
    <section class="log-panel stack"><h3>Planned targets</h3>${row.work.map((plan, index) => `<p>Block ${index + 1} · ${html(setSummary(plan, row, unit, 4))}</p>`).join('')}</section>
    <section class="log-panel stack"><h3>Suggestion · ${label[suggestion.action]}</h3><p>${html(suggestion.note)}</p>
      ${suggestion.changes.map(({ index, prescription }) => `<p>Block ${index + 1} · ${html(setSummary(prescription, row, unit, 4))}</p>`).join('')}
      ${suggestion.source ? `<h4>Actual results · ${html(suggestion.source.name)} · ${html(dayLabel(suggestion.source.day))}</h4>${evidenceList(suggestion.evidence)}
        ${suggestion.excluded.length ? `<details><summary>Sets outside the rule (${suggestion.excluded.length})</summary>${evidenceList(suggestion.excluded)}</details>` : ''}` : ''}
      ${suggestion.changes.length ? button('Accept suggestion', 'accept', '', 'primary') : ''}
      ${button('Override targets in routine editor', 'override')}
      <p class="builder-hint">Saving a target change creates a new routine version. Existing workouts and scheduled versions keep their original targets.</p>
      <p id="progression-error" class="entry-error" role="alert"></p></section>${button('Back to exercises', 'list')}</div>`;
}

export function readProgressionRule(form, unit, original) {
  const fields = new FormData(form);
  const mode = fields.get('mode');
  if (mode === 'off') return null;
  const text = fields.get('step').trim();
  const originalStep = original?.step != null && original.mode === mode && String(formatNumber(shownStep(original.step, original, unit))) === text;
  const step = mode === 'reps' || !text ? null : originalStep ? original.step : Number(text.replace(',', '.')) * (massMode(mode) && unit === 'lb' ? kilogramsPerPound : 1);
  const effortText = fields.get('effortLimit').trim();
  return { mode, step, threshold: fields.get('threshold'), miss: fields.get('miss'), effort: fields.get('effort'),
    effortLimit: effortText ? Number(effortText.replace(',', '.')) : null };
}

export function updateProgressionFields(form) {
  const { mode, step, threshold, miss, effort, effortLimit } = form.elements;
  const off = mode.value === 'off';
  step.parentElement.hidden = off || mode.value === 'reps';
  threshold.parentElement.hidden = !massMode(mode.value);
  miss.parentElement.hidden = off;
  effort.parentElement.hidden = off;
  effortLimit.parentElement.hidden = off || effort.value === 'none';
}
