// RFC 9842's dcb and dcz: decoding what the reference tools write, round
// trips through ContentEncoder, the header checks, and Decompress's client
// side with a dictionary store.

///|
/// The vectors' dictionary and the response they encode: brotli 1.2.1
/// `-q 5 -w 16 -D` and zstd 1.5.7 `-3 -D` wrote them, behind RFC 9842's
/// headers with the dictionary's real SHA-256.
fn vector_dictionary() -> Bytes {
  @utf8.encode(
    String::make(1, ' ').repeat(0) +
    "function render(items){return items.map(i=>`<li class=\"item\">${i.name}</li>`).join(\"\");}\n".repeat(
      20,
    ),
  )
}

///|
fn vector_input() -> Bytes {
  @utf8.encode(
    "function render(items){return items.map(i=>`<li class=\"item\">${i.title}</li>`).join(\"\");}\n".repeat(
      20,
    ) +
    "export default render;\n",
  )
}

///|
let vector_hash : String = "n60Ps/2Nj2L7hUkrdszv3Oo3fojgW5qgtprz+D1Aj64="

///|
let vector_dcb : String = "/0RDQp+tD7P9jY9i+4VJK3bM79zqN36I4FuaoLaa8/g9QI+uwuMAgDjlPKHEM45r7XDYgAOXBpl84EV1Ghxy84O8NKor52Bnr/ZPJP3NjktQGRYA"

///|
let vector_dcz : String = "XipNGCAAAACfrQ+z/Y2PYvuFSSt2zO/c6jd+iOBbmqC2mvP4PUCPrii1L/1kHwYtAQCgdGl0bGV4cG9ydCBkZWZhdWx0OwoEAByATNXs8Adj+4lckwwQnKPFBQ=="

///|
fn b64(text : String) -> Bytes {
  @base64.decode(text) catch {
    _ => abort("bad test base64")
  }
}

///|
/// SHA-256 for the tests: the real hash of the vectors' dictionary, and a
/// stand-in that depends on every byte for anything else.
fn sha256(data : BytesView) -> Bytes {
  if data == vector_dictionary()[:] {
    return b64(vector_hash)
  }
  let out = FixedArray::make(32, b'\x00')
  let mut h = 2166136261U
  for i, b in data {
    h = (h ^ b.to_uint()) * 16777619U
    out[i % 32] = out[i % 32] ^ (h & 0xFFU).to_byte()
  }
  out[1] = out[1] ^ (data.length() & 0xFF).to_byte()
  Bytes::from_array(out)
}

///|
fn url(text : String) -> @mttp_core.Url {
  @mttp_core.Url::parse(text) catch {
    _ => abort("bad test URL")
  }
}

///|
/// A store holding `content` as the dictionary for https://example.test/app/*,
/// and that dictionary.
fn stored(
  content : Bytes,
) -> (@dictionary.DictionaryStore, @dictionary.Dictionary) {
  let store = @dictionary.DictionaryStore::new(
    sha256~,
    clock=@sim.FakeClock::new(start_unix_ms=1_000_000L),
  )
  let ok = store.offer(
    url("https://example.test/app/dict.js"),
    @mttp_core.Headers::of([
      ("use-as-dictionary", "match=\"/app/*\", id=\"v1\""),
      ("cache-control", "max-age=3600"),
    ]),
    content,
    request_time_ms=1_000_000L,
  )
  guard ok && store.select(url("https://example.test/app/x.js")) is Some(d) else {
    abort("dictionary not stored")
  }
  (store, d)
}

///|
/// Decodes `wire` fed in pieces of `piece` bytes.
fn decode_in_pieces(
  undo : Array[@codings.Coding],
  dictionary : @dictionary.Dictionary?,
  wire : Bytes,
  piece : Int32,
) -> Bytes raise @mttp_core.TransportError {
  let decoder = @codings.ContentDecoder::new(undo, dictionary?)
  let out = Buffer()
  let mut at = 0
  for ;; {
    match decoder.pull() {
      Slice(bytes) => out.write_bytes(bytes)
      NeedInput =>
        if at < wire.length() {
          let end = (at + piece).min(wire.length())
          decoder.feed(wire[at:end].to_owned())
          at = end
        } else {
          decoder.end()
        }
      Done => return out.to_bytes()
      @codings.Pulled::.. => abort("unexpected pull")
    }
  }
}

///|
fn encode_with(
  coding : @codings.Coding,
  dictionary : @codings.ServerDictionary?,
  input : Bytes,
) -> Bytes raise @mttp_core.TransportError {
  let encoder = @codings.ContentEncoder::new(coding, dictionary?)
  let out = Buffer()
  let mut fed = false
  for ;; {
    match encoder.pull() {
      Slice(bytes) => out.write_bytes(bytes)
      NeedInput =>
        if fed {
          encoder.end()
        } else {
          encoder.feed(input)
          fed = true
        }
      Done => return out.to_bytes()
      @codings.Pulled::.. => abort("unexpected pull")
    }
  }
}

///|
test "dcb and dcz from brotli -D and zstd -D decode, in any pieces" {
  let (_, d) = stored(vector_dictionary())
  assert_eq(d.hash, b64(vector_hash))
  for piece in [1, 7, 4096] {
    assert_eq(
      decode_in_pieces([Dcb], Some(d), b64(vector_dcb), piece),
      vector_input(),
    )
    assert_eq(
      decode_in_pieces([Dcz], Some(d), b64(vector_dcz), piece),
      vector_input(),
    )
  }
}

///|
test "ContentEncoder writes dcb and dcz the decoder reads back" {
  let content = vector_dictionary()
  let (_, d) = stored(content)
  let server = @codings.ServerDictionary::new(content, sha256~, id="v1")
  assert_eq(server.hash, d.hash)
  let input = vector_input() + vector_input()
  for coding in [@codings.Coding::Dcb, Dcz] {
    let wire = encode_with(coding, Some(server), input)
    // The header comes first: magic number, then the dictionary's hash.
    assert_eq(
      wire[if coding is Dcb {
        4
      } else {
        8
      }:if coding is Dcb {
        36
      } else {
        40
      }].to_owned(),
      d.hash,
    )
    // With the dictionary the body is far smaller than without it.
    assert_true(
      wire.length() <
      encode_with(if coding is Dcb { Brotli } else { Zstd }, None, input).length(),
    )
    assert_eq(decode_in_pieces([coding], Some(d), wire, 3), input)
  }
}

///|
test "a dcb or dcz header that does not name the offered dictionary is refused" {
  let (_, d) = stored(vector_dictionary())
  let (_, other) = stored(b"another dictionary entirely")
  let refused = (
    undo : Array[@codings.Coding],
    dict : @dictionary.Dictionary?,
    wire : Bytes,
  ) => {
    try {
      decode_in_pieces(undo, dict, wire, 5) |> ignore
      None
    } catch {
      @mttp_core.TransportError(kind~, ..) => Some(kind)
    }
  }
  assert_eq(refused([Dcb], Some(other), b64(vector_dcb)), Some(Protocol))
  assert_eq(refused([Dcz], Some(other), b64(vector_dcz)), Some(Protocol))
  // A wrong magic number, a header cut short, an empty body.
  let wrong = b64(vector_dcz)
  assert_eq(refused([Dcb], Some(d), wrong), Some(Protocol))
  assert_eq(
    refused([Dcz], Some(d), b64(vector_dcz)[:20].to_owned()),
    Some(Protocol),
  )
  // RFC 9842 requires the header: an empty body is cut short.
  assert_eq(refused([Dcz], Some(d), b""), Some(Protocol))
  assert_eq(refused([Dcb], Some(d), b""), Some(Protocol))
  // The header alone, with no stream after it, is cut short too.
  assert_eq(
    refused([Dcz], Some(d), b64(vector_dcz)[:40].to_owned()),
    Some(Protocol),
  )
  // No dictionary offered: the coding cannot be undone.
  assert_eq(refused([Dcb], None, b64(vector_dcb)), Some(Protocol))
  // Without a dictionary an encoder cannot write dcb or dcz.
  let invalid = try {
    encode_with(Dcz, None, b"x") |> ignore
    None
  } catch {
    @mttp_core.TransportError(kind~, ..) => Some(kind)
  }
  assert_eq(invalid, Some(Invalid))
}

///|
test "dcb and dcz are accepted only when a dictionary is offered" {
  assert_eq(@codings.accept_encoding(), "gzip, deflate, br, zstd")
  assert_eq(
    @codings.accept_encoding(dictionary=true),
    "gzip, deflate, br, zstd, dcb, dcz",
  )
}

///|
priv struct DictionaryFixture {
  responses : Array[@mttp_core.Response]
  sent : Array[@mttp_core.Request]
}

///|
impl @mttp_core.Backend for DictionaryFixture with fn send(self, request, _) {
  self.sent.push(request)
  self.responses.remove(0)
}

///|
impl @mttp_core.Backend for DictionaryFixture with fn close(_) {
  ()
}

///|
test "Decompress advertises a matching dictionary and decodes dcz with it" {
  @driver.run_sync(() => {
    let (store, d) = stored(vector_dictionary())
    let inner = DictionaryFixture::{
      responses: [
        @mttp_core.Response::new(
          200,
          headers=@mttp_core.Headers::of([("content-encoding", "dcz")]),
          body=Bytes(b64(vector_dcz)),
        ),
        @mttp_core.Response::new(200, body=Bytes(b"plain")),
        @mttp_core.Response::new(200, body=Bytes(b"plain")),
      ],
      sent: [],
    }
    let backend = @codings.Decompress::new(inner, dictionaries=store)
    let options = @mttp_core.SendOptions::default()
    let response = backend.send(
      @mttp_core.Request::get("https://example.test/app/main.js"),
      options,
    )
    assert_eq(response.headers.get("content-encoding"), None)
    let body = match response.body {
      Stream(s) => @mttp_core.read_bounded(s.take(), 1 << 20)
      other => other.as_bytes().unwrap_or(b"")
    }
    assert_eq(body, vector_input())
    let sent = inner.sent[0].headers
    assert_eq(
      sent.get("accept-encoding"),
      Some("gzip, deflate, br, zstd, dcb, dcz"),
    )
    assert_eq(sent.get("available-dictionary"), Some(d.available_dictionary()))
    assert_eq(sent.get("dictionary-id"), Some("\"v1\""))
    // No dictionary for another path, nor over plain http: no dcb or dcz.
    backend
    .send(@mttp_core.Request::get("https://example.test/other"), options)
    .close()
    backend
    .send(@mttp_core.Request::get("http://example.test/app/x"), options)
    .close()
    for request in inner.sent[1:] {
      assert_eq(
        request.headers.get("accept-encoding"),
        Some("gzip, deflate, br, zstd"),
      )
      assert_eq(request.headers.get("available-dictionary"), None)
    }
  })
}

///|
test "Decompress stores a Use-As-Dictionary body once it is read to the end" {
  @driver.run_sync(() => {
    let clock = @sim.FakeClock::new(start_unix_ms=1_000_000L)
    let store = @dictionary.DictionaryStore::new(sha256~, clock~)
    let dictionary_response = (body : Bytes) => {
      @mttp_core.Response::new(
        200,
        headers=@mttp_core.Headers::of([
          ("use-as-dictionary", "match=\"/app/*\""),
          ("cache-control", "max-age=60"),
        ]),
        body=Bytes(body),
      )
    }
    let inner = DictionaryFixture::{
      responses: [dictionary_response(b"first"), dictionary_response(b"second")],
      sent: [],
    }
    let backend = @codings.Decompress::new(inner, dictionaries=store)
    let options = @mttp_core.SendOptions::default()
    // Closed before its end: not stored.
    backend
    .send(@mttp_core.Request::get("https://example.test/app/a.js"), options)
    .close()
    assert_eq(store.size().0, 0)
    let read = backend.send(
      @mttp_core.Request::get("https://example.test/app/b.js"),
      options,
    )
    match read.body {
      Stream(s) => @mttp_core.read_bounded(s.take(), 1 << 20) |> ignore
      _ => fail("expected a stream")
    }
    assert_eq(store.size().0, 1)
    // A body larger than the store keeps is not held, nor stored.
    let small = @dictionary.DictionaryStore::new(
      sha256~,
      clock~,
      max_dictionary_bytes=4,
    )
    let inner2 = DictionaryFixture::{
      responses: [dictionary_response(b"too large")],
      sent: [],
    }
    let backend2 = @codings.Decompress::new(inner2, dictionaries=small)
    let big = backend2.send(
      @mttp_core.Request::get("https://example.test/app/d.js"),
      options,
    )
    match big.body {
      Stream(s) =>
        assert_eq(@mttp_core.read_bounded(s.take(), 1 << 20), b"too large")
      _ => fail("expected a stream")
    }
    assert_eq(small.size().0, 0)
    assert_eq(
      store.select(url("https://example.test/app/c.js")).map(d => d.content),
      Some(b"second"),
    )
  })
}

///|
test "a collected body read past its end stays ended" {
  @driver.run_sync(() => {
    let clock = @sim.FakeClock::new(start_unix_ms=1_000_000L)
    let store = @dictionary.DictionaryStore::new(sha256~, clock~)
    let inner = DictionaryFixture::{
      responses: [
        @mttp_core.Response::new(
          200,
          headers=@mttp_core.Headers::of([
            ("use-as-dictionary", "match=\"/app/*\""),
            ("cache-control", "max-age=60"),
          ]),
          body=Bytes(b"whole"),
        ),
      ],
      sent: [],
    }
    let backend = @codings.Decompress::new(inner, dictionaries=store)
    let response = backend.send(
      @mttp_core.Request::get("https://example.test/app/a.js"),
      @mttp_core.SendOptions::default(),
    )
    guard response.body is Stream(s) else { fail("expected a stream") }
    let reader = s.take()
    assert_eq(reader.read_some(), Some(b"whole"))
    assert_eq(reader.read_some(), None)
    assert_eq(reader.read_some(), None)
    assert_eq(store.size().0, 1)
  })
}

///|
test "a deflate body whose first chunk is one byte decodes without joining chunks" {
  let input = vector_input() + vector_input()
  let wire = encode_with(Deflate, None, input)
  let decoder = @codings.ContentDecoder::new([Deflate])
  let out = Buffer()
  let pieces = [wire[:1].to_owned(), wire[1:].to_owned()]
  for ;; {
    match decoder.pull() {
      Slice(bytes) => out.write_bytes(bytes)
      NeedInput =>
        if pieces.is_empty() {
          decoder.end()
        } else {
          decoder.feed(pieces.remove(0))
        }
      Done => break
      @codings.Pulled::.. => fail("unexpected pull")
    }
  }
  assert_eq(out.to_bytes(), input)
}

///|
test "Content-Encoding names dcb and dcz" {
  assert_eq(@codings.coding_plan("dcb, dcz"), [Dcz, Dcb])
  assert_eq(@codings.Coding::Dcb.name(), "dcb")
}

///|
priv struct FailingBody {
  mut reads : Int32
}

///|
impl @mttp_core.BodyStream for FailingBody with fn read_some(self) {
  self.reads += 1
  if self.reads == 1 {
    Some(b"part")
  } else {
    raise @mttp_core.TransportError(kind=Network, phase=Body, detail="reset")
  }
}

///|
impl @mttp_core.BodyStream for FailingBody with fn close(_) {
  ()
}

///|
test "a dictionary without an id sends no Dictionary-ID; a failed body is not stored" {
  @driver.run_sync(() => {
    let clock = @sim.FakeClock::new(start_unix_ms=1_000_000L)
    let store = @dictionary.DictionaryStore::new(sha256~, clock~)
    let uad = @mttp_core.Headers::of([
      ("use-as-dictionary", "match=\"/app/*\""),
      ("cache-control", "max-age=60"),
    ])
    assert_true(
      store.offer(
        url("https://example.test/app/d.js"),
        uad,
        b"dict",
        request_time_ms=1_000_000L,
      ),
    )
    let inner = DictionaryFixture::{
      responses: [
        @mttp_core.Response::new(
          200,
          headers=uad,
          body=Stream(@mttp_core.StreamBody::new(FailingBody::{ reads: 0, })),
        ),
      ],
      sent: [],
    }
    let backend = @codings.Decompress::new(inner, dictionaries=store)
    let response = backend.send(
      @mttp_core.Request::get("https://example.test/app/e.js"),
      @mttp_core.SendOptions::default(),
    )
    assert_eq(inner.sent[0].headers.get("dictionary-id"), None)
    assert_true(inner.sent[0].headers.get("available-dictionary") is Some(_))
    guard response.body is Stream(s) else { fail("expected a stream") }
    let reader = s.take()
    assert_eq(reader.read_some(), Some(b"part"))
    let failed = try {
      reader.read_some() |> ignore
      false
    } catch {
      _ => true
    }
    assert_true(failed)
    // Closed by the failure: further reads end, and nothing new is stored.
    assert_eq(reader.read_some(), None)
    assert_eq(
      store.select(url("https://example.test/app/x.js")).map(d => d.content),
      Some(b"dict"),
    )
  })
}
