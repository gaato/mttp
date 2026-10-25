///|
#external
priv type Probe

///|
extern "js" fn Probe::new() -> Probe =
  #| () => ({calls: 0, done: false, failed: false, promise: null})

///|
extern "js" fn Probe::callback(self : Probe) -> JsBackground =
  #| probe => promise => {
  #|   ++probe.calls;
  #|   probe.promise = promise;
  #|   promise.then(() => {probe.done = true}, () => {probe.failed = true; probe.done = true});
  #| }

///|
extern "js" fn Probe::calls(self : Probe) -> Int32 =
  #| probe => probe.calls

///|
extern "js" fn Probe::done(self : Probe) -> Bool =
  #| probe => probe.done

///|
extern "js" fn Probe::failed(self : Probe) -> Bool =
  #| probe => probe.failed

///|
extern "js" fn Probe::settled(self : Probe) -> @js_async.Promise[Unit] =
  #| probe => probe.promise.then(() => {}, () => {})

///|
extern "js" fn awaited(promise : JsPromise) -> @js_async.Promise[WebResponse] =
  #| promise => promise

///|
extern "js" fn make_request(
  verb : String,
  body : Bytes,
  headers : FixedArray[FixedArray[String]],
) -> JsRequest =
  #| (method, body, headers) => new Request('https://example.test/path?q=1', {
  #| method, headers, body: ['GET', 'HEAD'].includes(method) ? undefined : body
  #| })

///|
extern "js" fn bodyless_request(
  headers : FixedArray[FixedArray[String]],
) -> JsRequest =
  #| headers => new Request('https://example.test/', {method: 'POST', headers})

///|
extern "js" fn streaming_request(
  chunks : FixedArray[Bytes],
  signal : @js_async.AbortSignal,
) -> JsRequest =
  #| (chunks, signal) => {
  #|   let index = 0;
  #|   return new Request('https://example.test/', {method: 'POST', signal, duplex: 'half',
  #|     body: new ReadableStream({pull(c) {
  #|       if (index === chunks.length) c.close(); else c.enqueue(chunks[index++]);
  #|     }}, {highWaterMark: 0})});
  #| }

///|
extern "js" fn WebResponse::status(self : WebResponse) -> Int32 =
  #| response => response.status

///|
extern "js" fn WebResponse::text(
  self : WebResponse,
) -> @js_async.Promise[String] =
  #| response => response.text()

///|
extern "js" fn WebResponse::sizes(
  self : WebResponse,
) -> @js_async.Promise[FixedArray[Int32]] =
  #| async response => {
  #|   const reader = response.body.getReader(), sizes = [];
  #|   for (;;) { const chunk = await reader.read(); if (chunk.done) break; sizes.push(chunk.value.length); }
  #|   reader.releaseLock(); return sizes;
  #| }

///|
extern "js" fn WebResponse::cookies(self : WebResponse) -> FixedArray[String] =
  #| response => response.headers.getSetCookie()

///|
extern "js" fn WebResponse::cancel(
  self : WebResponse,
) -> @js_async.Promise[Unit] =
  #| response => response.body.cancel()

///|
extern "js" fn test_env() -> JsEnv =
  #| () => ({binding: 'configured'})

///|
async test "Web Requests preserve metadata environment cookies and body ownership" {
  let probe = Probe::new()
  let adapter = fetch_handler(request => {
    assert_eq(request.url, "https://example.test/path?q=1") catch {
      _ => abort("URL lost")
    }
    if request.attributes.get(env) is None {
      abort("environment lost")
    }
    @model.Response::new(
      201,
      headers=@model.Headers::of([
        ("set-cookie", "a=1; Path=/"),
        ("set-cookie", "b=2; Path=/"),
      ]),
      body=request.body,
    )
  })
  let request = with_env(make_request("POST", b"hello", []), test_env())
  let promise = adapter(request, probe.callback())
  assert_eq(probe.calls(), 1)
  let reply = awaited(promise).wait()
  assert_eq(reply.status(), 201)
  assert_eq(reply.cookies().iter().collect(), ["a=1; Path=/", "b=2; Path=/"])
  assert_eq(reply.text().wait(), "hello")
  probe.settled().wait()
  assert_true(probe.done())
  assert_false(probe.failed())
}

///|
async test "a bodyless Fetch POST remains absent rather than an EOF stream" {
  let adapter = fetch_handler(request => {
    assert_true(request.body is Empty) catch {
      _ => abort("absent Fetch body became a stream")
    }
    @model.Response::new(204)
  })
  let absent = awaited(adapter(bodyless_request([]), Probe::new().callback())).wait()
  assert_eq(absent.status(), 204)
  let invalid = awaited(
    adapter(
      bodyless_request([["content-length", "4"]]),
      Probe::new().callback(),
    ),
  ).wait()
  assert_eq(invalid.status(), 400)
}

///|
async test "fetch request ceilings reject declared and observed overflow despite caught reads" {
  for configured in [None, Some(5)] {
    let ceiling = configured.unwrap_or(1048576)
    for size in [ceiling - 1, ceiling, ceiling + 1] {
      for declared in [false, true] {
        let probe = Probe::new()
        let adapter = fetch_handler(max_body_bytes?=configured, request => {
          if request.body is Stream(stream) {
            ignore(@model.read_bounded(stream.take(), ceiling + 1)) catch {
              _ => ()
            }
          }
          @model.Response::new(200)
        })
        let headers : FixedArray[FixedArray[String]] = if declared {
          [["content-length", size.to_string()]]
        } else {
          []
        }
        let reply = awaited(
          adapter(
            make_request("POST", Bytes::make(size, b'x'), headers),
            probe.callback(),
          ),
        ).wait()
        assert_eq(reply.status(), if size > ceiling { 413 } else { 200 })
        probe.settled().wait()
      }
    }
  }
}

///|
async test "background registration is synchronous and aggregate waits for all tasks after response" {
  for failing in [false, true] {
    let probe = Probe::new()
    let release = @cond_var.Cond()
    let finished = Ref(0)
    let adapter = fetch_handler(request => {
      let schedule = request.attributes.get(@model.background).unwrap()
      schedule(() => {
        release.wait()
        finished.val += 1
      })
      schedule(() => {
        release.wait()
        finished.val += 1
        if failing {
          raise Failure("background failure")
        }
      })
      @model.Response::new(204)
    })
    let promise = adapter(make_request("GET", b"", []), probe.callback())
    assert_eq(probe.calls(), 1)
    let reply = awaited(promise).wait()
    assert_eq(reply.status(), 204)
    assert_false(probe.done())
    release.broadcast()
    probe.settled().wait()
    assert_eq(finished.val, 2)
    assert_eq(probe.failed(), failing)
  }
}

///|
priv struct OutputSource {
  mut reads : Int32
  mut closes : Int32
}

///|
impl @model.BodyStream for OutputSource with fn read_some(self) {
  self.reads += 1
  if self.reads == 1 {
    Some(Bytes::make(131073, b'x'))
  } else {
    None
  }
}

///|
impl @model.BodyStream for OutputSource with fn close(self) {
  self.closes += 1
}

///|
async test "fetch response backpressure bounds chunks and closes sources on EOF and cancellation" {
  for cancel in [false, true] {
    let source = OutputSource::{ reads: 0, closes: 0, }
    let probe = Probe::new()
    let adapter = fetch_handler(_ => {
      @model.Response::new(200, body=Stream(@model.StreamBody::new(source)))
    })
    let reply = awaited(adapter(make_request("GET", b"", []), probe.callback())).wait()
    assert_eq(source.reads, 1)
    if cancel {
      reply.cancel().wait()
    } else {
      assert_eq(reply.sizes().wait().iter().collect(), [65536, 65536, 1])
    }
    assert_eq(source.closes, 1)
    probe.settled().wait()
  }
}

///|
async test "request abort cancels a blocked handler and settles its background registration" {
  let started = @cond_var.Cond()
  let cleaned = Ref(false)
  let controller = @js_async.AbortController::new()
  let probe = Probe::new()
  let adapter = fetch_handler(_ => {
    defer {
      cleaned.val = true
    }
    started.broadcast()
    @cond_var.Cond().wait()
    @model.Response::new(200)
  })
  let promise = adapter(
    streaming_request([], controller.signal()),
    probe.callback(),
  )
  if !cleaned.val {
    // from_async may start synchronously or on the next loop; give entry one turn.
    @async.sleep(1)
  }
  controller.abort()
  let rejected = try {
    ignore(awaited(promise).wait())
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
  assert_true(cleaned.val)
  probe.settled().wait()
}
