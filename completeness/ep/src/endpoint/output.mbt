///|
/// One way a response can look: a status, a body codec, and which values
/// take this shape (tapir's oneOfVariant).
pub struct Variant[T] {
  priv status : @model.Status
  priv matches : (T) -> Bool
  priv media_type : String?
  priv schema : @schema.Schema?
  priv description : String
  priv encode : (T) -> (@model.Headers, @model.Body)
  priv decode : async (@model.ResponseHead, @model.Body) -> T
  /// Sync decoding of a buffered body: for clients without an async
  /// runtime (wasm-gc in a browser, callback-style UI frameworks).
  priv decode_bytes : ((@model.ResponseHead, Bytes) -> T raise)?
}

///|
pub(all) struct VariantDoc {
  status : Int
  media_type : String?
  schema : @schema.Schema?
  description : String
} derive(Debug)

///|
pub fn[T] Variant::doc(self : Variant[T]) -> VariantDoc {
  {
    status: self.status.code(),
    media_type: self.media_type,
    schema: self.schema,
    description: self.description,
  }
}

///|
pub fn[T] json_variant(
  status : Int,
  codec : @schema.BodyCodec[T],
  matches? : (T) -> Bool = _ => true,
  description? : String = "",
) -> Variant[T] {
  let media_type = codec.media_type()
  {
    status: @model.Status(status),
    matches,
    media_type: Some(media_type),
    schema: Some(codec.schema()),
    description,
    encode: v => (
      @model.Headers::from_array([("content-type", media_type)]),
      Bytes(codec.encode(v)),
    ),
    decode: async fn(h, b) {
      let bytes = @client.body_bytes(b, @client.default_max_body)
      codec.decode(bytes) catch {
        f => raise @client.Deserialization(h, message=f.message(), body=bytes)
      }
    },
    decode_bytes: Some((h, bytes) => codec.decode(bytes) catch {
      f => raise @client.Deserialization(h, message=f.message(), body=bytes)
    }),
  }
}

///|
pub fn empty_variant(status : Int, description? : String = "") -> Variant[Unit] {
  {
    status: @model.Status(status),
    matches: _ => true,
    media_type: None,
    schema: None,
    description,
    encode: _ => (@model.Headers::new(), Empty),
    decode: async fn(_, b) {
      if b is Stream(s, ..) {
        s.close()
      }
    },
    decode_bytes: Some((_, _) => ()),
  }
}

///|
/// tapir's EndpointOutput: a list of variants; the first whose `matches`
/// accepts the value encodes it, the one whose status arrived decodes it.
pub struct Out[T] {
  priv variants : Array[Variant[T]]
}

///|
pub fn[T] Out::one_of(variants : Array[Variant[T]]) -> Out[T] {
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
pub fn[T] Out::docs(self : Out[T]) -> Array[VariantDoc] {
  self.variants.map(v => v.doc())
}

///|
fn[T] Out::encode(self : Out[T], v : T) -> @model.Response? {
  for variant in self.variants {
    if (variant.matches)(v) {
      let (headers, body) = (variant.encode)(v)
      return Some({ status: variant.status, headers, body })
    }
  }
  None
}

///|
fn[T] Out::for_status(self : Out[T], status : @model.Status) -> Variant[T]? {
  for variant in self.variants {
    if variant.status == status {
      return Some(variant)
    }
  }
  None
}

///|
/// Declared errors: which raised errors are ours (`classify`) and how each
/// is sent. Handlers raise anything; what `classify` misses is a 500.
pub struct Errors[E] {
  priv classify : (Error) -> E?
  priv out : Out[E]
}

///|
pub fn[E] Errors::new(classify : (Error) -> E?, variants : Array[Variant[E]]) -> Errors[E] {
  { classify, out: { variants, } }
}

///|
/// The error type of an endpoint that declares none; never raised.
pub(all) suberror NoError derive(Debug)

///|
pub fn no_errors() -> Errors[NoError] {
  { classify: _ => None, out: { variants: [] } }
}

///|
/// Server-sent events as a pull source: `next` returns `None` at the end.
/// Pull, so the sans-IO server and the in-process stub need no task or
/// queue; a push producer is bridged by the adapter's runtime.
pub(all) struct EventSource[T] {
  next : async () -> T?
  close : () -> Unit
}

///|
priv struct SseBody[T] {
  source : EventSource[T]
  encode : (T) -> String
}

///|
impl[T] @model.BodyStream for SseBody[T] with read_some(self) {
  let ev = (self.source.next)() catch {
    _ => raise @model.Network(phase=Body, message="event source failed")
  }
  match ev {
    None => None
    Some(v) => Some(@utf8.encode("data: \{(self.encode)(v)}\n\n"))
  }
}

///|
impl[T] @model.BodyStream for SseBody[T] with close(self) {
  (self.source.close)()
}

///|
/// Minimal SSE reader for the prototype (the real one is gaato's
/// incremental SseParser with max_event_bytes).
priv struct SseReader {
  stream : &@model.BodyStream
  mut pending : String
}

///|
async fn SseReader::next_data(self : SseReader) -> String? {
  while true {
    match self.pending.find("\n\n") {
      Some(i) => {
        let event = self.pending.unsafe_substring(start=0, end=i)
        self.pending = self.pending.unsafe_substring(
          start=i + 2,
          end=self.pending.length(),
        )
        if event.has_prefix("data: ") {
          return Some(event.unsafe_substring(start=6, end=event.length()))
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
pub fn[T] sse_out(codec : @schema.JsonCodec[T]) -> Out[EventSource[T]] {
  let variant : Variant[EventSource[T]] = {
    status: @model.Status(200),
    matches: _ => true,
    media_type: Some("text/event-stream"),
    schema: Some(codec.schema()),
    description: "event stream",
    encode: source => (
      @model.Headers::from_array([("content-type", "text/event-stream")]),
      Stream(
        SseBody::{ source, encode: v => codec.to_json(v).stringify() },
        length=None,
      ),
    ),
    decode: async fn(h, b) {
      let stream : &@model.BodyStream = match b {
        Stream(s, ..) => s
        Bytes(bytes) => @model.BytesStream::new([bytes])
        Empty => @model.BytesStream::new([])
      }
      let reader = SseReader::{ stream, pending: "" }
      {
        next: async fn() {
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
        close: () => stream.close(),
      }
    },
    decode_bytes: None,
  }
  { variants: [variant] }
}

///|
/// A variant for one case of a sum type: `project` picks the case out
/// (and decides `matches`), `inject` rebuilds it on the client.
pub fn[A, T] Variant::contramap(
  self : Variant[A],
  project : (T) -> A?,
  inject : (A) -> T,
) -> Variant[T] {
  {
    status: self.status,
    matches: t => project(t) is Some(_),
    media_type: self.media_type,
    schema: self.schema,
    description: self.description,
    encode: t => match project(t) {
      Some(a) => (self.encode)(a)
      None => (@model.Headers::new(), Empty)
    },
    decode: async fn(h, b) { inject((self.decode)(h, b)) },
    decode_bytes: match self.decode_bytes {
      Some(f) => Some((h, b) => inject(f(h, b)))
      None => None
    },
  }
}
