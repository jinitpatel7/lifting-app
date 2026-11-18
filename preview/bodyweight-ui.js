import { bodyweightTrend } from './bodyweight.js';
import { dayDistance } from './schedule.js';
import { kilogramsPerPound, localDayKey } from './storage.js';
import { escapeHTML as html } from './exercises.js';

const units = (kg, unit) => unit === 'lb' ? kg / kilogramsPerPound : kg;
const amount = (kg, unit, digits = 2) => new Intl.NumberFormat('en-US', { minimumFractionDigits: 1, maximumFractionDigits: digits }).format(units(kg, unit)) + ' ' + unit;
const edit = (label, date) => `<button type="button" class="secondary" data-action="weight" data-value="${date}">${label}</button>`;

export function bodyweightOn(entry, date, unit, today = localDayKey()) {
  const title = entry ? 'Bodyweight · ' + amount(entry.kilograms, unit) : 'No bodyweight reading';
  return `<p>${title}</p>${date <= today ? edit(entry ? 'Edit bodyweight' : 'Log bodyweight', date) : ''}`;
}

function chart(points, unit, format) {
  const values = points.flatMap(point => point.smoothed == null ? [point.kilograms] : [point.kilograms, point.smoothed]);
  const min = Math.min(...values);
  const max = Math.max(...values);
  const rawSpan = max - min;
  const span = dayDistance(points[0].day, points.at(-1).day);
  const x = date => span === 0 ? 150 : 12 + 276 * dayDistance(points[0].day, date) / span;
  const y = value => rawSpan === 0 ? 37 : 65 - (value - min) / rawSpan * 52;
  const smoothed = points.filter(point => point.smoothed != null);
  const line = smoothed.map(point => x(point.day) + ',' + y(point.smoothed)).join(' ');
  return `<div class="bodyweight-chart"><svg viewBox="0 0 300 76" role="img" aria-label="Historical bodyweight, raw readings and smoothed 7-day trend">
    ${smoothed.length ? `<polyline class="bodyweight-line" points="${line}"/>` : ''}
    ${smoothed.map(point => `<circle class="bodyweight-trend-dot" cx="${x(point.day)}" cy="${y(point.smoothed)}" r="2.2"/>`).join('')}
    ${points.map(point => `<circle class="bodyweight-raw-dot" cx="${x(point.day)}" cy="${y(point.kilograms)}" r="3"><title>${html(format(point.day))} · ${amount(point.kilograms, unit)}</title></circle>`).join('')}
    </svg><div class="analytics-axis"><span>${html(format(points[0].day))}</span>${span ? `<span>${html(format(points.at(-1).day))}</span>` : ''}</div>
    <div class="bodyweight-legend"><span>● Raw readings</span><span>━ Smoothed 7-day trend</span></div></div>`;
}

export function renderBodyweight(user, unit, format, today = localDayKey()) {
  const points = bodyweightTrend(Object.values(user.entries), today);
  const latest = points.at(-1);
  const recent = latest ? points.filter(entry => dayDistance(entry.day, latest.day) < 90) : [];
  const rate = user.targetKgPerWeek;
  return `<section class="surface settings-card bodyweight-history" aria-labelledby="bodyweight-history"><h2 id="bodyweight-history">Bodyweight history</h2>
    ${latest ? `${chart(recent, unit, format)}
      <p><strong>Latest reading · ${amount(latest.kilograms, unit)}</strong></p>
      ${latest.smoothed != null ? `<p>Smoothed trend on ${html(format(latest.day))} · ${amount(latest.smoothed, unit)}</p>` : ''}` : '<p>No readings yet</p>'}
    <p class="builder-hint">The smoothed trend is a trailing 7-day average of recorded readings. It appears after two readings in that window and follows historical dates.</p>
    <button type="button" class="secondary" data-action="weight-target">Edit target rate</button>
    ${rate != null ? `<p>Target rate · ${rate > 0 ? '+' : ''}${amount(rate, unit, 3)} per week</p>` : ''}
    <div class="bodyweight-edit-date"><label>Reading date<input type="date" aria-label="Reading date" id="history-weight-date" value="${today}" max="${today}"></label>
      <button type="button" class="secondary" data-action="weight-history">Log or edit reading</button></div>
    ${points.length ? `<details><summary>Raw readings</summary><ul class="active-exercises">${points.slice().reverse().map(point => `<li>
      <div><time datetime="${point.day}">${html(format(point.day))}</time><p>${amount(point.kilograms, unit)}</p>
      ${point.smoothed == null ? '' : `<p class="builder-hint">Smoothed · ${amount(point.smoothed, unit)}</p>`}</div>${edit('Edit reading', point.day)}</li>`).join('')}</ul></details>` : ''}
    </section>`;
}

export function renderWeightTarget(value, unit) {
  const text = value == null ? '' : String(Number(units(value, unit).toFixed(6)));
  return `<form id="weight-target-form" data-original="${text}"><label for="weight-target-input">Target ${unit} per week</label>
    <input id="weight-target-input" type="number" step="any" inputmode="text" value="${text}">
    <p class="builder-hint">Use a negative number for loss, a positive number for gain, or zero for maintenance. Leave it blank to remove the target.</p>
    <div id="weight-target-error" role="alert"></div><button class="primary" type="submit">Save target</button></form>`;
}
