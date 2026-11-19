import { escapeHTML as html } from './exercises.js';
import { equipmentName } from './history.js';
import { setSummary } from './routine-ui.js';
import { kilogramsPerPound } from './storage.js';
import { resultSummary } from './workout-ui.js';
import { massMode, modesFor, progressionModes, progressionRule, shownStep, suggestProgression } from './progression.js';

const button = (text, action, value = '', css = 'secondary') => `<button type="button" class="${css}" data-action="progression-${action}" data-value="${html(value)}">${text}</button>`;
const label = { off: 'Rule off', learning: 'Learning your baseline', hold: 'Hold targets', advance: 'Progress', adjust: 'Step back' };
const effortOptions = { none: 'Off', rir: 'Minimum RIR', rpe: 'Maximum RPE' };
const options = (list, selected) => Object.entries(list).map(([id, name]) => `<option value="${id}" ${id === selected ? 'selected' : ''}>${html(name)}</option>`).join('');
const select = (title, name, list, selected) => `<label for="progression-${name}">${title}<select id="progression-${name}" aria-label="${title}" name="${name}">${options(list, selected)}</select></label>`;
const formatNumber = value => value == null ? '' : Number(value.toFixed(6));
const positiveWhole = (value, fallback) => Number.isInteger(value) && value > 0 ? value : fallback;

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
      ${select('Progression method', 'mode', modeOptions, rule?.mode ?? (suggestion.action === 'off' ? 'off' : modes[0]))}
      <label for="progression-step">Smallest available increment (${stepUnit}${stepBasis})<input id="progression-step" name="step" inputmode="decimal" value="${rule ? formatNumber(shownStep(rule.step ?? 0, rule, unit)) || '' : ''}"></label>
      <label>Sessions required to increase target<input type="number" name="topSessions" min="2" max="12" value="${positiveWhole(rule?.topSessions, 2)}" required></label>
      ${select('Use recorded effort', 'effort', effortOptions, rule?.effort ?? 'none')}
      <label for="progression-effort-limit">Effort threshold<input id="progression-effort-limit" name="effortLimit" inputmode="decimal" value="${formatNumber(rule?.effortLimit)}"></label>
      <label><input type="checkbox" name="allowExtraSet" ${rule?.allowExtraSet ? 'checked' : ''}> Allow an extra working set on a plateau</label>
      <label>Plateau sessions<input type="number" name="plateauSessions" min="2" max="12" value="${positiveWhole(rule?.plateauSessions, 3)}" required></label>
      <label>Working set cap per workout<input type="number" name="volumeCap" min="1" max="30" value="${positiveWhole(rule?.volumeCap, 6)}" required></label></div>
      <p class="builder-hint">Load changes use the entered increment or saved equipment inventory. Adding a set also needs recorded effort in reserve or a favorable readiness check-in.</p>
      <p id="progression-rule-error" class="entry-error" role="alert"></p><button type="submit" class="secondary">Save rule</button></form></details>` : '<p>Name the specific machine or cable station in the routine to use progression for this exercise.</p>'}
    <section class="log-panel stack"><h3>Planned targets</h3>${row.work.map((plan, index) => `<p>Block ${index + 1} · ${html(setSummary(plan, row, unit, 4))}</p>`).join('')}</section>
    <section class="log-panel stack"><h3>Suggestion · ${label[suggestion.action]}</h3><p>${html(suggestion.note)}</p>
      ${renderChanges(row, suggestion, unit)}
      ${suggestion.warning ? `<p>${html(suggestion.warning)}</p>` : ''}
      ${suggestion.source ? `<h4>Actual results · ${html(suggestion.source.name)} · ${html(dayLabel(suggestion.source.day))}</h4>${evidenceList(suggestion.evidence)}
        ${suggestion.excluded.length ? `<details><summary>Sets outside the rule (${suggestion.excluded.length})</summary>${evidenceList(suggestion.excluded)}</details>` : ''}` : ''}
      ${suggestion.changes.length ? `<div class="builder-actions">${button('Apply once', 'once', '', 'primary')}
        ${data.routines.find(routine => routine.id === version.routineID)?.versions.at(-1)?.id === version.id ? button('Update routine', 'accept') : ''}
        ${button('Edit recommendation', 'override')}${button(suggestion.warning ? 'Hold for now' : 'Dismiss', 'dismiss')}</div>` : ''}
      <p class="builder-hint">Apply once uses the next matching workout. Update routine saves a new version. Existing scheduled versions keep their original targets.</p>
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
  return { mode, step, threshold: 'top', miss: 'stepBack', effort: fields.get('effort'), topSessions: Number(fields.get('topSessions')),
    allowExtraSet: fields.has('allowExtraSet'), plateauSessions: Number(fields.get('plateauSessions')), volumeCap: Number(fields.get('volumeCap')),
    effortLimit: effortText ? Number(effortText.replace(',', '.')) : null };
}

export function updateProgressionFields(form) {
  const { mode, step, effort, effortLimit, allowExtraSet, plateauSessions, volumeCap, topSessions } = form.elements;
  const off = mode.value === 'off';
  step.parentElement.hidden = off || mode.value === 'reps';
  topSessions.parentElement.hidden = off || mode.value === 'reps';
  allowExtraSet.parentElement.hidden = off;
  plateauSessions.parentElement.hidden = off || !allowExtraSet.checked;
  volumeCap.parentElement.hidden = off || !allowExtraSet.checked;
  effort.parentElement.hidden = off;
  effortLimit.parentElement.hidden = off || effort.value === 'none';
}

function renderChanges(row, suggestion, unit) {
  return suggestion.changes.map(({ index, prescription, replacement }) => {
    const old = setSummary(row.work[index], row, unit, 4);
    const blocks = replacement ?? [prescription];
    const next = blocks.length ? blocks.map(block => setSummary(block, row, unit, 4)).join(' + ') : 'Remove block';
    return `<p>Block ${index + 1} · ${html(old)} → ${html(next)}</p>`;
  }).join('');
}

export function renderWorkoutRecommendations(data, version, unit, include = () => true) {
  if (!version || version.revision <= 0) return '';
  const rows = version.exercises.filter(include).flatMap(row => {
    const suggestion = suggestProgression(data, version, row);
    if (suggestion.action === 'off') return [];
    const queued = data.progressionDecisions?.find(item => item.versionID === version.id && item.rowID === row.id)?.working;
    return [`<div class="stack"><strong>${html(row.exercise.name)} · ${label[suggestion.action]}</strong><p>${html(suggestion.note)}</p>
      ${renderChanges(row, suggestion, unit)}
      ${queued ? `<p>Queued targets · ${html(queued.map(plan => setSummary(plan, row, unit, 4)).join(' + '))}</p>` : ''}
      ${suggestion.warning ? `<p class="builder-hint">${html(suggestion.warning)}</p>` : ''}
      ${button('Review recommendation', 'review', `${version.routineID}:${row.id}:${version.id}`)}</div>`];
  });
  return rows.length ? `<section class="log-panel stack"><h3>Workout recommendations</h3>${rows.join('')}</section>` : '';
}
