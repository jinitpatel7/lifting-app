import { createReadStream } from 'node:fs';
import { stat } from 'node:fs/promises';
import { createServer } from 'node:http';
import { extname } from 'node:path';

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

createServer(async (request, response) => {
  try {
    const pathname = decodeURIComponent(new URL(request.url, 'http://localhost').pathname);
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
    response.writeHead(200, { 'Content-Type': types[extname(path.pathname)] });
    createReadStream(path).pipe(response);
  } catch {
    response.writeHead(404).end();
  }
}).listen(port, '127.0.0.1', () => {
  console.log(`Setline preview at http://127.0.0.1:${port}`);
});
