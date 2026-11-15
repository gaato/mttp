// Generators of wire-valid HTTP/1.1 messages for the property tests in
// property_test.mbt. Each generator draws from the quickcheck runner's
// seeded state only, so a seed gives the same message on every target. They
// stay test-only: the generators of `gaato/mttp_core/sim` serve the engines'
// tests, while these encode the codec's grammar (OWS, chunk extensions,
// reason phrases) and are useful to this package alone.

///|
/// A seeded source of choices.
struct Draw {
  state : @qc.RandomState
}

///|
/// A generator whose sample is drawn imperatively from the runner's state.
fn[T] drawn(f : (Draw) -> T) -> @qc.Generator[T] {
  @qc.Generator((_, state) => f({ state, }))
}

///|
/// A number in `0..<n`; 0 when `n` is at most 1.
fn Draw::below(self : Draw, n : Int32) -> Int32 {
  if n <= 1 {
    0
  } else {
    (self.state.next_uint() % n.reinterpret_as_uint()).reinterpret_as_int()
  }
}

///|
/// A number in `lo..=hi`.
fn Draw::range(self : Draw, lo : Int32, hi : Int32) -> Int32 {
  lo + self.below(hi - lo + 1)
}

///|
fn Draw::chance(self : Draw, percent : Int32) -> Bool {
  self.below(100) < percent
}

///|
fn[T] Draw::pick(self : Draw, xs : ArrayView[T]) -> T {
  xs[self.below(xs.length())]
}

///|
/// `lo..=hi` characters of `alphabet`.
fn Draw::text(self : Draw, alphabet : String, lo : Int32, hi : Int32) -> String {
  let out = StringBuilder()
  for _ in 0..<self.range(lo, hi) {
    out.write_char(alphabet.get_char(self.below(alphabet.length())).unwrap())
  }
  out.to_string()
}

///|
fn Draw::bytes(self : Draw, lo : Int32, hi : Int32) -> Bytes {
  Bytes::makei(self.range(lo, hi), _ => self.below(256).to_byte())
}

///|
/// Each ASCII letter in either case.
fn Draw::mixed_case(self : Draw, text : String) -> String {
  let out = StringBuilder()
  for c in text {
    let flipped = match c {
      'a'..<='z' if self.chance(50) => (c.to_int() - 32).unsafe_to_char()
      'A'..<='Z' if self.chance(50) => (c.to_int() + 32).unsafe_to_char()
      _ => c
    }
    out.write_char(flipped)
  }
  out.to_string()
}

///|
let tchars : String = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'*+-.^_`|~"

///|
/// Path and query characters other than `%`: unreserved, sub-delims, `:`
/// and `@` (RFC 3986).
let pchars : String = "abcxyzABCXYZ0189-._~!$&'()*+,;=:@"

///|
let hex_digits : String = "0123456789abcdefABCDEF"

///|
/// Request methods whose responses the totality and agreement properties
/// read arbitrary bytes as: with and without a body, and CONNECT's tunnel.
let methods_answered : Array[@mttp_core.Method] = [Get, Head, Post, Connect]

///|
/// Field names the generators never draw at random: the framing, routing
/// and connection fields the messages set themselves and that trailers may
/// not carry.
let reserved_names : Array[String] = [
  "content-length", "transfer-encoding", "host", "connection", "trailer",
]

///|
/// Methods with origin-form targets: the standard ones but CONNECT and
/// extension tokens, normalized as the parser reads them.
fn Draw::request_method(self : Draw) -> @mttp_core.Method {
  if self.chance(60) {
    return self.pick([Get, Head, Post, Put, Delete, Options, Trace, Patch])
  }
  match @mttp_core.Method::parse(self.text(tchars, 1, 10)) {
    Connect => Other("CONNECTX")
    meth => meth
  }
}

///|
/// An origin-form target: segments of pchars and percent-encodings, and an
/// optional query that may hold `/` and `?` too.
fn Draw::target(self : Draw) -> String {
  let out = StringBuilder()
  let pchar = (extra : String) => {
    if self.chance(15) {
      out.write_char('%')
      out.write_char(hex_digits.get_char(self.below(22)).unwrap())
      out.write_char(hex_digits.get_char(self.below(22)).unwrap())
    } else {
      out.write_string(self.text(pchars + extra, 1, 1))
    }
  }
  for _ in 0..<self.range(1, 4) {
    out.write_char('/')
    for _ in 0..<self.range(0, 6) {
      pchar("")
    }
  }
  if self.chance(40) {
    out.write_char('?')
    for _ in 0..<self.range(0, 8) {
      pchar("/?")
    }
  }
  out.to_string()
}

///|
/// A `Host` value: a name or an IPv4 address, with an optional port.
fn Draw::host(self : Draw) -> String {
  let name = match self.below(4) {
    0 => "127.0.0.\{self.range(1, 254)}"
    1 => self.text("abcdefghijklmnopqrstuvwxyz0123456789", 1, 8)
    _ =>
      self.text("abcdefghijklmnopqrstuvwxyz", 1, 8) +
      "." +
      self.text("abcdefghijklmnopqrstuvwxyz-", 1, 6) +
      ".test"
  }
  if self.chance(40) {
    "\{name}:\{self.range(1, 65535)}"
  } else {
    name
  }
}

///|
/// A field name: a tchar token or a common name, in mixed case, never one of
/// `reserved_names`.
fn Draw::field_name(self : Draw) -> String {
  let name = if self.chance(30) {
    self.pick([
      "Accept", "User-Agent", "Set-Cookie", "X-Request-Id", "Cache-Control", "ETag",
    ])
  } else {
    self.text(tchars, 1, 12)
  }
  let name = self.mixed_case(name)
  if reserved_names.contains(name.to_lower()) {
    "X-" + name
  } else {
    name
  }
}

///|
/// A character of a field value or reason phrase: VCHAR, obs-text or, when
/// `whitespace`, SP or HTAB. Octets are code points of the same value, as
/// the codec reads them.
fn Draw::field_char(self : Draw, whitespace~ : Bool) -> Char {
  let roll = self.below(100)
  if roll < 70 || (!whitespace && roll >= 85) {
    (0x21 + self.below(94)).unsafe_to_char()
  } else if roll < 85 {
    (0x80 + self.below(128)).unsafe_to_char()
  } else {
    self.pick([' ', '\t'])
  }
}

///|
/// A field value: possibly empty, SP and HTAB only inside it.
fn Draw::field_value(self : Draw) -> String {
  let length = self.range(0, 16)
  let out = StringBuilder()
  for i in 0..<length {
    out.write_char(self.field_char(whitespace=i > 0 && i < length - 1))
  }
  out.to_string()
}

///|
/// Optional whitespace around a field value.
fn Draw::ows(self : Draw) -> String {
  self.pick(["", "", " ", "\t", "  ", " \t"])
}

///|
/// `lo..=hi` fields with mixed-case names, sometimes repeating a name in
/// another case.
fn Draw::fields(self : Draw, lo : Int32, hi : Int32) -> Array[(String, String)] {
  let fields : Array[(String, String)] = []
  for _ in 0..<self.range(lo, hi) {
    let name = if !fields.is_empty() && self.chance(20) {
      self.mixed_case(self.pick(fields[:]).0)
    } else {
      self.field_name()
    }
    fields.push((name, self.field_value()))
  }
  fields
}

///|
/// The payload of a generated message and how it is framed.
#derive(Debug)
enum GenBody {
  /// No Content-Length and no Transfer-Encoding.
  Absent
  /// Content-Length and the bytes.
  Sized(Bytes)
  /// Chunked: nonempty chunks and the trailer fields.
  Chunks(chunks~ : Array[Bytes], trailers~ : Array[(String, String)])
}

///|
fn GenBody::payload(self : GenBody) -> Bytes {
  match self {
    Absent => b""
    Sized(bytes) => bytes
    Chunks(chunks~, ..) => concat(chunks)
  }
}

///|
fn GenBody::trailers(self : GenBody) -> @mttp_core.Headers {
  match self {
    Chunks(trailers~, ..) => @mttp_core.Headers::of(trailers)
    _ => @mttp_core.Headers::empty()
  }
}

///|
fn concat(pieces : ArrayView[Bytes]) -> Bytes {
  let out = Buffer()
  pieces.each(piece => out.write_bytes(piece))
  out.to_bytes()
}

///|
/// A body of up to 40 arbitrary bytes, framed by length or, when
/// `chunked`, by the chunked coding; `Absent` only when `absent`.
fn Draw::body(self : Draw, chunked~ : Bool, absent~ : Bool) -> GenBody {
  let roll = self.below(3)
  if roll == 0 && absent {
    return Absent
  }
  let payload = self.bytes(0, 40)
  if roll == 1 || !chunked {
    return Sized(payload)
  }
  let chunks = []
  for at = 0; at < payload.length(); {
    let end = (at + self.range(1, 16)).min(payload.length())
    chunks.push(payload[at:end].to_owned())
    continue end
  }
  // `field_name` never draws a forbidden trailer, and a repeated name is
  // an earlier drawn one.
  Chunks(chunks~, trailers=self.fields(0, 3))
}

///|
/// Writes a field line with optional whitespace around the value.
fn Draw::field_line(
  self : Draw,
  out : Buffer,
  name : String,
  value : String,
) -> Unit {
  write_latin1(out, name + ":" + self.ows() + value + self.ows() + "\r\n")
}

///|
fn write_latin1(out : Buffer, text : String) -> Unit {
  for c in text {
    out.write_byte(c.to_int().to_byte())
  }
}

///|
/// Chunk extensions (RFC 9112, section 7.1.1): BWS around `;` and `=`,
/// token or quoted values, nothing after the last one.
fn Draw::chunk_ext(self : Draw) -> String {
  if self.chance(50) {
    return ""
  }
  let bws = () => self.pick(["", "", " ", "\t"])
  let out = StringBuilder()
  for _ in 0..<self.range(1, 2) {
    out.write_string(bws() + ";" + bws() + self.text(tchars, 1, 6))
    if self.chance(60) {
      out.write_string(bws() + "=" + bws())
      if self.chance(50) {
        out.write_string(self.text(tchars, 1, 6))
      } else {
        out.write_char('"')
        for _ in 0..<self.range(0, 6) {
          match self.field_char(whitespace=true) {
            '"' | '\\' as c => {
              out.write_char('\\')
              out.write_char(c)
            }
            c => out.write_char(c)
          }
        }
        out.write_char('"')
      }
    }
  }
  out.to_string()
}

///|
/// A chunk size in hex of either case, sometimes with leading zeros.
fn Draw::chunk_size(self : Draw, size : Int32) -> String {
  let zeros = if self.chance(20) { "0" } else { "" }
  zeros + self.mixed_case(size.to_string(radix=16))
}

///|
/// The body as it goes on the wire after a head.
fn Draw::body_wire(self : Draw, body : GenBody) -> Bytes {
  match body {
    Absent => b""
    Sized(bytes) => bytes
    Chunks(chunks~, trailers~) => {
      let out = Buffer()
      for chunk in chunks {
        write_latin1(
          out,
          self.chunk_size(chunk.length()) + self.chunk_ext() + "\r\n",
        )
        out.write_bytes(chunk)
        out.write_bytes(b"\r\n")
      }
      write_latin1(out, self.chunk_size(0) + self.chunk_ext() + "\r\n")
      for field in trailers {
        self.field_line(out, field.0, field.1)
      }
      out.write_bytes(b"\r\n")
      out.to_bytes()
    }
  }
}

///|
/// The framing field for `body`, if it has one, with a mixed-case name.
fn Draw::framing_field(self : Draw, body : GenBody) -> (String, String)? {
  match body {
    Absent => None
    Sized(bytes) =>
      Some((self.mixed_case("content-length"), bytes.length().to_string()))
    Chunks(..) =>
      Some(
        (
          self.mixed_case("transfer-encoding"),
          self.pick(["chunked", "Chunked", "CHUNKED"]),
        ),
      )
  }
}

///|
/// Bytes after the message: nothing, a pipelined request or a few arbitrary
/// bytes.
fn Draw::suffix(self : Draw) -> Bytes {
  match self.below(4) {
    0 => b"GET /next HTTP/1.1\r\nHost: h\r\n\r\n"
    1 => self.bytes(1, 8)
    _ => b""
  }
}

///|
/// A generated request: its parts and the wire bytes that carry them.
#derive(Debug)
struct GenRequest {
  meth : @mttp_core.Method
  target : String
  version : @h1.Version
  /// Fields other than the framing field, in order, including Host.
  fields : Array[(String, String)]
  /// Every field of the head in wire order.
  head_fields : Array[(String, String)]
  body : GenBody
  /// The head as sent, without the empty lines before it.
  head : Bytes
  /// Empty lines, the head, the encoded body and the suffix.
  wire : Bytes
  suffix : Bytes
}

///|
/// Inserts `field` at a random position of `fields`.
fn Draw::insert(
  self : Draw,
  fields : Array[(String, String)],
  field : (String, String)?,
) -> Array[(String, String)] {
  let out = fields.copy()
  if field is Some(field) {
    out.insert(self.below(out.length() + 1), field)
  }
  out
}

///|
/// Requests with origin-form targets, at most six fields besides Host and
/// framing, empty lines before the request line and pipelined bytes after.
fn gen_request() -> @qc.Generator[GenRequest] {
  drawn(d => {
    let meth = d.request_method()
    let target = d.target()
    let version : @h1.Version = if d.chance(80) { Http11 } else { Http10 }
    let fields = d.fields(0, 6)
    let host = if version == Http11 || d.chance(50) {
      Some((d.mixed_case("host"), d.host()))
    } else {
      None
    }
    let fields = d.insert(fields, host)
    let body = d.body(chunked=version == Http11, absent=true)
    let head_fields = d.insert(fields, d.framing_field(body))
    let head = Buffer()
    write_latin1(head, "\{meth} \{target} \{d.version_text(version)}\r\n")
    for field in head_fields {
      d.field_line(head, field.0, field.1)
    }
    head.write_bytes(b"\r\n")
    let head = head.to_bytes()
    let suffix = d.suffix()
    let wire = Buffer()
    for _ in 0..<d.pick([0, 0, 0, 1, 2]) {
      wire.write_bytes(b"\r\n")
    }
    wire.write_bytes(head)
    wire.write_bytes(d.body_wire(body))
    wire.write_bytes(suffix)
    {
      meth,
      target,
      version,
      fields,
      head_fields,
      body,
      head,
      wire: wire.to_bytes(),
      suffix,
    }
  })
}

///|
/// The wire version: `HTTP/1.1` sometimes sent as a higher HTTP/1 minor
/// version, which the codec reads as `Http11` (RFC 9112, section 2.3).
fn Draw::version_text(self : Draw, version : @h1.Version) -> String {
  match version {
    Http10 => "HTTP/1.0"
    _ if self.chance(10) => "HTTP/1.\{self.range(2, 9)}"
    _ => "HTTP/1.1"
  }
}

///|
/// A generated response: its parts and the wire bytes that carry them.
#derive(Debug)
struct GenResponse {
  /// The method of the request it answers.
  meth : @mttp_core.Method
  version : @h1.Version
  status : Int32
  /// The reason phrase after the status code; `None` omits the space too.
  reason : String?
  /// Fields other than the framing field, in order.
  fields : Array[(String, String)]
  head_fields : Array[(String, String)]
  body : GenBody
  /// Whether a writer should frame an `Absent` body by closing.
  close : Bool
  head : Bytes
  /// The encoded body as sent, read or left over depending on the status.
  body_wire : Bytes
  wire : Bytes
  suffix : Bytes
}

///|
/// Responses with every status from 100 to 599, reason phrases of any
/// field characters (empty, absent, with leading or trailing whitespace),
/// up to six fields and any framing the version allows.
fn gen_response() -> @qc.Generator[GenResponse] {
  drawn(d => {
    let meth : @mttp_core.Method = d.pick([Get, Get, Post, Head, Connect])
    let version : @h1.Version = if d.chance(80) { Http11 } else { Http10 }
    let status = if d.chance(50) {
      d.pick([100, 101, 200, 201, 204, 206, 301, 304, 404, 500, 503])
    } else {
      d.range(100, 599)
    }
    let reason = match d.below(4) {
      0 => None
      1 => Some("")
      _ => {
        let out = StringBuilder()
        for _ in 0..<d.range(1, 20) {
          out.write_char(d.field_char(whitespace=true))
        }
        Some(out.to_string())
      }
    }
    let fields = d.fields(0, 6)
    let body = d.body(chunked=version == Http11, absent=true)
    let head_fields = d.insert(fields, d.framing_field(body))
    let head = Buffer()
    let reason_text = match reason {
      None => ""
      Some(text) => " " + text
    }
    write_latin1(head, "\{d.version_text(version)} \{status}\{reason_text}\r\n")
    for field in head_fields {
      d.field_line(head, field.0, field.1)
    }
    head.write_bytes(b"\r\n")
    let head = head.to_bytes()
    let body_wire = d.body_wire(body)
    let suffix = d.suffix()
    {
      meth,
      version,
      status,
      reason,
      fields,
      head_fields,
      body,
      close: d.chance(50),
      head,
      body_wire,
      wire: concat([head, body_wire, suffix]),
      suffix,
    }
  })
}

///|
/// Whether a response to `meth` with `status` never has a body (RFC 9112,
/// section 6.3), restated from the codec's documentation.
fn never_has_body(status : Int32, meth : @mttp_core.Method) -> Bool {
  meth == Head ||
  status / 100 == 1 ||
  status == 204 ||
  status == 304 ||
  (meth == Connect && status / 100 == 2)
}

///|
/// Whether the writer refuses body framing for `status` to `meth`.
fn refuses_body_framing(status : Int32, meth : @mttp_core.Method) -> Bool {
  status / 100 == 1 || status == 204 || (meth == Connect && status / 100 == 2)
}

///|
/// Damages `wire` one to three times: flips bits of a byte, inserts or
/// deletes a byte, duplicates a line, or turns a CRLF into a bare LF.
fn Draw::mutate(self : Draw, wire : Bytes) -> Bytes {
  let bytes = wire.to_array()
  for _ in 0..<self.range(1, 3) {
    match self.below(5) {
      0 if !bytes.is_empty() => {
        let at = self.below(bytes.length())
        bytes[at] = bytes[at] ^ self.range(1, 255).to_byte()
      }
      1 =>
        bytes.insert(
          self.below(bytes.length() + 1),
          self.pick([
            b'\r', b'\n', b' ', b'\t', b':', b';', b'0', b'\x00', b'\xff',
          ]),
        )
      2 if !bytes.is_empty() =>
        bytes.remove(self.below(bytes.length())) |> ignore
      3 => {
        let starts = [0]
        for i in 1..<bytes.length() {
          if bytes[i - 1] == b'\n' {
            starts.push(i)
          }
        }
        let start = self.pick(starts[:])
        let mut end = start
        while end < bytes.length() && bytes[end] != b'\n' {
          end += 1
        }
        let line = bytes[start:(end + 1).min(bytes.length())].to_owned()
        for i, byte in line {
          bytes.insert(start + i, byte)
        }
      }
      _ => {
        let crlfs = []
        for i in 1..<bytes.length() {
          if bytes[i - 1] == b'\r' && bytes[i] == b'\n' {
            crlfs.push(i - 1)
          }
        }
        if !crlfs.is_empty() {
          bytes.remove(self.pick(crlfs[:])) |> ignore
        }
      }
    }
  }
  Bytes::from_array(bytes)
}

///|
/// Start lines, field lines and body pieces of HTTP/1.1 put together in
/// random order and number, sometimes with arbitrary bytes between them: a
/// byte string that parses now and then, including heads that frame a body
/// ambiguously or with a coding the codec does not implement.
fn Draw::soup(self : Draw) -> Bytes {
  let starts : Array[Bytes] = [
    b"GET / HTTP/1.1\r\n", b"POST /a HTTP/1.1\r\n", b"PUT /a?b HTTP/1.0\r\n", b"HTTP/1.1 200 OK\r\n",
    b"HTTP/1.0 204\r\n", b"HTTP/1.1 100 Continue\r\n", b"HTTP/1.1 304 \r\n", b"HTTP/2.0 200\r\n",
  ]
  let fields : Array[Bytes] = [
    b"Host: h\r\n", b"Host: h\r\n", b"Content-Length: 3\r\n", b"Content-Length: 0\r\n",
    b"Transfer-Encoding: chunked\r\n", b"Transfer-Encoding: gzip, chunked\r\n", b"Transfer-Encoding: chunked, chunked\r\n",
    b"X: y\r\n", b"Connection: close\r\n", b" folded\r\n",
  ]
  let body : Array[Bytes] = [
    b"3\r\nabc\r\n", b"0\r\n", b"\r\n", b"5;a=\"b\"\r\n", b"X-T: 1\r\n", b"abc",
    b"GET / HTTP/1.1\r\n",
  ]
  let out = Buffer()
  let noise = () => if self.chance(7) { out.write_bytes(self.bytes(1, 4)) }
  if self.chance(85) {
    out.write_bytes(self.pick(starts[:]))
  }
  for _ in 0..<self.range(0, 5) {
    noise()
    out.write_bytes(self.pick(fields[:]))
  }
  if self.chance(85) {
    out.write_bytes(b"\r\n")
  }
  for _ in 0..<self.range(0, 5) {
    noise()
    out.write_bytes(self.pick(body[:]))
  }
  out.to_bytes()
}

///|
/// Default limits, or small ones (occasionally negative) so the limit paths
/// are reached by short inputs.
fn Draw::limits(self : Draw) -> @h1.Limits {
  if self.chance(75) {
    return @h1.Limits::default()
  }
  let bound = (lo : Int32, hi : Int32) => {
    if self.chance(3) {
      -1
    } else {
      self.range(lo, hi)
    }
  }
  {
    max_head_bytes: bound(16, 256),
    max_chunk_line_bytes: bound(1, 32),
    max_trailer_bytes: bound(2, 96),
    max_headers: bound(0, 6),
  }
}

///|
/// Bytes for the totality properties: a damaged valid request or response,
/// or syntax soup.
fn gen_hostile() -> @qc.Generator[Bytes] {
  let requests = gen_request()
  let responses = gen_response()
  @qc.Generator((size, state) => {
    let d : Draw = { state, }
    match d.below(3) {
      0 => d.mutate(requests.run(size, state).wire)
      1 => d.mutate(responses.run(size, state).wire)
      _ => d.soup()
    }
  })
}
