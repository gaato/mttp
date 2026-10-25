///|
extern "js" fn check_hosts() -> @js_async.Promise[Unit] =
  #| async () => {
  #|   const {resolve} = await import('node:path');
  #|   const {pathToFileURL} = await import('node:url');
  #|   const {existsSync} = await import('node:fs');
  #|   const root = existsSync(resolve('hosts/adapters.mjs')) ? resolve('hosts') : resolve('mttp-net/hosts');
  #|   const {workers, fastly, vercel, deno, bun} = await import(pathToFileURL(resolve(root, 'adapters.mjs')).href);
  #|   const {lambda} = await import(pathToFileURL(resolve(root, 'lambda.mjs')).href);
  #|   const check = (condition, message) => { if (!condition) throw new Error(message); };
  #|   const request = new Request('https://example.test/');
  #|   let envSeen, release, settled = false;
  #|   const background = new Promise(resolve => { release = resolve; });
  #|   const fetch = (req, schedule, env) => {
  #|     envSeen = env;
  #|     schedule(background);
  #|     return Promise.resolve(new Response('ok'));
  #|   };
  #|   const events = [], env = {binding: 'yes'};
  #|   const worker = workers(fetch);
  #|   const response = worker.fetch(request, env, {waitUntil(p) { events.push('wait'); check(p === background, 'worker aggregate identity'); }});
  #|   check(events.join() === 'wait' && envSeen === env, 'worker synchronous registration/environment');
  #|   check(await (await response).text() === 'ok', 'worker response');
  #|   events.length = 0;
  #|   fastly(fetch)({request, waitUntil(p) {events.push('wait'); check(p === background, 'fastly aggregate');},
  #|     respondWith(p) {events.push('respond'); p.then(r => r.body.cancel());}});
  #|   check(events.join() === 'wait,respond', 'Fastly waitUntil order');
  #|   let vercelRegistered = false;
  #|   await (await vercel(fetch, p => {vercelRegistered = p === background;})(request)).body.cancel();
  #|   check(vercelRegistered, 'Vercel registration');
  #|   for (const make of [deno, bun]) {
  #|     const app = make(fetch);
  #|     await (await app.fetch(request)).body.cancel();
  #|     app.whenIdle().then(() => {settled = true;});
  #|     await Promise.resolve();
  #|     check(!settled, 'process tracker returned before work');
  #|   }
  #|   release(); await background;
  #|   const event = {rawPath: '/a%2Fb', rawQueryString: 'x=1&x=2', headers: {}, cookies: ['a=1', 'b=2'],
  #|     requestContext: {domainName: 'example.test', http: {method: 'POST'}}, body: 'AP8=', isBase64Encoded: true};
  #|   let releaseLambda, entered;
  #|   const entry = new Promise(resolve => {entered = resolve;});
  #|   const task = new Promise(resolve => {releaseLambda = resolve;});
  #|   const handler = lambda(async (req, schedule) => {
  #|     check(req.url === 'https://example.test/a%2Fb?x=1&x=2', 'Lambda URL');
  #|     check(req.headers.get('cookie') === 'a=1; b=2', 'Lambda cookies');
  #|     const input = new Uint8Array(await req.arrayBuffer());
  #|     check(input.length === 2 && input[0] === 0 && input[1] === 255, 'Lambda binary body');
  #|     schedule(task); entered();
  #|     return new Response(input, {status: 201, headers: [['set-cookie', 'x=1'], ['set-cookie', 'y=2']]});
  #|   });
  #|   let returned = false;
  #|   const result = handler(event).then(value => {returned = true; return value;});
  #|   await entry; await Promise.resolve();
  #|   check(!returned, 'Lambda returned before background');
  #|   releaseLambda();
  #|   const output = await result;
  #|   check(output.statusCode === 201 && output.body === 'AP8=' && output.isBase64Encoded, 'Lambda response envelope');
  #|   check(output.cookies.join('|') === 'x=1|y=2' && !('set-cookie' in output.headers), 'Lambda response cookies');
  #|   check((await lambda(() => {throw new Error('must not run');}, {maxRequestBytes: 1})(event)).statusCode === 413, 'Lambda input limit');
  #|   check((await handler({...event, body: '!!!'})).statusCode === 400, 'Lambda invalid base64');
  #|   let cancelled = 0;
  #|   const oversized = lambda((_req, bg) => {
  #|     bg(Promise.resolve());
  #|     return Promise.resolve(new Response(new ReadableStream({
  #|       pull(c) {c.enqueue(new Uint8Array(3));}, cancel() {++cancelled;}
  #|     }, {highWaterMark: 0})));
  #|   }, {maxResponseBytes: 2});
  #|   let overflow = false;
  #|   try {await oversized(event);} catch(error) {overflow = error instanceof RangeError;}
  #|   check(overflow && cancelled === 1, 'Lambda output bound/cleanup');
  #|   let invalidLimit = false;
  #|   try {lambda(fetch, {maxRequestBytes: -1});} catch(error) {invalidLimit = error instanceof RangeError;}
  #|   check(invalidLimit, 'Lambda config');
  #|   const accepts = lambda(() => new Response(null, {status: 204}));
  #|   check((await accepts({...event, body: 'x'.repeat(1048576), isBase64Encoded: false})).statusCode === 204, 'Lambda default input boundary');
  #|   check((await accepts({...event, body: 'x'.repeat(1048577), isBase64Encoded: false})).statusCode === 413, 'Lambda default input overflow');
  #|   for (const size of [4194304, 4194305]) {
  #|     const bounded = lambda(() => new Response(new Uint8Array(size)));
  #|     let rejected = false;
  #|     try {await bounded(event);} catch (error) {rejected = error instanceof RangeError;}
  #|     check(rejected === (size > 4194304), 'Lambda default output boundary');
  #|   }
  #| }

///|
async test "host shims preserve synchronous registration lifecycle binary data and bounds" {
  check_hosts().wait()
}

///|
extern "js" fn check_exports() -> @js_async.Promise[Unit] =
  #| async () => {
  #|   const {resolve} = await import('node:path');
  #|   const {existsSync} = await import('node:fs');
  #|   const {pathToFileURL} = await import('node:url');
  #|   const root = existsSync(resolve('moon.work')) ? resolve('.') : resolve('..');
  #|   const app = await import(pathToFileURL(resolve(root, '_build/js/debug/build/gaato/mttp-fetch-example/mttp-fetch-example.js')).href);
  #|   if (typeof app.fetch !== 'function' || typeof app.fetch_with_env !== 'function') throw new Error('missing ESM function exports');
  #|   let calls = 0, background;
  #|   const response = app.fetch(new Request('https://example.test/', {method: 'POST', body: 'export smoke'}), promise => {
  #|     ++calls; background = promise;
  #|   });
  #|   if (calls !== 1) throw new Error('export did not register background synchronously');
  #|   if (await (await response).text() !== 'export smoke') throw new Error('export response mismatch');
  #|   await background;
  #| }

///|
async test "built application exports real fetch functions and handles a Web Request" {
  check_exports().wait()
}
