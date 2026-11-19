import { createCipheriv, createDecipheriv, createHash, randomBytes, scrypt, timingSafeEqual } from 'node:crypto';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { promisify } from 'node:util';

const derive = promisify(scrypt);
const backupLimit = 20 * 1024 * 1024;
const sessionLifetime = 8 * 60 * 60 * 1000;
const minute = 60_000;
const passwordSalt = randomBytes(16);
const digest = token => createHash('sha256').update(token).digest();

class HTTPError extends Error {
  constructor(status, message) { super(message); this.status = status; }
}

function answer(response, status, body) {
  response.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' });
  response.end(body === undefined ? undefined : JSON.stringify(body));
}

async function readJSON(request, limit) {
  if (!/^application\/json(?:\s*;|$)/i.test(request.headers['content-type'] ?? '')) throw new HTTPError(415, 'Send JSON data.');
  let size = 0;
  if (Number(request.headers['content-length']) > limit) { request.resume(); throw new HTTPError(413, 'The file is too large.'); }
  const chunks = [];
  for await (const chunk of request.iterator({ destroyOnReturn: false })) {
    size += chunk.length;
    if (size > limit) { request.resume(); throw new HTTPError(413, 'The file is too large.'); }
    chunks.push(chunk);
  }
  try { return JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { throw new HTTPError(400, 'The JSON could not be read.'); }
}

function keyFor(directory, configured) {
  if (configured) {
    if (!/^[a-f0-9]{64}$/i.test(configured)) throw new Error('SETLINE_BACKUP_KEY must be 64 hexadecimal characters.');
    return Buffer.from(configured, 'hex');
  }
  const file = join(directory, 'backup.key');
  try { writeFileSync(file, randomBytes(32), { flag: 'wx', mode: 0o600 }); }
  catch (error) { if (error.code !== 'EEXIST') throw error; }
  const key = readFileSync(file);
  if (key.length !== 32) throw new Error('Account backup key has an invalid length.');
  return key;
}

export function createAccountHandler({ directory, publicOrigin, port, backupKey }) {
  mkdirSync(directory, { recursive: true, mode: 0o700 });
  const key = keyFor(directory, backupKey);
  const db = new DatabaseSync(join(directory, 'accounts.sqlite'));
  db.exec(`PRAGMA foreign_keys = ON; PRAGMA secure_delete = ON;
    CREATE TABLE IF NOT EXISTS accounts (username TEXT PRIMARY KEY, salt BLOB NOT NULL, password_hash BLOB NOT NULL);
    CREATE TABLE IF NOT EXISTS sessions (digest BLOB PRIMARY KEY, username TEXT NOT NULL REFERENCES accounts, expires INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS backups (username TEXT NOT NULL REFERENCES accounts, platform TEXT NOT NULL, saved_at TEXT NOT NULL,
      nonce BLOB NOT NULL, tag BLOB NOT NULL, content BLOB NOT NULL, PRIMARY KEY (username, platform));`);
  const allowedOrigins = new Set([`http://127.0.0.1:${port}`, `http://localhost:${port}`, ...(publicOrigin ? [new URL(publicOrigin).origin] : [])]);
  const attempts = new Map();
  let hashing = 0;

  function throttle(request, username) {
    const now = Date.now();
    for (const [key, value] of attempts) if (value.until <= now) attempts.delete(key);
    const keys = [[`ip:${request.socket.remoteAddress}`, publicOrigin ? 60 : 15], [`user:${username}`, 8]];
    if (attempts.size >= 4096 || hashing >= 2 || keys.some(([key, max]) => (attempts.get(key)?.count ?? 0) >= max)) {
      throw new HTTPError(429, 'Too many sign-in attempts. Wait a few minutes and try again.');
    }
    for (const [key] of keys) {
      const prior = attempts.get(key) ?? { count: 0, until: now + 5 * minute };
      attempts.set(key, { ...prior, count: prior.count + 1 });
    }
  }

  async function login(request, response, registration) {
    const input = await readJSON(request, 4096);
    const username = typeof input?.username === 'string' ? input.username.trim().toLowerCase() : '';
    const password = typeof input?.password === 'string' ? input.password : '';
    if (!/^[a-z0-9][a-z0-9_-]{2,31}$/.test(username) || !password || Buffer.byteLength(password, 'utf8') > 1024) {
      throw new HTTPError(400, 'Use a 3–32 character account name with letters, numbers, hyphens or underscores and a valid password.');
    }
    if (registration && [...password].length < 15) throw new HTTPError(400, 'Use a password of at least 15 characters.');
    throttle(request, username);
    const found = db.prepare('SELECT salt, password_hash FROM accounts WHERE username = ?').get(username);
    const salt = registration ? randomBytes(16) : found?.salt ?? passwordSalt;
    hashing++;
    let hash;
    try { hash = await derive(password, salt, 32, { N: 2 ** 17, r: 8, p: 1, maxmem: 192 * 1024 * 1024 }); }
    finally { hashing--; }
    if (registration) {
      if (!db.prepare('INSERT OR IGNORE INTO accounts VALUES (?, ?, ?)').run(username, salt, hash).changes) {
        throw new HTTPError(409, 'This account name is already in use.');
      }
    } else if (!found || !timingSafeEqual(hash, found.password_hash)) {
      throw new HTTPError(401, 'The account name or password is incorrect.');
    }
    const token = randomBytes(32).toString('base64url');
    const now = Date.now();
    db.prepare('DELETE FROM sessions WHERE expires <= ?').run(now);
    db.prepare('INSERT INTO sessions VALUES (?, ?, ?)').run(digest(token), username, now + sessionLifetime);
    attempts.delete(`user:${username}`);
    answer(response, registration ? 201 : 200, { username, token });
  }

  function account(request) {
    const token = /^Bearer ([a-zA-Z0-9_-]{43})$/.exec(request.headers.authorization ?? '')?.[1];
    const tokenDigest = token && digest(token);
    const user = tokenDigest && db.prepare('SELECT username FROM sessions WHERE digest = ? AND expires > ?').get(tokenDigest, Date.now());
    if (!user) throw new HTTPError(401, 'Sign in to manage account backups.');
    return { username: user.username, tokenDigest };
  }

  async function backup(request, response, username, platform) {
    const associated = Buffer.from(`setline-backup-v1:${username}:${platform}`);
    if (request.method === 'GET') {
      const saved = db.prepare('SELECT * FROM backups WHERE username = ? AND platform = ?').get(username, platform);
      if (!saved) throw new HTTPError(404, 'No backup is saved for this client.');
      const decipher = createDecipheriv('aes-256-gcm', key, saved.nonce);
      decipher.setAAD(associated);
      decipher.setAuthTag(saved.tag);
      const data = Buffer.concat([decipher.update(saved.content), decipher.final()]);
      answer(response, 200, { savedAt: saved.saved_at, backup: JSON.parse(data.toString('utf8')) });
    } else if (request.method === 'PUT') {
      const data = await readJSON(request, backupLimit);
      if (data?.format !== 'setline-backup' || data.version !== 1 || data.platform !== platform || typeof data.createdAt !== 'string' ||
          !data.payload || typeof data.payload !== 'object' || Array.isArray(data.payload)) throw new HTTPError(400, 'Choose a supported Setline backup.');
      const nonce = randomBytes(12), savedAt = new Date().toISOString();
      const cipher = createCipheriv('aes-256-gcm', key, nonce);
      cipher.setAAD(associated);
      const encrypted = Buffer.concat([cipher.update(JSON.stringify(data), 'utf8'), cipher.final()]);
      db.prepare(`INSERT INTO backups VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT (username, platform) DO UPDATE SET
        saved_at = excluded.saved_at, nonce = excluded.nonce, tag = excluded.tag, content = excluded.content`)
        .run(username, platform, savedAt, nonce, cipher.getAuthTag(), encrypted);
      answer(response, 200, { savedAt });
    } else if (request.method === 'DELETE') {
      db.prepare('DELETE FROM backups WHERE username = ? AND platform = ?').run(username, platform);
      answer(response, 204);
    } else throw new HTTPError(405, 'This backup action is unavailable.');
  }

  const handler = async (request, response, path) => {
    try {
      if (request.headers.origin && !allowedOrigins.has(request.headers.origin)) throw new HTTPError(403, 'Open Setline from its configured address.');
      if (request.method === 'POST' && ['/api/account/register', '/api/account/sign-in'].includes(path)) {
        await login(request, response, path.endsWith('/register'));
      } else if (path === '/api/account/sign-out' && request.method === 'POST') {
        const current = account(request);
        db.prepare('DELETE FROM sessions WHERE digest = ?').run(current.tokenDigest);
        answer(response, 204);
      } else {
        const platform = /^\/api\/backup\/(ios|preview)$/.exec(path)?.[1];
        if (!platform) throw new HTTPError(404, 'This account action is unavailable.');
        const current = account(request);
        await backup(request, response, current.username, platform);
      }
    } catch (error) {
      if (!response.headersSent) answer(response, error.status ?? 500, { error: error.status ? error.message : 'The account service could not complete the request.' });
    }
  };
  handler.close = () => db.close();
  return handler;
}
