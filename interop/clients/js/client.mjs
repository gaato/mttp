// The host's fetch (Node's undici, Bun's and Deno's) against the mttp
// interop server, directly or through a reverse proxy. No dependencies; the
// node, bun and deno images in interop/images.tsv pin the runtimes.
// interop/run.mbtx runs it as
//
//   client.mjs <base> <direct> <case,case,...>
//
// where <base> is where the server's endpoints are (http://127.0.0.1:39000
// directly, or a proxy's /up prefix) and <direct> the server itself. It
// prints `CASE <id> ok|fail <detail>` per case.

const args = globalThis.Deno ? Deno.args : process.argv.slice(2);
if (args.length !== 3) {
  console.log('usage: client.mjs <base> <direct> <case,...>');
  globalThis.Deno ? Deno.exit(2) : process.exit(2);
}
const [base, , cases] = args;

// interop/pattern's binary and Digest.
function pattern(n) {
  const out = new Uint8Array(n);
  for (let i = 0; i < n; i++) out[i] = (i * 7 + (i >> 8)) & 0xff;
  return out;
}

function digest(bytes) {
  let h = 0x811c9dc5;
  for (const b of bytes) h = Math.imul(h ^ b, 0x01000193) >>> 0;
  return `${bytes.length}:${h.toString(16).padStart(8, '0')}`;
}

function echoed(text, key) {
  const line = text.split('\n').find((l) => l.startsWith(key + ' '));
  return line ? line.slice(key.length + 1) : '?';
}

function want(ok, what) {
  if (!ok) throw new Error(what);
}

async function bytesOf(response) {
  return new Uint8Array(await response.arrayBuffer());
}

async function upload(body, expected, extra = {}) {
  const response = await fetch(base + '/echo', { method: 'POST', body, ...extra });
  const text = await response.text();
  want(response.status === 200, `status ${response.status}`);
  const received = echoed(text, 'body');
  want(received === expected, `the server got ${received}`);
  return `${echoed(text, 'framing')}, ${received}`;
}

const run = {
  async get() {
    const response = await fetch(base + '/conn');
    want(response.status === 200, `status ${response.status}`);
    return (await response.text()).trim();
  },
  async reuse() {
    const peers = [];
    for (let i = 0; i < 2; i++) {
      peers.push((await (await fetch(base + '/conn')).text()).trim());
    }
    want(peers[0] === peers[1], `peers ${peers}`);
    return 'peer ' + peers[0];
  },
  async 'chunked-upload'() {
    const payload = pattern(1 << 20);
    let offset = 0;
    const stream = new ReadableStream({
      pull(controller) {
        if (offset >= payload.length) return controller.close();
        controller.enqueue(payload.slice(offset, offset + 65536));
        offset += 65536;
      },
    });
    return upload(stream, digest(payload), { duplex: 'half' });
  },
  async 'large-upload'() {
    const payload = pattern(16 << 20);
    return upload(payload, digest(payload));
  },
  async stream() {
    const body = await bytesOf(await fetch(base + '/stream?pieces=16&size=4096&delay_ms=10'));
    want(digest(body) === digest(pattern(16 * 4096)), `body ${digest(body)}`);
    return digest(body);
  },
  async head() {
    const response = await fetch(base + '/bytes?n=1000', { method: 'HEAD' });
    const body = await bytesOf(response);
    const length = response.headers.get('content-length');
    want(response.status === 200 && length === '1000' && body.length === 0,
      `status ${response.status}, length ${length}, ${body.length} body bytes`);
    const next = await bytesOf(await fetch(base + '/bytes?n=10'));
    want(digest(next) === digest(pattern(10)), `next body ${digest(next)}`);
    return 'length 1000, no body';
  },
  async 'no-content'() {
    const response = await fetch(base + '/status/204');
    const body = await bytesOf(response);
    want(response.status === 204 && body.length === 0, `status ${response.status}`);
    const next = await bytesOf(await fetch(base + '/bytes?n=10'));
    want(digest(next) === digest(pattern(10)), `next body ${digest(next)}`);
    return '204';
  },
  async parallel() {
    const expected = digest(pattern(100000));
    await Promise.all(Array.from({ length: 16 }, async () => {
      const body = await bytesOf(await fetch(base + '/bytes?n=100000'));
      want(digest(body) === expected, `body ${digest(body)}`);
    }));
    return '16 concurrent requests';
  },
};

for (const id of cases.split(',')) {
  try {
    if (!run[id]) throw new Error('unknown case');
    console.log(`CASE ${id} ok ${await run[id]()}`);
  } catch (error) {
    const cause = error.cause ? ` (${error.cause.message ?? error.cause})` : '';
    console.log(`CASE ${id} fail ${error.message}${cause}`);
  }
}
