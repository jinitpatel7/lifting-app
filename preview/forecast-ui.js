import { escapeHTML as html } from './exercises.js';
import { forecastExercise, forecastModel, scoreForecasts } from './forecast.js';
import { programContext } from './analytics.js';
import { kilogramsPerPound } from './storage.js';
import { variantKey } from './workout-log.js';

const labels = {
  weight: 'Load', added: 'Added load', assistance: 'Assistance', reps: 'Reps', duration: 'Duration', distance: 'Distance',
};
const isMass = key => ['weight', 'added', 'assistance'].includes(key);
const units = (metric, unit) => isMass(metric) ? unit : { reps: 'reps', duration: 's', distance: 'm' }[metric];
const number = (metric, value, unit) => new Intl.NumberFormat(undefined, { maximumFractionDigits: 2 }).format(isMass(metric) && unit === 'lb' ? value / kilogramsPerPound : value);
const status = forecast => ({ learning: 'Learning your baseline', paused: 'Forecast unavailable', ready: forecast.confidence })[forecast.status];
function setup(forecast) {
  const details = [];
  if (forecast.basis === 'perDumbbell' && forecast.measurement === 'weight') details.push('Load per dumbbell.');
  if (forecast.ranges.reps && ['perSide', 'separateSides'].includes(forecast.counting)) {
    details.push('Reps per side. Separately logged sides use the lower reps' + (forecast.measurement === 'assistance' ? ' and greater assistance.' :
      ['weight', 'added'].includes(forecast.measurement) ? ' and lower load.' : '.'));
  }
  if (['distance', 'duration'].includes(forecast.measurement)) details.push('Separately logged sides use the shorter result.');
  return details.join(' ');
}
const value = (metric, amount, unit) => `${number(metric, amount, unit)} ${units(metric, unit)}`;
const issued = iso => new Date(iso).toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' });

function forecastContent(forecast, unit, dateLabel) {
  const hasChange = forecast.notes.some(note => note.startsWith('The typical estimate changed'));
  return `<div class="forecast-content"><p><strong>${status(forecast)}</strong>${forecast.sources.length ? ` · ${forecast.sources.length} sessions used` : ''}</p>
    ${forecast.status === 'ready' ? `<dl class="forecast-ranges">${Object.entries(forecast.ranges).map(([metric, range]) => `<div><dt>${labels[metric]}</dt>
      <dd><strong>${number(metric, range.low, unit)}–${value(metric, range.high, unit)}</strong><small>Typical ${value(metric, range.center, unit)}
      ${hasChange && forecast.priorRanges?.[metric] && forecast.priorRanges[metric].center !== range.center ? ` · Prior forecast ${value(metric, forecast.priorRanges[metric].center, unit)}` : ''}</small></dd></div>`).join('')}</dl>
      ${setup(forecast) ? `<p class="builder-hint">${setup(forecast)}</p>` : ''}<p class="builder-hint">The range describes recent variation in the first straight working set.</p>` : ''}
    ${forecast.previous ? `<p class="builder-hint">Previous-session benchmark · ${html(dateLabel(forecast.previous.day))} ·
      ${Object.entries(forecast.previous.values).map(([metric, amount]) => value(metric, amount, unit)).join(' · ')}</p>` : ''}
    ${forecast.notes.map(note => `<p class="builder-hint">${html(note)}</p>`).join('')}
    ${forecast.sources.length ? `<p class="builder-hint">Source dates · ${forecast.sources.map(entry => html(dateLabel(entry.day))).join(', ')}</p>` : ''}</div>`;
}

const brief = (forecast, unit) => forecast.status !== 'ready' ? status(forecast) : Object.entries(forecast.ranges).map(([metric, range]) =>
  `${number(metric, range.low, unit)}–${value(metric, range.high, unit)}`).join(' · ');

export function renderForecastPreview(data, plan, entry, unit, dateLabel, now = new Date()) {
  const deload = programContext(data, { localDate: entry.date, scheduleID: entry.id }).kind === 'deload';
  if (!plan.exercises.length) return '';
  return `<details class="forecast-panel"><summary>Performance forecast preview</summary><p class="builder-hint">A forecast is saved when you start the workout.</p>
    ${plan.exercises.map(row => {
      const forecast = forecastExercise(data, plan, row, { now, day: entry.date, deload });
      return `<details class="forecast-row"><summary>${html(forecast.name)} · ${brief(forecast, unit)}</summary>${forecastContent(forecast, unit, dateLabel)}</details>`;
    }).join('')}</details>`;
}

export function renderActiveForecast(session, row, unit, dateLabel) {
  const forecast = session.performanceForecasts?.findLast(item => item.rowID === row.id && item.variant === variantKey(row));
  if (!forecast) return '';
  return `<details class="forecast-row" data-log-disclosure="forecast-${row.id}"><summary>Performance forecast · ${brief(forecast, unit)}</summary>
    <p class="builder-hint">Saved ${html(issued(forecast.issuedAt))} · Revision ${forecast.revision}</p>${forecastContent(forecast, unit, dateLabel)}</details>`;
}

export function renderForecastArchive(session, unit, dateLabel) {
  const archived = session.performanceForecasts ?? [];
  if (!archived.length) return '';
  return `<details class="forecast-panel"><summary>Saved performance forecasts</summary>
    <p class="builder-hint">These forecasts were saved before the respective exercise results. Each revision preserves its original estimate.</p>
    ${archived.map(forecast => `<details class="forecast-row"><summary>${html(forecast.name)} · Revision ${forecast.revision} · ${brief(forecast, unit)}</summary>
      <p class="builder-hint">${html(issued(forecast.issuedAt))} · ${html(forecast.equipment)} · ${html(forecast.model)}</p>${forecastContent(forecast, unit, dateLabel)}</details>`).join('')}
    </details>`;
}

export function renderForecastEvaluation(data, unit) {
  const scores = scoreForecasts(data);
  return `<section class="surface settings-card forecast-evaluation"><h2>Forecast accuracy</h2>
    <p class="builder-hint">Setline scores saved forecasts against the first comparable straight working set in each finished workout. The benchmark repeats the previous comparable session. Smaller average errors are better.</p>
    ${scores.length ? scores.map(score => `<details><summary>${html(score.name)} · ${html(score.equipment)}${score.setting ? ' · Setting ' + html(score.setting) : ''} · ${score.count} scored</summary>
      <p class="builder-hint">Model ${html(score.model)}</p><dl class="forecast-ranges">${Object.entries(score.metrics).map(([key, metric]) => `<div><dt>${labels[key]}</dt>
      <dd>Forecast error ${value(key, metric.forecastError, unit)}<br>Previous-session error ${value(key, metric.previousError, unit)}<br>${metric.inside} of ${score.count} inside the forecast range</dd></div>`).join('')}</dl></details>`).join('') :
      '<p>No comparable forecasts have been scored yet.</p>'}
    <details><summary>How forecasts work</summary><div class="forecast-content"><p>Model ${forecastModel} uses the median of up to eight comparable sessions from the preceding 120 days. It needs at least three. Ranges reflect recent variation and widen after a break of at least 21 days. They have no guaranteed coverage.</p>
    <p>Equipment and tracking stay separate. Exercise order, planned load or assistance, rep ranges, rest, and recorded effort can narrow the evidence when enough sessions match. Warm-ups, special sets, deloads, and isolated extremes stay outside the estimate.</p>
    <p>Scores require matching equipment, tracking, and first-or-later exercise order. Machine settings must also match. “More comparable history” requires at least six results without a long break or mixed context. Your workouts are processed locally. This version uses a fixed rule and leaves bodyweight and readiness out.</p></div></details></section>`;
}
