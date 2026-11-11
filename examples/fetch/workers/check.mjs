// Runs entry.js on workerd through `wrangler dev` (the version package.json
// pins), sends requests, checks the replies, and fails if wrangler or workerd
// logged an error or a warning. Build the MoonBit module and run `npm ci` in
// this directory first; scripts/gates.sh workerd does both.
//
//   node examples/fetch/workers/check.mjs
//
// WORKERD_CHECK_VERBOSE=1 prints wrangler's output on success as well;
// WORKERD_CHECK_ROUNDS=n repeats the unread-body requests n times (20).
import { spawn } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { connect, createServer } from 'node:net';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const READY_MS = 60_000;
// How many times the requests that leave the body unread are repeated.
const SLOW_ROUNDS = Number(process.env.WORKERD_CHECK_ROUNDS ?? 20);

const freePort = () => new Promise((resolve, reject) => {
  const server = createServer();
  server.on('error', reject);
  server.listen(0, '127.0.0.1', () => {
    const {port} = server.address();
    server.close(() => resolve(port));
  });
});

const failures = [];
const check = (condition, message) => { if (!condition) failures.push(message); };

// Lines wrangler prints for errors and warnings, from itself and from workerd:
// "✘ [ERROR] ...", "▲ [WARNING] ...", "[wrangler:error]", "Uncaught ...".
const problem = /\[ERROR\]|\[WARNING\]|\[wrangler:(error|warn)\]|Uncaught|workerd\/.*error/i;

const port = await freePort();
const inspector = await freePort();
const logs = mkdtempSync(join(tmpdir(), 'mttp-workerd-'));
const child = spawn(join(here, 'node_modules', '.bin', 'wrangler'), [
  'dev', '--ip', '127.0.0.1', '--port', String(port), '--inspector-port', String(inspector),
  '--show-interactive-dev-session=false', '--log-level', 'info',
], {
  cwd: here,
  detached: true,
  stdio: ['ignore', 'pipe', 'pipe'],
  env: {...process.env, WRANGLER_SEND_METRICS: 'false', WRANGLER_LOG_PATH: logs, NO_COLOR: '1', FORCE_COLOR: '0'},
});
let output = '';
child.stdout.on('data', chunk => { output += chunk; });
child.stderr.on('data', chunk => { output += chunk; });
const exited = new Promise(resolve => child.on('exit', (code, signal) => resolve({code, signal})));

const stop = async () => {
  if (child.exitCode !== null || child.signalCode !== null) return;
  try { process.kill(-child.pid, 'SIGTERM'); } catch {}
  const killer = setTimeout(() => { try { process.kill(-child.pid, 'SIGKILL'); } catch {} }, 5000);
  await exited;
  clearTimeout(killer);
};

const ready = async () => {
  const deadline = Date.now() + READY_MS;
  while (Date.now() < deadline) {
    if (/Ready on http/.test(output)) return true;
    if (child.exitCode !== null || child.signalCode !== null || problem.test(output)) return false;
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  return false;
};

const base = `http://127.0.0.1:${port}`;
const json = async (path, init) => {
  const response = await fetch(base + path, init);
  const type = response.headers.get('content-type');
  const text = await response.text();
  let body;
  try { body = JSON.parse(text); } catch { body = text; }
  return {status: response.status, type, body};
};
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
// POSTs a JSON body over a socket of its own, writing the head and, 2 ms
// later, the body. Resolves once the reply is complete (Content-Length or
// the last chunk); rejects after 10 s.
const splitPost = (path, body) => new Promise((resolve, reject) => {
  const socket = connect(port, '127.0.0.1');
  const timer = setTimeout(() => { socket.destroy(); reject(new Error(`POST ${path}: no complete reply in 10 s`)); }, 10_000);
  let text = '';
  const parse = () => {
    const split = text.indexOf('\r\n\r\n');
    if (split < 0) return;
    const head = text.slice(0, split).split('\r\n');
    let rest = text.slice(split + 4);
    const length = head.find(line => /^content-length:/i.test(line));
    if (length !== undefined) {
      if (rest.length < Number(length.split(':')[1])) return;
    } else if (head.some(line => /^transfer-encoding:\s*chunked$/i.test(line))) {
      let decoded = '';
      for (;;) {
        const end = rest.indexOf('\r\n');
        if (end < 0) return;
        const size = parseInt(rest.slice(0, end), 16);
        if (size === 0) break;
        if (rest.length < end + 4 + size) return;
        decoded += rest.slice(end + 2, end + 2 + size);
        rest = rest.slice(end + 4 + size);
      }
      rest = decoded;
    }
    clearTimeout(timer);
    socket.destroy();
    let parsed;
    try { parsed = JSON.parse(Buffer.from(rest, 'latin1').toString()); } catch { parsed = rest; }
    resolve({status: Number(head[0].split(' ')[1]), body: parsed});
  };
  socket.on('data', chunk => { text += chunk.toString('latin1'); parse(); });
  socket.on('error', error => { clearTimeout(timer); reject(error); });
  socket.on('connect', () => {
    socket.write(`POST ${path} HTTP/1.1\r\nhost: 127.0.0.1:${port}\r\n` +
      `content-type: application/json\r\ncontent-length: ${Buffer.byteLength(body)}\r\n\r\n`);
    setTimeout(() => socket.write(body), 2);
  });
});

try {
  if (!(await ready())) {
    failures.push('wrangler dev did not become ready');
  } else {
    // The first requests arrive together, so they share the lazy import.
    const hello = await Promise.all([1, 2, 3].map(() => json('/hello')));
    for (const reply of hello) {
      check(reply.status === 200 && reply.type === 'application/json', `GET /hello: ${reply.status} ${reply.type}`);
      check(same(reply.body, {greeting: 'hello from vars', limits: null, missing: null}),
        `GET /hello body: ${JSON.stringify(reply.body)}`);
    }
    const queued = await json('/notes', {method: 'POST', body: 'first note'});
    check(queued.status === 202 && same(queued.body, {queued: 'first note'}),
      `POST /notes: ${queued.status} ${JSON.stringify(queued.body)}`);
    // The note is stored by background work registered with waitUntil.
    let notes;
    for (let i = 0; i < 50; ++i) {
      notes = await json('/notes');
      if (same(notes.body, {notes: ['first note']})) break;
      await new Promise(resolve => setTimeout(resolve, 100));
    }
    check(notes.status === 200 && same(notes.body, {notes: ['first note']}),
      `GET /notes after background work: ${notes.status} ${JSON.stringify(notes.body)}`);
    // Replies that leave the request body unread or partly read, most followed
    // by background work, repeated because the failure they guard against
    // appeared in some runs only. wrangler dev drains a request body the
    // Worker left unused once the handler has answered; when the adapter had
    // cancelled the body or still held its reader, that drain was skipped or
    // failed, and a body still being uploaded then broke the connection and
    // failed the next request with "Network connection lost". A split request
    // sends its head first and its body 2 ms later: the failure was found with
    // Deno's fetch as the client, and Node's fetch, which writes a small body
    // together with its head, did not show it.
    // The partial read uses a body that arrives in one piece: a Worker that
    // reads part of a body and answers while the rest is still on its way
    // loses the connection on wrangler dev however it lets go of the body.
    const small = JSON.stringify({type: 2, data: {name: 'slow'}, pad: 'x'.repeat(300)});
    const large = 'y'.repeat(256 * 1024);
    const cases = [];
    for (const [name, body, split] of [['small', small, false], ['split', small, true], ['large', large, false]]) {
      cases.push(
        {path: '/slow', name, body, split, status: 200, read: body.length},
        {path: '/slow/unread', name, body, split, status: 200, read: 0},
        {path: '/reject', name, body, split, status: 401});
    }
    cases.push({path: '/slow/partial', name: 'small', body: small, split: false, status: 200, read: small.length});
    const background = cases.filter(c => c.path !== '/reject').length * SLOW_ROUNDS;
    for (let round = 0; round < SLOW_ROUNDS; ++round) {
      for (const {path, name, body, split, status, read} of cases) {
        const reply = split ? await splitPost(path, body) : await json(path, {
          method: 'POST', headers: {'content-type': 'application/json'}, body,
        });
        check(reply.status === status && (read === undefined || reply.body?.read === read),
          `POST ${path} (${name} body, round ${round + 1}): ${reply.status} ${JSON.stringify(reply.body).slice(0, 200)}`);
      }
    }
    let finished;
    for (let i = 0; i < 50; ++i) {
      finished = await json('/slow');
      if (finished.body?.finished === background) break;
      await new Promise(resolve => setTimeout(resolve, 100));
    }
    check(finished.status === 200 && finished.body?.finished === background,
      `GET /slow after background work: ${finished.status} ${JSON.stringify(finished.body)}, expected ${background}`);
    const missing = await json('/nowhere');
    check(missing.status === 404 && same(missing.body, {error: 'not found'}),
      `GET /nowhere: ${missing.status} ${JSON.stringify(missing.body)}`);
  }
} catch (error) {
  failures.push(`request failed: ${error?.stack ?? error}`);
} finally {
  await stop();
  rmSync(logs, {recursive: true, force: true});
}

const flagged = output.split('\n').filter(line => problem.test(line));
for (const line of flagged) failures.push(`wrangler logged: ${line.trim()}`);
if (failures.length) {
  console.error(output);
  console.error('workerd check: FAILED');
  for (const failure of failures) console.error(`  ${failure}`);
  process.exit(1);
}
const {version} = JSON.parse(readFileSync(join(here, 'node_modules', 'wrangler', 'package.json'), 'utf8'));
if (process.env.WORKERD_CHECK_VERBOSE) console.log(output);
console.log(`workerd check: OK (wrangler ${version}, port ${port})`);
