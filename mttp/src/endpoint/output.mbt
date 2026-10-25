///|
/// One status and representation with typed response encoders and decoders.
pub struct Variant[T] {
  priv status : Int32
  priv status_of : ((T) -> Int32)?
  priv dynamic_media : Bool
  priv matches : (T) -> Bool
  priv media_type : String?
  priv schema : @schema.Schema?
  priv headers : Array[String]
  priv header_schemas : Map[String, @schema.Schema]
  priv description : String
  priv encode : (T) -> (@model.Headers, @model.Body)
  priv decode_bytes : ((@model.ResponseHead, Bytes) -> T raise)?
  priv decode_stream : (async (@model.ResponseHead, &@model.BodyStream) -> T)?
}

///|
/// Documentation metadata for one response representation.
pub struct VariantDoc {
  status : Int32
  dynamic_status : Bool
  dynamic_media : Bool
  media_type : String?
  schema : @schema.Schema?
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
    headers: [],
    header_schemas: {},
    description,
    encode: v => {
      (
        @model.Headers::of([("content-type", media_type)]),
        Bytes(codec.encode(v)),
      )
    },
    decode_bytes: Some((h, bytes) => {
      codec.decode(bytes) catch {
        f => raise @client.Deserialization(h, message=f.message(), body=bytes)
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
    headers: [],
    header_schemas: {},
    description,
    encode: _ => (@model.Headers::empty(), Empty),
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
    headers: self.headers,
    header_schemas: self.header_schemas,
    description: self.description,
    encode: t => {
      match project(t) {
        Some(a) => (self.encode)(a)
        None => (@model.Headers::empty(), Empty)
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
    headers: [..self.headers, name],
    header_schemas,
    description: self.description,
    encode: v => {
      let (hs, body) = enc(v.0)
      (hs.add(name, codec.encode(v.1)), body)
    },
    decode_bytes: match self.decode_bytes {
      Some(f) =>
        Some((h, b) => {
          let t = f(h, b)
          guard h.headers.get(name) is Some(raw) else {
            raise @client.Deserialization(
              h,
              message="missing header \{name}",
              body=b,
            )
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
            raise @client.Deserialization(
              h,
              message="missing header \{name}",
              body=b"",
            )
          }
          let header = codec.decode(raw)
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
  header_schemas[name.to_lower()] = @schema.string.schema()
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
pub struct Out[T] {
  priv variants : Array[Variant[T]]
}

///|
/// Creates an ordered output union; the first matching encoder is selected.
pub fn[T] one_of(variants : Array[Variant[T]]) -> Out[T] {
  { variants: variants.copy(), }
}

///|
/// Creates a single buffered body-codec output, defaulting to status 200.
pub fn[T] json_out(
  codec : @schema.BodyCodec[T],
  status~ : Int32 = 200,
) -> Out[T] {
  { variants: [json_variant(status, codec)], }
}

///|
/// Creates a bodyless 204 output.
pub fn no_content() -> Out[Unit] {
  { variants: [empty_variant(204)], }
}

///|
/// Pairs every output variant with a typed response header.
pub fn[T, H] Out::and_header(
  self : Out[T],
  name : String,
  codec : @schema.TextCodec[H],
) -> Out[(T, H)] {
  { variants: self.variants.map(v => v.and_header(name, codec)), }
}

///|
/// Returns metadata for each declared output variant.
pub fn[T] Out::docs(self : Out[T]) -> Array[VariantDoc] {
  self.variants.map(v => v.doc())
}

///|
fn[T] Out::encode(self : Out[T], v : T) -> @model.Response? {
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
      if status == 204 || status == 304 {
        discard(body)
        return Some(@model.Response::new(status, headers~))
      }
      return Some(@model.Response::new(status, headers~, body~))
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
fn[T] Out::for_head(
  self : Out[T],
  head : @model.ResponseHead,
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
fn[T] Out::decode_bytes(
  self : Out[T],
  head : @model.ResponseHead,
  body : Bytes,
) -> T? raise {
  let candidates = self.for_head(head)
  if candidates.is_empty() {
    return None
  }
  let mut last : Error = @client.Deserialization(
    head,
    message="no buffered decoder",
    body~,
  )
  for v in candidates {
    match v.decode_bytes {
      Some(f) =>
        return Some(f(head, body)) catch {
          e => {
            last = e
            continue
          }
        }
      None =>
        last = @client.Deserialization(head, message="streaming variant", body~)
    }
  }
  match last {
    @client.ResponseError::_ as e => raise e
    e => raise @client.Deserialization(head, message=e.to_string(), body~)
  }
}

///|
/// Pull-only event streams (no push bodies in v0.x).
pub struct EventStream[T] {
  priv next : async () -> T?
  priv close_ : () -> Unit
  priv mut closed : Bool
}

///|
/// Creates a pull stream with cleanup invoked once on EOF, error or close.
pub fn[T] EventStream::from_pull(
  next : async () -> T?,
  close : () -> Unit,
) -> EventStream[T] {
  { next, close_: close, closed: false, }
}

///|
/// Creates a pull stream over the supplied ordered events.
pub fn[T] EventStream::from_array(items : Array[T]) -> EventStream[T] {
  let i : Ref[Int32] = { val: 0, }
  {
    next: () => {
      if i.val < items.length() {
        i.val += 1
        Some(items[i.val - 1])
      } else {
        None
      }
    },
    close_: () => (),
    closed: false,
  }
}

///|
/// Consumes events in order and closes the source even when the callback fails.
pub async fn[T] EventStream::each(
  self : EventStream[T],
  f : async (T) -> Unit,
) -> Unit {
  defer self.close()
  while self.next_event() is Some(v) {
    f(v)
  }
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
async fn[T] EventStream::next_event(self : EventStream[T]) -> T? {
  if self.closed {
    return None
  }
  errdefer self.close()
  let value = (self.next)()
  if value is None {
    self.close()
  }
  value
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
impl @model.BodyStream for EventBody with fn read_some(self) {
  if self.done {
    return None
  }
  errdefer @model.BodyStream::close(self)
  let next = (self.pull)() catch {
    _ =>
      raise @model.TransportError(
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
impl @model.BodyStream for EventBody with fn close(self) {
  if !self.done {
    self.done = true
    (self.close_)()
  }
}

///|
/// Reads `data` payloads through the moved, conformance-tested SseParser,
/// so line endings, fields, comments and split chunks follow the SSE spec.
priv struct SseReader {
  stream : &@model.BodyStream
  parser : @sse.SseParser
  ready : Array[String]
  mut offset : Int32
}

///|
async fn SseReader::next_data(
  self : SseReader,
) -> String? raise @model.TransportError {
  while self.offset == self.ready.length() {
    self.ready.clear()
    self.offset = 0
    match self.stream.read_some() {
      Some(chunk) =>
        for e in self.parser.feed(chunk) {
          self.ready.push(e.data)
        }
      None => {
        ignore(self.parser.finish())
        return None
      }
    }
  }
  let value = self.ready[self.offset]
  self.offset += 1
  Some(value)
}

///|
/// Streams JSON event data with optional event metadata mapping.
pub fn[T] sse_out(
  codec : @schema.JsonCodec[T],
  to_event? : (T) -> @sse.SseEvent,
) -> Out[EventStream[T]] {
  let variant : Variant[EventStream[T]] = {
    status: 200,
    status_of: None,
    dynamic_media: false,
    matches: _ => true,
    media_type: Some("text/event-stream"),
    schema: Some(codec.schema()),
    headers: [],
    header_schemas: {},
    description: "event stream",
    encode: es => {
      let body : &@model.BodyStream = EventBody::{
        pull: () => {
          match es.next_event() {
            None => None
            Some(v) => {
              let event = match to_event {
                Some(mapper) => mapper(v)
                None =>
                  @sse.SseEvent::{
                    event: "",
                    data: codec.to_json(v).stringify(),
                    id: None,
                    retry: None,
                  }
              }
              Some(@sse.encode(event))
            }
          }
        },
        close_: () => es.close(),
        done: false,
      }
      (
        @model.Headers::of([("content-type", "text/event-stream")]),
        Stream(@model.StreamBody::new(body)),
      )
    },
    decode_bytes: None,
    decode_stream: Some((h, stream) => {
      let reader = SseReader::{
        stream,
        parser: @sse.SseParser::new(),
        ready: [],
        offset: 0,
      }
      EventStream::from_pull(
        () => {
          match reader.next_data() {
            None => None
            Some(data) => {
              let j = @json.parse(data) catch {
                e =>
                  raise @client.Deserialization(
                    h,
                    message=e.to_string(),
                    body=b"",
                  )
              }
              Some(
                codec.from_json(j) catch {
                  failure =>
                    raise @client.Deserialization(
                      h,
                      message=failure.message(),
                      body=b"",
                    )
                },
              )
            }
          }
        },
        () => stream.close(),
      )
    }),
  }
  { variants: [variant], }
}

///|
/// Classifies raised errors into the declared typed response variants.
pub struct Errors[E] {
  priv classify : (Error) -> E?
  priv out : Out[E]
}

///|
/// Creates error classification and its ordered output variants.
pub fn[E] Errors::new(
  classify : (Error) -> E?,
  variants : Array[Variant[E]],
) -> Errors[E] {
  { classify, out: { variants: variants.copy(), }, }
}

///|
/// The uninhabited error type of an endpoint without declared errors.
pub(all) suberror NoError derive(Debug)

///|
fn no_errors() -> Errors[NoError] {
  { classify: _ => None, out: { variants: [], }, }
}
