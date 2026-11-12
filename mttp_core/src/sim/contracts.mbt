// The shared contract checks of CONTRACT.md. Each runs against the doubles
// of this package and against gaato/mttp_async's adapters, so a rule is
// tested the same way on both sides. A check raises `Failure` naming the
// first rule it saw broken; an unexpected `TransportError` from the code
// under test propagates as it is. The checks use only the ports, so they run
// on whatever scheduler the caller provides.

///|
/// The failure a check raises for a broken rule.
fn violation(check : String, rule : String) -> Failure {
  Failure("\{check}: \{rule}")
}

///|
/// The sentinel a check raises from a monitor, to recognise it again.
fn sentinel(check : String, step : String) -> @mttp_core.TransportError {
  @mttp_core.TransportError(
    kind=Protocol,
    phase=Unknown,
    detail="\{check}: \{step}",
  )
}

///|
/// Whether `error` is the sentinel made with `detail`.
fn is_sentinel(error : @mttp_core.TransportError, detail : String) -> Bool {
  let @mttp_core.TransportError(detail=actual, ..) = error
  actual == detail
}

///|
/// Checks the Coordination and Signal rules: a signal is sticky; a monitor
/// that completes lets the primary finish; the primary finishing cancels a
/// waiting monitor; a monitor failure cancels the primary and is raised; a
/// primary failure is raised; a primary success delivered before a monitor
/// error is final; and a cancelled supervision, nested inside another,
/// joins every child's cleanup before it returns. `supervise` returns only
/// after its children's cleanup in every case.
///
/// `suspend` yields to the scheduler once (a zero-length sleep or a pause),
/// so a child can reach its wait before the other acts.
pub async fn check_coordination_contract(
  coordination : &@rt.Coordination,
  suspend~ : async () -> Unit noraise,
) -> Unit {
  let check = "check_coordination_contract"
  // A signal is sticky: a notify before the wait is kept.
  let sticky = coordination.signal()
  sticky.notify()
  sticky.notify()
  sticky.wait()
  sticky.wait()
  //
  let cleaned = Ref(0)
  let finished = Ref(false)
  let started = coordination.signal()
  coordination.supervise(
    primary=() => {
      started.wait()
      suspend()
      finished.val = true
    },
    monitor=() => {
      defer {
        cleaned.val += 1
      }
      started.notify()
    },
  )
  if !finished.val {
    raise violation(check, "a monitor that completes must let primary finish")
  }
  //
  let forever = coordination.signal()
  let started = coordination.signal()
  coordination.supervise(primary=() => started.wait(), monitor=() => {
    defer {
      cleaned.val += 1
    }
    started.notify()
    forever.wait()
  })
  if cleaned.val != 2 {
    raise violation(
      check, "primary finishing must cancel the monitor and join its cleanup",
    )
  }
  //
  let detail = "\{check}: monitor failure"
  let started = coordination.signal()
  let raised = try {
    coordination.supervise(
      primary=() => {
        defer {
          cleaned.val += 1
        }
        started.notify()
        forever.wait()
      },
      monitor=() => {
        started.wait()
        raise sentinel(check, "monitor failure")
      },
    )
    false
  } catch {
    @mttp_core.TransportError(_) as error if is_sentinel(error, detail) => true
    @mttp_core.TransportError(_) =>
      raise violation(check, "a monitor failure was replaced by another error")
  }
  if !raised {
    raise violation(check, "a monitor failure must be raised")
  }
  if cleaned.val != 3 {
    raise violation(
      check, "a monitor failure must cancel primary and join its cleanup",
    )
  }
  //
  let detail = "\{check}: primary failure"
  let started = coordination.signal()
  let raised = try {
    coordination.supervise(
      primary=() => {
        started.wait()
        raise sentinel(check, "primary failure")
      },
      monitor=() => {
        defer {
          cleaned.val += 1
        }
        started.notify()
        forever.wait()
      },
    )
    false
  } catch {
    @mttp_core.TransportError(_) as error if is_sentinel(error, detail) => true
    @mttp_core.TransportError(_) =>
      raise violation(check, "a primary failure was replaced by another error")
  }
  if !raised {
    raise violation(check, "a primary failure must be raised")
  }
  if cleaned.val != 4 {
    raise violation(
      check, "a primary failure must cancel the monitor and join its cleanup",
    )
  }
  // A primary success delivered before a monitor error is final. The
  // monitor fails only once primary has returned, so the order holds
  // whichever child the scheduler starts first.
  let returned = coordination.signal()
  coordination.supervise(primary=() => returned.notify(), monitor=() => {
    returned.wait()
    raise sentinel(check, "late monitor failure")
  }) catch {
    @mttp_core.TransportError(_) =>
      raise violation(
        check, "a monitor failure after primary finished must be ignored",
      )
  }
  // Cancelling a supervision from outside (here: its parent's monitor
  // fails) unwinds both of its children before the parent returns.
  let detail = "\{check}: outer monitor failure"
  let entered = coordination.signal()
  let nested = Ref(0)
  let raised = try {
    coordination.supervise(
      primary=() => {
        defer {
          nested.val += 1
        }
        coordination.supervise(
          primary=() => {
            defer {
              nested.val += 1
            }
            entered.notify()
            forever.wait()
          },
          monitor=() => {
            defer {
              nested.val += 1
            }
            forever.wait()
          },
        )
      },
      monitor=() => {
        entered.wait()
        suspend()
        raise sentinel(check, "outer monitor failure")
      },
    )
    false
  } catch {
    @mttp_core.TransportError(_) as error if is_sentinel(error, detail) => true
    @mttp_core.TransportError(_) =>
      raise violation(
        check, "the outer monitor's failure was replaced by another error",
      )
  }
  if !raised {
    raise violation(check, "the outer monitor's failure must be raised")
  }
  if nested.val != 3 {
    raise violation(
      check, "a cancelled supervision must join both children's cleanup",
    )
  }
}

///|
/// Reads from `conn` until `want` bytes arrived or EOF, at most `max_len`
/// per read. Returns the bytes and the first broken rule seen.
async fn read_exactly(
  conn : &@rt.Conn,
  want : Int32,
  max_len~ : Int32,
) -> (Bytes, String?) raise @mttp_core.TransportError {
  let out = Buffer()
  while out.length() < want {
    match conn.read(max_len~) {
      None =>
        return (out.to_bytes(), Some("EOF before all written bytes arrived"))
      Some(chunk) if chunk.is_empty() =>
        return (out.to_bytes(), Some("a read returned an empty chunk"))
      Some(chunk) if chunk.length() > max_len =>
        return (out.to_bytes(), Some("a read returned more than max_len bytes"))
      Some(chunk) if chunk.length() > want - out.length() =>
        return (out.to_bytes(), Some("a read returned bytes nobody wrote"))
      Some(chunk) => out.write_bytes(chunk)
    }
  }
  (out.to_bytes(), None)
}

///|
/// Reads exactly `expected` from `conn` or raises the rule it broke.
async fn expect_read(
  check : String,
  conn : &@rt.Conn,
  expected : Bytes,
  max_len~ : Int32,
) -> Unit {
  let (got, problem) = read_exactly(conn, expected.length(), max_len~)
  if problem is Some(rule) {
    raise violation(check, rule)
  }
  if got != expected {
    raise violation(check, "the bytes read differ from the bytes written")
  }
}

///|
/// Runs a read and a write at the same time on `conn`: the read waits for
/// a reply that `peer` writes only after it has read the whole of the
/// write, more than one 64 KiB socket read. An end that holds its read
/// while the write waits cannot finish.
async fn overlap(
  check : String,
  conn : &@rt.Conn,
  peer : &@rt.Conn,
  coordination~ : &@rt.Coordination,
  suspend~ : async () -> Unit noraise,
) -> Unit {
  let big = Bytes::makei(65537, i => (i % 251).to_byte())
  let reply : Ref[(Bytes, String?)] = Ref((b"", None))
  let received : Ref[(Bytes, String?)] = Ref((b"", None))
  coordination.supervise(
    primary=() => {
      coordination.supervise(
        primary=() => reply.val = read_exactly(conn, 5, max_len=2),
        // Lets the read start first, whichever child runs first.
        monitor=() => {
          suspend()
          conn.write(big)
        },
      )
    },
    monitor=() => {
      received.val = read_exactly(peer, big.length(), max_len=4096)
      peer.write(b"reply")
    },
  )
  // The read's own fault first: a read that ends early also cuts the
  // write short.
  match reply.val {
    (_, Some(rule)) => raise violation(check, rule)
    (got, None) if got != b"reply" =>
      raise violation(check, "concurrent read and write corrupted the bytes")
    _ => ()
  }
  match received.val {
    (_, Some(rule)) => raise violation(check, rule)
    (got, None) if got != big =>
      raise violation(check, "concurrent read and write corrupted the bytes")
    _ => ()
  }
}

///|
/// Checks the Conn rules on a connected pair, where what one end writes the
/// other reads: whole writes and nonempty reads of at most `max_len` in both
/// directions; on each end, a read and a write outstanding at the same time
/// (the peer answers the read only after the whole write of more than
/// 64 KiB arrived, so an end that serializes its reads and writes cannot
/// finish); a cancelled read that loses no byte; `close` waking a pending read;
/// idempotent close; a write after close raising `TransportError`; and the
/// peer reading a sticky EOF after a close. Both ends are closed on return.
///
/// `shutdown_left`, for a double that has a write-half shutdown, ends the
/// writes of `left`; the check then also requires that `right` reads a
/// sticky EOF and can still write to `left`. `coordination` runs the
/// concurrent steps and should itself pass `check_coordination_contract`;
/// `suspend` yields to the scheduler once.
///
/// An end that serializes its reads and writes, or whose `close` does not
/// wake its reader, makes the check wait forever rather than fail: no port
/// can tell a slow peer from a stuck one. Run the check under a deadline;
/// the Driver reports such a hang as `DriverError(Deadlock)`.
pub async fn check_conn(
  left : &@rt.Conn,
  right : &@rt.Conn,
  coordination~ : &@rt.Coordination,
  suspend~ : async () -> Unit noraise,
  shutdown_left? : () -> Unit,
) -> Unit {
  let check = "check_conn"
  defer left.close()
  defer right.close()
  left.write(b"abcdef")
  expect_read(check, right, b"abcdef", max_len=2)
  right.write(b"reply")
  expect_read(check, left, b"reply", max_len=2)
  overlap(check, left, right, coordination~, suspend~)
  overlap(check, right, left, coordination~, suspend~)
  // A cancelled read gives up nothing that arrives later.
  let detail = "\{check}: cancel the read"
  let returned = Ref(false)
  coordination.supervise(
    primary=() => {
      let _ = right.read(max_len=1)
      returned.val = true
    },
    monitor=() => {
      suspend()
      raise sentinel(check, "cancel the read")
    },
  ) catch {
    @mttp_core.TransportError(_) as error if is_sentinel(error, detail) => ()
    _ => raise violation(check, "a pending read raised instead of waiting")
  }
  if returned.val {
    raise violation(check, "a read returned although the peer wrote nothing")
  }
  left.write(b"z")
  expect_read(check, right, b"z", max_len=1)
  // Half close, when the double has it: EOF ends only the read half.
  if shutdown_left is Some(shutdown) {
    shutdown()
    if right.read(max_len=1) is Some(_) || right.read(max_len=1) is Some(_) {
      raise violation(check, "EOF after the peer's shutdown is not sticky")
    }
    right.write(b"after")
    expect_read(check, left, b"after", max_len=2)
  }
  // Close wakes a pending read, which then returns EOF or raises.
  let woke : Ref[Bytes?] = Ref(None)
  coordination.supervise(
    primary=() => woke.val = left.read(max_len=1) catch { _ => None },
    monitor=() => {
      suspend()
      left.close()
    },
  )
  if woke.val is Some(_) {
    raise violation(check, "a read woken by close returned bytes")
  }
  left.close()
  let refused = try {
    left.write(b"x")
    false
  } catch {
    _ => true
  }
  if !refused {
    raise violation(check, "a write after close must raise")
  }
  if right.read(max_len=1) is Some(_) || right.read(max_len=1) is Some(_) {
    raise violation(check, "the peer of a closed end must read a sticky EOF")
  }
  right.close()
  right.close()
}

///|
/// Checks the BodyStream rules on a fresh stream from `make` that should
/// produce `expected`: nonempty chunks, exactly the expected bytes, a sticky
/// EOF, idempotent close and EOF after close. A stream that has not ended
/// within `max_reads` reads fails the check instead of keeping it running.
pub async fn check_body_stream_contract(
  make : () -> &@mttp_core.BodyStream,
  expected : Bytes,
  max_reads~ : Int32 = 1024,
) -> Unit {
  let check = "check_body_stream_contract"
  let stream = make()
  defer stream.close()
  let actual = Buffer()
  let mut ended = false
  for _ in 0..<max_reads.max(0) {
    match stream.read_some() {
      None => {
        ended = true
        break
      }
      Some(chunk) if chunk.is_empty() =>
        raise violation(check, "a read returned an empty chunk")
      Some(chunk) if chunk.length() > expected.length() - actual.length() =>
        raise violation(
          check, "the stream returned more than the expected bytes",
        )
      Some(chunk) => actual.write_bytes(chunk)
    }
  }
  if !ended {
    raise violation(check, "the stream did not end within \{max_reads} reads")
  }
  if actual.to_bytes() != expected {
    raise violation(check, "the bytes read differ from the expected bytes")
  }
  if stream.read_some() is Some(_) {
    raise violation(check, "EOF is not sticky")
  }
  stream.close()
  stream.close()
  if stream.read_some() is Some(_) {
    raise violation(check, "a read after close must return EOF")
  }
}

///|
/// A stream that is never read: a backend refuses its request first.
priv struct Unread {}

///|
impl @mttp_core.BodyStream for Unread with fn read_some(_) {
  None
}

///|
impl @mttp_core.BodyStream for Unread with fn close(_) {
  ()
}

///|
/// Sends `request` under `options` and requires a refusal of `kind` in
/// phase Pool, so unsent.
async fn expect_refusal(
  check : String,
  backend : &@mttp_core.Backend,
  label : String,
  request : @mttp_core.Request,
  options : @mttp_core.SendOptions,
  kind : @mttp_core.Kind,
) -> Unit {
  let response = backend.send(request, options) catch {
    @mttp_core.TransportError(kind=actual, phase=Pool, ..) if actual == kind =>
      return
    @mttp_core.TransportError(kind=actual, phase~, ..) =>
      raise violation(
        check,
        "\{label} raised \{@debug.to_string(actual)} in \{@debug.to_string(phase)}; want \{@debug.to_string(kind)} in Pool",
      )
  }
  response.close()
  raise violation(check, "\{label} was accepted")
}

///|
/// Checks the Backend rules that need no peer, on a fresh backend from
/// `make`: an invalid method, URL, header name or value, a stream body
/// declaring a negative length, and SendOptions that `validate` refuses are
/// all refused in phase Pool, before any I/O; `close` is idempotent; and a
/// send after close raises `Closed` in phase Pool.
///
/// The requests go to `url`, which can name a local fixture. A backend that
/// breaks the rules may do I/O there. Deadlines, framing, bodies and
/// connection reuse need configured peers and belong to each backend's own
/// suite.
pub async fn check_backend_contract(
  make : () -> &@mttp_core.Backend,
  url~ : String = "https://example.test/",
) -> Unit {
  let check = "check_backend_contract"
  let backend = make()
  defer backend.close()
  let options = @mttp_core.SendOptions::default()
  let get = @mttp_core.Request::get(url)
  let requests = [
    ("an invalid method", @mttp_core.Request::new(Other("BAD METHOD"), url)),
    ("a URL with CRLF", @mttp_core.Request::get(url + "\r\n")),
    ("a header value with LF", get.header("x-test", "one\ntwo")),
    ("a header name with a space", get.header("bad name", "value")),
    (
      "a stream declaring a negative length",
      @mttp_core.Request::post(url).body_stream(Unread::{ }, length=-1L),
    ),
  ]
  for item in requests {
    let (label, request) = item
    expect_refusal(check, backend, label, request, options, Invalid)
  }
  expect_refusal(
    check,
    backend,
    "a zero attempt deadline",
    get,
    { ..options, timeout_ms: Some(0), },
    Timeout(ms=0),
  )
  expect_refusal(
    check,
    backend,
    "a negative body byte limit",
    get,
    { ..options, body: Exchange(max_bytes=-1), },
    Invalid,
  )
  expect_refusal(
    check,
    backend,
    "a zero idle limit",
    get,
    { ..options, body: Stream(idle_ms=Some(0)), },
    Invalid,
  )
  backend.close()
  backend.close()
  expect_refusal(check, backend, "a send after close", get, options, Closed)
}
