import { createAccountClient } from './account-client.js';
import { escapeHTML as html } from './exercises.js';
import { dayOf, sessionMetrics, sessionStatus } from './history.js';
import { addImportedRoutine, backupDefaults, bodyweightCSV, dataFileLimit, makeBackup, parseDataFile, routineFile,
  shareDefaults, validateBackup, validateRoutine, workoutsCSV } from './portability.js';
import { renderPlan } from './routine-ui.js';
import { kilogramsPerPound } from './storage.js';
import { sessionPlan } from './workout-log.js';
import { resultSummary } from './workout-ui.js';

const button = (label, action, type = 'secondary') => `<button type="button" class="${type}" data-action="data-${action}">${label}</button>`;
const alert = '<p class="entry-error" id="data-error" role="alert"></p>';
const refHelp = 'Photo files are excluded. Optional device references may be unavailable on another device or if access to the original changes.';
const option = (name, label, selected) => `<label class="builder-check"><input type="checkbox" name="${name}" ${selected ? 'checked' : ''}>${label}</label>`;
const options = (values, names) => Object.entries(names).map(([key, label]) => option(key, label, values[key])).join('');
const backupLabels = { notes: 'Include personal notes and setup details', bodyweight: 'Include bodyweight and its target', readiness: 'Include readiness check-ins', forecasts: 'Include saved forecasts', photos: 'Include device photo references' };
const shareLabels = { sets: 'Include performed sets', notes: 'Include personal notes', bodyweight: 'Include same-day bodyweight', effort: 'Include actual effort' };
const pretty = object => JSON.stringify(object, null, 2);
function exportJSON(filename, document) {
  const content = pretty(document);
  if (new TextEncoder().encode(content).length > dataFileLimit) throw new Error('The file exceeds the 20 MB limit.');
  download(filename, content, 'application/json');
}

function download(filename, content, mime) {
  const url = URL.createObjectURL(new Blob([content], { type: mime }));
  const link = document.createElement('a');
  link.href = url;
  link.download = filename;
  link.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

function workoutSummary(session, weights, unit, includes) {
  const plan = sessionPlan(session);
  const metrics = sessionMetrics(session);
  const formatMass = kg => new Intl.NumberFormat(undefined, { maximumFractionDigits: 2 }).format(unit === 'lb' ? kg / kilogramsPerPound : kg);
  const lines = [`${plan.name} · ${dayOf(session)}`, `${sessionStatus(session)} · ${metrics.count} performed sets`];
  if (metrics.duration != null) lines.push(`Duration · ${Math.round(metrics.duration / 60)} min`);
  if (metrics.volume != null) lines.push(`Logged volume · ${formatMass(metrics.volume)} ${unit}·reps`);
  const weight = weights.entries[dayOf(session)]?.kilograms;
  if (includes.bodyweight && weight) lines.push(`Bodyweight · ${formatMass(weight)} ${unit}`);
  if (includes.notes && session.log?.notes?.trim()) lines.push(`Workout notes · ${session.log.notes.trim()}`);
  for (const row of plan.exercises) {
    const results = session.results.filter(result => result.exerciseID === row.id);
    const notes = includes.notes && session.log?.exercises.find(item => item.id === row.id)?.notes?.trim();
    if (!(includes.sets && results.length) && !notes) continue;
    lines.push('', row.exercise.name);
    if (includes.sets) for (const set of results) {
      const result = includes.effort ? set : { ...set, rir: null, rpe: null, failure: false };
      const purpose = set.purpose === 'warm-up' ? 'Warm-up' : 'Set';
      lines.push(`${purpose} ${set.order ?? results.indexOf(set) + 1} · ${resultSummary(result, row, unit)}`);
    }
    if (notes) lines.push(`Exercise notes · ${notes}`);
  }
  return lines.join('\n');
}

export function createPortabilityUI({ dialog, show, storage, photos, read, refresh, lookup, catalog, announce }) {
  const account = createAccountClient();
  let panel, selection, pending, trigger;
  let busy = false;
  const status = message => { const element = dialog.querySelector('#data-error'); if (element) element.textContent = message; };
  const present = (title, content) => show('portability', title, `<div class="data-panel stack">${content}${alert}</div>`, trigger);
  const get = (...names) => Object.fromEntries(names.map(key => [key, dialog.querySelector(`input[name="${key}"]`)?.checked === true]));
  const profile = () => read();

  function exportPanel() {
    panel = 'export';
    present('Data portability', `<p>Download files or import a Setline backup or routine. The files you save can contain training data.</p>
      <fieldset class="stack"><legend>Full backup options</legend>${options(backupDefaults, backupLabels)}</fieldset><p class="builder-hint">${refHelp}</p>
      ${button('Download full backup', 'backup-export', 'primary')}
      <fieldset class="stack"><legend>Workout CSV options</legend>${option('csvNotes', 'Include personal notes', false)}${option('csvEffort', 'Include actual effort', false)}</fieldset>
      <p class="builder-hint">CSV uses kilograms, seconds and meters. The bodyweight CSV is a separate file.</p>
      <div class="builder-actions">${button('Download workout CSV', 'workouts-csv')}${button('Download bodyweight CSV', 'weight-csv')}</div>
      <label class="data-file">Choose backup or routine file<input type="file" id="data-import-file" accept=".json,application/json"></label>`);
  }

  function accountPanel(message = '') {
    panel = 'account';
    present('Account storage', `<p>Account storage is optional. Records stay local until you choose to save a backup to your account.</p>
      ${account.username() ? `<p><strong>Signed in as ${html(account.username())}</strong></p>
        <fieldset class="stack"><legend>Account backup options</legend>${options(backupDefaults, backupLabels)}</fieldset><p class="builder-hint">${refHelp}</p>
        ${button('Review account save', 'account-review', 'primary')}${button('Get account backup', 'account-get')}
        <div class="builder-actions">${button('Delete account backup', 'account-review-delete')}${button('Sign out', 'account-logout')}</div>` :
      `<form id="data-account-form" class="stack">
        <label>Account name<input autocomplete="username" name="username" required minlength="3" maxlength="32" autocapitalize="off"></label>
        <label>Password<input autocomplete="current-password" type="password" name="password" required maxlength="256"></label>
        <p class="builder-hint">New accounts require a password of at least 15 characters.</p>
        <div class="builder-actions"><button class="primary" type="submit" value="sign-in">Sign in</button><button class="secondary" type="submit" value="register">Create account</button></div></form>`}
      ${message ? `<p role="status">${html(message)}</p>` : ''}`);
  }

  function routinePanel(notes = false) {
    panel = 'routine-share';
    const file = routineFile(selection, notes, lookup);
    present('Share routine', `<p>Review the exercises and targets before sharing. The routine file excludes workout history, bodyweight, and photos.</p>
      ${option('notes', 'Include exercise setup and technique notes', notes)}<div class="data-preview"><h3>${html(file.name)}</h3>
      ${renderPlan(file, profile().preferences.unit)}<div data-routine-notes ${notes ? '' : 'hidden'}>${routineNotes(selection)}</div></div>${button('Download routine file', 'routine-export', 'primary')}`);
  }

  function routineNotes(version) {
    return routineFile(version, true, lookup).exercises.map(({ exercise }) => {
      const details = [exercise.setup, exercise.cues, ...Object.values(exercise.machineSetup ?? {})].filter(Boolean);
      return details.length ? `<p><strong>${html(exercise.name)}</strong><br>${details.map(html).join('<br>')}</p>` : '';
    }).join('');
  }

  function summaryPanel(includes = shareDefaults) {
    panel = 'summary';
    const local = profile();
    const preview = workoutSummary(selection, local.weights, local.preferences.unit, includes);
    present('Share workout summary', `<p>Only the text in this preview is shared. Photo files and photo references are excluded.</p>
      <fieldset class="stack"><legend>Summary details</legend>${options(includes, shareLabels)}</fieldset>
      <pre class="data-preview" id="data-summary-preview">${html(preview)}</pre><div class="builder-actions">${button('Copy summary', 'summary-copy', 'primary')}${button('Download summary', 'summary-export')}</div>`);
  }

  function reviewImport(file, label) {
    if (file?.format === 'setline-routine') {
      validateRoutine(file);
      pending = file;
      panel = 'routine-import';
      present('Review routine import', `<div class="data-preview"><h3>${html(file.name)}</h3>${renderPlan(file, profile().preferences.unit)}</div>
        <p>Import creates a separate routine. An identical current routine will be kept as a single copy.</p>${button('Import routine', 'routine-import', 'primary')}${button('Back to local files', 'open')}`);
      return;
    }
    const data = validateBackup(file);
    pending = data;
    panel = 'restore';
    const local = profile();
    present('Review backup restore', `<p>${html(label)} · ${html(new Date(file.createdAt).toLocaleString())}</p>
      <p>${data.plans.routines.length} routines · ${data.plans.sessions.length} workouts · ${Object.keys(data.weights.entries).length} weigh-ins · ${data.photos.length} photo references</p>
      <p>Restore replaces your local records and settings, including ${local.plans.sessions.length} workouts currently on this device.</p>
      ${local.plans.sessions.some(session => !session.completedAt) ? '<p><strong>An active local workout will be replaced.</strong></p>' : ''}
      <p class="builder-hint">${refHelp}</p>${button('Replace local data', 'restore', 'primary')}${button('Back to local files', 'open')}`);
  }

  async function restore() {
    const old = storage.photoScope(), scope = crypto.randomUUID();
    try {
      await photos.stageRestore(pending.photos, scope);
      storage.replace(pending, scope);
    } catch (error) {
      await photos.discardScope(scope).catch(() => {});
      throw error;
    }
    await photos.discardScope(old).catch(() => {});
    await refresh();
    dialog.close();
    announce('Backup restored.');
  }

  function backup() { return makeBackup(profile(), get(...Object.keys(backupDefaults))); }

  async function action(name, value, focus) {
    if (busy) return;
    if (!dialog.open || !panel) trigger = focus;
    busy = true;
    try {
      switch (name) {
        case 'open': return exportPanel();
        case 'account': return accountPanel();
        case 'routine': selection = profile().plans.routines.find(item => item.id === value)?.versions.at(-1); if (selection) routinePanel(); return;
        case 'summary': selection = profile().plans.sessions.find(item => item.id === value && item.completedAt); if (selection) summaryPanel(); return;
        case 'backup-export': return exportJSON('setline-backup.json', backup());
        case 'workouts-csv': return download('setline-workouts.csv', workoutsCSV(profile().plans, { notes: get('csvNotes').csvNotes, effort: get('csvEffort').csvEffort }), 'text/csv');
        case 'weight-csv': return download('setline-bodyweight.csv', bodyweightCSV(profile().weights), 'text/csv');
        case 'routine-export': return exportJSON('setline-routine.json', routineFile(selection, get('notes').notes, lookup));
        case 'summary-copy': await navigator.clipboard.writeText(dialog.querySelector('#data-summary-preview').textContent); announce('Summary copied.'); return;
        case 'summary-export': return download('setline-workout-summary.txt', dialog.querySelector('#data-summary-preview').textContent, 'text/plain');
        case 'routine-import': {
          const local = profile();
          const result = addImportedRoutine(pending, local.plans, local.library, catalog);
          if (!result) { status('An identical routine is already saved.'); return; }
          storage.importRoutine(result);
          await refresh();
          dialog.close();
          announce('Routine imported.');
          return;
        }
        case 'restore': return await restore();
        case 'account-logout': await account.logout(); if (dialog.open) accountPanel('Signed out.'); return;
        case 'account-review': {
          pending = backup();
          const selected = get(...Object.keys(backupDefaults));
          panel = 'account-upload';
          present('Review account save', `<p>Save ${pending.payload.plans.sessions.length} workouts and ${pending.payload.plans.routines.length} routines to ${html(account.username())}.</p>
            <p>Optional details · ${Object.keys(selected).filter(name => selected[name]).map(name => html(backupLabels[name])).join(', ') || 'None selected'}</p>
            <p>This replaces the prior browser backup in this account.</p>${button('Save to account', 'account-save', 'primary')}${button('Back to account', 'account')}`);
          return;
        }
        case 'account-save': await account.save(pending); pending = null; if (dialog.open) accountPanel('Backup saved.'); return;
        case 'account-get': {
          const saved = await account.load();
          if (dialog.open) reviewImport(saved.backup, `Account backup saved ${new Date(saved.savedAt).toLocaleString()}`);
          return;
        }
        case 'account-review-delete':
          panel = 'account-delete';
          return present('Delete account backup', `<p>Delete the saved browser backup from ${html(account.username())}. Local records stay on this device.</p>
            ${button('Confirm delete backup', 'account-delete', 'primary')}${button('Back to account', 'account')}`);
        case 'account-delete': await account.remove(); if (dialog.open) accountPanel('Account backup deleted.'); return;
      }
    } catch (error) { status(error.message); }
    finally { busy = false; }
  }

  return {
    action,
    async change(event) {
      if (busy) return;
      const field = event.target;
      if (panel === 'export' && field.id === 'data-import-file' && field.files[0]) {
        busy = true;
        try {
          const file = field.files[0];
          if (file.size > dataFileLimit) throw new Error('Choose a file up to 20 MB.');
          const source = await file.text();
          if (dialog.open) reviewImport(parseDataFile(source), file.name);
        } catch (error) { status(error.message); field.value = ''; }
        finally { busy = false; }
      } else if (panel === 'summary' && field.type === 'checkbox') {
        dialog.querySelector('#data-summary-preview').textContent = workoutSummary(selection, profile().weights, profile().preferences.unit, get(...Object.keys(shareDefaults)));
      } else if (panel === 'routine-share' && field.name === 'notes') {
        dialog.querySelector('[data-routine-notes]').hidden = !field.checked;
      }
    },
    async submit(event) {
      if (event.target.id !== 'data-account-form') return;
      event.preventDefault();
      if (busy) return;
      busy = true;
      try {
        const values = new FormData(event.target);
        await account.login(values.get('username'), values.get('password'), event.submitter?.value === 'register');
        if (dialog.open) accountPanel('Signed in.');
      } catch (error) { status(error.message); }
      finally { busy = false; }
    },
    closed() { panel = selection = pending = trigger = null; },
  };
}
