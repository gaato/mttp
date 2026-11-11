///|
/// One status and representation with typed response encoders and decoders.
pub struct Variant[T] {
  priv status : Int32
  priv status_of : ((T) -> Int32)?
  priv dynamic_media : Bool
  priv matches : (T) -> Bool
  priv media_type : String?
  priv schema : @schema.Schema?
  priv item_schema : @schema.Schema?
  priv headers : Array[String]
  priv header_schemas : Map[String, @schema.Schema]
  priv description : String
  /// Attributes every response of this variant carries, such as
  /// `close_on_shutdown` on server-sent events.
  priv attributes : @mttp.Attributes
  priv encode : (T) -> (@mttp.Headers, @mttp.Body)
  priv decode_bytes : ((@mttp.ResponseHead, Bytes) -> T raise)?
  priv decode_stream : (async (@mttp.ResponseHead, &@mttp.BodyStream) -> T)?
}

///|
/// Documentation metadata for one response representation.
pub struct VariantDoc {
  status : Int32
  dynamic_status : Bool
  dynamic_media : Bool
  media_type : String?
  schema : @schema.Schema?
  // Schema of each item of a sequential media type (an SSE event), as in
  // OpenAPI 3.2's Media Type Object `itemSchema`.
  item_schema : @schema.Schema?
  headers : Array[String]
  header_schemas : Map[String, @schema.Schema]
  description : String
}

///|
/// Returns the status, media type, schema and header metadata.
pub fn[T] Variant::doc(self : Variant[T]) -> VariantDoc {
  {
    status: self.status,
    dynamic_status: self.status_of is Some(_),
    dynamic_media: self.dynamic_media,
    media_type: self.media_type,
    schema: self.schema,
    item_schema: self.item_schema,
    headers: self.headers.copy(),
    header_schemas: self.header_schemas.copy(),
    description: self.description,
  }
}

///|
/// Creates a buffered response variant from a body codec and fixed status.
pub fn[T] json_variant(
  status : Int32,
  codec : @schema.BodyCodec[T],
  description~ : String = "",
) -> Variant[T] {
  let media_type = codec.media_type()
  {
    status,
    status_of: None,
    dynamic_media: false,
    matches: _ => true,
    media_type: Some(media_type),
    schema: Some(codec.schema()),
    item_schema: None,
    headers: [],
    header_schemas: {},
    description,
    attributes: @mttp.Attributes::empty(),
    encode: v => {
      (
        @mttp.Headers::of([("content-type", media_type)]),
        Bytes(codec.encode(v)),
      )
    },
    decode_bytes: Some((h, bytes) => {
      codec.decode(bytes) catch {
        @schema.DecodeFailure(..) as f =>
          raise DecodeError(h, message=f.message(), body=bytes)
      }
    }),
    decode_stream: None,
  }
}

///|
/// Creates a fixed-status variant with no body representation.
pub fn empty_variant(
  status : Int32,
  description~ : String = "",
) -> Variant[Unit] {
  {
    status,
    status_of: None,
    dynamic_media: false,
    matches: _ => true,
    media_type: None,
    schema: None,
    item_schema: None,
    headers: [],
    header_schemas: {},
    description,
    attributes: @mttp.Attributes::empty(),
    encode: _ => (@mttp.Headers::empty(), Empty),
    decode_bytes: Some((_, _) => ()),
    decode_stream: None,
  }
}

///|
/// Embeds a response variant in a larger type using a partial projection.
pub fn[A, T] Variant::contramap(
  self : Variant[A],
  project : (T) -> A?,
  inject : (A) -> T,
) -> Variant[T] {
  {
    status: self.status,
    status_of: self.status_of.map(f => {
      value => {
        match project(value) {
          Some(value) => f(value)
          None => self.status
        }
      }
    }),
    dynamic_media: self.dynamic_media,
    matches: t => {
      match project(t) {
        Some(value) => (self.matches)(value)
        None => false
      }
    },
    media_type: self.media_type,
    schema: self.schema,
    item_schema: self.item_schema,
    headers: self.headers,
    header_schemas: self.header_schemas,
    description: self.description,
    attributes: self.attributes,
    encode: t => {
      match project(t) {
        Some(a) => (self.encode)(a)
        None => (@mttp.Headers::empty(), Empty)
      }
    },
    decode_bytes: match self.decode_bytes {
      Some(f) => Some((h, b) => inject(f(h, b)))
      None => None
    },
    decode_stream: match self.decode_stream {
      Some(f) => Some((h, s) => inject(f(h, s)))
      None => None
    },
  }
}

///|
/// tapir header[T] as an output (SC-03): a type-changing pair, like map2.
/// The client decoder reads the header; to_openapi documents it.
pub fn[T, H] Variant::and_header(
  self : Variant[T],
  name : String,
  codec : @schema.TextCodec[H],
) -> Variant[(T, H)] {
  let enc = self.encode
  let header_schemas = self.header_schemas.copy()
  header_schemas[name.to_lower()] = codec.schema()
  {
    status: self.status,
    status_of: self.status_of.map(f => value => f(value.0)),
    dynamic_media: self.dynamic_media,
    matches: v => (self.matches)(v.0),
    media_type: self.media_type,
    schema: self.schema,
    item_schema: self.item_schema,
    headers: [..self.headers, name],
    header_schemas,
    description: self.description,
    attributes: self.attributes,
    encode: v => {
      let (hs, body) = enc(v.0)
      (hs.add(name, codec.encode(v.1)), body)
    },
    decode_bytes: match self.decode_bytes {
      Some(f) =>
        Some((h, b) => {
          let t = f(h, b)
          guard h.headers.get(name) is Some(raw) else {
            raise DecodeError(h, message="missing header \{name}", body=b)
          }
          (t, codec.decode(raw))
        })
      None => None
    },
    decode_stream: match self.decode_stream {
      Some(f) =>
        Some((h, s) => {
          guard h.headers.get(name) is Some(raw) else {
            s.close()
            raise DecodeError(h, message="missing header \{name}", body=b"")
          }
          let header = codec.decode(raw) catch {
            error => raise DecodeError(h, message=error.message(), body=b"")
          }
          (f(h, s), header)
        })
      None => None
    },
  }
}

///|
/// A header that is always written (Cache-Control, a fixed Location).
pub fn[T] Variant::fixed_header(
  self : Variant[T],
  name : String,
  value : String,
) -> Variant[T] {
  let enc = self.encode
  let header_schemas = self.header_schemas.copy()
  header_schemas[name.to_lower()] = @schema.string
    .schema()
    .patch({ "const": Json(value) })
  {
    ..self,
    headers: [..self.headers, name],
    header_schemas,
    encode: v => {
      let (hs, body) = enc(v)
      (hs.add(name, value), body)
    },
  }
}

///|
/// An ordered collection of response variants for one output type.
pub struct Out[T, M] {
  priv mode : M
  priv variants : Array[Variant[T]]
}

///|
/// Creates an ordered output union; the first matching encoder is selected.
pub fn[T] one_of(variants : Array[Variant[T]]) -> Out[T, @client.Buffered] {
  { mode: @client.Buffered::{ }, variants: variants.copy(), }
}

///|
/// Creates a single buffered body-codec output, defaulting to status 200.
pub fn[T] json_out(
  codec : @schema.BodyCodec[T],
  status~ : Int32 = 200,
) -> Out[T, @client.Buffered] {
  { mode: @client.Buffered::{ }, variants: [json_variant(status, codec)], }
}

///|
/// Creates a bodyless 204 output.
pub fn no_content() -> Out[Unit, @client.Buffered] {
  { mode: @client.Buffered::{ }, variants: [empty_variant(204)], }
}

///|
/// Pairs every output variant with a typed response header.
pub fn[T, H, M] Out::and_header(
  self : Out[T, M],
  name : String,
  codec : @schema.TextCodec[H],
) -> Out[(T, H), M] {
  {
    mode: self.mode,
    variants: self.variants.map(v => v.and_header(name, codec)),
  }
}

///|
/// Returns metadata for each declared output variant.
pub fn[T, M] Out::docs(self : Out[T, M]) -> Array[VariantDoc] {
  self.variants.map(v => v.doc())
}

///|
fn[T, M] Out::encode(self : Out[T, M], v : T) -> @mttp.Response? {
  for variant in self.variants {
    if (variant.matches)(v) {
      let status = match variant.status_of {
        Some(f) => f(v)
        None => variant.status
      }
      if status < 200 || status > 599 {
        return None
      }
      let (headers, body) = (variant.encode)(v)
      let response = if status == 204 || status == 304 {
        discard(body)
        @mttp.Response::new(status, headers~)
      } else {
        @mttp.Response::new(status, headers~, body~)
      }
      return Some({ ..response, attributes: variant.attributes, })
    }
  }
  None
}

///|
fn media_matches(variant_media : String?, ct : String?) -> Bool {
  match (variant_media, ct) {
    (None, None) => true
    (None, Some(_)) | (Some(_), None) => false
    (Some(m), Some(c)) => media_type_token(m) == media_type_token(c)
  }
}

///|
/// Every variant whose (status, media type) matches the head, in
/// declaration order: a framework problem+json 404 never matches a
/// declared application/json 404 (I-02), and two declared variants at one
/// status are tried in turn (SC-04).
fn[T, M] Out::for_head(
  self : Out[T, M],
  head : @mttp.ResponseHead,
) -> Array[Variant[T]] {
  let ct = head.headers.get("content-type")
  self.variants.filter(v => {
    (v.status_of is Some(_) || v.status == head.status) &&
    (v.dynamic_media || media_matches(v.media_type, ct))
  })
}

///|
/// Buffered decode: first variant that decodes wins; Deserialization only
/// when every candidate failed.
fn[T, M] Out::decode_bytes(
  self : Out[T, M],
  head : @mttp.ResponseHead,
  body : Bytes,
) -> T? raise {
  let candidates = self.for_head(head)
  if candidates.is_empty() {
    return None
  }
  let mut last : Error = DecodeError(head, message="no buffered decoder", body~)
  for v in candidates {
    match v.decode_bytes {
      Some(f) =>
        return Some(f(head, body)) catch {
          DecodeError(_, ..) as e => {
            last = e
            continue
          }
          @schema.DecodeFailure(..) as e => {
            last = DecodeError(head, message=e.message(), body~)
            continue
          }
          error => raise error
        }
      None => last = DecodeError(head, message="streaming variant", body~)
    }
  }
  raise last
}

///|
/// The SSE fields `sse_out` writes beside an event's data: its `id`, its event
/// name (`event`; `""` or `"message"` leaves the event unnamed) and a `retry`
/// reconnection hint in milliseconds. Build it with `SseMeta::new`.
#derive(Eq, Debug)
pub(all) struct SseMeta {
  id : String?
  event : String
  retry : Int32?
}

///|
/// Creates event metadata; every field is absent by default.
///
/// ```mbt check
/// test {
///   let meta = @endpoint.SseMeta::new(id="7", event="update")
///   assert_eq(meta.id, Some("7"))
///   assert_eq(meta.retry, None)
/// }
/// ```
pub fn SseMeta::new(
  id? : String,
  event~ : String = "",
  retry? : Int32,
) -> SseMeta {
  { id, event, retry, }
}

///|
/// Compares all metadata fields.
pub extend SseMeta with Eq::{equal, not_equal}

///|
/// Debug representation of event metadata.
pub extend SseMeta with @debug.Debug::{to_repr}

///|
/// One typed event with its SSE fields. On a client, `id` is the stream's last
/// event ID as of this event (an `id` field stays in effect until another
/// replaces it), so it is the value to send back with `last_event_id()` when
/// resuming; `event` is the event name, `""` for an unnamed event (also one
/// named `message`); `retry` is the reconnection hint sent with this event.
/// Items of a stream made with `from_pull` or `from_array` have no SSE fields:
/// `id: None, event: "", retry: None`.
#derive(Eq, Debug)
pub(all) struct SseItem[T] {
  data : T
  id : String?
  event : String
  retry : Int32?
}

///|
/// Creates an item; the SSE fields are absent by default.
pub fn[T] SseItem::new(
  data : T,
  id? : String,
  event~ : String = "",
  retry? : Int32,
) -> SseItem[T] {
  { data, id, event, retry, }
}

///|
/// Compares the data and all SSE fields.
pub extend SseItem with Eq::{equal, not_equal}

///|
/// Debug representation of an item.
pub extend SseItem with @debug.Debug::{to_repr}

///|
/// Pull-only event streams (no push bodies in v0.x).
pub struct EventStream[T] {
  priv pull : async () -> SseItem[T]?
  priv close_ : () -> Unit
  priv mut closed : Bool
}

///|
/// Creates a pull stream with cleanup invoked once on EOF, error or close.
pub fn[T] EventStream::from_pull(
  next : async () -> T?,
  close : () -> Unit,
) -> EventStream[T] {
  {
    pull: () => next().map(data => SseItem::new(data)),
    close_: close,
    closed: false,
  }
}

///|
/// Creates a pull stream over the supplied ordered events.
pub fn[T] EventStream::from_array(items : Array[T]) -> EventStream[T] {
  let i : Ref[Int32] = { val: 0, }
  EventStream::from_pull(
    () => {
      if i.val < items.length() {
        i.val += 1
        Some(items[i.val - 1])
      } else {
        None
      }
    },
    () => (),
  )
}

///|
/// Consumes events in order and closes the source even when the callback fails.
pub async fn[T] EventStream::each(
  self : EventStream[T],
  f : async (T) -> Unit,
) -> Unit {
  defer self.close()
  while self.next_item() is Some(item) {
    f(item.data)
  }
}

///|
/// Consumes events with their SSE fields in order, like `each`, and closes the
/// source even when the callback fails.
pub async fn[T] EventStream::each_item(
  self : EventStream[T],
  f : async (SseItem[T]) -> Unit,
) -> Unit {
  defer self.close()
  while self.next_item() is Some(item) {
    f(item)
  }
}

///|
/// Pulls the next event, or `None` at the end; after the end every call
/// returns `None`. The stream closes itself at the end, on failure and on
/// cancellation; a caller that stops before the end calls `close` (a client
/// stream borrowed by `stream_request` or `call_with` is also closed when the
/// callback returns).
pub async fn[T] EventStream::next(self : EventStream[T]) -> T? {
  self.next_item().map(item => item.data)
}

///|
/// Pulls the next event with its SSE fields, as `next` does.
pub async fn[T] EventStream::next_item(self : EventStream[T]) -> SseItem[T]? {
  if self.closed {
    return None
  }
  errdefer self.close()
  let item = (self.pull)()
  if item is None {
    self.close()
  }
  item
}

///|
/// Closes the event source once, including when it was never read.
pub fn[T] EventStream::close(self : EventStream[T]) -> Unit {
  if !self.closed {
    self.closed = true
    (self.close_)()
  }
}

///|
/// A stream of `f` applied to each event, keeping each event's `id`, event
/// name and `retry`. The new stream owns this one: closing it, or reaching
/// its end, closes this one. Read only the new stream.
pub fn[T, U] EventStream::map(
  self : EventStream[T],
  f : (T) -> U,
) -> EventStream[U] {
  {
    pull: () => {
      self
      .next_item()
      .map(item => {
        SseItem::new(
          f(item.data),
          id?=item.id,
          event=item.event,
          retry?=item.retry,
        )
      })
    },
    close_: () => self.close(),
    closed: false,
  }
}

///|
/// The encoded side: a pull BodyStream over the event stream, written by the
/// adapter with backpressure and passed through Router-as-Backend unbuffered.
priv struct EventBody {
  pull : async () -> Bytes?
  close_ : () -> Unit
  mut done : Bool
}

///|
impl @mttp.BodyStream for EventBody with fn read_some(self) {
  if self.done {
    return None
  }
  errdefer @mttp.BodyStream::close(self)
  let next = (self.pull)() catch {
    _ =>
      raise @mttp.TransportError(
        kind=Protocol,
        phase=Body,
        detail="event source failed",
      )
  }
  match next {
    Some(b) => Some(b)
    None => {
      self.done = true
      (self.close_)()
      None
    }
  }
}

///|
impl @mttp.BodyStream for EventBody with fn close(self) {
  if !self.done {
    self.done = true
    (self.close_)()
  }
}

///|
/// Streams events whose `data` is the codec's JSON. `meta` gives each value
/// its `id`, event name and `retry`; without it each event has data only. A
/// client reads the fields back with `EventStream::next_item` or `each_item`.
pub fn[T] sse_out(
  codec : @schema.JsonCodec[T],
  meta? : (T) -> SseMeta,
) -> Out[EventStream[T], @client.Streaming] {
  let defs = Map([])
  let problems = []
  let data_schema = codec.schema().reference(defs, problems~)
  // One parsed event, in the shape OpenAPI 3.2 gives text/event-stream items:
  // every field is a string except retry, and the JSON payload is described
  // as the content of the data string.
  let event_schema : @schema.Schema = {
    name: None,
    defs,
    problems,
    json: {
      "type": "object",
      "required": ["data"],
      "properties": {
        "event": { "type": "string" },
        "data": {
          "type": "string",
          "contentMediaType": "application/json",
          "contentSchema": data_schema,
        },
        "id": { "type": "string" },
        "retry": { "type": "integer", "minimum": 0 },
      },
    },
  }
  let variant : Variant[EventStream[T]] = {
    status: 200,
    status_of: None,
    dynamic_media: false,
    matches: _ => true,
    media_type: Some("text/event-stream"),
    schema: Some(@schema.string.schema()),
    item_schema: Some(event_schema),
    headers: [],
    header_schemas: {},
    description: "event stream",
    attributes: @mttp.Attributes::empty().put(@mttp.close_on_shutdown, true),
    encode: es => {
      let body : &@mttp.BodyStream = EventBody::{
        pull: () => {
          match es.next() {
            None => None
            Some(value) => {
              let fields = match meta {
                Some(mapper) => mapper(value)
                None => SseMeta::new()
              }
              Some(
                @sse.encode(@sse.SseEvent::{
                  event: fields.event,
                  data: codec.to_json(value).stringify(),
                  id: fields.id,
                  retry: fields.retry,
                }),
              )
            }
          }
        },
        close_: () => es.close(),
        done: false,
      }
      (
        @mttp.Headers::of([("content-type", "text/event-stream")]),
        Stream(@mttp.StreamBody::new(body)),
      )
    },
    decode_bytes: None,
    decode_stream: Some((h, stream) => {
      let reader = @sse.SseReader::new(stream)
      EventStream::{
        pull: () => {
          match reader.next_event() {
            None => None
            Some(event) => {
              let data = codec.body().decode(@mttp.encode_utf8(event.data)) catch {
                  failure =>
                    raise DecodeError(h, message=failure.message(), body=b"")
                }
              // The parser names an unnamed event `message`; items use the
              // `""` that SseMeta writes for one, so meta round-trips.
              let name = if event.event == "message" { "" } else { event.event }
              Some(SseItem::{
                data,
                id: event.id,
                event: name,
                retry: event.retry,
              })
            }
          }
        },
        close_: () => reader.close(),
        closed: false,
      }
    }),
  }
  { mode: @client.Streaming::{ }, variants: [variant], }
}

///|
/// Marker for an endpoint without declared application errors.
#derive(Debug, Eq)
pub(all) struct NoError {}

///|
/// Compares the no-error marker.
pub extend NoError with Eq::{equal, not_equal}

///|
fn no_errors() -> Out[NoError, @client.Buffered] {
  { mode: @client.Buffered::{ }, variants: [], }
}

///|
#derive(Debug)
priv suberror DecodeError {
  DecodeError(@mttp.ResponseHead, message~ : String, body~ : Bytes)
}
