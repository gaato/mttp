///|
priv struct Selected[T] {
  accept : Bool
  reject : (@model.ResponseHead, Bytes) -> Unit raise
  read : async (@model.ResponseHead, @model.Body, RequestOptions) -> T
  streaming : Bool
}

///|
/// A response interpretation selected once after its head arrives. Buffered
/// readers participate in attempts; accepted streaming readers run only once.
pub struct ResponseAs[T] {
  priv select : (@model.ResponseHead) -> Selected[T]
  priv streaming : Bool
}

///|
fn default_reject(head : @model.ResponseHead, body : Bytes) -> Unit raise {
  raise UnexpectedStatus(head, body~)
}

///|
/// Creates an interpretation. By default only 2xx heads are accepted, and
/// rejected heads raise UnexpectedStatus after reading a bounded excerpt.
pub fn[T] ResponseAs::new(
  read : async (@model.ResponseHead, @model.Body, RequestOptions) -> T,
  accept_head~ : (@model.ResponseHead) -> Bool = head => {
    @model.is_success(head.status)
  },
  reject~ : (@model.ResponseHead, Bytes) -> Unit raise = default_reject,
  streaming~ : Bool = false,
) -> ResponseAs[T] {
  {
    select: head => { accept: accept_head(head), reject, read, streaming, },
    streaming,
  }
}

///|
/// Buffers a body within the supplied byte limit and closes its stream.
pub async fn read_body(
  body : @model.Body,
  limit : Int32,
) -> Bytes raise @model.TransportError {
  if limit < 0 {
    if body is Stream(stream) {
      stream.close()
    }
    raise @model.TransportError(
      kind=Invalid,
      phase=Body,
      detail="negative body limit",
    )
  }
  match body {
    Empty => b""
    Bytes(bytes) =>
      if bytes.length() > limit {
        raise @model.TransportError(
          kind=TooLarge(limit~),
          phase=Body,
          detail="body exceeds limit",
        )
      } else {
        bytes
      }
    Stream(stream) => @model.read_bounded(stream.take(), limit)
    @model.Body::.. =>
      raise @model.TransportError(
        kind=Invalid,
        phase=Body,
        detail="unsupported body kind",
      )
  }
}

///|
async fn error_excerpt(body : @model.Body) -> Bytes raise @model.TransportError {
  match body {
    Empty => b""
    Bytes(bytes) => bytes[:bytes.length().min(max_error_body)].to_owned()
    Stream(stream) => {
      let reader = stream.take()
      defer reader.close()
      let out = Buffer()
      while out.length() < max_error_body && reader.read_some() is Some(chunk) {
        let remaining = max_error_body - out.length()
        out.write_bytes(chunk[:chunk.length().min(remaining)])
      }
      out.to_bytes()
    }
    @model.Body::.. =>
      raise @model.TransportError(
        kind=Invalid,
        phase=Body,
        detail="unsupported body kind",
      )
  }
}

///|
/// Buffers successful bodies as bytes, bounded by max_body_bytes.
pub fn as_bytes() -> ResponseAs[Bytes] {
  ResponseAs::new((_, body, options) => read_body(body, options.max_body_bytes))
}

///|
/// Buffers a UTF-8 string, replacing malformed sequences with U+FFFD.
pub fn as_string() -> ResponseAs[String] {
  as_bytes().map(bytes => @utf8.decode_lossy(bytes))
}

///|
/// Parses a UTF-8 JSON value; failures retain the head and original bytes.
pub fn as_json_value() -> ResponseAs[Json] {
  as_bytes().map_with_head((bytes, head) => {
    @json.parse(@utf8.decode(bytes)) catch {
      error =>
        raise Deserialization(head, message=error.to_string(), body=bytes)
    }
  })
}

///|
/// Parses and decodes JSON using the target type's FromJson implementation.
pub fn[T : @json.FromJson] as_json() -> ResponseAs[T] {
  as_bytes().map_with_head((bytes, head) => {
    let value = @json.parse(@utf8.decode(bytes)) catch {
      error =>
        raise Deserialization(head, message=error.to_string(), body=bytes)
    }
    @json.from_json(value) catch {
      error =>
        raise Deserialization(head, message=error.to_string(), body=bytes)
    }
  })
}

///|
/// Discards accepted bodies, closing streams without reading them.
pub fn ignore_body() -> ResponseAs[Unit] {
  ResponseAs::new((_, body, _) => if body is Stream(stream) { stream.close() })
}

///|
priv struct MemoryStream {
  mut bytes : Bytes?
}

///|
impl @model.BodyStream for MemoryStream with fn read_some(self) {
  let bytes = self.bytes
  self.bytes = None
  bytes
}

///|
impl @model.BodyStream for MemoryStream with fn close(self) {
  self.bytes = None
}

///|
fn stream_of(
  body : @model.Body,
) -> &@model.BodyStream raise @model.TransportError {
  match body {
    Stream(stream) => stream.take()
    Bytes(bytes) if !bytes.is_empty() => MemoryStream::{ bytes: Some(bytes), }
    _ => MemoryStream::{ bytes: None, }
  }
}

///|
/// Gives the accepted stream to a callback once and closes it on every exit.
pub fn[T] as_stream(
  read : async (@model.ResponseHead, &@model.BodyStream) -> T,
) -> ResponseAs[T] {
  ResponseAs::new(
    (head, body, _) => {
      let stream = stream_of(body)
      defer stream.close()
      read(head, stream)
    },
    streaming=true,
  )
}

///|
/// Reads bounded SSE events until EOF or a stop predicate matches. The stop
/// event is not delivered, allowing protocol sentinels such as [DONE].
pub fn as_sse(
  receive : async (@sse.SseEvent) -> Unit,
  max_event_bytes~ : Int32 = 16 * 1024 * 1024,
  stop~ : (@sse.SseEvent) -> Bool = _ => false,
) -> ResponseAs[Unit] {
  as_stream((_, stream) => {
    let parser = @sse.SseParser::new(max_event_bytes~)
    while stream.read_some() is Some(chunk) {
      for event in parser.feed(chunk) {
        if stop(event) {
          return
        }
        receive(event)
      }
    }
    // WHATWG EOF discards an incomplete event; finish can still report an
    // overflow deferred until after the last dispatched event.
    let _ = parser.finish()
  })
}

///|
/// Selects an interpretation exactly once per response head. The selected
/// reader runs inside the attempt, so this combinator is buffered for deadline
/// and retry policy even when its callback reads a stream.
pub fn[T] from_head(
  choose : (@model.ResponseHead) -> ResponseAs[T],
) -> ResponseAs[T] {
  {
    select: head => { ..(choose(head).select)(head), streaming: false, },
    streaming: false,
  }
}

///|
/// Accepts every status while retaining the selected reader and streaming mode.
pub fn[T] ResponseAs::any_status(self : ResponseAs[T]) -> ResponseAs[T] {
  {
    select: head => { ..(self.select)(head), accept: true, },
    streaming: self.streaming,
  }
}

///|
/// Maps the decoded value; mapping failures follow the same attempt policy.
pub fn[A, B] ResponseAs::map(
  self : ResponseAs[A],
  f : (A) -> B raise,
) -> ResponseAs[B] {
  self.map_with_head((value, _) => f(value))
}

///|
/// Maps a decoded value together with its response metadata.
pub fn[A, B] ResponseAs::map_with_head(
  self : ResponseAs[A],
  f : (A, @model.ResponseHead) -> B raise,
) -> ResponseAs[B] {
  {
    select: head => {
      let selected = (self.select)(head)
      {
        accept: selected.accept,
        reject: selected.reject,
        streaming: selected.streaming,
        read: (h, body, options) => f((selected.read)(h, body, options), h),
      }
    },
    streaming: self.streaming,
  }
}
