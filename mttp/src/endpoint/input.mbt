///|
/// Authentication metadata shared by server challenges and API descriptions.
#non_exhaustive
pub(all) enum AuthScheme {
  Bearer(format~ : String?)
  Basic
  ApiKeyHeader(String)
  ApiKeyQuery(String)
  ApiKeyCookie(String)
  Signature(String)
} derive(Eq, Debug)

///|
/// The request location consumed by an input atom.
#non_exhaustive
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
/// One documented input, including its schema, requiredness and rest-path marker.
pub struct Atom {
  location : Location
  name : String
  schema : @schema.Schema
  required : Bool
  description : String?
  rest : Bool
}

///|
/// The body supplied after head decoding: absent, buffered, or pull-only.
#non_exhaustive
pub(all) enum BodyValue {
  NoBody
  Buffered(Bytes)
  Streamed(&@model.BodyStream)
}

///|
/// A decoding failure associated with its input metadata.
pub(all) struct InputFailure {
  atom : Atom
  failure : @schema.DecodeFailure
}

///|
/// Collected failures from independent endpoint inputs.
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
  priv captures : Map[String, String]
  priv query : Array[(String, String)]
  priv mut headers : @model.Headers
  priv mut body : @model.Body
}

///|
fn RequestSink::new() -> RequestSink {
  {
    captures: Map([]),
    query: [],
    headers: @model.Headers::empty(),
    body: Empty,
  }
}

///|
/// A decoded head whose remaining work may require the bounded body.
pub struct Staged[T] {
  priv needs_body : Bool
  priv finish : (BodyValue) -> T raise InputErrors
}

///|
/// Bidirectional request encoding and staged decoding with documentation atoms.
pub struct Input[T] {
  priv atoms : Array[Atom]
  priv decode : (Head) -> Staged[T] raise InputErrors
  priv encode : (T, RequestSink) -> Unit
}

///|
/// Returns a copy of this input's metadata array.
pub fn[T] Input::atoms(self : Input[T]) -> Array[Atom] {
  self.atoms.copy()
}

///|
/// For custom inputs. The atoms must describe what decode reads (Risk:
/// closure-erased inputs; testing.verify and round-trip properties check it).
pub fn[T] Input::new(
  atoms : Array[Atom],
  decode : (Head) -> Staged[T] raise InputErrors,
  encode : (T, RequestSink) -> Unit,
) -> Input[T] {
  { atoms: atoms.copy(), decode, encode, }
}

///|
/// Server-only: reads a typed request attribute set by an adapter or a
/// middleware (remote_addr, request id). No docs, a no-op on encode.
pub fn[T] attribute(key : @model.AttributeKey[T]) -> Input[T?] {
  {
    atoms: [],
    decode: head => ready(head.request.attributes.get(key)),
    encode: (_, _) => (),
  }
}

///|
fn[T] ready(v : T) -> Staged[T] {
  { needs_body: false, finish: _ => v, }
}

///|
fn fail(atom : Atom, failure : @schema.DecodeFailure) -> InputErrors {
  InputErrors([{ atom, failure, }])
}

///|
fn atom(location : Location, name : String, schema : @schema.Schema) -> Atom {
  { location, name, schema, required: true, description: None, rest: false, }
}

///|
/// An input which consumes no request fields and yields Unit.
pub fn unit() -> Input[Unit] {
  { atoms: [], decode: _ => ready(()), encode: (_, _) => (), }
}

///|
/// Decodes one required path capture using a text codec.
pub fn[T] path(name : String, codec : @schema.TextCodec[T]) -> Input[T] {
  let a = atom(Path, name, codec.schema())
  {
    atoms: [a],
    decode: head => {
      guard head.captures.get(name) is Some(raw) else {
        raise fail(a, missing())
      }
      ready(codec.decode(raw) catch { f => raise fail(a, f) })
    },
    encode: (v, sink) => sink.captures[name] = codec.encode(v),
  }
}

///|
/// Decodes one required query value, rejecting duplicate occurrences.
pub fn[T] query(name : String, codec : @schema.TextCodec[T]) -> Input[T] {
  let a = atom(Query, name, codec.schema())
  {
    atoms: [a],
    decode: head => {
      let values = head.query.filter(p => p.0 == name).map(p => p.1)
      match values {
        [] => raise fail(a, missing())
        [raw] => ready(codec.decode(raw) catch { f => raise fail(a, f) })
        _ => raise fail(a, multiple(values.length()))
      }
    },
    encode: (v, sink) => sink.query.push((name, codec.encode(v))),
  }
}

///|
/// Decodes one required header, rejecting duplicates case-insensitively.
pub fn[T] header(name : String, codec : @schema.TextCodec[T]) -> Input[T] {
  let a = atom(Header, name, codec.schema())
  {
    atoms: [a],
    decode: head => {
      let raw = single_header(head, name, a)
      ready(codec.decode(raw) catch { f => raise fail(a, f) })
    },
    encode: (v, sink) => sink.headers = sink.headers.add(name, codec.encode(v)),
  }
}

///|
/// Reads a nonempty Bearer credential with a case-insensitive scheme name.
pub fn bearer(scheme_name~ : String = "bearer") -> Input[String] {
  let a = atom(
    Auth(scheme=Bearer(format=None), scheme_name~),
    "Authorization",
    @schema.string.schema(),
  )
  {
    atoms: [a],
    decode: head => {
      let raw = single_header(head, "authorization", a)
      guard raw.length() > 7 && raw[:7].to_owned().to_lower() == "bearer " else {
        raise fail(a, mismatch("Bearer"))
      }
      let token = raw[7:].trim_start(chars=" ").to_owned()
      guard !token.is_empty() && token.iter().all(c => c != ' ' && c != '\t') else {
        raise fail(a, mismatch("Bearer"))
      }
      ready(token)
    },
    encode: (token, sink) => {
      sink.headers = sink.headers.add("authorization", "Bearer \{token}")
    },
  }
}

///|
/// Reads a required signature header without interpreting the signature.
pub fn signature_header(name : String) -> Input[String] {
  let a = atom(
    Auth(scheme=Signature(name), scheme_name=name),
    name,
    @schema.string.schema(),
  )
  {
    atoms: [a],
    decode: head => {
      let raw = single_header(head, name, a)
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
      finish: b => {
        match b {
          Buffered(bytes) => bytes
          _ => raise fail(a, missing())
        }
      },
    },
    encode: (bytes, sink) => sink.body = Bytes(bytes),
  }
}

///|
/// A pull-only request body. The server limits bytes as the handler reads;
/// the client transfers the supplied reader exactly once.
pub fn stream_body(
  media_type~ : String = "application/octet-stream",
) -> Input[&@model.BodyStream] {
  let a = atom(
    Body(media_type~, streamed=true),
    "body",
    @schema.Schema::of({ "type": "string" }),
  )
  {
    atoms: [a],
    decode: head => {
      if !content_type_matches(head, media_type) {
        raise fail(
          a,
          unsupported_media_type(
            head.request.headers.get("content-type").unwrap_or(""),
          ),
        )
      }
      Staged::after_body(body => {
        match body {
          Streamed(reader) => reader
          _ => raise fail(a, missing())
        }
      })
    },
    encode: (reader, sink) => {
      sink.headers = sink.headers.set("content-type", media_type)
      sink.body = Stream(@model.StreamBody::new(reader))
    },
  }
}

///|
fn content_type_matches(head : Head, media_type : String) -> Bool {
  match head.request.headers.get_all("content-type") {
    [ct] =>
      // media types are case-insensitive; parameters may follow
      media_type_token(ct) == media_type_token(media_type)
    _ => false
  }
}

///|
fn single_header(
  head : Head,
  name : String,
  a : Atom,
) -> String raise InputErrors {
  match head.request.headers.get_all(name) {
    [] => raise fail(a, missing())
    [value] => value
    values => raise fail(a, multiple(values.length()))
  }
}

///|
fn media_type_token(value : String) -> String {
  let token = match value.split_once(";") {
    Some((token, _)) => token
    None => value[:]
  }
  token.trim(chars=" \t").to_owned().to_lower()
}

///|
/// Decodes a buffered body with an exact media type; parameters are allowed.
pub fn[T] body(codec : @schema.BodyCodec[T]) -> Input[T] {
  let media_type = codec.media_type()
  let a = atom(Body(media_type~, streamed=false), "body", codec.schema())
  {
    atoms: [a],
    decode: head => {
      // No body and no Content-Type is an absent body (Missing), which an
      // optional() body turns into None; a body of the wrong type is 415.
      let absent = head.request.headers.get("content-type") is None &&
        (
          head.request.body is Empty ||
          (head.request.body is Bytes(b) && b.length() == 0)
        )
      if absent {
        raise fail(a, missing())
      }
      if !content_type_matches(head, media_type) {
        raise fail(
          a,
          unsupported_media_type(
            head.request.headers.get("content-type").unwrap_or(""),
          ),
        )
      }
      {
        needs_body: true,
        finish: b => {
          match b {
            Buffered(bytes) =>
              codec.decode(bytes) catch {
                f => raise fail(a, f)
              }
            _ => raise fail(a, missing())
          }
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
/// Turns missing head inputs into None; malformed present values still fail.
pub fn[T] Input::optional(self : Input[T]) -> Input[T?] {
  {
    atoms: self.atoms.map(a => { ..a, required: false, }),
    decode: head => {
      let staged = (self.decode)(head) catch {
        InputErrors(fs) as e =>
          if fs
            .iter()
            .all(f => f.failure is @schema.DecodeFailure(kind=Missing, ..)) {
            return ready(None)
          } else {
            raise e
          }
      }
      { needs_body: staged.needs_body, finish: b => Some((staged.finish)(b)), }
    },
    encode: (v, sink) => if v is Some(x) { (self.encode)(x, sink) },
  }
}

///|
/// Transforms an input bidirectionally, attributing mapping failures to its first atom.
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
          to(v) catch {
            f => raise fail(first, f)
          }
        },
      }
    },
    encode: (u, sink) => (self.encode)(from(u), sink),
  }
}

///|
/// Combines two inputs, collecting both head failures before body processing.
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
      guard sa is Some(sa) && sb is Some(sb) else {
        raise InputErrors(failures)
      }
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
/// Pairs two typed inputs without changing their encoding or staging.
pub fn[A, B] pair(a : Input[A], b : Input[B]) -> Input[(A, B)] {
  Input::map2(a, b, (x, y) => (x, y), p => p)
}
