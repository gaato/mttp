// Runs entry.js on workerd through `wrangler dev` (the version package.json
// pins), sends requests, checks the replies, and fails if wrangler or workerd
// logged an error or a warning. Build the MoonBit module and run `npm ci` in
// this directory first; scripts/gates.sh workerd does both.
//
//   node examples/fetch/workers/check.mjs
//
// WORKERD_CHECK_VERBOSE=1 prints wrangler's output on success as well;
// WORKERD_CHECK_ROUNDS=n repeats the unread-body requests n times (20).
// WORKERD_CHECK_WS_ROUNDS=n repeats the WebSocket batch n times (20; 0 skips it).
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
const WS_ROUNDS = Number(process.env.WORKERD_CHECK_WS_ROUNDS ?? 20);

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
const echoPort = await freePort();
const echo = spawn(join(here, '../../../_build/native/debug/build/gaato/mttp-interop/mttp_server/mttp_server.exe'),
  ['websocket', `127.0.0.1:${echoPort}`], {stdio: ['ignore', 'pipe', 'pipe']});
let echoOutput = '';
echo.stdout.on('data', chunk => { echoOutput += chunk; });
echo.stderr.on('data', chunk => { echoOutput += chunk; });
const echoExited = new Promise(resolve => echo.on('exit', resolve));
const logs = mkdtempSync(join(tmpdir(), 'mttp-workerd-'));
const child = spawn(join(here, 'node_modules', '.bin', 'wrangler'), [
  'dev', '--ip', '127.0.0.1', '--port', String(port), '--inspector-port', String(inspector),
  '--show-interactive-dev-session=false', '--log-level', 'info',
  '--var', `WS_ECHO_URL:ws://127.0.0.1:${echoPort}/`,
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
  echo.kill('SIGTERM');
  await echoExited;
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
  let phase = 'fetch';
  let responseStatus;
  try {
    const response = await fetch(base + path, init);
    responseStatus = response.status;
    phase = `body (status ${response.status})`;
    const type = response.headers.get('content-type');
    const text = await response.text();
    let body;
    try { body = JSON.parse(text); } catch { body = text; }
    return {status: response.status, type, body};
  } catch (error) {
    throw Object.assign(new Error(`${init?.method ?? 'GET'} ${path} ${phase}: ${error}; cause: ${error?.cause ?? ''}`, {cause: error}),
      {responseStatus});
  }
};
const knownUnreadReset = error => {
  if (error.responseStatus !== 200) return false;
  const failure = error.cause;
  const closed = cause => cause?.name === 'SocketError' &&
    cause.message === 'other side closed' && cause.code === 'UND_ERR_SOCKET';
  return closed(failure) || (failure instanceof TypeError &&
    failure.message === 'terminated' && closed(failure.cause));
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
    const echoSocket = () => new Promise((resolve, reject) => {
      const socket = new WebSocket(`ws://127.0.0.1:${port}/ws`, ['echo']);
      socket.binaryType = 'arraybuffer';
      const timer = setTimeout(() => { socket.close(); reject(new Error('WebSocket echo timed out')); }, 5000);
      let phase = 0;
      socket.addEventListener('open', () => {
        check(socket.protocol === 'echo', `WebSocket protocol: ${socket.protocol}`);
        socket.send('héllo');
      });
      socket.addEventListener('message', event => {
        if (phase++ === 0) {
          check(event.data === 'héllo', `WebSocket text: ${event.data}`);
          socket.send(new Uint8Array([0, 128, 255]));
        } else {
          check(same(Array.from(new Uint8Array(event.data)), [0, 128, 255]), 'WebSocket binary echo');
          socket.close(4001, 'finished');
        }
      });
      socket.addEventListener('close', event => {
        clearTimeout(timer);
        check(phase === 2 && event.code === 4001 && event.reason === 'finished',
          `WebSocket close: ${phase} ${event.code} ${event.reason}`);
        resolve();
      });
      socket.addEventListener('error', () => { clearTimeout(timer); reject(new Error('WebSocket failed')); });
    });
    // Warm requests reuse the MoonBit scheduler. Closing one request must
    // not strand another session's Promise reactions in its ended context.
    // The original single batch only exposed this intermittently.
    for (let round = 0; round < WS_ROUNDS; ++round) {
      await Promise.all([1, 2, 3].map(echoSocket));
      const wsClient = await json('/ws-client', {signal: AbortSignal.timeout(15000)});
      check(wsClient.status === 200 && wsClient.body?.websocket === true,
        `Workers WebSocket client (round ${round + 1}): ${wsClient.status} ${JSON.stringify(wsClient.body)}`);
    }
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
    // failed, and with wrangler 4.126.0 a body still being uploaded then broke
    // the connection and failed the next request with "Network connection
    // lost". A split request sends its head first
    // and its body 2 ms later: the failure was found with Deno's fetch as the
    // client, and Node's fetch, which writes a small body together with its
    // head, did not show it. A partial read gets the first piece the host
    // delivers, whose size varies.
    const small = JSON.stringify({type: 2, data: {name: 'slow'}, pad: 'x'.repeat(300)});
    const large = 'y'.repeat(256 * 1024);
    const cases = [];
    for (const [name, body, split] of [['small', small, false], ['split', small, true], ['large', large, false]]) {
      cases.push(
        {path: '/slow', name, body, split, status: 200, read: body.length},
        {path: '/slow/partial', name, body, split, status: 200, read: 'some'},
        {path: '/slow/unread', name, body, split, status: 200, read: 0},
        {path: '/reject', name, body, split, status: 401});
    }
    const background = cases.filter(c => c.path !== '/reject').length * SLOW_ROUNDS;
    for (let round = 0; round < SLOW_ROUNDS; ++round) {
      for (const {path, name, body, split, status, read} of cases) {
        const label = `POST ${path} (${name} body, round ${round + 1})`;
        const early = path === '/slow/partial' || path === '/slow/unread' || path === '/reject';
        let reply;
        try {
          reply = split ? await splitPost(path, body) : await json(path, {
            method: 'POST', headers: {'content-type': 'application/json'}, body,
          });
        } catch (error) {
          // Only a body reset after the expected 200 is the upstream defect.
          // Full reads, rejected requests, timeouts and runtime logs stay strict.
          if (!early || status !== 200 || !knownUnreadReset(error)) throw error;
          console.log(`KNOWN ${label}: ${error.message}; https://github.com/cloudflare/workerd/issues/7634`);
          continue;
        }
        const got = reply.body?.read;
        const passed = reply.status === status &&
          (read === undefined || got === read || (read === 'some' && got > 0 && got <= body.length));
        check(passed, `${label}: ${reply.status} ${JSON.stringify(reply.body).slice(0, 200)}`);
        if (early && passed) console.log(`PASS ${label}: early response passed`);
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
  if (echoOutput) console.error(echoOutput);
  console.error('workerd check: FAILED');
  for (const failure of failures) console.error(`  ${failure}`);
  process.exit(1);
}
const {version} = JSON.parse(readFileSync(join(here, 'node_modules', 'wrangler', 'package.json'), 'utf8'));
if (process.env.WORKERD_CHECK_VERBOSE) console.log(output);
console.log(`workerd check: OK (wrangler ${version}, port ${port})`);
