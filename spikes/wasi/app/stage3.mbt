///|
const BASE = "http://127.0.0.1:18765"

///|
/// A request body that arrives in pieces, with a pause between them.
priv struct Pieces {
  clock : &@rt.Clock
  pieces : Array[Bytes]
  mut next : Int
}

///|
impl @mttp.BodyStream for Pieces with fn read_some(self) {
  if self.next >= self.pieces.length() {
    return None
  }
  self.clock.sleep(20)
  let p = self.pieces[self.next]
  self.next += 1
  Some(p)
}

///|
impl @mttp.BodyStream for Pieces with fn close(_) {
  ()
}

///|
fn describe(e : Error) -> String {
  match e {
    @mttp.TransportError(..) as t =>
      t.message() + (if t.is_unsent() { " [unsent]" } else { "" })
    other => other.to_string()
  }
}

///|
async fn expect_error(
  name : String,
  backend : WasiBackend,
  clock : &@rt.Clock,
  request : @mttp.Request,
  options : @mttp.SendOptions,
  read_body~ : Bool = false,
) -> Unit {
  let t0 = clock.now_unix_ms()
  let outcome = try {
    let response = backend.send(request, options)
    if read_body {
      let bytes = response.body.read_all(max=1 << 20)
      "ok: \{response.status}, \{bytes.length()} bytes"
    } else {
      "ok: \{response.status}"
    }
  } catch {
    e => describe(e)
  } noraise {
    s => s
  }
  say("  \{name}: \{outcome} (\{clock.now_unix_ms() - t0} ms)")
}

///|
async fn stage3() -> Unit {
  let clock = WasiClock::{  }
  let timer = WasiTimer::{ clock, }
  @sim.check_backend_contract(() => WasiBackend::new(clock, timer))
  say("stage3: check_backend_contract passed")
  let backend = WasiBackend::new(clock, timer)
  let exchange = @mttp.SendOptions::default()
  // The Client over the backend.
  let client = @mclient.Client::new(backend, clock, timer~)
  let reply = client.send(@mclient.get(BASE + "/hello"))
  say("  client GET: \{reply.status} \{@debug.to_string(reply.body)}")
  let src = Pieces::{ clock, pieces: [b"one,", b"two,", b"three"], next: 0 }
  let post = {
    ..@mttp.Request::new(Post, BASE + "/echo"),
    body: Stream(@mttp.StreamBody::new(src)),
  }
  let reply = client.send(@mclient.request(post))
  say("  client streamed POST: \{reply.status} \{@debug.to_string(reply.body)}")
  let small = @mclient.Client::new(backend, clock, timer~, max_body_bytes=1000)
  let big = try {
    let r = small.send(@mclient.get(BASE + "/big?n=2000"))
    "\{r.status} \{@debug.to_string(r.body).length()} chars"
  } catch {
    e => describe(e)
  } noraise {
    s => s
  }
  say("  client GET of 2000 bytes, limit 1000: \{big}")
  // The backend alone, for exact kinds and phases.
  expect_error(
    "slow head, 300 ms deadline",
    backend,
    clock,
    @mttp.Request::get(BASE + "/slow-head?ms=2000"),
    { ..exchange, timeout_ms: Some(300) },
  )
  expect_error(
    "slow body, Exchange, 300 ms deadline",
    backend,
    clock,
    @mttp.Request::get(BASE + "/slow-body?ms=2000"),
    { ..exchange, timeout_ms: Some(300) },
    read_body=true,
  )
  expect_error(
    "slow body, Stream idle 200 ms",
    backend,
    clock,
    @mttp.Request::get(BASE + "/slow-body?ms=2000"),
    @mttp.SendOptions::{ timeout_ms: None, body: @mttp.BodyTiming::Stream(idle_ms=Some(200)) },
    read_body=true,
  )
  expect_error(
    "declared 2000 bytes, Exchange max 1000",
    backend,
    clock,
    @mttp.Request::get(BASE + "/big?n=2000"),
    @mttp.SendOptions::{ timeout_ms: None, body: @mttp.BodyTiming::Exchange(max_bytes=1000) },
    read_body=true,
  )
  expect_error(
    "connection refused",
    backend,
    clock,
    @mttp.Request::get("http://127.0.0.1:1/"),
    exchange,
  )
  expect_error(
    "unknown host",
    backend,
    clock,
    @mttp.Request::get("http://no-such-host.invalid/"),
    exchange,
  )
  // Closing a body mid-way: the host must let the connection go.
  let drip = backend.send(@mttp.Request::get(BASE + "/drip"), @mttp.SendOptions::{
    timeout_ms: None,
    body: @mttp.BodyTiming::Stream(idle_ms=None),
  })
  guard drip.body is Stream(s) else { fail("drip: not a stream") }
  let reader = s.take()
  ignore(reader.read_some())
  ignore(reader.read_some())
  reader.close()
  clock.sleep(300)
  let closed = backend.send(@mttp.Request::get(BASE + "/closed"), exchange)
  let n = closed.body.read_all(max=100)
  say("  drip closed after 2 reads; server saw early closes: \{@utf8.decode_lossy(n)}")
  // Cancelling a body read through the Timer (Stream, no idle limit).
  let drip2 = backend.send(@mttp.Request::get(BASE + "/drip"), @mttp.SendOptions::{
    timeout_ms: None,
    body: @mttp.BodyTiming::Stream(idle_ms=None),
  })
  let finished = timer.within(200, () => {
    ignore(drip2.body.read_all(max=1 << 20)) catch {
      _ => ()
    }
  })
  clock.sleep(300)
  let closed = backend.send(@mttp.Request::get(BASE + "/closed"), exchange)
  let n = closed.body.read_all(max=100)
  say("  drip read cancelled by within(200): finished=\{finished}; early closes now: \{@utf8.decode_lossy(n)}")
  if !backend.notes.is_empty() {
    say("  host notes: \{backend.notes[0]}")
  }
}

///|
priv struct Failing {}

///|
impl @mttp.BodyStream for Failing with fn read_some(_) {
  raise @mttp.TransportError(kind=Network, phase=Write, detail="the caller's stream failed")
}

///|
impl @mttp.BodyStream for Failing with fn close(_) {
  ()
}

///|
pub async fn stage3_rule3() -> Unit {
  let clock = WasiClock::{  }
  let backend = WasiBackend::new(clock, WasiTimer::{ clock, })
  expect_error(
    "stream body failing on its first read",
    backend,
    clock,
    { ..@mttp.Request::new(Post, BASE + "/echo"), body: Stream(@mttp.StreamBody::new(Failing::{  })) },
    @mttp.SendOptions::default(),
  )
}
