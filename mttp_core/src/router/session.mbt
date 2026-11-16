///|
/// The session cookie's SameSite attribute (from `gaato/mttp_core/cookie`).
pub using @cookie {type SameSite}

///|
/// Mutable request-local string values. The signed cookie is readable by the
/// client; never store secrets here. Changes are written when the head returns.
pub struct Session {
  priv values : Map[String, String]
  priv max_bytes : Int32
  priv mut dirty : Bool
}

///|
/// The request attribute holding the current `Session`, set by `sessions`.
pub let session : @mttp_core.AttributeKey[Session] = @mttp_core.AttributeKey::new(
  "mttp.router.session",
)

///|
/// The value stored under `key`, if any.
pub fn Session::get(self : Session, key : String) -> String? {
  self.values.get(key)
}

///|
/// Ignores writes whose JSON map exceeds max_bytes; equal writes are no-ops.
/// The full outgoing cookie has a separate max_bytes check after signing.
pub fn Session::set(self : Session, key : String, value : String) -> Unit {
  if self.values.get(key) == Some(value) {
    return
  }
  // Reject obviously oversized strings before encoding a candidate map.
  if key.length() > self.max_bytes || value.length() > self.max_bytes {
    return
  }
  let candidate = self.values.copy()
  candidate[key] = value
  if @mttp_core.encode_utf8(session_json(candidate).stringify()).length() >
    self.max_bytes {
    return
  }
  self.values[key] = value
  self.dirty = true
}

///|
/// Removes `key`; removing an absent key is not a change.
pub fn Session::remove(self : Session, key : String) -> Unit {
  if self.values.contains(key) {
    self.values.remove(key)
    self.dirty = true
  }
}

///|
/// Removes every value; clearing an empty session is not a change.
pub fn Session::clear(self : Session) -> Unit {
  if !self.values.is_empty() {
    self.values.clear()
    self.dirty = true
  }
}

///|
/// Whether this request changed the session, so its cookie will be rewritten.
pub fn Session::changed(self : Session) -> Bool {
  self.dirty
}

///|
fn session_json(values : Map[String, String]) -> Json {
  Json::object(Map::from_iter(values.iter().map(p => (p.0, Json::string(p.1)))))
}

///|
/// Caller-supplied authentication, no crypto dependency. verify must compare
/// signatures in constant time, and can try several keys for rotation.
/// No renewal on reads; mutations renew from the response-head time. Empty
/// changed sessions expire the cookie. Nonpositive bounds clamp to one.
pub fn sessions(
  sign~ : (Bytes) -> Bytes,
  verify~ : (Bytes, Bytes) -> Bool,
  cookie_name~ : String = "session",
  max_age_ms~ : Int32,
  clock~ : &@rt.Clock,
  secure~ : Bool = true,
  same_site~ : SameSite = Lax,
  max_bytes~ : Int32 = 4096,
) -> Middleware {
  let max_bytes = max_bytes.max(1)
  let max_age_ms = max_age_ms.max(1)
  // A cookie name must be a nonempty HTTP token, otherwise emit no cookie.
  let valid_name = !cookie_name.is_empty() &&
    cookie_name
    .iter()
    .all(c => {
      c is ('a'..<='z' | 'A'..<='Z' | '0'..<='9') ||
      "!#$%&'*+-.^_`|~".contains(c.to_string())
    })
  (request, next) => {
    let values = read_session(
      request,
      cookie_name,
      max_bytes,
      clock.now_unix_ms(),
      verify,
    )
    let current = { values, max_bytes, dirty: false, }
    let response = next(request.attribute(session, current))
    if !current.changed() || !valid_name {
      return response
    }
    let empty = current.values.is_empty()
    let age = if empty { 0L } else { seconds(max_age_ms) }
    let value = if empty {
      ""
    } else {
      let expires = @window.saturating_add_ms(clock.now_unix_ms(), max_age_ms)
      let payload = @mttp_core.encode_utf8(
        Json::array([
          Json::string(expires.to_string()),
          session_json(current.values),
        ]).stringify(),
      )
      "\{@base64.encode(payload)}.\{@base64.encode(sign(payload))}"
    }
    let same = match same_site {
      Strict => "Strict"
      Lax => "Lax"
      NoRestriction => "None"
      SameSite::.. => "Lax"
    }
    let field = "\{cookie_name}=\{value}; Path=/; Max-Age=\{age}; HttpOnly; SameSite=\{same}" +
      (if secure { "; Secure" } else { "" })
    if @mttp_core.encode_utf8(field).length() > max_bytes {
      return response
    }
    { ..response, headers: response.headers.add("set-cookie", field), }
  }
}

///|
fn read_session(
  request : @mttp_core.Request,
  name : String,
  max_bytes : Int32,
  now : Int64,
  verify : (Bytes, Bytes) -> Bool,
) -> Map[String, String] {
  let mut found : String? = None
  for field in request.headers.get_all("cookie") {
    for part in field.split(";") {
      let pair = part.trim().split_once("=")
      if pair is Some((key, value)) && key == name {
        // Refuse ambiguous duplicates, even across Cookie header fields.
        if found is Some(_) {
          return Map([])
        }
        if value.length() > max_bytes {
          return Map([])
        }
        found = Some(value.to_owned())
      }
    }
  }
  guard found is Some(value) else { return Map([]) }
  guard value.split(".").collect() is [payload, signature] else {
    return Map([])
  }
  let (payload, signature) = (
    @base64.decode(payload),
    @base64.decode(signature),
  ) catch {
    _ => return Map([])
  }
  if !verify(payload, signature) {
    return Map([])
  }
  let text = @utf8.decode(payload) catch { _ => return Map([]) }
  let json = @json.parse(text) catch { _ => return Map([]) }
  guard json is Array([String(expiry), Object(values)]) else { return Map([]) }
  let expiry = @string.parse_int64(expiry) catch { _ => return Map([]) }
  if expiry <= now {
    return Map([])
  }
  let result : Map[String, String] = Map([])
  for key, value in values {
    guard value is String(value) else { return Map([]) }
    result[key] = value
  }
  result
}
