import { analyticsDefaults, dashboardStats, estimateHelp, estimateSource, exerciseAnalytics, metrics, normalizedAnalytics, weeklyAnalytics } from './analytics.js';
import { equipmentName, unlinkedStation } from './history.js';
import { escapeHTML as html } from './exercises.js';
import { dayDistance } from './schedule.js';
import { kilogramsPerPound, localDayKey } from './storage.js';

const number = new Intl.NumberFormat('en-US', { maximumFractionDigits: 2 });
const mass = (value, unit) => unit === 'lb' ? value / kilogramsPerPound : value;
const button = (label, action, value = '', pressed) => `<button type="button" class="secondary" data-action="analytics-${action}" data-value="${value}"
  ${pressed == null ? '' : `aria-pressed="${pressed}"`}>${label}</button>`;
const unavailable = 'Unrecorded';

function display(metric, value, unit) {
  if (value == null) return unavailable;
  if (metric === 'load' || metric === 'estimate') return number.format(mass(value, unit)) + ' ' + unit;
  if (metric === 'volume') return number.format(mass(value, unit)) + ' ' + unit + '·reps';
  return number.format(value) + ({ duration: ' s', distance: ' m', reps: ' reps' }[metric] ?? '');
}

function settingsCard(settings, open) {
  const checks = (items, name, selected) => Object.entries(items).map(([key, label]) =>
    `<label class="builder-check"><input type="checkbox" name="${name}" value="${key}" ${selected.includes(key) ? 'checked' : ''}>${label}</label>`).join('');
  const check = settings.plateauEnabled ? 'checked' : '';
  return `<details class="surface settings-card analytics-options" ${open ? 'open' : ''}><summary>Analytics settings</summary>
    <div id="analytics-options" class="stack">
      <fieldset><legend>Show exercise metrics and records</legend>${checks(metrics, 'metric', settings.visible)}</fieldset>
      <fieldset><legend>Weekly dashboard statistics</legend>${checks(dashboardStats, 'stat', settings.dashboard)}</fieldset>
      <fieldset><legend>Plateau flags</legend>
        <label class="builder-check"><input type="checkbox" name="plateauEnabled" ${check}>Show possible plateau flags</label>
        <div class="builder-fields">
          <label>Plateau metric<select name="plateauMetric" aria-label="Plateau metric">${Object.entries(metrics).map(([key, label]) =>
            `<option value="${key}" ${key === settings.plateauMetric ? 'selected' : ''}>${label}</option>`).join('')}</select></label>
          <label>Comparable sessions<input type="number" aria-label="Comparable sessions" name="plateauSessions" min="3" max="12" value="${settings.plateauSessions}"></label>
          <label>Minimum improvement (%)<input type="number" aria-label="Minimum improvement (%)" name="plateauPercent" min="0.1" max="25" step="0.1" value="${settings.plateauPercent}"></label>
          <label>Training break (days)<input type="number" aria-label="Training break (days)" name="breakDays" min="7" max="90" value="${settings.breakDays}"></label>
        </div>
        <p class="builder-hint">Setline compares the first eligible session with the best later session in the window and flags improvement below your threshold. It uses matching working sets, excludes deloads, and starts a new window after a training break or a routine version, program, or equipment change.</p>
      </fieldset>
      ${button('Save analytics settings', 'save')}<p id="analytics-error" role="alert" class="entry-error"></p>
    </div></details>`;
}

function weeklyReport(report, settings, unit, names, format) {
  const first = report.days[0], last = report.days.at(-1);
  const tally = (purpose, label) => `<div><dt>${label}</dt><dd>${report.performed[purpose]} completed · ${report.planned[purpose]} planned</dd></div>`;
  const stats = {
    workouts: report.totals.workouts, sets: report.performed.working,
    volume: display('volume', report.totals.volume, unit), duration: display('duration', report.totals.duration, unit), distance: display('distance', report.totals.distance, unit),
  };
  const rows = [...report.muscles].sort(([a], [b]) => (names[a] ?? a).localeCompare(names[b] ?? b));
  return `<section class="surface settings-card analytics-week"><h2>Weekly dashboard</h2>
    <div class="builder-actions">${button('Previous week', 'week', '-7')}${button('This week', 'week', '0')}${button('Next week', 'week', '7')}</div>
    <p class="builder-hint">${format(first)} – ${format(last)}</p>
    ${settings.dashboard.length ? `<dl class="history-metrics analytics-tallies">${settings.dashboard.map(key => key === 'plan' ?
      tally('working', 'Working sets') + tally('warm-up', 'Warm-ups') :
      `<div><dt>${dashboardStats[key]}</dt><dd>${stats[key]}</dd></div>`).join('')}</dl>` : ''}
    <div class="analytics-muscle"><h3>Weekly sets by muscle</h3><p class="builder-hint">Primary muscles count as direct sets. Secondary muscles count as indirect sets. Each performed set counts once per muscle.</p>
    ${rows.length ? `<div class="analytics-table-wrap"><table><caption class="sr-only">Weekly working and warm-up sets by muscle</caption>
      <colgroup></colgroup><colgroup span="2"></colgroup><colgroup span="2"></colgroup>
      <thead><tr><th rowspan="2" scope="col">Muscle</th><th colspan="2" scope="colgroup">Working</th><th colspan="2" scope="colgroup">Warm-ups</th></tr>
      <tr><th scope="col">Direct</th><th scope="col">Indirect</th><th scope="col">Direct</th><th scope="col">Indirect</th></tr></thead>
      <tbody>${rows.map(([key, row]) => `<tr><th scope="row">${html(names[key] ?? key)}</th><td>${row.working.direct}</td><td>${row.working.indirect}</td>
        <td>${row['warm-up'].direct}</td><td>${row['warm-up'].indirect}</td></tr>`).join('')}</tbody></table></div>` : '<p>No logged sets for this week and filter selection.</p>'}</div></section>`;
}

function chart(metric, series, unit, format, loadLabel) {
  const points = series.points.filter(point => point.values[metric] != null);
  if (!points.length) return '';
  const title = metric === 'load' ? loadLabel : metrics[metric];
  const low = Math.min(...points.map(point => point.values[metric]));
  const spread = Math.max(...points.map(point => point.values[metric])) - low;
  const earliest = series.points[0].date;
  const span = dayDistance(earliest, series.points.at(-1).date);
  const x = date => span === 0 ? 150 : 12 + dayDistance(earliest, date) * 276 / span;
  const y = point => spread === 0 ? 38 : 65 - (point.values[metric] - low) * 52 / spread;
  const line = points.map(point => x(point.date) + ',' + y(point)).join(' ');
  const label = `${title}, ${points.length} ${points.length === 1 ? 'date' : 'dates'}`;
  return `<section class="analytics-chart"><h3>${title}</h3><p class="builder-hint">Latest · ${display(metric, points.at(-1).values[metric], unit)} · ${format(points.at(-1).date)}</p>
    <svg viewBox="0 0 300 76" role="img" aria-label="${label}">
      ${series.points.filter(point => point.events.length).map(point => `<line x1="${x(point.date)}" x2="${x(point.date)}" y1="4" y2="72" class="analytics-annotation"/>`).join('')}
      <polyline points="${line}" fill="none" stroke="currentColor" stroke-width="2"/>
      ${points.map(point => `<circle fill="currentColor" cx="${x(point.date)}" cy="${y(point)}" r="3"><title>${format(point.date)} · ${display(metric, point.values[metric], unit)}</title></circle>`).join('')}
    </svg><div class="analytics-axis"><span>${format(series.points[0].date)}</span>${span ? `<span>${format(series.points.at(-1).date)}</span>` : ''}</div>
    <details><summary>Values by date</summary><ul class="analytics-values">${points.map(point => `<li>${point.date} · ${display(metric, point.values[metric], unit)}</li>`).join('')}</ul></details></section>`;
}

function recordsBlock(records, unit) {
  const text = entry => `${display('load', entry.load, unit)} × ${entry.reps}${entry.side ? ' · ' + entry.side : ''} · ${entry.date}`;
  return records.heaviest ? `<div class="analytics-records"><p><strong>Heaviest logged load ${display('load', records.heaviest.load, unit)}</strong></p>
    <p class="builder-hint">${text(records.heaviest)}</p>
    <details><summary>Best reps at each load</summary><ul class="analytics-values">${records.byLoad.map(entry => `<li>${text(entry)}</li>`).join('')}</ul></details>
    <details><summary>Heaviest load by rep count</summary><ul class="analytics-values">${records.byReps.map(entry => `<li>${text(entry)}</li>`).join('')}</ul></details></div>` : '';
}

export function renderAnalytics(data, filters, unit, view, lookup, names, dateFormat) {
  const settings = normalizedAnalytics(data.analyticsSettings);
  const format = date => dateFormat(date, { month: 'short', day: 'numeric', year: 'numeric' });
  const purpose = view.purpose ?? 'working';
  const report = weeklyAnalytics(data, view.week ?? filters.to ?? localDayKey(), filters, lookup);
  const profiles = exerciseAnalytics(data, filters, purpose, settings);
  let cards = '';
  for (const series of profiles) {
    const { row, plateau } = series;
    const available = settings.visible.filter(metric => series.points.some(point => point.values[metric] != null));
    if (!available.length && !plateau) continue;
    const annotations = series.points.filter(point => point.events.length);
    const basis = row.basis === 'perDumbbell' ? ' · Per dumbbell' : '';
    const loadLabel = row.measurement === 'assistance' ? 'Assistance load' : row.measurement === 'added' ? 'Added load' : 'Load';
    cards += `<section class="surface settings-card history-trend analytics-exercise"><h2>${html(row.exercise.name)}</h2>
      <p class="builder-hint">${html(equipmentName(row))}${basis}${unlinkedStation(row) ? ' · Unidentified station, single session' : ''}</p>
      ${plateau?.state === 'deload' ? '<p class="analytics-notice">Planned deload · Plateau check paused</p>' : plateau?.state === 'flag' ?
        `<p class="analytics-notice">Possible plateau · ${metrics[settings.plateauMetric]} · ${number.format(plateau.change)}% best change over ${plateau.count} sessions</p>` : ''}
      ${settings.visible.includes('load') ? recordsBlock(series.records, unit) : ''}
      <div class="analytics-charts">${available.map(metric => chart(metric, series, unit, format, loadLabel)).join('')}</div>
      ${annotations.length ? `<details><summary>Chart annotations</summary><ul class="analytics-values">${annotations.map(point =>
        `<li>${point.date} · ${html(point.events.join(' · '))}</li>`).join('')}</ul></details>` : ''}</section>`;
  }
  return `${settingsCard(settings, view.settingsOpen)}${weeklyReport(report, settings, unit, names, format)}
    <section class="surface settings-card"><h2>Exercise trends and records</h2><div class="builder-actions" role="group" aria-label="Trend set type">
      ${button('Working sets', 'purpose', 'working', purpose === 'working')}${button('Warm-ups', 'purpose', 'warm-up', purpose === 'warm-up')}</div>
      <p class="builder-hint">Trends come from finished workouts. Dates show peak load and estimated 1RM, and totals for reps, volume, duration, and distance.</p>
      <details><summary>Estimated 1RM formula and limitations</summary><p>${estimateHelp}</p><a href="${estimateSource}" target="_blank" rel="noreferrer">Validation study</a></details>
      <p class="builder-hint">Equipment series stay separate. Machine settings have no weight or volume metric. Workout totals exclude machine and cable loads.</p>
    </section>${cards || '<section class="surface settings-card"><h2>No matching exercise trends</h2><p>Check the filters, the selected set type, and visible metrics.</p></section>'}`;
}

export function readAnalyticsSettings(section) {
  const value = key => section.querySelector(`[name="${key}"]`);
  const checked = key => [...section.querySelectorAll(`[name="${key}"]:checked`)].map(item => item.value);
  return { ...analyticsDefaults, visible: checked('metric'), dashboard: checked('stat'), plateauEnabled: value('plateauEnabled').checked,
    plateauMetric: value('plateauMetric').value, plateauSessions: Number(value('plateauSessions').value),
    plateauPercent: Number(value('plateauPercent').value), breakDays: Number(value('breakDays').value) };
}
