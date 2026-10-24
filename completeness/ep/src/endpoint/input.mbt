///|
pub(all) enum AuthScheme {
  Bearer(format~ : String?)
  Basic
  ApiKeyHeader(String)
  ApiKeyQuery(String)
} derive(Eq, Debug)

///|
pub(all) enum Location {
  Path
  Query
  Header
  Cookie
  Auth(scheme~ : AuthScheme, scheme_name~ : String)
  /// `secondary`: a raw copy of the body for a security check (signatures);
  /// it forces buffering and is not the documented request body.
  Body(media_type~ : String, streamed~ : Bool, secondary~ : Bool)
} derive(Eq, Debug)

///|
/// The untyped description of one input: what routing, documentation and
/// the decode-failure handler look at. The typed parts live in closures.
pub(all) struct Atom {
  location : Location
  name : String
  schema : @schema.Schema
  required : Bool
  description : String?
} derive(Eq, Debug)

///|
pub(all) struct InputFailure {
  atom : Atom
  failure : @schema.DecodeFailure
} derive(Debug)

///|
/// Every failure of a request's inputs, not just the first.
pub(all) suberror InputErrors {
  InputErrors(Array[InputFailure])
} derive(Debug)

///|
/// What an input sees of a request before its body is read.
pub struct Head {
  request : @model.Request
  captures : Map[String, String]
}

///|
pub(all) enum BodyValue {
  NoBody
  Buffered(Bytes)
  Streamed(&@model.BodyStream)
}

///|
/// Head decoded; waiting for the body (if the input has one).
pub struct Staged[T] {
  priv finish : (BodyValue) -> T raise InputErrors
}

///|
/// Where a client request is assembled while inputs are encoded into it.
pub struct RequestSink {
  captures : Map[String, String]
  query : Array[(String, String)]
  mut headers : @model.Headers
  mut body : @model.Body
}

///|
pub fn RequestSink::new() -> RequestSink {
  { captures: {}, query: [], headers: @model.Headers::new(), body: Empty }
}

///|
/// tapir's EndpointInput, as a value: atoms for interpreters that only read
/// the shape, closures for the typed directions.
pub struct Input[T] {
  priv atoms : Array[Atom]
  priv decode : (Head) -> Staged[T] raise InputErrors
  priv encode : (T, RequestSink) -> Unit
}

///|
pub fn[T] Input::atoms(self : Input[T]) -> Array[Atom] {
  self.atoms
}

///|
fn[T] ready(v : T) -> Staged[T] {
  { finish: _ => v }
}

///|
fn fail(atom : Atom, failure : @schema.DecodeFailure) -> InputErrors {
  InputErrors([{ atom, failure }])
}

///|
pub fn none() -> Input[Unit] {
  { atoms: [], decode: _ => ready(()), encode: (_, _) => () }
}

///|
pub fn[T] path(name : String, codec : @schema.TextCodec[T]) -> Input[T] {
  let atom = {
    location: Path,
    name,
    schema: codec.schema(),
    required: true,
    description: None,
  }
  {
    atoms: [atom],
    decode: head => {
      guard head.captures.get(name) is Some(raw) else { raise fail(atom, Missing) }
      ready(codec.decode(raw) catch { f => raise fail(atom, f) })
    },
    encode: (v, sink) => sink.captures[name] = codec.encode(v),
  }
}

///|
pub fn[T] query(name : String, codec : @schema.TextCodec[T]) -> Input[T] {
  let atom = {
    location: Query,
    name,
    schema: codec.schema(),
    required: true,
    description: None,
  }
  {
    atoms: [atom],
    decode: head => {
      let values = head.request.uri.query_all(name)
      match values {
        [] => raise fail(atom, Missing)
        [raw] => ready(codec.decode(raw) catch { f => raise fail(atom, f) })
        _ => raise fail(atom, Multiple(values.length()))
      }
    },
    encode: (v, sink) => sink.query.push((name, codec.encode(v))),
  }
}

///|
pub fn[T] header(name : String, codec : @schema.TextCodec[T]) -> Input[T] {
  let atom = {
    location: Header,
    name,
    schema: codec.schema(),
    required: true,
    description: None,
  }
  {
    atoms: [atom],
    decode: head => {
      guard head.request.headers.get(name) is Some(raw) else {
        raise fail(atom, Missing)
      }
      ready(codec.decode(raw) catch { f => raise fail(atom, f) })
    },
    encode: (v, sink) => sink.headers = sink.headers.add(name, codec.encode(v)),
  }
}

///|
/// `Authorization: Bearer <token>`; a missing or malformed one is a 401
/// with a challenge, decided before the body is read.
pub fn bearer(scheme_name? : String = "bearer") -> Input[String] {
  let atom = {
    location: Auth(scheme=Bearer(format=None), scheme_name~),
    name: "Authorization",
    schema: @schema.string.schema(),
    required: true,
    description: None,
  }
  {
    atoms: [atom],
    decode: head => {
      guard head.request.headers.get("authorization") is Some(raw) else {
        raise fail(atom, Missing)
      }
      guard raw.has_prefix("Bearer ") else {
        raise fail(atom, Mismatch(expected="Bearer", actual=raw))
      }
      ready(raw.unsafe_substring(start=7, end=raw.length()))
    },
    encode: (token, sink) => sink.headers = sink.headers.add(
      "authorization",
      "Bearer \{token}",
    ),
  }
}

///|
/// Absent becomes `None`; a present but malformed value is still a failure.
pub fn[T] Input::optional(self : Input[T]) -> Input[T?] {
  {
    atoms: self.atoms.map(a => { ..a, required: false }),
    decode: head => {
      let staged = (self.decode)(head) catch {
        InputErrors(fs) as e =>
          if fs.iter().all(f => f.failure is Missing) {
            return ready(None)
          } else {
            raise e
          }
      }
      { finish: b => Some((staged.finish)(b)) }
    },
    encode: (v, sink) => if v is Some(x) { (self.encode)(x, sink) },
  }
}

///|
fn content_type_matches(head : Head, media_type : String) -> Bool {
  match head.request.headers.get("content-type") {
    None => false
    Some(ct) => ct == media_type || ct.has_prefix("\{media_type};")
  }
}

///|
/// A buffered body, decoded by `codec`; size bounded by the endpoint.
pub fn[T] body(codec : @schema.BodyCodec[T]) -> Input[T] {
  let media_type = codec.media_type()
  let atom = {
    location: Body(media_type~, streamed=false, secondary=false),
    name: "body",
    schema: codec.schema(),
    required: true,
    description: None,
  }
  {
    atoms: [atom],
    decode: head => {
      if !content_type_matches(head, media_type) {
        raise fail(atom, Mismatch(
          expected=media_type,
          actual=head.request.headers.get("content-type").unwrap_or(""),
        ))
      }
      {
        finish: b => match b {
          Buffered(bytes) => codec.decode(bytes) catch { f => raise fail(atom, f) }
          _ => raise fail(atom, Missing)
        },
      }
    },
    encode: (v, sink) => {
      sink.headers = sink.headers.add("content-type", media_type)
      sink.body = Bytes(codec.encode(v))
    },
  }
}

///|
/// The body as a stream, unbuffered; the server bounds it, the handler
/// reads it. Only meaningful without a `raw_body` security input.
pub fn stream_body(media_type : String) -> Input[&@model.BodyStream] {
  let atom = {
    location: Body(media_type~, streamed=true, secondary=false),
    name: "body",
    schema: @schema.raw_bytes.schema(),
    required: true,
    description: None,
  }
  {
    atoms: [atom],
    decode: _ => {
      finish: b => match b {
        Streamed(s) => s
        Buffered(bytes) => @model.BytesStream::new([bytes])
        NoBody => raise fail(atom, Missing)
      },
    },
    encode: (s, sink) => {
      sink.headers = sink.headers.add("content-type", media_type)
      sink.body = Stream(s, length=None)
    },
  }
}

///|
/// The raw body bytes for a security input (webhook signatures). The server
/// buffers the body (bounded) after the head checks pass and before the
/// security logic runs; the regular body input decodes the same bytes.
pub fn raw_body() -> Input[Bytes] {
  let atom = {
    location: Body(media_type="*/*", streamed=false, secondary=true),
    name: "body",
    schema: @schema.raw_bytes.schema(),
    required: true,
    description: None,
  }
  {
    atoms: [atom],
    decode: _ => {
      finish: b => match b {
        Buffered(bytes) => bytes
        _ => raise fail(atom, Missing)
      },
    },
    // the client sends the regular body; signing is a client wrapper's job
    encode: (_, _) => (),
  }
}

///|
/// Both directions: `to` builds the value on the server, `from` takes it
/// apart on the client. Failures of both sides are collected.
pub fn[A, B, T] Input::map2(
  a : Input[A],
  b : Input[B],
  to : (A, B) -> T,
  from : (T) -> (A, B),
) -> Input[T] {
  {
    atoms: [..a.atoms, ..b.atoms],
    decode: head => {
      let failures = []
      let sa = Some((a.decode)(head)) catch {
        InputErrors(fs) => {
          failures.append(fs)
          None
        }
      }
      let sb = Some((b.decode)(head)) catch {
        InputErrors(fs) => {
          failures.append(fs)
          None
        }
      }
      guard sa is Some(sa) && sb is Some(sb) else { raise InputErrors(failures) }
      { finish: body => to((sa.finish)(body), (sb.finish)(body)) }
    },
    encode: (v, sink) => {
      let (x, y) = from(v)
      (a.encode)(x, sink)
      (b.encode)(y, sink)
    },
  }
}

///|
pub fn[A, B] Input::pair(a : Input[A], b : Input[B]) -> Input[(A, B)] {
  Input::map2(a, b, (x, y) => (x, y), p => p)
}

///|
/// Decoding: run the head stage of both security and regular input.
pub fn[T] Input::decode_head(self : Input[T], head : Head) -> Staged[T] raise InputErrors {
  (self.decode)(head)
}

///|
pub fn[T] Staged::finish(self : Staged[T], body : BodyValue) -> T raise InputErrors {
  (self.finish)(body)
}

///|
pub fn[T] Input::encode(self : Input[T], v : T, sink : RequestSink) -> Unit {
  (self.encode)(v, sink)
}
