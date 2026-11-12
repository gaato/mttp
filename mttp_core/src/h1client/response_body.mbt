///|
/// The body of a response, read from its connection as the caller pulls.
/// It owns the connection and its slot until it reaches the end of the
/// message (which parks a reusable connection) or is closed or fails (which
/// closes it).
priv struct ResponseBody {
  client : Client
  key : String
  agent : String?
  wire : Wire
  framing : @h1.Framing
  chunked : @h1.ChunkedDecoder
  timer : PhaseTimer
  /// The most body bytes admitted from the wire, or `None` for no bound.
  limit : Int32?
  /// Whether the connection may be parked once the body ends.
  reusable : Bool
  /// Bytes still due under `Length` framing.
  mut remaining : Int64
  /// Body bytes delivered so far.
  mut count : Int64
  /// Decoded chunk payloads not delivered yet.
  mut chunks : Array[Bytes]
  mut index : Int32
  /// The message ended on the wire.
  mut raw_done : Bool
  mut closed : Bool
  mut busy : Bool
}

///|
fn ResponseBody::new(
  client : Client,
  key : String,
  agent : String?,
  wire : Wire,
  framing : @h1.Framing,
  timer : PhaseTimer,
  limit : Int32?,
  reusable : Bool,
) -> ResponseBody {
  {
    client,
    key,
    agent,
    wire,
    framing,
    timer,
    limit,
    reusable,
    chunked: @h1.ChunkedDecoder::new(client.config.head_limits),
    remaining: match framing {
      Length(n) => n
      _ => 0L
    },
    count: 0L,
    chunks: [],
    index: 0,
    raw_done: false,
    closed: false,
    busy: false,
  }
}

///|
/// Hands the connection back once: parked when `reusable`, closed
/// otherwise; the slot is freed either way.
fn ResponseBody::finish(self : ResponseBody, reusable : Bool) -> Unit {
  if !self.closed {
    self.closed = true
    self.chunks.clear()
    self.client.release(self.key, self.agent, self.wire, reusable)
  }
}

///|
impl @mttp_core.BodyStream for ResponseBody with fn close(self) {
  self.finish(false)
}

///|
/// The next piece of the body under the Body limits: `TooLarge(limit)` at
/// the piece that would cross the byte bound, before it is delivered. Any
/// failure, cancellation included, closes the connection.
impl @mttp_core.BodyStream for ResponseBody with fn read_some(self) {
  if self.closed {
    return None
  }
  if self.busy {
    raise @mttp_core.TransportError(
      kind=Invalid,
      phase=Body,
      detail="concurrent body read",
    )
  }
  self.busy = true
  defer {
    self.busy = false
  }
  errdefer self.finish(false)
  // A declared length past the bound is refused before waiting for bytes.
  if self.limit is Some(limit) &&
    self.framing is Length(declared) &&
    declared > limit.to_int64() {
    raise too_large(limit)
  }
  match self.timer.run(Body, () => self.read_raw()) {
    Some(bytes) => {
      if self.limit is Some(limit) &&
        bytes.length().to_int64() > limit.to_int64() - self.count {
        raise too_large(limit)
      }
      self.count += bytes.length().to_int64()
      Some(bytes)
    }
    None => {
      self.finish(self.raw_done && self.reusable)
      None
    }
  }
}

///|
/// The next nonempty payload piece as the framing delimits it, or `None`
/// at its end.
async fn ResponseBody::read_raw(self : ResponseBody) -> Bytes? {
  match self.framing {
    Length(_) => {
      if self.remaining == 0L {
        self.raw_done = true
        return None
      }
      let max = self.remaining.min(io_bytes.to_int64()).to_int()
      guard self.wire.read(max) is Some(bytes) else {
        raise @mttp_core.TransportError(
          kind=Protocol,
          phase=Body,
          detail="EOF before the end of Content-Length",
        )
      }
      self.remaining -= bytes.length().to_int64()
      Some(bytes)
    }
    Chunked =>
      for ;; {
        if self.index < self.chunks.length() {
          let bytes = self.chunks[self.index]
          self.index += 1
          if !bytes.is_empty() {
            return Some(bytes)
          }
          continue
        }
        self.chunks.clear()
        self.index = 0
        if self.raw_done {
          return None
        }
        guard self.wire.read(io_bytes) is Some(bytes) else {
          self.chunked.finish()
          self.raw_done = true
          return None
        }
        let decoded = self.chunked.feed(bytes)
        self.chunks = decoded.chunks
        self.raw_done = decoded.done
        self.wire.unread(bytes[decoded.consumed:])
      }
    UntilClose => {
      let bytes = self.wire.read(io_bytes)
      if bytes is None {
        self.raw_done = true
      }
      bytes
    }
    _ => {
      self.raw_done = true
      None
    }
  }
}

///|
fn too_large(limit : Int32) -> @mttp_core.TransportError {
  @mttp_core.TransportError(
    kind=TooLarge(limit~),
    phase=Body,
    detail="the response body exceeds \{limit} bytes",
  )
}
