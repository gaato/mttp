///|
priv struct ResponseBody {
  backend : H1Backend
  key : String
  agent : String?
  wire : Wire
  framing : @h1.Framing
  chunked : @h1.ChunkedDecoder
  decoder : @codings.ContentDecoder?
  timer : PhaseTimer
  limit : Int32?
  reusable : Bool
  mut remaining : Int64
  mut count : Int64
  mut chunks : Array[Bytes]
  mut index : Int32
  mut raw_done : Bool
  mut closed : Bool
  mut busy : Bool
}

///|
fn ResponseBody::new(
  backend : H1Backend,
  key : String,
  agent : String?,
  wire : Wire,
  framing : @h1.Framing,
  decoder : @codings.ContentDecoder?,
  timer : PhaseTimer,
  limit : Int32?,
  reusable : Bool,
) -> ResponseBody {
  {
    backend,
    key,
    agent,
    wire,
    framing,
    decoder,
    timer,
    limit,
    reusable,
    chunked: @h1.ChunkedDecoder::new(backend.head_limits),
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
fn ResponseBody::finish(self : ResponseBody, reusable : Bool) -> Unit {
  if !self.closed {
    self.closed = true
    self.chunks.clear()
    self.backend.release(self.key, self.agent, self.wire, reusable)
  }
}

///|
impl @model.BodyStream for ResponseBody with fn close(self) {
  self.finish(false)
}

///|
impl @model.BodyStream for ResponseBody with fn read_some(self) {
  if self.closed {
    return None
  }
  if self.busy {
    raise @model.TransportError(
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
  let result = self.timer.run(Body, () => {
    @codings.read_decoded(() => self.read_raw(), self.decoder)
  })
  match result {
    Some(bytes) => {
      if self.limit is Some(limit) &&
        bytes.length().to_int64() > limit.to_int64() - self.count {
        raise @model.TransportError(
          kind=TooLarge(limit~),
          phase=Body,
          detail="decoded body exceeds limit",
        )
      }
      if self.limit is Some(_) {
        self.count += bytes.length().to_int64()
      }
      Some(bytes)
    }
    None => {
      self.finish(self.raw_done && self.reusable)
      None
    }
  }
}

///|
async fn ResponseBody::read_raw(self : ResponseBody) -> Bytes? {
  match self.framing {
    Length(_) => {
      if self.remaining == 0L {
        self.raw_done = true
        return None
      }
      guard self.wire.read(self.remaining.min(65536L).to_int()) is Some(bytes) else {
        raise @model.TransportError(
          kind=Protocol,
          phase=Body,
          detail="EOF before Content-Length",
        )
      }
      self.remaining -= bytes.length().to_int64()
      Some(bytes)
    }
    Chunked => {
      while true {
        if self.index < self.chunks.length() {
          let bytes = self.chunks[self.index]
          self.index += 1
          return Some(bytes)
        }
        self.chunks.clear()
        self.index = 0
        if self.raw_done {
          return None
        }
        guard self.wire.read(65536) is Some(bytes) else {
          self.chunked.finish()
          self.raw_done = true
          return None
        }
        let decoded = self.chunked.feed(bytes)
        self.chunks = decoded.chunks
        self.raw_done = decoded.done
        self.wire.unread(bytes[decoded.consumed:])
      }
      None
    }
    UntilClose => {
      let bytes = self.wire.read(65536)
      if bytes is None {
        self.raw_done = true
      }
      bytes
    }
    NoBody => {
      self.raw_done = true
      None
    }
    @h1.Framing::.. =>
      raise @model.TransportError(
        kind=Protocol,
        phase=Body,
        detail="unsupported body framing",
      )
  }
}
