///|
/// Captures remaining path segments with a final `{name...}` template.
/// Internally the capture is slash-prefixed percent-encoded segments, so an
/// empty list, an empty segment and an encoded slash stay distinguishable.
pub fn paths(name : String) -> Input[Array[String]] {
  let a = Atom::new(
    Path,
    name,
    @schema.Schema::of({ "type": "array", "items": { "type": "string" } }),
    rest=true,
  )
  {
    atoms: [a],
    decode: head => {
      guard head.captures.get(name) is Some(raw) else {
        raise fail(a, missing())
      }
      if raw.is_empty() {
        return ready([])
      }
      guard raw.has_prefix("/") else { raise fail(a, mismatch("rest path")) }
      let parts = []
      for segment in raw[1:].split("/") {
        parts.push(
          @model.percent_decode(segment.to_owned()) catch {
            _ => raise fail(a, mismatch("rest path"))
          },
        )
      }
      ready(parts)
    },
    encode: (parts, sink) => {
      let builder = StringBuilder()
      for part in parts {
        builder.write_char('/')
        builder.write_string(@model.percent_encode(part))
      }
      sink.captures[name] = builder.to_string()
    },
  }
}

///|
/// Reads repeated query values in wire order; absence yields an empty array.
pub fn[T] query_list(
  name : String,
  codec : @schema.TextCodec[T],
) -> Input[Array[T]] {
  let a = Atom::new(
    Query,
    name,
    @schema.Schema::of({ "type": "array", "items": codec.schema().json }),
    required=false,
  )
  {
    atoms: [a],
    decode: head => {
      let values = []
      let failures = []
      for (key, raw) in head.query {
        if key == name {
          values.push(codec.decode(raw)) catch {
            error => failures.push(InputFailure::new(a, error))
          }
        }
      }
      if !failures.is_empty() {
        raise InputErrors(failures)
      }
      ready(values)
    },
    encode: (values, sink) => {
      for value in values {
        sink.query.push((name, codec.encode(value)))
      }
    },
  }
}

///|
/// Reads all decoded query pairs, retaining duplicates and wire order.
pub fn query_params() -> Input[Array[(String, String)]] {
  {
    atoms: [],
    decode: head => ready(head.query.copy()),
    encode: (pairs, sink) => sink.query.append(pairs),
  }
}

///|
/// Reads all headers with their original order and duplicates.
pub fn headers() -> Input[@model.Headers] {
  {
    atoms: [],
    decode: head => ready(head.request.headers),
    encode: (headers, sink) => {
      for (name, value) in headers.iter() {
        sink.headers = sink.headers.add(name, value)
      }
    },
  }
}

///|
/// Reads one cookie without URL-decoding it. Duplicate names are rejected.
pub fn[T] cookie(name : String, codec : @schema.TextCodec[T]) -> Input[T] {
  let a = atom(Cookie, name, codec.schema())
  {
    atoms: [a],
    decode: head => {
      let values = []
      for line in head.request.headers.get_all("cookie") {
        for pair in line.split(";") {
          if pair.split_once("=") is Some((key, value)) {
            if key.trim(chars=" \t") == name {
              values.push(value.trim(chars=" \t").to_owned())
            }
          }
        }
      }
      match values {
        [] => raise fail(a, missing())
        [value] =>
          ready(codec.decode(value) catch { error => raise fail(a, error) })
        _ => raise fail(a, multiple(values.length()))
      }
    },
    encode: (value, sink) => {
      let pair = name + "=" + codec.encode(value)
      let previous = sink.headers.get("cookie")
      sink.headers = sink.headers.set(
        "cookie",
        match previous {
          Some(old) => old + "; " + pair
          None => pair
        },
      )
    },
  }
}

///|
fn[T] auth_input(
  input : Input[T],
  scheme : AuthScheme,
  scheme_name : String,
) -> Input[T] {
  let atoms = input.atoms.map(a => {
    ..a,
    location: Auth(scheme~, scheme_name~),
  })
  {
    atoms,
    decode: head => {
      (input.decode)(head) catch {
        InputErrors(failures) =>
          raise InputErrors(
            failures.map(f => {
              ..f,
              atom: { ..f.atom, location: Auth(scheme~, scheme_name~), },
            }),
          )
      }
    },
    encode: input.encode,
  }
}

///|
/// Reads a required API key header; repeated credentials are rejected.
pub fn api_key_header(
  name : String,
  scheme_name~ : String = "apiKey",
) -> Input[String] {
  auth_input(header(name, @schema.string), ApiKeyHeader(name), scheme_name)
}

///|
/// Reads a required API key query parameter.
pub fn api_key_query(
  name : String,
  scheme_name~ : String = "apiKey",
) -> Input[String] {
  auth_input(query(name, @schema.string), ApiKeyQuery(name), scheme_name)
}

///|
/// Reads a required API key cookie.
pub fn api_key_cookie(
  name : String,
  scheme_name~ : String = "apiKey",
) -> Input[String] {
  auth_input(cookie(name, @schema.string), ApiKeyCookie(name), scheme_name)
}

///|
/// Decodes UTF-8 Basic credentials. The first colon separates user/password;
/// malformed credentials never appear in reported decoding messages.
pub fn basic(scheme_name~ : String = "basic") -> Input[(String, String)] {
  let a = atom(
    Auth(scheme=Basic, scheme_name~),
    "Authorization",
    @schema.string.schema(),
  )
  {
    atoms: [a],
    decode: head => {
      let raw = single_header(head, "authorization", a)
      guard raw.length() > 6 && raw[:6].to_owned().to_lower() == "basic " else {
        raise fail(a, mismatch("Basic"))
      }
      let bytes = @base64.decode(
        raw[6:].trim_start(chars=" "),
        ignore_whitespace=false,
      ) catch {
        _ => raise fail(a, mismatch("Basic"))
      }
      let text = @utf8.decode(bytes) catch {
        _ => raise fail(a, mismatch("Basic"))
      }
      guard text.split_once(":") is Some((user, password)) else {
        raise fail(a, mismatch("Basic"))
      }
      ready((user.to_owned(), password.to_owned()))
    },
    encode: (credentials, sink) => {
      sink.headers = sink.headers.add(
        "authorization",
        "Basic " +
        @base64.encode(@model.encode_utf8(credentials.0 + ":" + credentials.1)),
      )
    },
  }
}

///|
/// Reads the SSE reconnection cursor as an optional header.
pub fn last_event_id() -> Input[String?] {
  header("last-event-id", @schema.string).optional()
}

///|
/// Returns the adapter's remote address. Forwarded addresses are considered
/// only when the caller explicitly trusts the incoming proxy headers.
pub fn client_ip(trust_forwarded~ : Bool = false) -> Input[String?] {
  {
    atoms: [],
    decode: head => {
      if trust_forwarded {
        if head.request.headers.get("x-forwarded-for") is Some(value) {
          let first = value
            .split(",")
            .next()
            .unwrap_or("")
            .trim(chars=" \t")
            .to_owned()
          if !first.is_empty() {
            return ready(Some(first))
          }
        }
      }
      ready(head.request.attributes.get(@model.remote_addr))
    },
    encode: (_, _) => (),
  }
}
