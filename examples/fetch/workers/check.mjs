// Runs entry.js on workerd through `wrangler dev` (the version package.json
// pins), sends requests, checks the replies, and fails if wrangler or workerd
// logged an error or a warning. Build the MoonBit module and run `npm ci` in
// this directory first; scripts/gates.sh workerd does both.
//
//   node examples/fetch/workers/check.mjs
//
// WORKERD_CHECK_VERBOSE=1 prints wrangler's output on success as well.
import { spawn } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { createServer } from 'node:net';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const READY_MS = 60_000;

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
