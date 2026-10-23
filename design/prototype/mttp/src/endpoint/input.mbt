///|
pub(all) enum AuthScheme {
  Bearer(format~ : String?)
  Basic
  ApiKeyHeader(String)
  ApiKeyQuery(String)
  ApiKeyCookie(String)
  Signature(String)
} derive(Eq, Debug)

///|
pub(all) enum Location {
  Path
  Query
  Header
  Cookie
  Auth(scheme~ : AuthScheme, scheme_name~ : String)
  Body(media_type~ : String, streamed~ : Bool)
  RawBody
  /// Not read from the request (an attribute, or `unit()`); a failure while
  /// mapping such an input is attributed here.
  Derived
} derive(Eq, Debug)

///|
pub(all) struct Atom {
  location : Location
  name : String
  schema : @schema.Schema
  required : Bool
  description : String?
}

///|
pub(all) enum BodyValue {
  NoBody
  Buffered(Bytes)
  Streamed(&@model.BodyStream)
}

///|
pub(all) struct InputFailure {
  atom : Atom
  failure : @schema.DecodeFailure
}

///|
pub(all) suberror InputErrors {
  InputErrors(Array[InputFailure])
}

///|
/// What an input sees of a request before its body is read.
pub struct Head {
  request : @model.Request
  captures : Map[String, String]
  query : Array[(String, String)]
}

///|
/// What an input writes when the client interpreter encodes a request.
pub struct RequestSink {
  captures : Map[String, String]
  query : Array[(String, String)]
  mut headers : @model.Headers
  mut body : @model.Body
}

///|
fn RequestSink::new() -> RequestSink {
  { captures: Map::new(), query: [], headers: @model.Headers::empty(), body: Empty }
}

///|
pub struct Staged[T] {
  priv needs_body : Bool
  priv finish : (BodyValue) -> T raise InputErrors
}

///|
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
/// For custom inputs. The atoms must describe what decode reads (Risk:
/// closure-erased inputs; testing.verify and round-trip properties check it).
pub fn[T] Input::new(
  atoms : Array[Atom],
  decode : (Head) -> Staged[T] raise InputErrors,
  encode : (T, RequestSink) -> Unit,
) -> Input[T] {
  { atoms, decode, encode }
}

///|
/// Server-only: reads a typed request attribute set by an adapter or a
/// middleware (remote_addr, request id). No docs, a no-op on encode.
pub fn[T] attribute(key : @model.AttributeKey[T]) -> Input[T?] {
  { atoms: [], decode: head => ready(head.request.attributes.get(key)), encode: (_, _) => () }
}

///|
fn[T] ready(v : T) -> Staged[T] {
  { needs_body: false, finish: _ => v }
}

///|
fn fail(atom : Atom, failure : @schema.DecodeFailure) -> InputErrors {
  InputErrors([{ atom, failure }])
}

///|
fn atom(location : Location, name : String, schema : @schema.Schema) -> Atom {
  { location, name, schema, required: true, description: None }
}

///|
pub fn unit() -> Input[Unit] {
  { atoms: [], decode: _ => ready(()), encode: (_, _) => () }
}

///|
pub fn[T] path(name : String, codec : @schema.TextCodec[T]) -> Input[T] {
  let a = atom(Path, name, codec.schema())
  {
    atoms: [a],
    decode: head => {
      guard head.captures.get(name) is Some(raw) else { raise fail(a, Missing) }
      ready(codec.decode(raw) catch { f => raise fail(a, f) })
    },
    encode: (v, sink) => sink.captures[name] = codec.encode(v),
  }
}

///|
pub fn[T] query(name : String, codec : @schema.TextCodec[T]) -> Input[T] {
  let a = atom(Query, name, codec.schema())
  {
    atoms: [a],
    decode: head => {
      let values = head.query.filter(p => p.0 == name).map(p => p.1)
      match values {
        [] => raise fail(a, Missing)
        [raw] => ready(codec.decode(raw) catch { f => raise fail(a, f) })
        _ => raise fail(a, Multiple(values.length()))
      }
    },
    encode: (v, sink) => sink.query.push((name, codec.encode(v))),
  }
}

///|
pub fn[T] header(name : String, codec : @schema.TextCodec[T]) -> Input[T] {
  let a = atom(Header, name, codec.schema())
  {
    atoms: [a],
    decode: head => {
      guard head.request.headers.get(name) is Some(raw) else { raise fail(a, Missing) }
      ready(codec.decode(raw) catch { f => raise fail(a, f) })
    },
    encode: (v, sink) => sink.headers = sink.headers.add(name, codec.encode(v)),
  }
}

///|
pub fn bearer(scheme_name? : String = "bearer") -> Input[String] {
  let a = atom(
    Auth(scheme=Bearer(format=None), scheme_name~),
    "Authorization",
    @schema.string.schema(),
  )
  {
    atoms: [a],
    decode: head => {
      guard head.request.headers.get("authorization") is Some(raw) else {
        raise fail(a, Missing)
      }
      guard raw.has_prefix("Bearer ") else {
        raise fail(a, Mismatch(expected="Bearer", actual=raw))
      }
      ready(raw.view(start_offset=7).to_string())
    },
    encode: (token, sink) => sink.headers = sink.headers.add(
      "authorization",
      "Bearer \{token}",
    ),
  }
}

///|
pub fn signature_header(name : String) -> Input[String] {
  let a = atom(Auth(scheme=Signature(name), scheme_name=name), name, @schema.string.schema())
  {
    atoms: [a],
    decode: head => {
      guard head.request.headers.get(name) is Some(raw) else { raise fail(a, Missing) }
      ready(raw)
    },
    encode: (v, sink) => sink.headers = sink.headers.add(name, v),
  }
}

///|
/// In a security input: buffered (bounded by the endpoint limit) before
/// authenticate runs.
pub fn raw_body() -> Input[Bytes] {
  let a = atom(RawBody, "body", @schema.Schema::of({ "type": "string" }))
  {
    atoms: [a],
    decode: _ => {
      needs_body: true,
      finish: b => match b {
        Buffered(bytes) => bytes
        _ => raise fail(a, Missing)
      },
    },
    encode: (_, _) => (),
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
pub fn[T] body(codec : @schema.BodyCodec[T]) -> Input[T] {
  let media_type = codec.media_type()
  let a = atom(Body(media_type~, streamed=false), "body", codec.schema())
  {
    atoms: [a],
    decode: head => {
      if !content_type_matches(head, media_type) {
        raise fail(a, UnsupportedMediaType(
          head.request.headers.get("content-type").unwrap_or(""),
        ))
      }
      {
        needs_body: true,
        finish: b => match b {
          Buffered(bytes) => codec.decode(bytes) catch { f => raise fail(a, f) }
          _ => raise fail(a, Missing)
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
      { needs_body: staged.needs_body, finish: b => Some((staged.finish)(b)) }
    },
    encode: (v, sink) => if v is Some(x) { (self.encode)(x, sink) },
  }
}

///|
pub fn[T, U] Input::map(
  self : Input[T],
  to : (T) -> U raise @schema.DecodeFailure,
  from : (U) -> T,
) -> Input[U] {
  // An input built from no part of the request (attribute, unit) has no
  // atom to blame, so its mapping failures are reported as Derived.
  let first = match self.atoms {
    [a, ..] => a
    [] => atom(Derived, "", @schema.Schema::of({}))
  }
  {
    atoms: self.atoms,
    decode: head => {
      let s = (self.decode)(head)
      // A mapping over head-only inputs runs during head decoding, so its
      // failure is reported before any body is read.
      if !s.needs_body {
        let v = (s.finish)(NoBody)
        let u = to(v) catch { f => raise fail(first, f) }
        return ready(u)
      }
      {
        needs_body: true,
        finish: b => {
          let v = (s.finish)(b)
          to(v) catch { f => raise fail(first, f) }
        },
      }
    },
    encode: (u, sink) => (self.encode)(from(u), sink),
  }
}

///|
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
      {
        needs_body: sa.needs_body || sb.needs_body,
        finish: body => to((sa.finish)(body), (sb.finish)(body)),
      }
    },
    encode: (v, sink) => {
      let (x, y) = from(v)
      (a.encode)(x, sink)
      (b.encode)(y, sink)
    },
  }
}

///|
pub fn[A, B] pair(a : Input[A], b : Input[B]) -> Input[(A, B)] {
  Input::map2(a, b, (x, y) => (x, y), p => p)
}
