///|
/// Buffered response processing, including a stream buffered by Client.
pub(all) struct Buffered {}

///|
/// Response processing which may hand a live body to a consumer.
pub(all) struct Streaming {}

///|
/// Closed set of response-lifetime markers used by typed descriptions.
pub trait ResponseMode {
  fn fresh() -> Self
  fn may_stream(Self) -> Bool
}

///|
/// Constructs the buffered marker.
pub impl ResponseMode for Buffered with fn fresh() {
  Buffered::{ }
}

///|
/// Buffered descriptions never contain live-stream consumers.
pub impl ResponseMode for Buffered with fn may_stream(_) {
  false
}

///|
/// Constructs the streaming marker.
pub impl ResponseMode for Streaming with fn fresh() {
  Streaming::{ }
}

///|
/// Streaming descriptions may select buffered or streaming branches.
pub impl ResponseMode for Streaming with fn may_stream(_) {
  true
}

///|
/// Keeps the trait's operations from being promoted to methods of the marker
/// (`#deprecated` on an `extend` declares that the promotion is unwanted).
#deprecated
pub extend Buffered with ResponseMode::{fresh, may_stream}

///|
/// Keeps the trait's operations from being promoted to methods of the marker.
#deprecated
pub extend Streaming with ResponseMode::{fresh, may_stream}

///|
priv struct Selected[T] {
  read : async (@http.ResponseHead, @http.Body, Int32) -> T
  prepare : (async (@http.ResponseHead, @http.Body, Int32) -> Selected[T])?
  streaming : Bool
  excerpt : Bool
}

///|
/// An immutable response description. Selection after the head arrives decides
/// the actual lifetime; the marker describes possible streaming.
pub struct ResponsePlan[T, M] {
  priv select : (@http.ResponseHead, Bool) -> Selected[T]
  priv mode : M
  priv any_status : Bool
}

///|
/// A buffered response description.
pub type ResponseAs[T] = ResponsePlan[T, Buffered]

///|
/// A response description with a scoped live-stream consumer.
pub type StreamResponseAs[T] = ResponsePlan[T, Streaming]

///|
/// Buffers any status within max_body_bytes, then invokes a custom decoder.
/// The decoder sees immutable bytes, never ownership of the original stream.
pub fn[T] ResponsePlan::new(
  decode : (@http.ResponseHead, Bytes) -> T raise,
) -> ResponseAs[T] {
  {
    mode: Buffered::{ },
    any_status: true,
    select: (_, _) => {
      streaming: false,
      prepare: None,
      excerpt: false,
      read: (head, body, limit) => decode(head, read_body(body, limit)),
    },
  }
}

///|
/// Buffers a body within the supplied byte limit and closes its stream.
pub async fn read_body(
  body : @http.Body,
  limit : Int32,
) -> Bytes raise @http.TransportError {
  if limit < 0 {
    if body is Stream(stream) {
      stream.close()
    }
    raise @http.TransportError(
      kind=Invalid,
      phase=Body,
      detail="negative body limit",
    )
  }
  match body {
    Empty => b""
    Bytes(bytes) =>
      if bytes.length() > limit {
        raise @http.TransportError(
          kind=TooLarge(limit~),
          phase=Body,
          detail="body exceeds limit",
        )
      } else {
        bytes
      }
    Stream(stream) => @http.read_bounded(stream.take(), limit)
    @http.Body::.. =>
      raise @http.TransportError(
        kind=Invalid,
        phase=Body,
        detail="unsupported body kind",
      )
  }
}

///|
fn diagnostic_body(bytes : Bytes) -> Bytes {
  if bytes.length() <= max_error_body {
    bytes
  } else {
    bytes[:max_error_body].to_owned()
  }
}

///|
async fn error_excerpt(body : @http.Body) -> Bytes raise @http.TransportError {
  match body {
    Empty => b""
    Bytes(bytes) => diagnostic_body(bytes)
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
    @http.Body::.. =>
      raise @http.TransportError(
        kind=Invalid,
        phase=Body,
        detail="unsupported body kind",
      )
  }
}

///|
fn[T] rejected() -> Selected[Result[T, ResponseFailure]] {
  {
    streaming: false,
    prepare: None,
    excerpt: true,
    read: (head, body, _) => {
      Err(UnexpectedStatus(head, body=error_excerpt(body)))
    },
  }
}

///|
/// Rejects a head-selected representation with a bounded diagnostic excerpt.
/// This description always returns UnexpectedStatus, including for HTTP 2xx.
pub fn[T] ResponsePlan::reject() -> ResponseAs[Result[T, ResponseFailure]] {
  { mode: Buffered::{ }, any_status: false, select: (_, _) => rejected(), }
}

///|
/// Buffers successful bodies; non-2xx responses are bounded failure values.
pub fn as_bytes() -> ResponseAs[Result[Bytes, ResponseFailure]] {
  {
    mode: Buffered::{ },
    any_status: false,
    select: (head, any) => {
      if !any && !@http.is_success(head.status) {
        rejected()
      } else {
        {
          streaming: false,
          prepare: None,
          excerpt: false,
          read: (_, body, limit) => Ok(read_body(body, limit)),
        }
      }
    },
  }
}

///|
/// Decodes UTF-8 lossily while preserving HTTP failures as values.
pub fn as_string() -> ResponseAs[Result[String, ResponseFailure]] {
  as_bytes().map_ok(bytes => @utf8.decode_lossy(bytes))
}

///|
fn json_value(
  head : @http.ResponseHead,
  bytes : Bytes,
) -> Result[Json, ResponseFailure] {
  Ok(@json.parse(@utf8.decode(bytes))) catch {
    error =>
      Err(
        Deserialization(
          head,
          message=error.to_string(),
          body=diagnostic_body(bytes),
        ),
      )
  }
}

///|
/// Parses JSON; status and decoding failures are received-response values.
pub fn as_json_value() -> ResponseAs[Result[Json, ResponseFailure]] {
  as_bytes().map_with_head((result, head) => {
    match result {
      Ok(bytes) => json_value(head, bytes)
      Err(error) => Err(error)
    }
  })
}

///|
/// Parses and decodes JSON without raising received-response failures.
pub fn[T : @json.FromJson] as_json() -> ResponseAs[Result[T, ResponseFailure]] {
  as_bytes().map_with_head((result, head) => {
    match result {
      Err(error) => Err(error)
      Ok(bytes) =>
        match json_value(head, bytes) {
          Err(error) => Err(error)
          Ok(value) =>
            Ok(@json.from_json(value)) catch {
              error =>
                Err(
                  Deserialization(
                    head,
                    message=error.to_string(),
                    body=diagnostic_body(bytes),
                  ),
                )
            }
        }
    }
  })
}

///|
/// Discards a successful body; rejected statuses retain a bounded excerpt.
pub fn ignore_body() -> ResponseAs[Result[Unit, ResponseFailure]] {
  {
    mode: Buffered::{ },
    any_status: false,
    select: (head, any) => {
      if !any && !@http.is_success(head.status) {
        rejected()
      } else {
        {
          streaming: false,
          prepare: None,
          excerpt: false,
          read: (_, body, _) => {
            if body is Stream(stream) {
              stream.close()
            }
            Ok(())
          },
        }
      }
    },
  }
}

///|
priv struct MemoryStream {
  mut bytes : Bytes?
}

///|
impl @http.BodyStream for MemoryStream with fn read_some(self) {
  let bytes = self.bytes
  self.bytes = None
  bytes
}

///|
impl @http.BodyStream for MemoryStream with fn close(self) {
  self.bytes = None
}

///|
fn stream_of(body : @http.Body) -> &@http.BodyStream raise @http.TransportError {
  match body {
    Stream(stream) => stream.take()
    Bytes(bytes) if !bytes.is_empty() => MemoryStream::{ bytes: Some(bytes), }
    _ => MemoryStream::{ bytes: None, }
  }
}

///|
/// Hands a successful stream to a callback once, closing it on every exit.
/// Rejected responses are buffered failure values before any handoff.
pub fn[T] as_stream(
  use_ : async (@http.ResponseHead, &@http.BodyStream) -> T,
) -> StreamResponseAs[Result[T, ResponseFailure]] {
  ResponsePlan::stream((head, stream, _) => use_(head, stream))
}

///|
/// Creates a scoped stream interpreter that also receives the effective
/// `max_body_bytes`, for a consumer that buffers the stream itself and must
/// keep the decoded-byte limit the Client would have applied.
/// Client owns cleanup and never retries once this interpreter starts.
pub fn[T] ResponsePlan::stream(
  use_ : async (@http.ResponseHead, &@http.BodyStream, Int32) -> T,
) -> StreamResponseAs[Result[T, ResponseFailure]] {
  {
    mode: Streaming::{ },
    any_status: false,
    select: (head, any) => {
      if !any && !@http.is_success(head.status) {
        rejected()
      } else {
        {
          streaming: true,
          prepare: None,
          excerpt: false,
          read: (head, body, limit) => {
            let stream = stream_of(body)
            defer stream.close()
            Ok(use_(head, stream, limit))
          },
        }
      }
    },
  }
}

///|
/// Reads bounded SSE events until EOF or a protocol stop predicate matches.
/// An event over `max_event_bytes` raises `TooLarge(limit)` in phase Body as
/// soon as the chunk holding it is read, after the events before it in that
/// chunk were delivered.
pub fn as_sse(
  receive : async (@sse.SseEvent) -> Unit,
  max_event_bytes~ : Int32 = 16 * 1024 * 1024,
  stop~ : (@sse.SseEvent) -> Bool = _ => false,
) -> StreamResponseAs[Result[Unit, ResponseFailure]] {
  as_stream((_, stream) => {
    let parser = @sse.SseParser::new(max_event_bytes~)
    while stream.read_some() is Some(chunk) {
      for event in parser.feed(chunk) {
        if stop(event) {
          return
        }
        receive(event)
      }
      // An overflow behind the events this chunk completed is raised now,
      // not after a read that may never come.
      ignore(parser.feed(b""))
    }
    let _ = parser.finish()
  })
}

///|
/// Selects once per head, preserving the selected branch's actual lifetime.
pub fn[T, M : ResponseMode] from_head(
  choose : (@http.ResponseHead) -> ResponsePlan[T, M],
) -> ResponsePlan[T, M] {
  {
    mode: ResponseMode::fresh(),
    any_status: false,
    select: (head, any) => {
      let selected = choose(head)
      (selected.select)(head, any || selected.any_status)
    },
  }
}

///|
/// Widens a buffered description without changing its selected reader.
pub fn[T] ResponsePlan::as_streaming(
  self : ResponseAs[T],
) -> StreamResponseAs[T] {
  { select: self.select, mode: Streaming::{ }, any_status: self.any_status, }
}

///|
/// Interprets every status through the successful branch of this description.
pub fn[T, M] ResponsePlan::any_status(
  self : ResponsePlan[T, M],
) -> ResponsePlan[T, M] {
  { ..self, any_status: true, }
}

///|
/// Transforms the full interpreted value. Unknown mapping errors propagate.
pub fn[A, B, M] ResponsePlan::map(
  self : ResponsePlan[A, M],
  f : (A) -> B raise,
) -> ResponsePlan[B, M] {
  self.map_with_head((value, _) => f(value))
}

///|
/// Transforms an interpreted value together with actual response metadata.
pub fn[A, B, M] ResponsePlan::map_with_head(
  self : ResponsePlan[A, M],
  f : (A, @http.ResponseHead) -> B raise,
) -> ResponsePlan[B, M] {
  {
    mode: self.mode,
    any_status: self.any_status,
    select: (head, any) => map_selected((self.select)(head, any), f),
  }
}

///|
fn[A, B] map_selected(
  selected : Selected[A],
  f : (A, @http.ResponseHead) -> B raise,
) -> Selected[B] {
  {
    streaming: selected.streaming,
    excerpt: selected.excerpt,
    prepare: selected.prepare.map(prepare => {
      (h, body, limit) => map_selected(prepare(h, body, limit), f)
    }),
    read: (h, body, limit) => f((selected.read)(h, body, limit), h),
  }
}

///|
/// Decodes bounded bytes inside the attempt, then hands a successful value
/// to a scoped callback after release and retry decisions. An Err is already
/// the final value, so failures can be inspected before any callback starts.
pub fn[A, T] ResponsePlan::prepared_stream(
  decode : (@http.ResponseHead, Bytes) -> Result[A, T] raise,
  use_ : async (A) -> T,
) -> ResponsePlan[T, Streaming] {
  {
    mode: Streaming::{ },
    any_status: true,
    select: (_, _) => {
      streaming: false,
      excerpt: false,
      read: (_, _, _) => abort("prepared reader must be prepared first"),
      prepare: Some((head, body, limit) => {
        match decode(head, read_body(body, limit)) {
          Err(value) =>
            {
              streaming: false,
              excerpt: false,
              prepare: None,
              read: (_, _, _) => value,
            }
          Ok(value) =>
            {
              streaming: true,
              excerpt: false,
              prepare: None,
              read: (_, _, _) => use_(value),
            }
        }
      }),
    },
  }
}

///|
/// Transforms successful Result values while retaining their error type.
pub fn[A, B, E, M] ResponsePlan::map_ok(
  self : ResponsePlan[Result[A, E], M],
  f : (A) -> B raise,
) -> ResponsePlan[Result[B, E], M] {
  self.map(result => {
    match result {
      Ok(value) => Ok(f(value))
      Err(error) => Err(error)
    }
  })
}
