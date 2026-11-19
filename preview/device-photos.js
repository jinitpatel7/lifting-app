import { isDay } from './storage.js';

const readOnly = { mode: 'read' };
const storeName = 'links';

export function createDevicePhotoStore(indexedDB, currentScope = () => null) {
  let opened;
  function open() {
    if (!indexedDB) return Promise.reject(new Error('Photo links cannot be stored in this browser.'));
    return opened ??= new Promise((resolve, reject) => {
      const request = indexedDB.open('setline-device-photos-v1', 1);
      request.onupgradeneeded = () => request.result.createObjectStore(storeName, { keyPath: 'id' });
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error);
      request.onblocked = () => reject(new Error('Close other Setline tabs and reopen photo links.'));
    });
  }
  async function transaction(mode, work) {
    const db = await open();
    return new Promise((resolve, reject) => {
      const txn = db.transaction(storeName, mode);
      const result = work(txn.objectStore(storeName));
      txn.oncomplete = () => resolve(result?.result);
      txn.onabort = () => reject(txn.error ?? new Error('The photo link could not be saved.'));
    });
  }
  const list = async () => {
    const links = await transaction('readonly', files => files.getAll());
    return links.filter(link => (link.scope ?? null) === currentScope()).map(({ referenceID, scope, ...link }) =>
      ({ ...link, id: referenceID ?? link.id })).sort((a, b) => a.day.localeCompare(b.day) || a.createdAt.localeCompare(b.createdAt));
  };
  const scoped = (link, scope) => scope ? { ...link, scope, referenceID: link.id, id: `${scope}:${link.id}` } : link;
  return {
    list,
    async link(handles, day, sessionID = null) {
      if (!isDay(day) || !handles.length || !handles.every(handle => handle?.kind === 'file' && typeof handle.getFile === 'function')) {
        throw new Error('Choose a photo file and a valid date.');
      }
      const scope = currentScope();
      const old = (await list()).filter(link => link.day === day && link.sessionID === sessionID);
      const additions = [];
      for (const handle of handles) {
        const duplicate = (await Promise.all([...old, ...additions].map(async link => {
          try { return await link.handle.isSameEntry(handle); } catch { return false; }
        }))).some(Boolean);
        if (!duplicate) additions.push({ id: crypto.randomUUID(), day, sessionID, name: handle.name, handle, createdAt: new Date().toISOString() });
      }
      await transaction('readwrite', files => { for (const link of additions) files.add(scoped(link, scope)); });
      return list();
    },
    async unlink(id) {
      const scope = currentScope();
      await transaction('readwrite', files => files.delete(scope ? `${scope}:${id}` : id));
      return list();
    },
    async stageRestore(references, scope) {
      if (!references.length) return [];
      const original = await list();
      const restored = references.map(link => {
        const prior = original.find(item => item.id === link.id && item.name === link.name && item.createdAt === link.createdAt);
        return prior?.handle ? { ...link, handle: prior.handle } : link;
      });
      await transaction('readwrite', files => { for (const link of restored) files.add(scoped(link, scope)); });
      return restored;
    },
    async discardScope(scope) {
      return transaction('readwrite', files => {
        const cursor = files.openCursor();
        cursor.onsuccess = () => {
          const current = cursor.result;
          if (!current) return;
          if ((current.value.scope ?? null) === scope) current.delete();
          current.continue();
        };
      });
    },
  };
}

export const photosOn = (links, day) => links.filter(link => link.day === day);
export const photoDates = links => [...new Set(links.map(link => link.day))].sort();

export async function readDevicePhoto(handle) {
  if (!handle) return { state: 'missing' };
  try {
    if (typeof handle.queryPermission === 'function') {
      const permission = await handle.queryPermission(readOnly);
      if (permission !== 'granted') return { state: 'denied' };
    }
    const file = await handle.getFile();
    return file.size && (!file.type || file.type.startsWith('image/')) ? { state: 'ready', file } : { state: 'unavailable' };
  } catch (error) {
    if (error.name === 'NotFoundError') return { state: 'missing' };
    if (['NotAllowedError', 'SecurityError'].includes(error.name)) return { state: 'denied' };
    return { state: 'unavailable' };
  }
}

export function requestDevicePhoto(handle) {
  return handle?.requestPermission?.(readOnly) ?? Promise.resolve('denied');
}
