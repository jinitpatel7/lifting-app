import { escapeHTML as html } from './exercises.js';
import { photosOn, readDevicePhoto } from './device-photos.js';

const button = (title, action, value = '') => `<button type="button" class="secondary" data-action="photos-${action}" data-value="${html(value)}">${title}</button>`;
const preview = (link) => `<div class="photo-preview" data-photo-preview="${html(link.id)}"><p>Loading photo</p></div>`;
const privacy = '<p class="builder-hint">Setline stores file links. Your device’s photo-sync settings separately control whether originals are kept in your personal cloud library.</p>';

export function renderPhotoArea(links, day, sessionID, canLink = true) {
  const relevant = photosOn(links, day).filter(link => link.sessionID === sessionID);
  return `<div class="progress-photo-area">${relevant.length ? `<div class="photo-thumbnails">${relevant.map(preview).join('')}</div>` :
    '<p class="builder-hint">No linked progress photos.</p>'}
    ${canLink ? button(sessionID ? 'Link workout photos' : 'Link date photos', 'manage', sessionID ?? day) : ''}
  </div>`;
}

export function renderManagePhotos(links, context, supported) {
  const relevant = photosOn(links, context.day).filter(link => link.sessionID === context.sessionID);
  return `<div class="stack"><p>${html(context.day)}${context.workout ? ' · ' + html(context.workout) : ''}</p>
    ${supported ? button('Choose device photos', 'choose') : '<p>This browser cannot keep links to device photos. Use the iPhone app or a browser with a supported local file picker.</p>'}
    <p class="builder-hint">Use the iPhone app to take a new photo after a workout.</p>
    ${relevant.map(link => `<div class="log-panel photo-manage-card">${preview(link)}<p>${html(link.name)}</p>
      ${context.pendingRemove === link.id ? '<p>Remove this link? The original file stays on your device.</p>' +
        button('Confirm remove link', 'confirm-remove', link.id) + button('Cancel removal', 'cancel-remove') : button('Remove link', 'remove', link.id)}</div>`).join('')}
    ${relevant.length ? '' : '<p class="builder-hint">No linked progress photos.</p>'}
    ${privacy}<p class="builder-hint">Photo content is excluded from Setline exports and sharing.</p>
    <p id="photo-error" class="entry-error" role="alert"></p>
    ${context.returnToFinish ? button('Back to workout summary', 'back-finish', context.sessionID) : ''}
  </div>`;
}

export function renderPhotoComparison(links, context, label) {
  const field = (name, key) => `<label>${name}<input type="date" aria-label="${name}" data-photo-date="${key}" value="${html(context[key])}"></label>`;
  const column = key => {
    const day = context[key];
    const relevant = photosOn(links, day);
    const selected = relevant.find(link => link.id === context[key + 'ID']) ?? relevant[0];
    return `<section class="log-panel photo-compare-side"><h3>${html(label(day))}</h3>
      ${relevant.length > 1 ? `<label>Photo for ${html(day)}<select aria-label="Photo for ${html(day)}" data-photo-choice="${key}">
      ${relevant.map(link => `<option value="${html(link.id)}" ${selected.id === link.id ? 'selected' : ''}>${html(link.name)}</option>`).join('')}</select></label>` : ''}
      ${selected ? preview(selected) : '<p>No linked photos</p>'}</section>`;
  };
  const match = context.first === context.second;
  return `<div class="stack"><div class="builder-fields">${field('First date', 'first')}${field('Second date', 'second')}</div>
    ${match ? '<p>Choose two different dates to compare.</p>' : `<div class="photo-compare-grid">${column('first')}${column('second')}</div>`}
    ${privacy}</div>`;
}

const previewRuns = new WeakMap();
export function cancelPhotoPreviews(root) {
  const prior = previewRuns.get(root);
  if (prior) for (const url of prior.urls) URL.revokeObjectURL(url);
  previewRuns.delete(root);
}

export function paintPhotoPreviews(root, links) {
  cancelPhotoPreviews(root);
  const run = { urls: [] };
  previewRuns.set(root, run);
  for (const node of root.querySelectorAll('[data-photo-preview]')) {
    const link = links.find(link => link.id === node.dataset.photoPreview);
    node.textContent = 'Loading photo';
    readDevicePhoto(link?.handle).then(state => {
      if (!node.isConnected || previewRuns.get(root) !== run) return;
      if (state.state !== 'ready') {
        node.textContent = {
          denied: 'Photo access is off.',
          missing: 'The linked photo was deleted or moved.',
          unavailable: 'The original is unavailable on this device.',
        }[state.state];
        if (state.state === 'denied' && typeof link?.handle?.requestPermission === 'function') {
          const allow = document.createElement('button');
          allow.type = 'button';
          allow.className = 'secondary';
          allow.dataset.action = 'photos-allow';
          allow.dataset.value = link.id;
          allow.textContent = 'Allow photo access';
          node.append(allow);
        }
        return;
      }
      const url = URL.createObjectURL(state.file);
      run.urls.push(url);
      const image = document.createElement('img');
      image.alt = 'Linked progress photo';
      image.addEventListener('error', () => {
        if (image.isConnected) node.textContent = 'Photo preview unavailable.';
      }, { once: true });
      image.src = url;
      node.replaceChildren(image);
    });
  }
}
