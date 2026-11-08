///|
/// A pull reader over one event-stream body. Complete events from a chunk
/// precede any overflow in that chunk; pending overflow is checked before
/// reading again, even when the peer sends nothing more. Use one reader per
/// source, without concurrent pulls, and close it when stopping early.
pub struct SseReader {
  priv source : &@http.BodyStream
  priv parser : SseParser
  priv ready : Array[SseEvent]
  priv mut offset : Int32
  priv mut closed : Bool
}

///|
/// Takes ownership of a source without reading it. Each event has the same
/// byte bound as SseParser (16 MiB by default); queued events come from at
/// most one source chunk. EOF, failure, cancellation and close release the
/// source. `each` also closes it when its callback fails or a sentinel stops it.
///
/// ```mbt check
/// test {
///   let d = @driver.Driver::new()
///   let source = @sim.Feed::bytes(d, [b"data: hello\n\n"])
///   let reader = @sse.SseReader::new(source)
///   let events = []
///   d.run(() => reader.each(event => events.push(event.data)))
///   assert_eq(events, ["hello"])
///   assert_eq(source.closes(), 1)
/// }
/// ```
pub fn SseReader::new(
  source : &@http.BodyStream,
  max_event_bytes~ : Int32 = default_max_event_bytes,
) -> SseReader {
  {
    source,
    parser: SseParser::new(max_event_bytes~),
    ready: [],
    offset: 0,
    closed: false,
  }
}

///|
/// Pulls the next complete event. EOF is permanent, incomplete final events
/// are discarded, and transport failures propagate unchanged. Closes the
/// source on EOF, failure or cancellation; a successful pull keeps it open.
pub async fn SseReader::next_event(
  self : SseReader,
) -> SseEvent? raise @http.TransportError {
  if self.closed {
    return None
  }
  errdefer self.close()
  while self.offset == self.ready.length() {
    self.ready.clear()
    self.offset = 0
    // feed may have returned completed events before recording an overflow.
    // Surface that failure now, before a read that could wait indefinitely.
    ignore(self.parser.feed(b""))
    match self.source.read_some() {
      Some(chunk) => self.ready.append(self.parser.feed(chunk))
      None => {
        ignore(self.parser.finish())
        self.close()
        return None
      }
    }
  }
  let event = self.ready[self.offset]
  self.offset += 1
  Some(event)
}

///|
/// Consumes events until EOF or a stop predicate matches, without delivering
/// the matching sentinel. Closes the source on every exit, including callback
/// failure and cancellation. An intentional stop discards queued events and
/// any pending overflow, preserving protocol-sentinel behavior.
pub async fn SseReader::each(
  self : SseReader,
  receive : async (SseEvent) -> Unit,
  stop~ : (SseEvent) -> Bool = _ => false,
) -> Unit {
  defer self.close()
  while self.next_event() is Some(event) {
    if stop(event) {
      return
    }
    receive(event)
  }
}

///|
/// Closes the source once and discards queued events, including before the
/// first pull. Later pulls return EOF without touching the source.
pub fn SseReader::close(self : SseReader) -> Unit {
  if !self.closed {
    self.closed = true
    self.ready.clear()
    self.source.close()
  }
}
