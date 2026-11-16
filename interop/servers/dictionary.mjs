// RFC 9842's server side in Node, for the mttp client's dictionary cases:
// Node's zlib codes the page with the dictionary (brotli and zstd both take
// a raw `dictionary`, which `brotli -D` and `zstd -D` read as well). No
// dependencies; interop/images.tsv pins the node image. interop/run.mbtx
// starts it on 39060 (http) and 39061 (https, the suite's certificate).
//
//   GET /dict/dictionary          interop/pattern's dictionary, with
//                                 Use-As-Dictionary (match /dict/*, id
//                                 interop-1) and a lifetime
//   GET /dict/page?coding=dcb|dcz the page, coded with the dictionary when
//                                 the request offers it as RFC 9842 asks
//                                 (Available-Dictionary with its SHA-256,
//                                 Dictionary-ID, the coding in
//                                 Accept-Encoding); otherwise plain. X-Coded
//                                 says which, X-Why why not, and
//                                 X-Page-Digest is the plain page's digest.

import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import http from 'node:http';
import https from 'node:https';
import zlib from 'node:zlib';

// interop/pattern's text and Digest.
function text(n) {
  const lines = [];
  let length = 0;
  for (let line = 1; length < n; line++) {
    const s = `${String(line).padStart(6, '0')} the quick brown fox jumps over the lazy dog\n`;
    lines.push(s);
    length += s.length;
  }
  return Buffer.from(lines.join('')).subarray(0, n);
}

function digest(bytes) {
  let h = 0x811c9dc5;
  for (const b of bytes) h = Math.imul(h ^ b, 0x01000193) >>> 0;
  return `${bytes.length}:${h.toString(16).padStart(8, '0')}`;
}

const dictionary = text(64 << 10);
const page = text(96 << 10);
const id = 'interop-1';
const hash = createHash('sha256').update(dictionary).digest();
const available = `:${hash.toString('base64')}:`;

// RFC 9842 sections 4 and 5: the fixed headers before the coded stream.
const headers = {
  dcb: Buffer.concat([Buffer.from([0xff, 0x44, 0x43, 0x42]), hash]),
  dcz: Buffer.concat([
    Buffer.from([0x5e, 0x2a, 0x4d, 0x18, 0x20, 0x00, 0x00, 0x00]),
    hash,
  ]),
};
const coders = {
  dcb: (input) => zlib.brotliCompressSync(input, { dictionary }),
  dcz: (input) => zlib.zstdCompressSync(input, { dictionary }),
};

function handle(request, response) {
  const url = new URL(request.url, 'http://localhost');
  if (url.pathname === '/dict/dictionary') {
    response.writeHead(200, {
      'content-type': 'text/plain',
      'cache-control': 'max-age=3600',
      'use-as-dictionary': `match="/dict/*", id="${id}"`,
      'content-length': dictionary.length,
    });
    response.end(dictionary);
    return;
  }
  if (url.pathname !== '/dict/page') {
    response.writeHead(404);
    response.end();
    return;
  }
  const coding = url.searchParams.get('coding');
  const accepted = (request.headers['accept-encoding'] ?? '')
    .split(',')
    .map((s) => s.trim().split(';')[0].toLowerCase());
  const why = [];
  if (!(coding in coders)) why.push(`unknown coding ${coding}`);
  if (request.headers['available-dictionary'] !== available) {
    why.push(`Available-Dictionary ${request.headers['available-dictionary'] ?? 'absent'}`);
  }
  if (request.headers['dictionary-id'] !== `"${id}"`) {
    why.push(`Dictionary-ID ${request.headers['dictionary-id'] ?? 'absent'}`);
  }
  if (!accepted.includes(coding)) {
    why.push(`Accept-Encoding ${request.headers['accept-encoding'] ?? 'absent'}`);
  }
  const common = {
    'content-type': 'text/plain',
    'x-page-digest': digest(page),
    vary: 'accept-encoding, available-dictionary',
  };
  if (why.length > 0) {
    response.writeHead(200, { ...common, 'x-coded': 'none', 'x-why': why.join('; ') });
    response.end(page);
    return;
  }
  const body = Buffer.concat([headers[coding], coders[coding](page)]);
  response.writeHead(200, {
    ...common,
    'content-encoding': coding,
    'content-length': body.length,
    'x-coded': coding,
  });
  response.end(body);
}

http.createServer(handle).listen(39060, '127.0.0.1');
https
  .createServer(
    {
      cert: readFileSync('/certs/server.pem'),
      key: readFileSync('/certs/server.key'),
    },
    handle,
  )
  .listen(39061, '127.0.0.1');
