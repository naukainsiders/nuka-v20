import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const baseDir = path.dirname(fileURLToPath(import.meta.url));
const port = Number(process.env.PORT || 8080);
const contentTypes = {
  '.html': 'text/html; charset=utf-8',
  '.htm': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8',
  '.mjs': 'application/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.svg': 'image/svg+xml'
};

const server = http.createServer((request, response) => {
  try {
    const pathname = decodeURIComponent(new URL(request.url || '/', `http://${request.headers.host || '127.0.0.1'}`).pathname);
    const relativePath = pathname === '/' ? 'index.html' : pathname.replace(/^\/+/, '');
    const filePath = path.resolve(baseDir, relativePath);
    if (filePath !== baseDir && !filePath.startsWith(`${baseDir}${path.sep}`)) {
      response.writeHead(400, { 'Content-Type':'text/plain; charset=utf-8' });
      response.end('Bad request');
      return;
    }
    if (!fs.existsSync(filePath) || !fs.statSync(filePath).isFile()) {
      response.writeHead(404, { 'Content-Type':'text/plain; charset=utf-8' });
      response.end('Not Found');
      return;
    }
    response.writeHead(200, {
      'Content-Type': contentTypes[path.extname(filePath).toLowerCase()] || 'application/octet-stream',
      'Access-Control-Allow-Origin': '*'
    });
    fs.createReadStream(filePath).pipe(response);
  } catch (error) {
    response.writeHead(500, { 'Content-Type':'text/plain; charset=utf-8' });
    response.end('Internal server error');
  }
});

server.listen(port, '127.0.0.1', () => {
  console.log(`HTTP server listening on http://127.0.0.1:${port}/`);
});
