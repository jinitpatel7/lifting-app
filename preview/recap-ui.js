import { escapeHTML as html } from './exercises.js';
import { programContext } from './analytics.js';
import { renderForecastPreview } from './forecast-ui.js';
import { dayOf } from './history.js';
import { renderPlan } from './routine-ui.js';
import { offsetDay } from './schedule.js';
import { kilogramsPerPound } from './storage.js';
import { energyActivities, energyReference, energySource, workoutEnergy } from './workout-energy.js';

const format = (value, maximumFractionDigits = 2) => new Intl.NumberFormat(undefined, { maximumFractionDigits }).format(value);
const displayMass = (kg, unit) => format(unit === 'lb' ? kg / kilogramsPerPound : kg);
const units = { reps: 'reps', duration: 's', distance: 'm' };
const isMass = metric => ['weight', 'added', 'assistance'].includes(metric);
const quantity = (metric, value, unit) => `${isMass(metric) ? displayMass(value, unit) : format(value)} ${units[metric] ?? unit}`;
const metrics = { weight: 'Load', added: 'Added load', assistance: 'Assistance', reps: 'Reps', duration: 'Duration', distance: 'Distance' };
const sourceLinks = `<a href="${energySource}" target="_blank" rel="noreferrer">Adult Compendium activity table</a> · <a href="${energyReference}" target="_blank" rel="noreferrer">MET definition</a>`;

export function renderScore(assessment) {
  if (assessment.status === 'unavailable') return `<p class="builder-hint workout-score">${html(assessment.reason)}</p>`;
  const title = assessment.summary;
  return `<details class="surface settings-card workout-score"><summary>${html(title)}</summary><div class="stack recap-content">
    <dl>${assessment.components.map(component => `<div><dt>${html(component.name)}</dt><dd>${component.points == null ? 'Unavailable' :
      `${format(component.points, 1)} / ${format(component.weight * 100, 1)} points`} · ${html(component.detail)}</dd></div>`).join('')}</dl>
    <p class="builder-hint">Available weights are normalized. Each set’s lowest target credit counts. Effort earns full credit within one point and tapers to zero at four points.</p>
    </div></details>`;
}

export function renderWeeklyRecap(report, database, unit, today, names, dateLabel) {
  const { jobs, training, records, changes, weight, energy, next, first, last, deloads } = report;
  const title = `${dateLabel(first)} – ${dateLabel(last)}`;
  const statuses = [[jobs.pending, 'upcoming'], [jobs.missed, 'missed'], [jobs.skipped, 'skipped'],
    [jobs.scheduledIncomplete, 'scheduled with incomplete logs']].filter(([count]) => count).map(([count, label]) => `${count} ${label}`);
  const volume = training.totals.volume;
  const nextDeload = next && programContext(database, { localDate: next.entry.date, scheduleID: next.entry.id }).kind === 'deload';
  const goal = next ? `<div class="stack"><p><strong>${html(next.plan.name)}</strong> · ${html(dateLabel(next.entry.date))}${nextDeload ? ' · Planned deload' : ''}</p>
    <div><h4>Planned targets · Version ${next.plan.revision}</h4>${renderPlan(next.plan, unit)}</div>
    ${renderForecastPreview(database, next.plan, next.entry, unit, dateLabel)}</div>` : '<p>No upcoming session scheduled.</p>';
  return `<section class="surface settings-card weekly-recap" aria-labelledby="weekly-recap-title"><div class="section-top"><h2 id="weekly-recap-title">Weekly recap</h2></div>
    <p class="builder-hint">${html(title)}${today <= last ? ' · In progress' : ''}</p>
    <div class="builder-actions"><button class="secondary" type="button" data-action="recap-week" data-value="-7">Previous recap week</button>
      <button class="secondary" type="button" data-action="recap-week" data-value="7" ${offsetDay(first, 7) > today ? 'disabled' : ''}>Next recap week</button></div>
    <div class="recap-stats"><div><span>Scheduled sessions</span><strong>${jobs.scheduled} of ${jobs.planned} completed</strong>
      ${statuses.length ? `<small>${statuses.join(' · ')}</small>` : ''}</div>
      <div><span>Unscheduled sessions</span><strong>${jobs.unscheduled} completed</strong></div>
      <div><span>Working-set volume</span><strong>${volume == null ? 'Unavailable' : displayMass(volume, unit) + ' ' + unit + '·reps'}</strong><small>External and added load outside machine and cable work</small></div>
      <div><span>Bodyweight trend</span><strong>${weight.latest ? displayMass(weight.latest.smoothed, unit) + ' ' + unit : 'Unavailable'}</strong>
      <small>${weight.latest ? `7-day average on ${html(dateLabel(weight.latest.day))}` : `${weight.count} readings this week`}
      ${weight.initial ? ` · ${weight.latest.smoothed >= weight.initial.smoothed ? '+' : ''}${displayMass(weight.latest.smoothed - weight.initial.smoothed, unit)} ${unit} vs ${html(dateLabel(weight.initial.day))}` : ''}</small></div></div>
    ${jobs.deload ? `<p class="recap-context">${jobs.deload} scheduled ${jobs.deload === 1 ? 'session is' : 'sessions are'} in a planned deload.</p>` : ''}
    ${deloads.length ? `<p class="builder-hint">Deload programs this week · ${html(deloads.join(', '))}</p>` : ''}
    ${jobs.incomplete ? `<p class="builder-hint">${jobs.incomplete} ${jobs.incomplete === 1 ? 'incomplete log' : 'incomplete logs'} this week. Logged sets contribute to volume and muscle coverage. Unlogged work stays unknown.</p>` : ''}
    <details class="recap-disclosure"><summary>Personal records and comparable changes</summary><div class="stack recap-content">
      <h3>Personal records</h3>${records.length ? `<ul>${records.map(record => `<li><strong>${html(record.name)} · ${html(record.equipment)}</strong>
        <span>${html(record.kind)} · ${record.effort ? `${displayMass(record.effort.load, unit)} ${unit}${record.perDumbbell ? ' per dumbbell' : ''} × ${record.effort.reps}${record.effort.side ? ` (${record.effort.side})` : ''}` : quantity(record.metric, record.value, unit)} · ${html(dateLabel(record.date))}</span></li>`).join('')}</ul>` : '<p>No new records with an earlier comparison.</p>'}
      <h3>Comparable performance changes</h3><p class="builder-hint">First straight working sets on the same setup and in similar exercise order. Deloads stay outside these comparisons.</p>
      ${changes.length ? `<ul>${changes.map(change => `<li><strong>${html(change.name)} · ${html(change.equipment)}${change.setting ? ' · Setting ' + html(change.setting) : ''}</strong>
        <span>${html(dateLabel(change.previous.day))} → ${html(dateLabel(change.current.day))}</span>${Object.keys(change.current.values).map(metric => `<span>${metrics[metric]} · ${quantity(metric, change.previous.values[metric], unit)} → ${quantity(metric, change.current.values[metric], unit)}${metric === 'weight' && change.basis === 'perDumbbell' ? ' per dumbbell' : ''}${metric === 'reps' && change.counting !== 'total' ? ' per side' : ''}</span>`).join('')}</li>`).join('')}</ul>` : '<p>No comparable performance changes recorded.</p>'}</div></details>
    <details class="recap-disclosure"><summary>Muscle coverage</summary><div class="recap-content stack"><p class="builder-hint">Logged sets by muscle and role</p>
      ${training.muscles.size ? `<div class="recap-table"><table><thead><tr><th scope="col">Muscle</th><th scope="col">Direct work</th><th scope="col">Indirect work</th><th scope="col">Direct warm-up</th><th scope="col">Indirect warm-up</th></tr></thead><tbody>
      ${[...training.muscles].sort(([a], [b]) => (names[a] ?? a).localeCompare(names[b] ?? b)).map(([id, count]) => `<tr><th scope="row">${html(names[id] ?? id)}</th>
      <td>${count.working.direct}</td><td>${count.working.indirect}</td><td>${count['warm-up'].direct}</td><td>${count['warm-up'].indirect}</td></tr>`).join('')}</tbody></table></div>` : '<p>No muscle coverage logged.</p>'}</div></details>
    <details class="recap-disclosure"><summary>Next scheduled workout</summary><div class="stack recap-content"><p class="builder-hint">Upcoming from today’s schedule.</p>${goal}</div></details>
    <div class="recap-energy"><strong>${energy.count ? `Estimated gross calories · ${format(energy.total, 0)} kcal` : 'Calories unavailable'}</strong>
      <p class="builder-hint">${energy.count ? `${energy.count} of ${energy.eligible} logged workouts have enough inputs. The total covers those workouts.` : 'Requires calorie inputs for a finished workout and a weigh-in on its date.'}</p></div></section>`;
}

export function renderSessionEnergy(session, entries = {}) {
  const kilograms = entries[dayOf(session)]?.kilograms;
  const estimate = session.completedAt && session.results.length ? workoutEnergy(session.energyInput, kilograms) : null;
  return `<div class="session-energy"><strong>${estimate ? `Estimated gross calories · ${format(estimate.kilocalories, 0)} kcal` : 'Calories unavailable'}</strong>
    ${session.completedAt && session.results.length ? `<button type="button" class="secondary" data-action="energy-edit" data-value="${html(session.id)}">Calorie inputs</button>` : ''}</div>`;
}

export function renderEnergyEditor(session, entries, dateLabel) {
  const input = session.energyInput;
  const day = dayOf(session);
  const weight = entries[day]?.kilograms;
  const estimate = workoutEnergy(input, weight);
  return `<form id="energy-form" class="stack"><p class="dialog-description">${html(dateLabel(day))} · ${weight ? `${displayMass(weight, 'kg')} kg recorded bodyweight` : 'No bodyweight reading on this date'}</p>
    <label>Activity category<select name="activity" aria-label="Activity category"><option value="">Choose a matching activity</option>
      ${Object.entries(energyActivities).map(([key, activity]) => `<option value="${key}" ${input?.activity === key ? 'selected' : ''}>${html(activity.title)} · ${activity.met} MET</option>`).join('')}</select></label>
    <label>Activity minutes<input name="minutes" aria-label="Activity minutes" inputmode="decimal" value="${input?.minutes ?? ''}"></label>
    <p class="builder-hint">Enter minutes for the selected activity. Leave out unrelated activity and extended idle time.</p>
    <p><strong>${estimate ? `Estimated gross calories · ${format(estimate.kilocalories, 0)} kcal` : 'Calories unavailable'}</strong></p>
    <details><summary>Estimation method and assumptions</summary><div class="stack recap-content"><p>Estimated kcal = MET × bodyweight in kg × activity hours. This uses the standard approximation of 1 kcal per kg per hour for 1 MET.</p>
      <p>Gross calories include energy at rest during the entered time. Adult Compendium values are population estimates. Actual energy use varies.</p><p>${sourceLinks}</p></div></details>
    <p id="energy-error" class="entry-error" role="alert"></p><div class="builder-actions"><button class="primary" type="submit">Save calorie inputs</button>
    ${input ? '<button class="secondary" type="button" data-action="energy-clear">Clear inputs</button>' : ''}</div></form>`;
}
