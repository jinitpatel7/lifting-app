import { escapeHTML as html } from './exercises.js';
import { dayDistance, offsetDay, scheduleEntries, scheduleVersion, statusLabels, weekdays, weekKinds } from './schedule.js';

const action = (label, key, value = '') => `<button type="button" class="secondary" data-action="${key}" data-value="${html(value)}">${html(label)}</button>`;
const option = (id, label, selected) => `<option value="${html(id)}"${String(id) === String(selected) ? ' selected' : ''}>${html(label)}</option>`;
const input = (name, id, value, type = 'text', limits = '') => `<label>${html(name)}<input type="${type}" id="${id}" aria-label="${html(name)}" value="${html(value)}" ${limits}></label>`;
const select = (name, id, options) => `<label>${html(name)}<select id="${id}" aria-label="${html(name)}">${options}</select></label>`;
const errors = '<p id="schedule-error" class="entry-error" role="alert"></p>';

function routineOptions(data) {
  return '<option value="">Choose a routine version</option>' + data.routines.flatMap(item => item.versions.slice().reverse()).map(version =>
    option(version.id, version.name + ' · v' + version.revision)).join('');
}

export function rotationSteps(data, steps) {
  return steps.length ? `<ol class="schedule-steps">${steps.map((id, index) =>
    `<li><strong>${html(scheduleVersion(data, id)?.name ?? 'Routine')}</strong><div class="builder-actions">
    ${index > 0 ? action('Move up', 'schedule-step-up', index) : ''}
    ${index < steps.length - 1 ? action('Move down', 'schedule-step-down', index) : ''}
    ${action('Remove step', 'schedule-step-remove', index)}</div></li>`).join('')}</ol>` : '<p class="builder-hint">Add routines in the order you want to train them.</p>';
}

export function renderSchedulePlanner(data, today, anchor, rotationStepsDraft, section = '') {
  const recurring = (data.weekdayRules ?? []).filter(rule => !rule.endBefore);
  const rotation = (data.rotations ?? []).find(rule => !rule.endBefore);
  return `<div class="schedule-planner stack">
    <section class="log-panel"><h3>Calendar view</h3><div class="builder-fields">
      ${select('Week starts on', 'schedule-week-start', weekdays.map((name, index) => option(index, name, data.scheduleSettings?.weekStart ?? 1)).join(''))}
      ${select('Calendar view', 'schedule-view', option('week', 'Training week', data.scheduleSettings?.mode ?? 'week') + option('rolling', 'Rolling seven days', data.scheduleSettings?.mode))}
      </div>${action('Save calendar view', 'schedule-save-settings')}</section>
    <details class="log-panel" ${section === 'weekday' ? 'open' : ''}><summary>Weekday assignments</summary>
      ${recurring.map(rule => `<div class="schedule-item"><span>${html(weekdays[rule.weekday])} · ${html(scheduleVersion(data, rule.versionID)?.name ?? '')} · from ${rule.start}</span>
        ${action('End weekday assignment', 'schedule-end-weekday', rule.id)}</div>`).join('')}
      <div class="builder-fields">${select('Weekday', 'schedule-weekday', weekdays.map((name, index) => option(index, name, new Date(anchor + 'T00:00:00Z').getUTCDay())).join(''))}
      ${select('Routine version for weekday', 'schedule-weekday-version', routineOptions(data))}
      ${input('Start weekday assignment', 'schedule-weekday-start', today, 'date')}</div>
      ${action('Assign weekday', 'schedule-save-weekday')}</details>
    <details class="log-panel" ${section === 'rotation' ? 'open' : ''}><summary>Rotating sequence</summary>
      <p class="builder-hint">A finished session with logged sets or an explicit skip advances the sequence. A missed day holds your place. The calendar shows the next rotation slot.</p>
      ${rotation ? `<p>${rotation.versions.map(id => html(scheduleVersion(data, id)?.name ?? '')).join(' → ')} · Every ${rotation.interval} day(s) from ${rotation.start}</p>
        ${action('End rotation', 'schedule-end-rotation', rotation.id)}` : ''}
      <div class="builder-fields">${input('Rotation start date', 'schedule-rotation-start', today, 'date')}
      ${input('Days between slots', 'schedule-rotation-interval', 1, 'number', 'min="1" max="30"')}
      ${select('Routine version for rotation', 'schedule-rotation-version', routineOptions(data))}</div>
      ${action('Add to sequence', 'schedule-step-add')}
      <div id="schedule-sequence">${rotationSteps(data, rotationStepsDraft)}</div>
      ${action(rotation ? 'Replace rotation' : 'Save rotation', 'schedule-save-rotation')}</details>
    <details class="log-panel" ${section === 'blocks' ? 'open' : ''}><summary>Program blocks</summary>
      ${(data.programBlocks ?? []).map(block => `<div class="schedule-item"><span>${html(block.name)} · ${block.first} to ${block.last}</span>
        ${action('Open program', 'schedule-open-block', block.id)}</div>`).join('')}
      <div class="builder-fields">${input('Program name', 'schedule-block-name', '')}
      ${input('Program start date', 'schedule-block-start', today, 'date')}
      ${input('Number of weeks', 'schedule-block-count', 4, 'number', 'min="2" max="52"')}</div>
      ${action('Create program block', 'schedule-save-block')}</details>
    ${errors}
  </div>`;
}

export function renderProgramWeek(data, block, index) {
  const count = Math.ceil((dayDistance(block.first, block.last) + 1) / 7);
  const first = offsetDay(block.first, index * 7);
  const last = offsetDay(first, Math.min(6, dayDistance(first, block.last)));
  const week = block.weeks?.[index];
  const rows = data.schedule.filter(entry => entry.blockID === block.id && (entry.moves?.[0] ?? entry.date) >= first && (entry.moves?.[0] ?? entry.date) <= last);
  const statuses = new Map(scheduleEntries(data, rows.map(entry => entry.date)).map(entry => [entry.key, entry.status]));
  return `<div class="stack schedule-program" data-block-id="${block.id}" data-week-start="${first}" data-week-end="${last}">
    ${action('Training schedule', 'schedule-open-blocks')}
    ${select('Program week', 'schedule-block-week', Array.from({ length: count }, (_, i) => option(i,
      'Week ' + (i + 1) + ' · ' + weekKinds[block.weeks?.[i]?.kind ?? 'training'], index)).join(''))}
    <p class="builder-hint">${first} to ${last}. Use saved routine versions for the sessions you want to train this week.</p>
    <div class="builder-fields">${select('Week type', 'schedule-week-kind', Object.entries(weekKinds).map(([key, name]) => option(key, name, week?.kind ?? 'training')).join(''))}
    <label>Progression or deload notes<textarea id="schedule-week-notes" aria-label="Progression or deload notes" rows="3">${html(week?.notes ?? '')}</textarea></label></div>
    ${action('Save week', 'schedule-save-week', index)}
    <section class="log-panel"><h3>Scheduled sessions</h3>
      ${rows.length ? rows.map(entry => {
        const version = scheduleVersion(data, entry.versionID);
        return `<p>${entry.date} · ${html(version?.name ?? '')} · v${version?.revision ?? ''} · ${statusLabels[statuses.get(entry.id)] ?? 'Planned'}</p>`;
      }).join('') : '<p class="builder-hint">No sessions assigned to this week.</p>'}
      <div class="builder-fields">${input('Program session date', 'schedule-program-date', first, 'date', `min="${first}" max="${last}"`)}
      ${select('Routine version for program', 'schedule-program-version', routineOptions(data))}</div>
      ${action('Add program session', 'schedule-add-block-session', index)}
    </section>${errors}
  </div>`;
}

export function renderMove(entry, today) {
  const suggested = entry.date === today ? offsetDay(today, 1) : today;
  return `<div class="stack" data-schedule-date="${entry.date}">
    ${input('New workout date', 'schedule-move-date', suggested, 'date', `min="${today}"`)}
    ${action('Save new date', 'schedule-save-move', entry.key)}${errors}</div>`;
}

export const readinessFields = { soreness: 'Soreness', sleep: 'Sleep quality', energy: 'Energy', motivation: 'Motivation' };
export function renderReadiness(date, entry) {
  return `<div class="stack"><p class="builder-hint">Soreness ranges from none to high. Sleep quality, energy, and motivation range from low to high.</p>
    <div class="builder-fields">${Object.entries(readinessFields).map(([key, name]) => select(name, 'readiness-' + key,
      '<option value="">Choose 1–5</option>' + [1, 2, 3, 4, 5].map(value => option(value, value, entry?.[key])).join(''))).join('')}</div>
    ${action('Save check-in', 'schedule-save-readiness', date)}${errors}</div>`;
}

export function scheduleSummary(data, entry, formatDate) {
  const block = data.programBlocks?.find(item => item.id === entry.blockID);
  const index = block && Math.floor(dayDistance(block.first, entry.moves?.[0] ?? entry.date) / 7);
  const week = block && block.weeks[index];
  const name = statusLabels[entry.status];
  const detail = entry.destination ? 'Moved to ' + formatDate(entry.destination) :
    entry.moves?.length ? 'Moved from ' + formatDate(entry.moves.at(-1)) : entry.rotationID ? 'Rotating sequence' : '';
  return { name, detail, block, kind: block && weekKinds[week?.kind ?? 'training'], index, notes: week?.notes };
}
