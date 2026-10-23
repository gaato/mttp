///|
pub struct Variant[T] {
  priv status : Int
  priv matches : (T) -> Bool
  priv media_type : String?
  priv schema : @schema.Schema?
  priv headers : Array[String]
  priv description : String
  priv encode : (T) -> (@model.Headers, @model.Body)
  priv decode_bytes : ((@model.ResponseHead, Bytes) -> T raise)?
  priv decode_stream : (async (@model.ResponseHead, &@model.BodyStream) -> T)?
}

///|
pub(all) struct VariantDoc {
  status : Int
  media_type : String?
  schema : @schema.Schema?
  headers : Array[String]
  description : String
}

///|
pub fn[T] Variant::doc(self : Variant[T]) -> VariantDoc {
  { status: self.status, media_type: self.media_type, schema: self.schema, headers: self.headers, description: self.description }
}

///|
pub fn[T] json_variant(status : Int, codec : @schema.BodyCodec[T], description? : String = "") -> Variant[T] {
  let media_type = codec.media_type()
  {
    status,
    matches: _ => true,
    media_type: Some(media_type),
    schema: Some(codec.schema()),
    headers: [],
    description,
    encode: v => (@model.Headers::of([("content-type", media_type)]), Bytes(codec.encode(v))),
    decode_bytes: Some((h, bytes) => codec.decode(bytes) catch {
      f => raise @client.Deserialization(h, message=f.message(), body=bytes)
    }),
    decode_stream: None,
  }
}

///|
pub fn empty_variant(status : Int, description? : String = "") -> Variant[Unit] {
  {
    status,
    matches: _ => true,
    media_type: None,
    schema: None,
    headers: [],
    description,
    encode: _ => (@model.Headers::empty(), Empty),
    decode_bytes: Some((_, _) => ()),
    decode_stream: None,
  }
}

///|
pub fn[A, T] Variant::contramap(self : Variant[A], project : (T) -> A?, inject : (A) -> T) -> Variant[T] {
  {
    status: self.status,
    matches: t => project(t) is Some(_),
    media_type: self.media_type,
    schema: self.schema,
    headers: self.headers,
    description: self.description,
    encode: t => match project(t) {
      Some(a) => (self.encode)(a)
      None => (@model.Headers::empty(), Empty)
    },
    decode_bytes: match self.decode_bytes {
      Some(f) => Some((h, b) => inject(f(h, b)))
      None => None
    },
    decode_stream: match self.decode_stream {
      Some(f) => Some(async fn(h, s) { inject(f(h, s)) })
      None => None
    },
  }
}

///|
/// tapir header[T] as an output (SC-03): a type-changing pair, like map2.
/// The client decoder reads the header; to_openapi documents it.
pub fn[T, H] Variant::and_header(self : Variant[T], name : String, codec : @schema.TextCodec[H]) -> Variant[(T, H)] {
  let enc = self.encode
  {
    status: self.status,
    matches: v => (self.matches)(v.0),
    media_type: self.media_type,
    schema: self.schema,
    headers: [..self.headers, name],
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
            raise @client.Deserialization(h, message="missing header \{name}", body=b)
          }
          (t, codec.decode(raw))
        })
      None => None
    },
    decode_stream: None,
  }
}

///|
/// A header that is always written (Cache-Control, a fixed Location).
pub fn[T] Variant::fixed_header(self : Variant[T], name : String, value : String) -> Variant[T] {
  let enc = self.encode
  {
    ..self,
    headers: [..self.headers, name],
    encode: v => {
      let (hs, body) = enc(v)
      (hs.add(name, value), body)
    },
  }
}

///|
pub struct Out[T] {
  priv variants : Array[Variant[T]]
}

///|
pub fn[T] one_of(variants : Array[Variant[T]]) -> Out[T] {
  { variants, }
}

///|
pub fn[T] json_out(codec : @schema.BodyCodec[T], status? : Int = 200) -> Out[T] {
  { variants: [json_variant(status, codec)] }
}

///|
pub fn no_content() -> Out[Unit] {
  { variants: [empty_variant(204)] }
}

///|
pub fn[T, H] Out::and_header(self : Out[T], name : String, codec : @schema.TextCodec[H]) -> Out[(T, H)] {
  { variants: self.variants.map(v => v.and_header(name, codec)) }
}

///|
pub fn[T] Out::docs(self : Out[T]) -> Array[VariantDoc] {
  self.variants.map(v => v.doc())
}

///|
fn[T] Out::encode(self : Out[T], v : T) -> @model.Response? {
  for variant in self.variants {
    if (variant.matches)(v) {
      let (headers, body) = (variant.encode)(v)
      return Some(@model.Response::new(variant.status, headers~, body~))
    }
  }
  None
}

///|
fn media_matches(variant_media : String?, ct : String?) -> Bool {
  match (variant_media, ct) {
    (None, None) => true
    (None, Some(_)) | (Some(_), None) => false
    (Some(m), Some(c)) => {
      let m = m.to_lower()
      let c = c.to_lower()
      c == m || c.has_prefix(m + ";") || c.has_prefix(m + " ")
    }
  }
}

///|
/// Every variant whose (status, media type) matches the head, in
/// declaration order: a framework problem+json 404 never matches a
/// declared application/json 404 (I-02), and two declared variants at one
/// status are tried in turn (SC-04).
fn[T] Out::for_head(self : Out[T], head : @model.ResponseHead) -> Array[Variant[T]] {
  let ct = head.headers.get("content-type")
  self.variants.filter(v => v.status == head.status && media_matches(v.media_type, ct))
}

///|
/// Buffered decode: first variant that decodes wins; Deserialization only
/// when every candidate failed.
fn[T] Out::decode_bytes(self : Out[T], head : @model.ResponseHead, body : Bytes) -> T? raise {
  let candidates = self.for_head(head)
  if candidates.is_empty() {
    return None
  }
  let mut last : Error? = None
  for v in candidates {
    match v.decode_bytes {
      Some(f) =>
        return Some(f(head, body)) catch {
          e => {
            last = Some(e)
            continue
          }
        }
      None => last = Some(@client.Deserialization(head, message="streaming variant", body~))
    }
  }
  match last {
    Some(@client.ResponseError::_ as e) => raise e
    Some(e) => raise @client.Deserialization(head, message=e.to_string(), body~)
    None => None
  }
}

///|
/// Pull-only event streams (no push bodies in v0.x).
pub struct EventStream[T] {
  priv next : async () -> T?
  priv close : () -> Unit
}

///|
pub fn[T] EventStream::from_pull(next : async () -> T?, close : () -> Unit) -> EventStream[T] {
  { next, close }
}

///|
pub fn[T] EventStream::from_array(items : Array[T]) -> EventStream[T] {
  let i : Ref[Int] = { val: 0 }
  {
    next: async fn() {
      if i.val < items.length() {
        i.val += 1
        Some(items[i.val - 1])
      } else {
        None
      }
    },
    close: () => (),
  }
}

///|
pub async fn[T] EventStream::each(self : EventStream[T], f : async (T) -> Unit) -> Unit {
  defer (self.close)()
  while (self.next)() is Some(v) {
    f(v)
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
impl @model.BodyStream for EventBody with read_some(self) {
  if self.done {
    return None
  }
  let next = (self.pull)() catch {
    _ => raise @model.TransportError(kind=Protocol, phase=Body, detail="event source failed")
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
impl @model.BodyStream for EventBody with close(self) {
  if !self.done {
    self.done = true
    (self.close_)()
  }
}

///|
priv struct SseReader {
  stream : &@model.BodyStream
  mut pending : String
}

///|
async fn SseReader::next_data(self : SseReader) -> String? raise @model.TransportError {
  while true {
    match self.pending.find("\n\n") {
      Some(i) => {
        let event = self.pending.view(end_offset=i).to_string()
        self.pending = self.pending.view(start_offset=i + 2).to_string()
        if event.has_prefix("data: ") {
          return Some(event.view(start_offset=6).to_string())
        }
      }
      None =>
        match self.stream.read_some() {
          None => return None
          Some(chunk) => self.pending = self.pending + @utf8.decode_lossy(chunk)
        }
    }
  }
  None
}

///|
pub fn[T] sse_out(codec : @schema.JsonCodec[T]) -> Out[EventStream[T]] {
  let variant : Variant[EventStream[T]] = {
    status: 200,
    matches: _ => true,
    media_type: Some("text/event-stream"),
    schema: Some(codec.schema()),
    headers: [],
    description: "event stream",
    encode: es => {
      let body : &@model.BodyStream = EventBody::{
        pull: async fn() {
          match (es.next)() {
            None => None
            Some(v) => Some(@utf8.encode("data: \{codec.to_json(v).stringify()}\n\n"))
          }
        },
        close_: es.close,
        done: false,
      }
      (@model.Headers::of([("content-type", "text/event-stream")]), Stream(body, length=None))
    },
    decode_bytes: None,
    decode_stream: Some(async fn(h, stream) {
      let reader = SseReader::{ stream, pending: "" }
      EventStream::from_pull(
        async fn() {
          match reader.next_data() {
            None => None
            Some(data) => {
              let j = @json.parse(data) catch {
                e => raise @client.Deserialization(h, message=e.to_string(), body=b"")
              }
              Some(codec.from_json(j))
            }
          }
        },
        () => stream.close(),
      )
    }),
  }
  { variants: [variant] }
}

///|
pub struct Errors[E] {
  priv classify : (Error) -> E?
  priv out : Out[E]
}

///|
pub fn[E] Errors::new(classify : (Error) -> E?, variants : Array[Variant[E]]) -> Errors[E] {
  { classify, out: { variants, } }
}

///|
pub(all) suberror NoError derive(Debug)

///|
fn no_errors() -> Errors[NoError] {
  { classify: _ => None, out: { variants: [] } }
}
