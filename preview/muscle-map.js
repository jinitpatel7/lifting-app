import { escapeHTML } from './exercises.js';

export function muscleInvolvement(exercises) {
  const primary = new Set(exercises.flatMap(exercise => exercise.primary ?? []));
  const secondary = new Set(exercises.flatMap(exercise => exercise.secondary ?? []).filter(group => !primary.has(group)));
  return { primary, secondary };
}

function polygons(part) {
  const points = mirror => part.points.map(([x, y]) => `${mirror ? 120 - x : x},${y}`).join(' ');
  const polygon = mirror => `<polygon points="${points(mirror)}"/>`;
  return polygon(false) + (part.mirror ? polygon(true) : '');
}

export function renderMuscleMap(anatomy, involvement, selected) {
  if (!anatomy) return '<section class="surface muscle-card"><h2>Muscle map</h2><p>Muscle diagram unavailable</p></section>';
  const { primary, secondary } = involvement;
  const role = group => primary.has(group) ? 'primary' : secondary.has(group) ? 'secondary' : '';
  const region = anatomy.regions[selected];
  const list = groups => [...groups].map(group => anatomy.regions[group]?.name).filter(Boolean).join(', ');
  const figure = (side, label) => `<figure class="atlas-figure">
    <svg viewBox="0 0 120 236" role="group" aria-label="${label} muscle diagram">
      <g class="atlas-neutral" aria-hidden="true">${anatomy.neutral.map(polygons).join('')}</g>
      ${anatomy[side].map(part => {
        const name = anatomy.regions[part.group]?.name;
        const emphasis = role(part.group);
        return `<g class="atlas-region ${emphasis}" tabindex="0" role="button" aria-pressed="${part.group === selected}"
          aria-label="${escapeHTML(`${label}: ${name}${emphasis ? `, ${emphasis}` : ''}`)}"
          data-muscle-region="${part.group}" data-muscle-side="${side}">${polygons(part)}</g>`;
      }).join('')}
    </svg><figcaption>${label}</figcaption></figure>`;
  return `<section class="surface muscle-card" aria-labelledby="muscle-title">
    <div class="section-top"><h2 id="muscle-title">Muscle map</h2></div>
    <div class="anatomy-atlas">${figure('front', 'Front')}${figure('back', 'Back')}</div>
    <div class="muscle-key">
      <div><span class="key-dot primary-dot"></span><div><strong>Primary</strong>${primary.size ? `<span>${escapeHTML(list(primary))}</span>` : ''}</div></div>
      <div><span class="key-dot secondary-dot"></span><div><strong>Secondary</strong>${secondary.size ? `<span>${escapeHTML(list(secondary))}</span>` : ''}</div></div>
    </div>
    ${primary.size || secondary.size ? '' : '<p class="map-empty">No planned muscle targets</p>'}
    <label class="map-picker">Select muscle region<select id="muscle-region-picker" aria-label="Select muscle region">
      <option value="">Choose a region</option>${Object.entries(anatomy.regions).map(([key, item]) => `<option value="${key}" ${key === selected ? 'selected' : ''}>${escapeHTML(item.name)}</option>`).join('')}
    </select></label>
    ${region ? `<div class="map-selection" aria-live="polite"><h3>${escapeHTML(region.name)}</h3>
      <p>${escapeHTML(region.muscles.join(' · '))}</p>
      ${role(selected) ? `<p class="map-role">${role(selected)} involvement</p>` : ''}
      <button type="button" class="secondary" data-action="exercise-library" data-value="${selected}">Browse ${escapeHTML(region.name.toLowerCase())} exercises</button>
    </div>` : ''}
  </section>`;
}
