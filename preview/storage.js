const legacyKey = 'setline-preview-v1';
const userKey = 'setline-user-weights-v2';
const sampleKey = 'setline-sample-preview-v1';
const preferencesKey = 'setline-preferences-v1';

export const kilogramsPerPound = 0.45359237;

export function localDayKey(date = new Date(), timeZone) {
  if (timeZone) {
    const parts = new Intl.DateTimeFormat('en', { timeZone, year: 'numeric', month: '2-digit', day: '2-digit' }).formatToParts(date);
    return ['year', 'month', 'day'].map(key => parts.find(part => part.type === key).value).join('-');
  }
  const month = String(date.getMonth() + 1).padStart(2, '0');
  const day = String(date.getDate()).padStart(2, '0');
  return `${date.getFullYear()}-${month}-${day}`;
}

export function createBrowserStore(storage) {
  const read = key => {
    const raw = storage.getItem(key);
    return raw === null ? null : JSON.parse(raw);
  };
  const write = (key, value) => storage.setItem(key, JSON.stringify(value));
  const legacy = () => read(legacyKey) ?? {};

  function loadUser() {
    const stored = read(userKey);
    if (stored) {
      if (stored.schemaVersion !== 2 || !isRecord(stored.entries)) {
        throw new Error('Unsupported bodyweight storage');
      }
      for (const [day, entry] of Object.entries(stored.entries)) {
        if (!isDay(day) || entry?.day !== day || typeof entry.id !== 'string' || !validWeight(entry.kilograms)) {
          throw new Error('Invalid stored bodyweight entry');
        }
      }
      return stored;
    }
    const entries = {};
    const migratedAt = new Date().toISOString();
    for (const [day, kilograms] of Object.entries(legacy().weights ?? {})) {
      if (!isDay(day) || !validWeight(kilograms)) throw new Error('Invalid legacy bodyweight entry');
      entries[day] = { id: crypto.randomUUID(), day, kilograms, createdAt: migratedAt, updatedAt: migratedAt };
    }
    const user = { schemaVersion: 2, entries };
    if (Object.keys(entries).length) write(userKey, user);
    return user;
  }

  function loadSample() {
    const stored = read(sampleKey);
    if (!stored) return { weights: {}, active: legacy().active ?? null };
    if (!isRecord(stored.weights)) throw new Error('Invalid sample storage');
    return stored;
  }

  return {
    loadUser,
    loadSample,
    loadPreferences: () => {
      const { appearance, opaque, unit } = read(preferencesKey) ?? legacy();
      return { appearance, opaque, unit };
    },
    savePreferences: preferences => write(preferencesKey, preferences),
    saveSample: sample => {
      loadSample();
      write(sampleKey, sample);
    },
    saveWeight: (day, kilograms) => {
      if (!isDay(day) || !validWeight(kilograms)) throw new Error('Invalid bodyweight entry');
      const user = loadUser();
      const timestamp = new Date().toISOString();
      const entry = user.entries[day] ?? { id: crypto.randomUUID(), day, createdAt: timestamp };
      user.entries[day] = { ...entry, kilograms, updatedAt: timestamp };
      write(userKey, user);
      return user;
    },
    saveWeightTarget: kilogramsPerWeek => {
      if (kilogramsPerWeek != null && !Number.isFinite(kilogramsPerWeek)) throw new Error('Enter a valid weekly rate of change.');
      const user = loadUser();
      if (kilogramsPerWeek == null) delete user.targetKgPerWeek;
      else user.targetKgPerWeek = kilogramsPerWeek;
      write(userKey, user);
      return user;
    },
  };
}

function validWeight(kilograms) { return Number.isFinite(kilograms) && kilograms > 0; }
function isRecord(value) { return value !== null && typeof value === 'object' && !Array.isArray(value); }

export function isDay(key) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(key)) return false;
  const date = new Date(`${key}T12:00:00Z`);
  return Number.isFinite(date.valueOf()) && date.toISOString().slice(0, 10) === key;
}
