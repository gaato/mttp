// The body of one request, read lazily from the connection as the handler
// pulls it. It shares one deadline (`body_timeout_ms`) from the first pull to
// the end, so a peer that trickles bytes cannot keep a connection forever.
// A failure is sticky and remembered: the response the handler returns is
// replaced by the status of the failure, even when the handler caught it.

///|
priv struct RequestBody {
  wire : Wire
  clock : &@rt.Clock
  framing : @h1.Framing
  limits : ServerLimits
  decoder : @h1.ChunkedDecoder
  /// Bytes of a `Length` body not read yet.
  mut remaining : Int64
  /// Payload bytes delivered so far.
  mut count : Int64
  /// Payload decoded from the last read of a chunked body and not delivered
  /// yet; at most one read's worth.
  chunks : Array[Bytes]
  /// The whole body was read from the wire.
  mut done : Bool
  /// The application closed its reader; the engine may still drain.
  mut closed : Bool
  /// `100 Continue` is still owed before the first read from the wire.
  mut expect : Bool
  mut failure : @mttp.TransportError?
  /// The first body pull requests ownership from the read-ahead monitor.
  mut claimed : Bool
  claim : &@rt.Signal
  /// Notified only after the monitor's pending read has unwound.
  ready : &@rt.Signal
  /// True during a body pull. Cancellation deliberately leaves it true so
  /// an enclosing response-producer timeout can identify an input wait.
  mut reading : Bool
  /// Notified once the whole body was read, so the peer monitor may read
  /// ahead.
  changed : &@rt.Signal
  mut started_at : Int64?
}

///|
fn RequestBody::new(
  wire : Wire,
  clock : &@rt.Clock,
  coordination : &@rt.Coordination,
  framing : @h1.Framing,
  limits : ServerLimits,
  expect~ : Bool,
) -> RequestBody {
  let done = framing is (NoBody | UntilClose) || framing == Length(0L)
  let changed = coordination.signal()
  if done {
    changed.notify()
  }
  {
    wire,
    clock,
    framing,
    limits,
    decoder: @h1.ChunkedDecoder::new(@h1.Limits::default()),
    remaining: if framing is Length(n) {
      n
    } else {
      0L
    },
    count: 0L,
    chunks: [],
    done,
    closed: false,
    expect: expect && !done,
    failure: None,
    claimed: false,
    claim: coordination.signal(),
    ready: coordination.signal(),
    reading: false,
    changed,
    started_at: None,
  }
}

///|
/// What is left of the body's deadline; raises `Timeout` in phase Body once
/// it ran out. The deadline starts at the first pull.
fn RequestBody::budget(self : RequestBody) -> Int32 raise @mttp.TransportError {
  let now = self.clock.now_unix_ms()
  let started = self.started_at.unwrap_or(now)
  self.started_at = Some(started)
  let elapsed = (now - started).max(0L)
  let limit = self.limits.body_timeout_ms
  if elapsed >= limit.to_int64() {
    raise timeout(limit, Body, "the request body")
  }
  limit - elapsed.to_int()
}

///|
/// The next piece of payload, at most `max_len` bytes from the wire, or
/// `None` at the end. Failures are sticky.
async fn RequestBody::next(
  self : RequestBody,
  max_len~ : Int32 = io_bytes,
) -> Bytes? raise @mttp.TransportError {
  if self.failure is Some(error) {
    raise error
  }
  self.reading = true
  let chunk = try {
    if !self.done && !self.claimed {
      // Handoff cleanup counts against the first pull's body budget too.
      let _ = self.budget()
      self.claimed = true
      self.claim.notify()
      self.ready.wait()
    }
    self.next_raw(max_len)
  } catch {
    error => {
      self.reading = false
      raise self.fail(error)
    }
  }
  self.reading = false
  if chunk is Some(bytes) {
    self.count += bytes.length().to_int64()
    if self.count > self.limits.max_body_bytes.to_int64() {
      let error = @mttp.TransportError(
        kind=TooLarge(limit=self.limits.max_body_bytes),
        phase=Body,
        detail="request body exceeds \{self.limits.max_body_bytes} bytes",
      )
      raise self.fail(error)
    }
  }
  chunk
}

///|
/// Records the body's first failure and returns `error` to raise.
fn RequestBody::fail(
  self : RequestBody,
  error : @mttp.TransportError,
) -> @mttp.TransportError {
  if self.failure is None {
    self.failure = Some(error)
  }
  self.chunks.clear()
  error
}

///|
async fn RequestBody::next_raw(
  self : RequestBody,
  max_len : Int32,
) -> Bytes? raise @mttp.TransportError {
  for ;; {
    if self.done && self.chunks.is_empty() {
      return None
    }
    let budget = self.budget()
    if !self.chunks.is_empty() {
      return Some(self.chunks.remove(0))
    }
    if self.expect {
      self.expect = false
      self.wire.write(b"HTTP/1.1 100 Continue\r\n\r\n", budget)
    }
    let read = within(
      self.wire.timer,
      self.budget(),
      timeout(self.limits.body_timeout_ms, Body, "the request body"),
      () => self.wire.read(max_len, Body),
    )
    guard read is Some(bytes) else {
      raise @mttp.TransportError(
        kind=Protocol,
        phase=Body,
        detail="the peer ended the request body early",
      )
    }
    match self.framing {
      Length(_) => {
        let take = bytes.length().to_int64().min(self.remaining).to_int()
        self.remaining -= take.to_int64()
        self.wire.unread(bytes[take:])
        if self.remaining == 0L {
          self.finish()
        }
        return Some(bytes[:take].to_owned())
      }
      _ => {
        let decoded = self.decoder.feed(bytes) catch {
          @h1.ParseError(detail~, ..) =>
            raise @mttp.TransportError(kind=Protocol, phase=Body, detail~)
        }
        self.wire.unread(bytes[decoded.consumed:])
        for chunk in decoded.chunks {
          if !chunk.is_empty() {
            self.chunks.push(chunk)
          }
        }
        if decoded.done {
          self.finish()
        }
      }
    }
  }
}

///|
fn RequestBody::finish(self : RequestBody) -> Unit {
  self.done = true
  self.changed.notify()
}

///|
/// Whether the next request may follow on the connection: reads and
/// discards what the handler left unread, at most `drain_max_bytes`. A
/// failed body, a body still waiting for `100 Continue` or a longer rest
/// leaves the connection to be closed.
async fn RequestBody::drain(
  self : RequestBody,
) -> Bool raise @mttp.TransportError {
  if self.expect {
    return false
  }
  let mut remaining = self.limits.drain_max_bytes
  for ;; {
    if remaining == 0 {
      return self.done && self.chunks.is_empty()
    }
    let chunk = self.next(max_len=remaining.min(io_bytes))
    guard chunk is Some(bytes) else { return true }
    if bytes.length() > remaining {
      return false
    }
    remaining -= bytes.length()
  }
}

///|
impl @mttp.BodyStream for RequestBody with fn read_some(self) {
  if self.closed {
    return None
  }
  errdefer {
    self.closed = true
  }
  let chunk = self.next()
  if chunk is None {
    self.closed = true
  }
  chunk
}

///|
/// Closing the application's reader leaves the bytes on the wire: the
/// engine still answers a failure with its status and drains a small rest
/// before reusing the connection.
impl @mttp.BodyStream for RequestBody with fn close(self) {
  self.closed = true
}
