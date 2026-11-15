// The reading of an input by mttp's codec, in the line format the vectors
// use (scripts/gen_vectors.mbtx, "the outcome model"), and the vector
// blocks themselves.

///|
/// Which end reads the input: a server reads requests, a client responses.
enum Side {
  Request
  Response
}

///|
/// One vector block of a generated table.
struct Vector {
  id : String
  side : Side
  wire : Bytes
  expect : Array[String]
  upstream : Array[String]
  reason : String
}

///|
/// The vectors of a generated table: blocks that start at `case`.
fn vectors(table : String) -> Array[Vector] raise {
  let out = []
  let mut block : Map[String, Array[String]] = Map([])
  fn close() raise {
    guard block.get("case") is Some([id]) else { return }
    let side = match block.get("side") {
      Some(["request"]) => Request
      Some(["response"]) => Response
      _ => fail("\{id}: no side")
    }
    guard block.get("wire") is Some([wire]) else { fail("\{id}: no wire") }
    out.push({
      id,
      side,
      wire: unescape(wire),
      expect: block.get("expect").unwrap_or([]),
      upstream: block.get("upstream").unwrap_or([]),
      reason: block.get("reason").unwrap_or([]).join(" "),
    })
  }
  for line in table.split("\n") {
    guard line.split_once(" ") is Some((key, value)) else { continue }
    let key = key.to_owned()
    if key == "case" {
      close()
      block = Map([])
    }
    match block.get(key) {
      Some(values) => values.push(value.to_owned())
      None => block[key] = [value.to_owned()]
    }
  }
  close()
  out
}

///|
/// The bytes a vector line spells with `\\`, `\r`, `\n`, `\t` and `\xHH`.
fn unescape(text : StringView) -> Bytes raise {
  let out = Buffer()
  let mut i = 0
  while i < text.length() {
    let c = text.get_char(i).unwrap()
    if c != '\\' {
      out.write_byte(c.to_int().to_byte())
      i += 1
      continue
    }
    match text.get_char(i + 1) {
      Some('\\') => out.write_byte(b'\\')
      Some('r') => out.write_byte(b'\r')
      Some('n') => out.write_byte(b'\n')
      Some('t') => out.write_byte(b'\t')
      Some('x') => {
        let hex = text[i + 2:i + 4].to_owned()
        out.write_byte(@string.parse_int(hex, base=16).to_byte())
        i += 2
      }
      _ => fail("bad escape in \{text}")
    }
    i += 2
  }
  out.to_bytes()
}

///|
/// `text` (code points 0 to 255, one per byte) escaped as vector lines are.
fn esc(text : String) -> String {
  let out = StringBuilder()
  for c in text {
    let code = c.to_int()
    match c {
      '\\' => out.write_string("\\\\")
      '\r' => out.write_string("\\r")
      '\n' => out.write_string("\\n")
      '\t' => out.write_string("\\t")
      _ if code < 0x20 || code >= 0x7f => {
        let hex = "0123456789abcdef"
        out.write_string("\\x")
        out.write_char(hex.get_char(code / 16 % 16).unwrap())
        out.write_char(hex.get_char(code % 16).unwrap())
      }
      _ => out.write_char(c)
    }
  }
  out.to_string()
}

///|
fn esc_bytes(bytes : BytesView) -> String {
  let out = StringBuilder()
  for byte in bytes {
    out.write_char(byte.to_int().unsafe_to_char())
  }
  esc(out.to_string())
}

///|
fn kind_name(kind : @h1.ParseKind) -> String {
  match kind {
    HeadTooLarge => "HeadTooLarge"
    Malformed => "Malformed"
    Smuggling => "Smuggling"
    Unsupported => "Unsupported"
    @h1.ParseKind::.. => "unknown"
  }
}

///|
fn version_name(version : @h1.Version) -> String {
  match version {
    Http10 => "1.0"
    Http11 => "1.1"
    @h1.Version::.. => "unknown"
  }
}

///|
/// Whether a field's comma-separated elements include `token`.
fn has_token(
  headers : @mttp_core.Headers,
  name : String,
  token : String,
) -> Bool {
  headers
  .get_all(name)
  .iter()
  .any(value => {
    value
    .split(",")
    .any(element => element.trim(chars=" \t").to_owned().to_lower() == token)
  })
}

///|
/// How reading one message ended.
enum Step {
  Next(Array[BytesView])
  Stop
  Refused(@h1.ParseKind)
}

///|
fn only_crlf(pieces : Array[BytesView]) -> Bool {
  let bytes = Buffer()
  for piece in pieces {
    bytes.write_bytesview(piece)
  }
  let bytes = bytes.to_bytes()
  for i = 0; i < bytes.length(); i = i + 2 {
    if !bytes[i:].has_prefix(b"\r\n") {
      return false
    }
  }
  true
}

///|
/// Reads one message from `pieces` as the engines do, keeping the piece
/// boundaries: the head through `HeadDecoder`, the framing from
/// `request_framing` or `response_framing` (for a GET), the body by length,
/// through `ChunkedDecoder` or to the end. The input ending is not a close:
/// a body still open is `incomplete`. After a CONNECT request, a request
/// asking to upgrade, or a 101 response, the bytes that follow are not HTTP
/// (`handoff`); after `Connection: close`, or an HTTP/1.0 message without
/// keep-alive, the engines close the connection, so bytes left are `closed`.
fn read_one(
  side : Side,
  pieces : Array[BytesView],
  out : Array[String],
) -> Step raise {
  let limits = @h1.Limits::default()
  let decoder = @h1.HeadDecoder::new(
    max=limits.max_head_bytes,
    skip_leading_crlf=side is Request,
  )
  let after : Array[BytesView] = []
  let mut head = None
  for piece in pieces {
    if head is None {
      let result = decoder.feed(piece)
      if result.head is Some(bytes) {
        head = Some(bytes)
        after.push(piece[result.consumed:])
      }
    } else {
      after.push(piece)
    }
  }
  guard head is Some(head) else {
    out.push("incomplete")
    return Stop
  }
  let (headers, framing, handoff, http10) = match side {
    Request => {
      let request = @h1.parse_request_head(head, limits~)
      out.push(
        "request \{request.meth} \{esc(request.target)} \{version_name(request.version)}",
      )
      (
        request.headers,
        @h1.request_framing(request.headers),
        request.meth is Connect ||
        (
          request.headers.contains("upgrade") &&
          has_token(request.headers, "connection", "upgrade")
        ),
        request.version is Http10,
      )
    }
    Response => {
      let response = @h1.parse_response_head(head, limits~)
      out.push("response \{response.status} \{version_name(response.version)}")
      (
        response.headers,
        @h1.response_framing(response.headers, status=response.status),
        response.status == 101,
        response.version is Http10,
      )
    }
  }
  for field in headers.iter() {
    out.push("header \{field.0.to_lower()}: \{esc(field.1)}")
  }
  let body = Buffer()
  let rest : Array[BytesView] = []
  let mut trailers = @mttp_core.Headers::empty()
  let complete = match framing {
    NoBody => {
      rest.append(after)
      true
    }
    Length(n) => {
      for piece in after {
        let take = (n - body.length().to_int64())
          .min(piece.length().to_int64())
          .to_int()
        body.write_bytesview(piece[:take])
        rest.push(piece[take:])
      }
      body.length().to_int64() == n
    }
    Chunked => {
      let chunked = @h1.ChunkedDecoder::new(limits)
      let mut done = false
      for piece in after {
        if done {
          rest.push(piece)
          continue
        }
        let result = chunked.feed(piece)
        for chunk in result.chunks {
          body.write_bytes(chunk)
        }
        if result.done {
          done = true
          trailers = result.trailers
          rest.push(piece[result.consumed:])
        }
      }
      done
    }
    UntilClose => {
      after.each(piece => body.write_bytesview(piece))
      false
    }
    @h1.Framing::.. => fail("unknown framing \{Repr(framing)}")
  }
  if body.length() > 0 {
    out.push("body \{esc_bytes(body.to_bytes())}")
  }
  guard complete else {
    out.push("incomplete")
    return Stop
  }
  for field in trailers.iter() {
    out.push("trailer \{field.0.to_lower()}: \{esc(field.1)}")
  }
  out.push("complete")
  let remaining = rest.fold(init=0, (n, piece) => n + piece.length())
  if handoff {
    out.push("handoff")
    Stop
  } else if has_token(headers, "connection", "close") ||
    (http10 && !has_token(headers, "connection", "keep-alive")) {
    if remaining > 0 {
      out.push("closed")
    }
    Stop
  } else {
    Next(rest)
  }
}

///|
/// What mttp's codec reads from `pieces`, one line per fact.
fn reading(side : Side, pieces : Array[Bytes]) -> String raise {
  let out = []
  let mut rest = pieces.map(piece => piece[:])
  for ;; {
    let left = rest.fold(init=0, (n, piece) => n + piece.length())
    if left == 0 || (side is Request && only_crlf(rest)) {
      break
    }
    let mark = out.length()
    let step = read_one(side, rest, out) catch {
      @h1.ParseError(kind~, ..) => Refused(kind)
      error => raise error
    }
    match step {
      Next(next) => rest = next
      Stop => break
      Refused(kind) => {
        out.truncate(mark)
        out.push("refused \{kind_name(kind)}")
        break
      }
    }
  }
  out.join("\n")
}

///|
/// The reading of `vector`, the same whole, split in two at every offset,
/// one byte at a time and cut after every CR and non-ASCII byte.
fn check(vector : Vector) -> String raise {
  let wire = vector.wire
  let whole = reading(vector.side, [wire])
  for cut in 0..<=wire.length() {
    let pieces = [wire[:cut].to_owned(), wire[cut:].to_owned()]
    assert_eq(
      reading(vector.side, pieces),
      whole,
      msg="\{vector.id}: cut at \{cut}",
    )
  }
  assert_eq(
    reading(vector.side, @harness.single_bytes(wire)),
    whole,
    msg="\{vector.id}: byte by byte",
  )
  assert_eq(
    reading(vector.side, @harness.hostile_chunks(wire)),
    whole,
    msg="\{vector.id}: cut after every CR",
  )
  whole
}

///|
/// Checks every case and every documented difference of a table pair and
/// returns how many there were. A case must read as expected; a difference
/// must read as mttp's documented answer and not as the source's, so one
/// that stops differing is noticed.
fn check_tables(cases : String, differences : String) -> (Int32, Int32) raise {
  let failures = []
  let cases = vectors(cases)
  for vector in cases {
    let got = check(vector)
    if got != vector.expect.join("\n") {
      failures.push(mismatch(vector.id, vector.expect.join("\n"), got))
    }
  }
  let differences = vectors(differences)
  for vector in differences {
    let got = check(vector)
    if got != vector.expect.join("\n") {
      failures.push(
        mismatch("\{vector.id} (difference)", vector.expect.join("\n"), got),
      )
    } else if got == vector.upstream.join("\n") {
      failures.push("\{vector.id}: no longer differs")
    } else if vector.reason == "" {
      failures.push("\{vector.id}: a difference without a reason")
    }
  }
  if !failures.is_empty() {
    fail("\{failures.length()} vectors:\n" + failures.join("\n"))
  }
  (cases.length(), differences.length())
}

///|
fn mismatch(id : String, expected : String, got : String) -> String {
  let indent = (text : String) => text.replace_all(old="\n", new="\n    ")
  "\{id}\n  expected\n    \{indent(expected)}\n  got\n    \{indent(got)}"
}

///|
/// The skip counts of a table: `<count> <reason>` lines.
fn skipped(table : String) -> Array[String] {
  table
  .split("\n")
  .filter(line => line != "")
  .map(line => line.to_owned())
  .collect()
}
