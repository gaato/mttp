///|
/// The tests' `secure`: TLS unless a trusted proxy says otherwise.
fn secure(request : @mttp_core.Request) -> Bool {
  request.headers.get("x-forwarded-proto") != Some("http")
}

///|
/// A response of `body` with a known length, as a handler returns it.
fn page(body : Bytes) -> @mttp_core.Response {
  @mttp_core.Response::new(
    200,
    headers=@mttp_core.Headers::of([
      ("content-type", "text/javascript"),
      ("etag", "\"v2\""),
    ]),
    body=Bytes(body),
  )
}

///|
async fn body_of(response : @mttp_core.Response) -> Bytes {
  match response.body {
    Stream(s) => @mttp_core.read_bounded(s.take(), 1 << 22)
    other => other.as_bytes().unwrap_or(b"")
  }
}

///|
test "dictionary_compress codes with the dictionary the request names" {
  @driver.run_sync(() => {
    let content = vector_dictionary()
    let server = @codings.ServerDictionary::new(content, sha256~, id="v1")
    let (_, client) = stored(content)
    let handler = @codings.dictionary_compress(
      secure~,
      _ => page(vector_input()),
      [@codings.ServerDictionary::new(b"another", sha256~), server],
    )
    let request = (accept : String, hash : Bytes?) => {
      let headers = @mttp_core.Headers::of([("accept-encoding", accept)])
      let headers = match hash {
        Some(h) =>
          headers.set(
            "available-dictionary",
            @sf.serialize_bare_item(Bytes(h)).unwrap(),
          )
        None => headers
      }
      {
        ..@mttp_core.Request::get("https://example.test/app/main.js"),
        headers,
      }
    }
    for accept in ["gzip, br, zstd, dcb, dcz", "dcb"] {
      let response = handler(request(accept, Some(server.hash)))
      let coding : @codings.Coding = if accept == "dcb" { Dcb } else { Dcz }
      assert_eq(response.headers.get("content-encoding"), Some(coding.name()))
      // The section 9.3.3 check decided the coding: a cache keys on what
      // it read as well.
      assert_eq(response.headers.get_all("vary"), [
        "Accept-Encoding", "Available-Dictionary", "Sec-Fetch-Site", "Sec-Fetch-Mode",
        "Origin",
      ])
      assert_eq(response.headers.get("content-length"), None)
      assert_eq(response.headers.get("etag"), Some("W/\"v2\""))
      let wire = body_of(response)
      assert_eq(
        decode_in_pieces([coding], Some(client), wire, 11),
        vector_input(),
      )
    }
    // An unknown hash, or no dcb/dcz accepted: compressed as compress does,
    // and still marked as varying on Available-Dictionary.
    let unknown = handler(request("gzip, dcz", Some(sha256(b"unknown"))))
    assert_eq(unknown.headers.get("content-encoding"), Some("gzip"))
    assert_eq(unknown.headers.get_all("vary"), [
      "Accept-Encoding", "Available-Dictionary",
    ])
    let plain = handler(request("br", Some(server.hash)))
    assert_eq(plain.headers.get("content-encoding"), Some("br"))
    // A plain coding or identity weighed above the dictionary coding wins.
    let weighed = handler(request("gzip;q=1, dcz;q=0.1", Some(server.hash)))
    assert_eq(weighed.headers.get("content-encoding"), Some("gzip"))
    let identity = handler(
      request("identity;q=1, dcz;q=0.1", Some(server.hash)),
    )
    assert_eq(identity.headers.get("content-encoding"), None)
    let tie = handler(request("gzip, dcz", Some(server.hash)))
    assert_eq(tie.headers.get("content-encoding"), Some("dcz"))
    // Not over a secure context: plain http to a host that is not loopback.
    // Not over TLS, as `secure` tells: no dictionary coding, whatever the
    // URL the client wrote.
    let cleartext = handler({
      ..request("dcz", Some(server.hash)),
      headers: request("dcz", Some(server.hash)).headers.set(
        "x-forwarded-proto", "http",
      ),
    })
    assert_eq(cleartext.headers.get("content-encoding"), None)
    // Identity refused and no dictionary: 406, still varying on it.
    let refused = handler(
      request("dcz, identity;q=0", Some(sha256(b"unknown"))),
    )
    assert_eq(refused.status, 406)
    assert_eq(refused.headers.get_all("vary"), [
      "Accept-Encoding", "Available-Dictionary",
    ])
    // A small body stays as it is.
    let small = @codings.dictionary_compress(
      _ => page(b"tiny"),
      [server],
      secure~,
    )(request("dcz", Some(server.hash)))
    assert_eq(small.headers.get("content-encoding"), None)
    assert_eq(body_of(small), b"tiny")
  })
}

///|
test "dictionary_compress keeps a cross-origin response it may not code readable only through CORS" {
  @driver.run_sync(() => {
    let content = vector_dictionary()
    let server = @codings.ServerDictionary::new(content, sha256~)
    let handler = @codings.dictionary_compress(
      secure~,
      _ => page(vector_input()),
      [server],
    )
    let headers = @mttp_core.Headers::of([
      ("accept-encoding", "dcz, gzip"),
      (
        "available-dictionary",
        @sf.serialize_bare_item(Bytes(server.hash)).unwrap(),
      ),
      ("sec-fetch-site", "cross-site"),
      ("sec-fetch-mode", "no-cors"),
    ])
    let response = handler({
      ..@mttp_core.Request::get("https://example.test/app/main.js"),
      headers,
    })
    assert_eq(response.headers.get("content-encoding"), Some("gzip"))
    // HEAD, a range and a malformed Accept-Encoding are left to compress.
    let head = handler({
      ..@mttp_core.Request::new(Head, "https://example.test/app/main.js"),
      headers: headers.remove("sec-fetch-site"),
    })
    assert_eq(head.headers.get("content-encoding"), None)
    // Available-Dictionary that is not a Byte Sequence names nothing.
    let not_bytes = handler({
      ..@mttp_core.Request::get("https://example.test/app/main.js"),
      headers: headers
      .remove("sec-fetch-site")
      .set("available-dictionary", "\"not bytes\""),
    })
    assert_eq(not_bytes.headers.get("content-encoding"), Some("gzip"))
    // Malformed elsewhere in Accept-Encoding: refused as compress refuses it.
    let malformed = handler({
      ..@mttp_core.Request::get("https://example.test/app/main.js"),
      headers: headers
      .remove("sec-fetch-site")
      .set("accept-encoding", "dcz, gzip;q=2"),
    })
    assert_eq(malformed.status, 400)
    // encode_body cannot write dcb or dcz without the dictionary.
    let missing = try {
      @codings.encode_body(Bytes(b"x"), Dcz) |> ignore
      None
    } catch {
      @mttp_core.TransportError(kind~, ..) => Some(kind)
    }
    assert_eq(missing, Some(Invalid))
    let bad = handler({
      ..@mttp_core.Request::get("https://example.test/app/main.js"),
      headers: headers
      .remove("sec-fetch-site")
      .set("accept-encoding", "dcz;q=2"),
    })
    assert_eq(bad.status, 400)
  })
}

///|
test "use_as_dictionary marks a response, and a client stores it and uses it" {
  @driver.run_sync(() => {
    let content = vector_dictionary()
    let server = @codings.ServerDictionary::new(content, sha256~, id="v1")
    let app : @mttp_core.Handler = request => {
      if request.url.has_suffix("/dict.js") {
        let marked = @codings.use_as_dictionary(
          {
            ..page(content),
            headers: page(content).headers.set("cache-control", "max-age=3600"),
          },
          match_="/app/*",
          id="v1",
        ) catch {
          _ => @mttp_core.Response::new(500)
        }
        marked
      } else {
        page(vector_input())
      }
    }
    let served = @codings.dictionary_compress(app, [server], secure~)
    let inner = HandlerBackend::{ handler: served, last_coding: Ref(None), }
    let store = @dictionary.DictionaryStore::new(
      sha256~,
      clock=@sim.FakeClock::new(start_unix_ms=1_000_000L),
    )
    let client = @codings.Decompress::new(inner, dictionaries=store)
    let options = @mttp_core.SendOptions::default()
    let first = client.send(
      @mttp_core.Request::get("https://example.test/app/dict.js"),
      options,
    )
    assert_eq(
      first.headers.get("use-as-dictionary"),
      Some("match=\"/app/*\", id=\"v1\""),
    )
    assert_eq(body_of(first), content)
    assert_eq(store.size().0, 1)
    let second = client.send(
      @mttp_core.Request::get("https://example.test/app/main.js"),
      options,
    )
    assert_eq(body_of(second), vector_input())
    assert_eq(inner.last_coding.val, Some("dcz"))
    // A match a Structured Field cannot carry raises Invalid.
    let refused = try {
      @codings.use_as_dictionary(page(b""), match_="/é") |> ignore
      None
    } catch {
      @mttp_core.TransportError(kind~, ..) => Some(kind)
    }
    assert_eq(refused, Some(Invalid))
  })
}

///|
/// A backend that answers with a handler, as a server would, and notes the
/// coding of the last response.
priv struct HandlerBackend {
  handler : @mttp_core.Handler
  last_coding : Ref[String?]
}

///|
impl @mttp_core.Backend for HandlerBackend with fn send(self, request, _) {
  let response = (self.handler)(request)
  self.last_coding.val = response.headers.get("content-encoding")
  response
}

///|
impl @mttp_core.Backend for HandlerBackend with fn close(_) {
  ()
}
