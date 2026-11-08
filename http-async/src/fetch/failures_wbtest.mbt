///|
async test "abort after response creation closes the output stream and rejects future reads" {
  let controller = @js_async.AbortController::new()
  let source = OutputSource::{ reads: 0, closes: 0, }
  let probe = Probe::new()
  let adapter = fetch_handler(_ => {
    @http.Response::new(200, body=Stream(@http.StreamBody::new(source)))
  })
  let reply = awaited(
    adapter(streaming_request([], controller.signal()), probe.callback()),
  ).wait()
  assert_eq(source.reads, 1)
  controller.abort()
  let rejected = try {
    ignore(reply.text().wait())
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
  assert_eq(source.closes, 1)
  probe.settled().wait()
}

///|
async test "lazy echo overflow is rejected before response headers and buffered replies are sliced" {
  for echo in [true, false] {
    let probe = Probe::new()
    let adapter = fetch_handler(max_body_bytes=2, request => {
      @http.Response::new(
        200,
        body=if echo { request.body } else { Bytes(Bytes::make(65537, b'x')) },
      )
    })
    let reply = awaited(
      adapter(make_request("POST", b"abc", []), probe.callback()),
    ).wait()
    if echo {
      assert_eq(reply.status(), 413)
    } else {
      assert_eq(reply.sizes().wait().iter().collect(), [65536, 1])
    }
    probe.settled().wait()
  }
}

///|
priv struct CaughtInputOutput {
  body : @http.Body
  fallback : Bool
  fail_output : Bool
  failure : Ref[@http.TransportError?]
  mut reads : Int32
  mut closes : Int32
}

///|
impl @http.BodyStream for CaughtInputOutput with fn read_some(self) {
  self.reads += 1
  if self.reads > 1 {
    return None
  }
  if self.body is Stream(cell) {
    ignore(@http.read_bounded(cell.take(), 10)) catch {
      error => self.failure.val = Some(error)
    }
  }
  if self.fail_output {
    raise @http.TransportError(
      kind=Network,
      phase=Body,
      detail="response producer failed",
    )
  }
  if self.fallback {
    Some(b"fallback")
  } else {
    None
  }
}

///|
impl @http.BodyStream for CaughtInputOutput with fn close(self) {
  self.closes += 1
}

///|
async fn caught_prefetch(
  request : JsRequest,
  fallback : Bool,
  expected : Int32,
  fail_output~ : Bool = false,
) -> Unit {
  let probe = Probe::new()
  let failure : Ref[@http.TransportError?] = Ref(None)
  let source : Ref[CaughtInputOutput?] = Ref(None)
  let adapter = fetch_handler(max_body_bytes=2, request => {
    let output = CaughtInputOutput::{
      body: request.body,
      fallback,
      fail_output,
      failure,
      reads: 0,
      closes: 0,
    }
    source.val = Some(output)
    @http.Response::new(201, body=Stream(@http.StreamBody::new(output)))
  })
  let reply = awaited(adapter(request, probe.callback())).wait()
  let output = source.val.unwrap()
  assert_eq(failure.val is Some(_), expected == 400 || expected == 413)
  assert_eq(output.reads, 1)
  assert_eq(output.closes, if expected == 201 && fallback { 0 } else { 1 })
  assert_eq(reply.status(), expected)
  assert_eq(
    reply.text().wait(),
    if expected == 201 && fallback {
      "fallback"
    } else {
      ""
    },
  )
  assert_eq(output.closes, 1)
  probe.settled().wait()
  assert_eq(probe.calls(), 1)
  assert_false(probe.failed())
}

///|
async test "caught request overflow during response prefetch stays 413 for fallback and EOF" {
  for fallback in [false, true] {
    caught_prefetch(make_request("POST", b"abc", []), fallback, 413)
  }
}

///|
async test "caught malformed input during response prefetch stays 400 for fallback and EOF" {
  for fallback in [false, true] {
    for length in ["0", "2"] {
      caught_prefetch(
        make_request("POST", b"x", [["content-length", length]]),
        fallback,
        400,
      )
    }
    let request = InputProbe::new(
      @js_async.AbortController::new().signal(),
      true,
    )
    caught_prefetch(request.request(), fallback, 400)
  }
}

///|
async test "response prefetch preserves valid replies and independent producer failures stay 500" {
  for fallback in [false, true] {
    for fail_output in [false, true] {
      caught_prefetch(
        make_request("POST", b"x", [["content-length", "1"]]),
        fallback,
        if fail_output {
          500
        } else {
          201
        },
        fail_output~,
      )
    }
  }
}

///|
async test "late background scheduling cannot escape a settled host aggregate" {
  let schedule : Ref[((async () -> Unit) -> Unit)?] = Ref(None)
  let probe = Probe::new()
  let adapter = fetch_handler(request => {
    schedule.val = request.attributes.get(@http.background)
    @http.Response::new(204)
  })
  ignore(
    awaited(adapter(make_request("GET", b"", []), probe.callback())).wait(),
  )
  probe.settled().wait()
  let ran = Ref(false)
  schedule.val.unwrap()(() => ran.val = true)
  @async.sleep(0)
  assert_false(ran.val)
}

///|
async test "fetch suppresses HEAD and null-body statuses and releases output ownership" {
  for status in [200, 204, 205, 304] {
    let source = OutputSource::{ reads: 0, closes: 0, }
    let probe = Probe::new()
    let adapter = fetch_handler(_ => {
      @http.Response::new(status, body=Stream(@http.StreamBody::new(source)))
    })
    let reply = awaited(
      adapter(
        make_request(if status == 200 { "HEAD" } else { "GET" }, b"", []),
        probe.callback(),
      ),
    ).wait()
    assert_eq(reply.status(), status)
    assert_eq(reply.text().wait(), "")
    assert_eq(source.reads, 0)
    assert_eq(source.closes, 1)
    probe.settled().wait()
  }
}

///|
async test "fetch invalid response heads and negative configuration yield 500" {
  for mode in 0..<3 {
    let source = OutputSource::{ reads: 0, closes: 0, }
    let probe = Probe::new()
    let adapter = fetch_handler(
      max_body_bytes=if mode == 2 { -1 } else { 10 },
      _ => {
        @http.Response::new(
          if mode == 0 {
            700
          } else {
            200
          },
          headers=if mode == 1 {
            @http.Headers::of([("x-bad", "bad\r\nvalue")])
          } else {
            @http.Headers::empty()
          },
          body=Stream(@http.StreamBody::new(source)),
        )
      },
    )
    let reply = awaited(adapter(make_request("GET", b"", []), probe.callback())).wait()
    assert_eq(reply.status(), 500)
    assert_eq(source.closes, if mode == 2 { 0 } else { 1 })
    probe.settled().wait()
  }
}

///|
async test "fetch length mismatches and malformed framing stay rejected when handlers catch reads" {
  for length in ["1", "3", "invalid"] {
    let probe = Probe::new()
    let adapter = fetch_handler(request => {
      if request.body is Stream(stream) {
        ignore(@http.read_bounded(stream.take(), 10)) catch {
          _ => ()
        }
      }
      @http.Response::new(200)
    })
    let reply = awaited(
      adapter(
        make_request("POST", b"xx", [["content-length", length]]),
        probe.callback(),
      ),
    ).wait()
    assert_eq(reply.status(), 400)
    probe.settled().wait()
  }
}

///|
async test "empty request chunks have a finite processing budget and large chunks are sliced" {
  for empty_count in [0, 1023, 1024] {
    let probe = Probe::new()
    let observed = Ref(0)
    let adapter = fetch_handler(request => {
      if request.body is Stream(stream) {
        let body = stream.take() catch { _ => abort("fresh body unavailable") }
        try {
          while body.read_some() is Some(bytes) {
            observed.val = observed.val.max(bytes.length())
          }
        } catch {
          _ => ()
        }
      }
      @http.Response::new(200)
    })
    let chunks = if empty_count > 0 {
      FixedArray::make(empty_count, b"")
    } else {
      [Bytes::make(131073, b'x')]
    }
    let reply = awaited(
      adapter(
        streaming_request(chunks, @js_async.AbortController::new().signal()),
        probe.callback(),
      ),
    ).wait()
    assert_eq(reply.status(), if empty_count == 1024 { 400 } else { 200 })
    assert_eq(observed.val, if empty_count > 0 { 0 } else { 65536 })
    probe.settled().wait()
  }
}

///|
async test "already aborted requests still enter cleanup and settle the aggregate promise" {
  let controller = @js_async.AbortController::new()
  controller.abort()
  let probe = Probe::new()
  let entered = Ref(false)
  let adapter = fetch_handler(_ => {
    entered.val = true
    @http.Response::new(200)
  })
  let rejected = try {
    ignore(
      awaited(
        adapter(streaming_request([], controller.signal()), probe.callback()),
      ).wait(),
    )
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
  assert_false(entered.val)
  probe.settled().wait()
  assert_eq(probe.calls(), 1)
}

///|
#external
priv type InputProbe

///|
extern "js" fn InputProbe::new(
  signal : @js_async.AbortSignal,
  failing : Bool,
) -> InputProbe =
  #| (signal, failing) => {
  #|   const state = {cancels: 0};
  #|   state.request = new Request('https://example.test/', {method: 'POST', signal, duplex: 'half',
  #|     body: new ReadableStream({pull(c) {
  #|       if (failing) c.error(new Error('input failure')); else return new Promise(() => {});
  #|     }, cancel() {++state.cancels;}}, {highWaterMark: 0})});
  #|   return state;
  #| }

///|
extern "js" fn InputProbe::request(self : InputProbe) -> JsRequest =
  #| state => state.request

///|
extern "js" fn InputProbe::cancels(self : InputProbe) -> Int32 =
  #| state => state.cancels

///|
async test "host read failure maps to 400 and cancellation releases an active request reader once" {
  for failing in [false, true] {
    let controller = @js_async.AbortController::new()
    let input = InputProbe::new(controller.signal(), failing)
    let probe = Probe::new()
    let started = Ref(false)
    let changed = @cond_var.Cond()
    let cleaned = Ref(false)
    let adapter = fetch_handler(request => {
      defer {
        cleaned.val = true
      }
      started.val = true
      changed.broadcast()
      if request.body is Stream(stream) {
        ignore(@http.read_bounded(stream.take(), 10)) catch {
          _ => ()
        }
      }
      @http.Response::new(200)
    })
    let result = adapter(input.request(), probe.callback())
    while !started.val {
      changed.wait()
    }
    if failing {
      assert_eq(awaited(result).wait().status(), 400)
    } else {
      controller.abort()
      let rejected = try {
        ignore(awaited(result).wait())
        false
      } catch {
        _ => true
      }
      assert_true(rejected)
      assert_eq(input.cancels(), 1)
    }
    assert_true(cleaned.val)
    probe.settled().wait()
  }
}
