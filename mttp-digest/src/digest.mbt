///|
// HTTP Digest access authentication (RFC 7616, with RFC 2617's challenges
// that offer no qop). A client answers a 401's Digest challenge once, keeps
// the nonce per origin and reuses it with a counted `nc` on later calls, as
// httpx's `DigestAuth` and requests' `HTTPDigestAuth` do.

///|
/// The most origins a client keeps a Digest nonce for; the oldest is
/// forgotten first.
let max_digest_origins : Int32 = 16

///|
/// The largest nonce count: `nc` is eight hex digits (RFC 7616 §3.4).
let max_nonce_count : Int64 = 0xFFFFFFFFL

///|
/// The hash function a Digest challenge names. SHA-512-256 is not offered:
/// it needs SHA-512 with its own initial values, which moonbitlang/x does
/// not provide, so challenges naming it are passed over.
priv enum DigestHash {
  Md5
  Sha256
}

///|
/// The quality of protection a response is computed with.
priv enum Qop {
  /// The method and URI.
  Auth
  /// The method, the URI and the request body.
  AuthInt
}

///|
/// A Digest challenge this client can answer.
priv struct DigestChallenge {
  realm : String
  nonce : String
  opaque_data : String?
  hash : DigestHash
  /// `-sess`: the session key mixes in the nonce and the cnonce.
  sess : Bool
  /// `None` for an RFC 2069 challenge, which offers no qop.
  qop : Qop?
  /// The nonce expired but the credentials were right.
  stale : Bool
  /// The server wants the username hashed.
  userhash : Bool
}

///|
/// A nonce in use for one origin and the last `nc` sent with it.
priv struct DigestNonce {
  challenge : DigestChallenge
  mut count : Int64
}

///|
/// The nonces a client holds, by origin, at most `max_digest_origins`.
priv struct DigestState {
  nonces : Map[String, DigestNonce]
}

///|
fn DigestState::new() -> DigestState {
  { nonces: {}, }
}

///|
/// Takes `challenge` as the nonce for `origin`, counting its first use,
/// and forgets the oldest origin when there are too many.
fn DigestState::adopt(
  self : DigestState,
  origin : String,
  challenge : DigestChallenge,
) -> Unit {
  self.nonces.remove(origin)
  while self.nonces.length() >= max_digest_origins {
    guard self.nonces.keys().head() is Some(oldest) else { break }
    self.nonces.remove(oldest)
  }
  self.nonces.set(origin, { challenge, count: 1, })
}

///|
/// The nonce for `origin` and its next count, to authorize a request before
/// any challenge. A nonce without qop has no count, so it is not reused; one
/// that wants the body is not used without it; a nonce whose count ran out
/// is forgotten.
fn DigestState::next(
  self : DigestState,
  origin : String,
  body_in_memory : Bool,
) -> (DigestChallenge, Int64)? {
  guard self.nonces.get(origin) is Some(nonce) else { return None }
  match nonce.challenge.qop {
    None => return None
    Some(AuthInt) if !body_in_memory => return None
    Some(_) => ()
  }
  guard next_nonce_count(nonce.count) is Some(count) else {
    self.nonces.remove(origin)
    return None
  }
  nonce.count = count
  Some((nonce.challenge, count))
}

///|
/// The count after `count`, or `None` once `nc` cannot hold it.
fn next_nonce_count(count : Int64) -> Int64? {
  if count < max_nonce_count {
    Some(count + 1)
  } else {
    None
  }
}

///|
/// Whether to answer a Digest challenge after `answers` answers in this
/// call: once, and once more when the answer's nonce turned out stale.
fn should_answer(answers : Int32, stale : Bool) -> Bool {
  answers == 0 || (answers == 1 && stale)
}

///|
/// The parsed URL, its origin and the request target a Digest response
/// names, or `None` for a URL without an origin.
fn digest_target(url : String) -> (@model.Url, String, String)? {
  let url = @model.Url::parse(url) catch { _ => return None }
  guard url.scheme is Some(scheme) && url.host is Some(host) else {
    return None
  }
  let port = match url.port_or_default() {
    Some(port) => port.to_string()
    None => ""
  }
  let path = if url.path.is_empty() { "/" } else { url.path }
  let target = match url.query {
    Some(query) => path + "?" + query
    None => path
  }
  let host = if host.contains(":") { "[" + host + "]" } else { host }
  Some((url, "\{scheme}://\{host}:\{port}", target))
}

///|
/// Whether `other` parses to a URL of the same origin as `url`.
fn same_origin_as(url : @model.Url, other : String) -> Bool {
  let other = @model.Url::parse(other) catch { _ => return false }
  url.same_origin(other)
}

///|
/// The first challenge of the `WWW-Authenticate` headers, in order, that is
/// a Digest challenge this client can answer, as RFC 7616 §3.7 asks.
fn find_digest_challenge(
  headers : @model.Headers,
  body_in_memory : Bool,
) -> DigestChallenge? {
  let mut remaining = 16384
  for (name, value) in headers.iter() {
    if name != "www-authenticate" {
      continue
    }
    if value.length() > remaining {
      return None
    }
    let size = @model.encode_utf8(value).length()
    if size > remaining {
      return None
    }
    remaining -= size
  }
  for value in headers.get_all("www-authenticate") {
    for challenge in parse_challenges(value) {
      if challenge.0 == "digest" &&
        digest_challenge(challenge.1, body_in_memory) is Some(digest) {
        return Some(digest)
      }
    }
  }
  None
}

///|
/// A Digest challenge from its parameters, or `None` when it lacks a realm
/// or a nonce, names an unknown algorithm, or offers only a qop this client
/// cannot use: `auth-int` needs the body in memory.
fn digest_challenge(
  params : Array[(String, String)],
  body_in_memory : Bool,
) -> DigestChallenge? {
  let param = (name : String) => {
    for pair in params {
      if pair.0 == name {
        return Some(pair.1)
      }
    }
    None
  }
  guard param("realm") is Some(realm) && param("nonce") is Some(nonce) else {
    return None
  }
  let (hash, sess) = match param("algorithm").map(String::to_lower) {
    None | Some("md5") => (Md5, false)
    Some("md5-sess") => (Md5, true)
    Some("sha-256") => (Sha256, false)
    Some("sha-256-sess") => (Sha256, true)
    Some(_) => return None
  }
  let qop = match param("qop") {
    // A session key needs a cnonce, but RFC 2617 §3.2.2 forbids sending one
    // without a qop, so a server cannot check any answer to a `-sess`
    // challenge without qop (requests and httpx send ones it cannot).
    // Such a challenge is declined and its 401 returned.
    None => if sess { return None } else { None }
    Some(list) => {
      let offered = list
        .split(",")
        .map(item => item.trim().to_owned().to_lower())
        .collect()
      if offered.contains("auth") {
        Some(Auth)
      } else if offered.contains("auth-int") && body_in_memory {
        Some(AuthInt)
      } else {
        return None
      }
    }
  }
  let flag = (name : String) => {
    param(name).map(String::to_lower) is Some("true")
  }
  Some({
    realm,
    nonce,
    opaque_data: param("opaque"),
    hash,
    sess,
    qop,
    stale: flag("stale"),
    userhash: flag("userhash"),
  })
}

///|
/// The `Authorization` value answering `challenge` (RFC 7616 §3.4), with
/// nonce count `count` and client nonce `cnonce`; `body` is hashed for
/// `auth-int`. Strings are hashed as UTF-8.
fn digest_authorization(
  challenge : DigestChallenge,
  username : String,
  password : String,
  http_method : String,
  uri : String,
  count : Int64,
  cnonce : String,
  body : Bytes?,
) -> String {
  let h = (text : String) => {
    digest_hash(challenge.hash, @model.encode_utf8(text))
  }
  let realm = challenge.realm
  let nonce = challenge.nonce
  let nc = hex8(count)
  let secret = h("\{username}:\{realm}:\{password}")
  let ha1 = if challenge.sess {
    h("\{secret}:\{nonce}:\{cnonce}")
  } else {
    secret
  }
  let ha2 = match challenge.qop {
    Some(AuthInt) => {
      let body_hash = digest_hash(challenge.hash, body.unwrap_or(b""))
      h("\{http_method}:\{uri}:\{body_hash}")
    }
    Some(Auth) | None => h("\{http_method}:\{uri}")
  }
  let qop = match challenge.qop {
    Some(Auth) => Some("auth")
    Some(AuthInt) => Some("auth-int")
    None => None
  }
  let response = match qop {
    Some(qop) => h("\{ha1}:\{nonce}:\{nc}:\{cnonce}:\{qop}:\{ha2}")
    None => h("\{ha1}:\{nonce}:\{ha2}")
  }
  let parts = []
  if challenge.userhash {
    parts.push("username=" + quote(h("\{username}:\{realm}")))
  } else if username.iter().all(c => c >= ' ' && c <= '~') {
    parts.push("username=" + quote(username))
  } else {
    parts.push("username*=UTF-8''" + ext_value(username))
  }
  parts.push("realm=" + quote(realm))
  parts.push("uri=" + quote(uri))
  parts.push("algorithm=" + algorithm_name(challenge))
  parts.push("nonce=" + quote(nonce))
  if qop is Some(qop) {
    parts.push("nc=" + nc)
    parts.push("cnonce=" + quote(cnonce))
    parts.push("qop=" + qop)
  }
  parts.push("response=" + quote(response))
  if challenge.opaque_data is Some(data) {
    parts.push("opaque=" + quote(data))
  }
  if challenge.userhash {
    parts.push("userhash=true")
  }
  "Digest " + parts.join(", ")
}

///|
/// The algorithm token a response names.
fn algorithm_name(challenge : DigestChallenge) -> String {
  let name = match challenge.hash {
    Md5 => "MD5"
    Sha256 => "SHA-256"
  }
  if challenge.sess {
    name + "-sess"
  } else {
    name
  }
}

///|
/// The lower-case hex digest of `data`.
fn digest_hash(hash : DigestHash, data : Bytes) -> String {
  match hash {
    Md5 => @crypto.bytes_to_hex_string(@crypto.md5(data))
    Sha256 => @crypto.bytes_to_hex_string(@crypto.sha256(data))
  }
}

///|
/// `value` as a quoted-string, `\` and `"` escaped.
fn quote(value : String) -> String {
  let buffer = StringBuilder()
  buffer.write_char('"')
  for c in value {
    if c == '"' || c == '\\' {
      buffer.write_char('\\')
    }
    buffer.write_char(c)
  }
  buffer.write_char('"')
  buffer.to_string()
}

///|
/// `value` percent-encoded as UTF-8 for an RFC 8187 `ext-value`, keeping
/// `attr-char`s.
fn ext_value(value : String) -> String {
  let buffer = StringBuilder()
  for byte in @model.encode_utf8(value) {
    let c = byte.to_int().unsafe_to_char()
    let keep = (c >= 'a' && c <= 'z') ||
      (c >= 'A' && c <= 'Z') ||
      (c >= '0' && c <= '9') ||
      "!#$&+-.^_`|~".contains_char(c)
    if keep {
      buffer.write_char(c)
    } else {
      buffer.write_char('%')
      buffer.write_char(hex_digit(byte.to_int() >> 4, upper=true))
      buffer.write_char(hex_digit(byte.to_int() & 0xF, upper=true))
    }
  }
  buffer.to_string()
}

///|
/// `n` as eight lower-case hex digits, the form of `nc`.
fn hex8(n : Int64) -> String {
  let buffer = StringBuilder()
  for shift = 28; shift >= 0; shift = shift - 4 {
    buffer.write_char(hex_digit(((n >> shift) & 0xFL).to_int()))
  }
  buffer.to_string()
}

///|
/// The hex digit for `n`, in 0 through 15.
fn hex_digit(n : Int32, upper~ : Bool = false) -> Char {
  let ten = if upper { 'A' } else { 'a' }
  if n < 10 {
    ('0'.to_int() + n).unsafe_to_char()
  } else {
    (ten.to_int() + n - 10).unsafe_to_char()
  }
}

///|
/// A client nonce: 128 bits from `random`, as hex.
fn make_cnonce(random : () -> Double) -> String {
  let buffer = StringBuilder()
  for _ in 0..<4 {
    let word = (random() * 4294967296.0).to_int64()
    buffer.write_string(hex8(word.max(0L).min(max_nonce_count)))
  }
  buffer.to_string()
}

///|
/// Whether `c` is an RFC 9110 `tchar`.
fn is_tchar(c : Char) -> Bool {
  (c >= 'a' && c <= 'z') ||
  (c >= 'A' && c <= 'Z') ||
  (c >= '0' && c <= '9') ||
  "!#$%&'*+-.^_`|~".contains_char(c)
}

///|
/// The challenges of a `WWW-Authenticate` value (RFC 9110 §11.6.1): each
/// scheme, lower-cased, with its parameters, names lower-cased and
/// quoted-strings unescaped. A token68 is skipped. Several challenges may
/// share a value, separated by commas; malformed parts are skipped.
fn parse_challenges(value : String) -> Array[(String, Array[(String, String)])] {
  let chars : Array[Char] = value.iter().collect()
  let n = chars.length()
  let challenges = []
  let mut i = 0
  while i < n {
    i = skip_while(chars, i, c => c == ' ' || c == '\t' || c == ',')
    if i >= n {
      break
    }
    let start = i
    i = skip_while(chars, i, is_tchar)
    if i == start {
      i = skip_item(chars, i)
      continue
    }
    let scheme = String::from_array(chars[start:i]).to_lower()
    let params = []
    i = skip_ws(chars, i)
    let token68 = skip_while(chars, skip_while(chars, i, is_token68_char), c => {
      c == '='
    })
    let after = skip_ws(chars, token68)
    if token68 > i && (after >= n || chars[after] == ',') {
      challenges.push((scheme, params))
      i = after
      continue
    }
    while i < n {
      let name_end = skip_while(chars, i, is_tchar)
      let equals = skip_ws(chars, name_end)
      guard name_end > i && equals < n && chars[equals] == '=' else { break }
      let name = String::from_array(chars[i:name_end]).to_lower()
      let start = skip_ws(chars, equals + 1)
      let (value, end) = if start < n && chars[start] == '"' {
        read_quoted(chars, start)
      } else {
        let end = skip_while(chars, start, c => {
          c != ',' && c != ' ' && c != '\t'
        })
        (String::from_array(chars[start:end]), end)
      }
      params.push((name, value))
      i = skip_ws(chars, end)
      guard i < n && chars[i] == ',' else { break }
      i = skip_while(chars, i, c => c == ' ' || c == '\t' || c == ',')
    }
    challenges.push((scheme, params))
  }
  challenges
}

///|
/// The index of the first character from `i` on that is not `p`.
fn skip_while(chars : Array[Char], i : Int32, p : (Char) -> Bool) -> Int32 {
  let mut i = i
  while i < chars.length() && p(chars[i]) {
    i += 1
  }
  i
}

///|
fn skip_ws(chars : Array[Char], i : Int32) -> Int32 {
  skip_while(chars, i, c => c == ' ' || c == '\t')
}

///|
/// Whether `c` may appear in a token68 before its trailing `=`s.
fn is_token68_char(c : Char) -> Bool {
  (c >= 'a' && c <= 'z') ||
  (c >= 'A' && c <= 'Z') ||
  (c >= '0' && c <= '9') ||
  "-._~+/".contains_char(c)
}

///|
/// The index of the next comma outside a quoted-string, from `i`, which is
/// not a comma.
fn skip_item(chars : Array[Char], i : Int32) -> Int32 {
  let mut i = i
  while i < chars.length() && chars[i] != ',' {
    if chars[i] == '"' {
      i = read_quoted(chars, i).1
    } else {
      i += 1
    }
  }
  i
}

///|
/// The quoted-string opening at `start`, unescaped, and the index after its
/// closing quote; an unterminated one runs to the end.
fn read_quoted(chars : Array[Char], start : Int32) -> (String, Int32) {
  let buffer = StringBuilder()
  let mut i = start + 1
  while i < chars.length() {
    let c = chars[i]
    if c == '\\' && i + 1 < chars.length() {
      buffer.write_char(chars[i + 1])
      i += 2
    } else if c == '"' {
      return (buffer.to_string(), i + 1)
    } else {
      buffer.write_char(c)
      i += 1
    }
  }
  (buffer.to_string(), i)
}
