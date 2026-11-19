import { createReadStream } from 'node:fs';
import { stat } from 'node:fs/promises';
import { createServer } from 'node:http';
import { extname, resolve } from 'node:path';
import { createAccountHandler } from './account-server.mjs';

const types = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.jpg': 'image/jpeg',
  '.png': 'image/png',
  '.webp': 'image/webp',
  '.mp4': 'video/mp4',
  '.mov': 'video/quicktime',
  '.woff2': 'font/woff2',
};
const publicPath = new URL('./', import.meta.url);
const sharedPath = new URL('../ios/Setline/Resources/', import.meta.url);
const port = Number(process.env.PORT || 4173);
let account;

createServer({ requestTimeout: 30_000, headersTimeout: 10_000 }, async (request, response) => {
  try {
    const pathname = decodeURIComponent(new URL(request.url, 'http://localhost').pathname);
    if (pathname.startsWith('/api/')) {
      account ??= createAccountHandler({ directory: resolve(process.env.SETLINE_DATA_DIR ?? '.setline-data'),
        port, publicOrigin: process.env.SETLINE_PUBLIC_ORIGIN, backupKey: process.env.SETLINE_BACKUP_KEY });
      await account(request, response, pathname);
      return;
    }
    if (request.method !== 'GET' && request.method !== 'HEAD') { response.writeHead(405).end(); return; }
    if (pathname !== '/' && !/^\/(?:shared\/)?[a-zA-Z0-9_-]+\.[a-zA-Z0-9]+$/.test(pathname)) {
      response.writeHead(400).end();
      return;
    }
    const path = pathname.startsWith('/shared/')
      ? new URL(pathname.slice('/shared/'.length), sharedPath)
      : new URL(`.${pathname === '/' ? '/index.html' : pathname}`, publicPath);
    if (!types[extname(path.pathname)] || !(await stat(path)).isFile()) {
      response.writeHead(404).end();
      return;
    }
    response.writeHead(200, { 'Content-Type': types[extname(path.pathname)], 'X-Content-Type-Options': 'nosniff',
      'Content-Security-Policy': "default-src 'self'; img-src 'self' blob: data:; style-src 'self' 'unsafe-inline'; object-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'" });
    if (request.method === 'HEAD') { response.end(); return; }
    createReadStream(path).pipe(response);
  } catch {
    response.writeHead(404).end();
  }
}).listen(port, '127.0.0.1', () => {
  console.log(`Setline preview at http://127.0.0.1:${port}`);
});
