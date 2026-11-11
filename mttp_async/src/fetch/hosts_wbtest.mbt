///|
extern "js" fn check_hosts() -> @js_async.Promise[Unit] =
  #| async () => {
  #|   const {resolve} = await import('node:path');
  #|   const {pathToFileURL} = await import('node:url');
  #|   const {existsSync} = await import('node:fs');
  #|   const root = existsSync(resolve('hosts/adapters.mjs')) ? resolve('hosts') : resolve('mttp_async/hosts');
  #|   const {workers, fastly, vercel, deno, bun, node} = await import(pathToFileURL(resolve(root, 'adapters.mjs')).href);
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
  #|   for (const make of [deno, bun, node]) {
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
  #|   check((await accepts({...event, body: Buffer.alloc(1048576, 97).toString('base64')})).statusCode === 204, 'Lambda base64 input boundary without regexp stack overflow');
  #|   for (const body of ['YQ=\n', '====', 'YQ', 'YQ=']) {
  #|     check((await accepts({...event, body})).statusCode === 400, 'Lambda base64 grammar');
  #|   }
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

///|
extern "js" fn check_bodyless_lambda(
  adapter : (JsRequest, JsBackground) -> JsPromise,
) -> @js_async.Promise[Unit] =
  #| async adapter => {
  #|   const {resolve} = await import('node:path');
  #|   const {pathToFileURL} = await import('node:url');
  #|   const {existsSync} = await import('node:fs');
  #|   const root = existsSync(resolve('hosts/lambda.mjs')) ? resolve('hosts') : resolve('mttp_async/hosts');
  #|   const {lambda} = await import(pathToFileURL(resolve(root, 'lambda.mjs')).href);
  #|   const entry = lambda(adapter);
  #|   const event = {headers: {}, rawPath: '/', requestContext: {domainName: 'example.test', http: {method: 'POST'}}};
  #|   for (const absent of [event, {...event, body: null}]) {
  #|     if ((await entry(absent)).statusCode !== 204) throw new Error('bodyless Lambda POST became a streamed body');
  #|   }
  #|   for (const body of ['', 'x']) {
  #|     if ((await entry({...event, body})).statusCode !== 200) throw new Error('present Lambda body became absent');
  #|   }
  #| }

///|
async test "bodyless Lambda POST reaches the model as Body Empty and present empty stays streamed" {
  check_bodyless_lambda(
    fetch_handler(request => {
      @mttp.Response::new(if request.body is Empty { 204 } else { 200 })
    }),
  ).wait()
}

///|
extern "js" fn check_prefetch_hosts(
  adapter : (JsRequest, JsBackground) -> JsPromise,
) -> @js_async.Promise[Unit] =
  #| async adapter => {
  #|   const {resolve} = await import('node:path');
  #|   const {pathToFileURL} = await import('node:url');
  #|   const {existsSync} = await import('node:fs');
  #|   const root = existsSync(resolve('hosts/adapters.mjs')) ? resolve('hosts') : resolve('mttp_async/hosts');
  #|   const {workers, fastly, vercel, node, deno, bun} = await import(pathToFileURL(resolve(root, 'adapters.mjs')).href);
  #|   const {lambda} = await import(pathToFileURL(resolve(root, 'lambda.mjs')).href);
  #|   for (const [body, headers, expected] of [['abc', {}, 413], ['x', {'content-length': '0'}, 400]]) {
  #|     const request = () => new Request('https://example.test/', {method: 'POST', body, headers});
  #|     const pending = [], register = p => pending.push(p);
  #|     const check = async promise => {
  #|       const response = await promise;
  #|       if (response.status !== expected || await response.text() !== '') throw new Error('shim lost prefetch input failure');
  #|     };
  #|     await check(workers((req, bg, _env) => adapter(req, bg)).fetch(request(), {}, {waitUntil: register}));
  #|     let result;
  #|     fastly(adapter)({request: request(), waitUntil: register, respondWith(p) { result = p; }});
  #|     await check(result);
  #|     await check(vercel(adapter, register)(request()));
  #|     for (const tracked of [node, deno, bun]) {
  #|       const app = tracked(adapter);
  #|       await check(app.fetch(request()));
  #|       await app.whenIdle();
  #|     }
  #|     const output = await lambda(adapter)({body, headers, rawPath: '/', requestContext: {
  #|       domainName: 'example.test', http: {method: 'POST'}
  #|     }});
  #|     if (output.statusCode !== expected || output.body !== '') throw new Error('Lambda lost prefetch input failure');
  #|     await Promise.all(pending);
  #|   }
  #| }

///|
async test "all host shims preserve caught prefetch input failures" {
  for fallback in [false, true] {
    let sources : Array[CaughtInputOutput] = []
    check_prefetch_hosts(
      fetch_handler(max_body_bytes=2, request => {
        let source = CaughtInputOutput::{
          body: request.body,
          fallback,
          fail_output: false,
          failure: Ref(None),
          reads: 0,
          closes: 0,
        }
        sources.push(source)
        @mttp.Response::new(201, body=Stream(@mttp.StreamBody::new(source)))
      }),
    ).wait()
    assert_eq(sources.length(), 14)
    for source in sources {
      assert_true(source.failure.val is Some(_))
      assert_eq(source.reads, 1)
      assert_eq(source.closes, 1)
    }
  }
}
