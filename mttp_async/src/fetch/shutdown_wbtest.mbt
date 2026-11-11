// close_on_shutdown on JS hosts: the adapter marks such a Response, and the
// mark ends the body at a read boundary once a shutdown signal aborts. Aborts
// of the request signal after a completed body change nothing.

///|
/// First read returns `first`, the next waits until cancelled.
priv struct BlockedSource {
  first : Bytes
  mut reads : Int32
  mut closes : Int32
}

///|
impl @mttp.BodyStream for BlockedSource with fn read_some(self) {
  self.reads += 1
  if self.reads == 1 {
    return Some(self.first)
  }
  @cond_var.Cond().wait()
  None
}

///|
impl @mttp.BodyStream for BlockedSource with fn close(self) {
  self.closes += 1
}

///|
fn streamed(source : &@mttp.BodyStream, cut : Bool?) -> @mttp.Response {
  let response = @mttp.Response::new(
    200,
    body=Stream(@mttp.StreamBody::new(source)),
  )
  match cut {
    Some(value) =>
      {
        ..response,
        attributes: response.attributes.put(@mttp.close_on_shutdown, value),
      }
    None => response
  }
}

///|
extern "js" fn WebResponse::marked(self : WebResponse) -> Bool =
  #| response => {
  #|   const mark = Object.getOwnPropertyDescriptor(response, Symbol.for('gaato.mttp.closeOnShutdown'));
  #|   return mark !== undefined && typeof mark.value === 'function' && !mark.enumerable;
  #| }

///|
extern "js" fn signalled_request(
  verb : String,
  signal : @js_async.AbortSignal,
) -> JsRequest =
  #| (method, signal) => new Request('https://example.test/', {method, signal})

///|
async test "a Response is marked exactly when close_on_shutdown is true and it has a body" {
  for
    case in [
      (Some(true), "GET", true),
      (Some(false), "GET", false),
      (None, "GET", false),
      (Some(true), "HEAD", false),
    ] {
    let (cut, verb, expected) = case
    let source = BlockedSource::{ first: b"data: 1\n\n", reads: 0, closes: 0, }
    let adapter = fetch_handler(_ => streamed(source, cut))
    let probe = Probe::new()
    let controller = @js_async.AbortController::new()
    let reply = awaited(
      adapter(signalled_request(verb, controller.signal()), probe.callback()),
    ).wait()
    assert_eq(reply.marked(), expected)
    if verb != "HEAD" {
      reply.cancel().wait()
    }
    assert_eq(source.closes, 1)
    probe.settled().wait()
  }
  // A buffered body is marked too; responses the adapter makes itself never.
  let adapter = fetch_handler(request => {
    if request.url.has_suffix("/bad") {
      return @mttp.Response::new(200, headers=@mttp.Headers::of([("x", "\n")]))
    }
    let response = @mttp.Response::new(200, body=Bytes(b"data: 1\n\n"))
    {
      ..response,
      attributes: response.attributes.put(@mttp.close_on_shutdown, true),
    }
  })
  let buffered = awaited(
    adapter(make_request("GET", b"", []), Probe::new().callback()),
  ).wait()
  assert_true(buffered.marked())
  assert_eq(buffered.text().wait(), "data: 1\n\n")
}

///|
/// Reads the first chunk, starts a second read that waits in the source, then
/// aborts either the shutdown signal handed to the mark or the request signal.
/// Resolves to "done" or "rejected", or "timeout" when the waiting read is not
/// ended within a second. Only JS work is awaited between the abort and the
/// result, so a pull left cancelled but unscheduled shows up as a timeout.
extern "js" fn interrupt_waiting_read(
  response : WebResponse,
  request : @js_async.AbortController,
  shutdown : Bool,
) -> @js_async.Promise[String] =
  #| async (response, request, shutdown) => {
  #|   const reader = response.body.getReader();
  #|   const first = await reader.read();
  #|   if (first.done || new TextDecoder().decode(first.value) !== 'data: 1\n\n') return 'first chunk lost';
  #|   const stop = new AbortController();
  #|   response[Symbol.for('gaato.mttp.closeOnShutdown')](stop.signal);
  #|   const next = reader.read().then(r => r.done ? 'done' : 'more', () => 'rejected');
  #|   await new Promise(resolve => setTimeout(resolve, 10));
  #|   if (shutdown) stop.abort(); else request.abort();
  #|   let timer;
  #|   const timeout = new Promise(resolve => { timer = setTimeout(() => resolve('timeout'), 1000); });
  #|   const result = await Promise.race([next, timeout]);
  #|   clearTimeout(timer);
  #|   return result;
  #| }

///|
async test "shutdown or a request abort ends a body cleanly while its read waits and closes it once" {
  for shutdown in [true, false] {
    let source = BlockedSource::{ first: b"data: 1\n\n", reads: 0, closes: 0, }
    let adapter = fetch_handler(_ => streamed(source, Some(true)))
    let probe = Probe::new()
    let controller = @js_async.AbortController::new()
    let reply = awaited(
      adapter(signalled_request("GET", controller.signal()), probe.callback()),
    ).wait()
    let result = interrupt_waiting_read(reply, controller, shutdown).wait()
    // A shutdown ends the body, and so does a client leaving before the
    // end: neither is an error a host would log.
    assert_eq(result, "done")
    assert_eq(source.reads, 2)
    assert_eq(source.closes, 1)
    probe.settled().wait()
    assert_false(probe.failed())
  }
}

///|
/// Reads one chunk, aborts the shutdown signal (already aborted when `early`)
/// while no read is pending, then reads to the end. Returns the chunk sizes.
extern "js" fn stop_between_reads(
  response : WebResponse,
  early : Bool,
) -> @js_async.Promise[FixedArray[Int32]] =
  #| async (response, early) => {
  #|   const reader = response.body.getReader(), sizes = [];
  #|   const first = await reader.read();
  #|   sizes.push(first.value.length);
  #|   const stop = new AbortController();
  #|   if (early) stop.abort();
  #|   response[Symbol.for('gaato.mttp.closeOnShutdown')](stop.signal);
  #|   stop.abort();
  #|   for (;;) { const chunk = await reader.read(); if (chunk.done) break; sizes.push(chunk.value.length); }
  #|   return sizes;
  #| }

///|
async test "shutdown never cuts inside one source read and ends at once between reads" {
  for early in [false, true] {
    // A 131073-byte read leaves the host in 64 KiB pieces; all of them go out.
    let large = BlockedSource::{
      first: Bytes::make(131073, b'x'),
      reads: 0,
      closes: 0,
    }
    let adapter = fetch_handler(_ => streamed(large, Some(true)))
    let reply = awaited(
      adapter(make_request("GET", b"", []), Probe::new().callback()),
    ).wait()
    assert_eq(stop_between_reads(reply, early).wait().iter().collect(), [
      65536, 65536, 1,
    ])
    assert_eq(large.reads, 1)
    assert_eq(large.closes, 1)
    // A whole read already delivered: the body ends without another read.
    let small = BlockedSource::{ first: b"data: 1\n\n", reads: 0, closes: 0, }
    let adapter = fetch_handler(_ => streamed(small, Some(true)))
    let reply = awaited(
      adapter(make_request("GET", b"", []), Probe::new().callback()),
    ).wait()
    assert_eq(stop_between_reads(reply, early).wait().iter().collect(), [9])
    assert_eq(small.reads, 1)
    assert_eq(small.closes, 1)
  }
}

///|
/// Reads the body to its end, then aborts the request signal and the shutdown
/// signal. Resolves to the text read.
extern "js" fn abort_after_completion(
  response : WebResponse,
  request : @js_async.AbortController,
) -> @js_async.Promise[String] =
  #| async (response, request) => {
  #|   const stop = new AbortController();
  #|   response[Symbol.for('gaato.mttp.closeOnShutdown')]?.(stop.signal);
  #|   const text = await response.text();
  #|   request.abort();
  #|   stop.abort();
  #|   await new Promise(resolve => setTimeout(resolve, 10));
  #|   return text;
  #| }

///|
async test "aborts after a completed body cancel nothing and close nothing twice" {
  for cut in [false, true] {
    let source = OutputSource::{ reads: 0, closes: 0, }
    let probe = Probe::new()
    let adapter = fetch_handler(_ => streamed(source, Some(cut)))
    let controller = @js_async.AbortController::new()
    let reply = awaited(
      adapter(signalled_request("GET", controller.signal()), probe.callback()),
    ).wait()
    assert_eq(abort_after_completion(reply, controller).wait().length(), 131073)
    assert_eq(source.reads, 2)
    assert_eq(source.closes, 1)
    probe.settled().wait()
    assert_false(probe.failed())
  }
}

///|
/// Through the process host shim: shutdown() ends a marked body, leaves an
/// unmarked one streaming, and whenIdle() then resolves. Returns the outcome of
/// each read after shutdown and whether whenIdle resolved within a second.
extern "js" fn shim_shutdown(
  adapter : (JsRequest, JsBackground) -> JsPromise,
) -> @js_async.Promise[String] =
  #| async adapter => {
  #|   const {resolve} = await import('node:path');
  #|   const {pathToFileURL} = await import('node:url');
  #|   const {existsSync} = await import('node:fs');
  #|   const root = existsSync(resolve('hosts/adapters.mjs')) ? resolve('hosts') : resolve('mttp_async/hosts');
  #|   const {deno, bun, node} = await import(pathToFileURL(resolve(root, 'adapters.mjs')).href);
  #|   // Each wait is raced with a timer, which also keeps the event loop alive.
  #|   const within = (promise, ms, late) => {
  #|     let timer;
  #|     return Promise.race([promise, new Promise(r => { timer = setTimeout(() => r(late), ms); })])
  #|       .finally(() => clearTimeout(timer));
  #|   };
  #|   const outcomes = [];
  #|   for (const tracked of [deno, bun, node]) {
  #|     const app = tracked(adapter);
  #|     const marked = (await app.fetch(new Request('https://example.test/marked'))).body.getReader();
  #|     const plain = (await app.fetch(new Request('https://example.test/plain'))).body.getReader();
  #|     await marked.read(); await plain.read();
  #|     const next = marked.read().then(r => r.done ? 'done' : 'more');
  #|     app.shutdown();
  #|     const ended = await within(next, 1000, 'timeout');
  #|     const idle = await within(app.whenIdle().then(() => 'idle'), 1000, 'busy');
  #|     const still = await within(plain.read().then(() => 'ended'), 20, 'open');
  #|     await plain.cancel();
  #|     outcomes.push(`${ended} ${idle} ${still}`);
  #|   }
  #|   return outcomes.join('|');
  #| }

///|
async test "the process host shims' shutdown ends marked bodies and leaves others" {
  let sources : Array[BlockedSource] = []
  let adapter = fetch_handler(request => {
    let source = BlockedSource::{ first: b"data: 1\n\n", reads: 0, closes: 0, }
    sources.push(source)
    streamed(source, Some(request.url.has_suffix("/marked")))
  })
  assert_eq(
    shim_shutdown(adapter).wait(),
    "done idle open|done idle open|done idle open",
  )
  assert_eq(sources.length(), 6)
  for source in sources {
    assert_eq(source.reads, 2)
    assert_eq(source.closes, 1)
  }
}

///|
/// Through the process host shims, as an app serves server-sent events from
/// Deno: fetches a stream whose producer has no event yet, then shuts down.
/// Returns per shim "no head" when the Response did not arrive within a
/// second, or the opening chunk read, whether the Response carries the mark,
/// how the waiting read ended and whether whenIdle resolved.
extern "js" fn shim_shutdown_before_event(
  adapter : (JsRequest, JsBackground) -> JsPromise,
) -> @js_async.Promise[String] =
  #| async adapter => {
  #|   const {resolve} = await import('node:path');
  #|   const {pathToFileURL} = await import('node:url');
  #|   const {existsSync} = await import('node:fs');
  #|   const root = existsSync(resolve('hosts/adapters.mjs')) ? resolve('hosts') : resolve('mttp_async/hosts');
  #|   const {deno, bun, node} = await import(pathToFileURL(resolve(root, 'adapters.mjs')).href);
  #|   const within = (promise, ms, late) => {
  #|     let timer;
  #|     return Promise.race([promise, new Promise(r => { timer = setTimeout(() => r(late), ms); })])
  #|       .finally(() => clearTimeout(timer));
  #|   };
  #|   const mark = Symbol.for('gaato.mttp.closeOnShutdown');
  #|   const outcomes = [];
  #|   for (const tracked of [deno, bun, node]) {
  #|     const app = tracked(adapter);
  #|     const response = await within(app.fetch(new Request('https://example.test/events')), 1000, null);
  #|     if (response === null) {
  #|       app.shutdown();
  #|       outcomes.push('no head');
  #|       continue;
  #|     }
  #|     const marked = typeof response[mark] === 'function' ? 'marked' : 'unmarked';
  #|     const reader = response.body.getReader();
  #|     const first = await reader.read();
  #|     const opening = JSON.stringify(new TextDecoder().decode(first.value));
  #|     const next = reader.read().then(r => r.done ? 'done' : 'more');
  #|     app.shutdown();
  #|     const ended = await within(next, 1000, 'timeout');
  #|     const idle = await within(app.whenIdle().then(() => 'idle'), 1000, 'busy');
  #|     outcomes.push(`${opening} ${marked} ${ended} ${idle}`);
  #|   }
  #|   return outcomes.join('|');
  #| }

///|
async test "the process host shims' shutdown ends an event stream that has no event yet" {
  let produced = Ref(0)
  let closes = Ref(0)
  let events = @endpoint.endpoint
    .get("/events")
    .output(@endpoint.sse_out(@schema.jint))
    .serve_public(_ => {
      Ok(
        @endpoint.EventStream::from_pull(
          () => {
            @cond_var.Cond().wait()
            produced.val += 1
            None
          },
          () => closes.val += 1,
        ),
      )
    })
  let adapter = fetch_handler(request => {
    events.dispatch(request, Map([]), @endpoint.DispatchContext::new())
  })
  assert_eq(
    shim_shutdown_before_event(adapter).wait(),
    "\":\\n\\n\" marked done idle|\":\\n\\n\" marked done idle|\":\\n\\n\" marked done idle",
  )
  // No stream gave an event, and the shutdown closed each one once.
  assert_eq(produced.val, 0)
  assert_eq(closes.val, 3)
}
