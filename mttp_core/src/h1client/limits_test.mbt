///|
/// `prefix`, then `a` repeated until the result is `total` bytes long with
/// `suffix` at the end.
fn padded(prefix : String, total : Int32, suffix : String) -> Bytes {
  @utf8.encode(
    prefix + "a".repeat(total - prefix.length() - suffix.length()) + suffix,
  )
}

///|
/// Fetches a response scripted as `wire` and returns its body as text, or
/// the kind and phase of the failure; the connection must be closed after
/// a failure and parked after success.
fn outcome(
  wire : Bytes,
  config~ : @h1client.ClientConfig = @h1client.ClientConfig::default(),
  options~ : @mttp_core.SendOptions = exchange(),
) -> Result[String, (@mttp_core.Kind, @mttp_core.Phase)] raise {
  let h = Harness::new(config~)
  let conn = h.scripted([Chunk(wire), Eof])
  let mut result : Result[String, (@mttp_core.Kind, @mttp_core.Phase)] = Err(
    (Invalid, Unknown),
  )
  h.run(() => {
    result = Ok(
      fetch(h.client, @mttp_core.Request::get("http://example.test/"), options~),
    ) catch {
      error => Err(kind_phase(error))
    }
    if result is Ok(_) {
      assert_eq(h.client.idle_connections(), 1)
    } else {
      assert_eq(conn.closes(), 1)
      assert_eq(h.client.idle_connections(), 0)
    }
    h.finish()
  })
  result
}

///|
test "response heads are read within the head byte and field limits" {
  let limit = @h1client.ClientConfig::default().head_limits.max_head_bytes
  assert_eq(limit, 16384)
  let head = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nX: "
  assert_eq(outcome(padded(head, limit, "\r\n\r\n") + b"ok"), Ok("ok"))
  assert_eq(
    outcome(padded(head, limit + 1, "\r\n\r\n") + b"ok"),
    Err((Protocol, Head)),
  )
  for count in [100, 101] {
    let fields = StringBuilder()
    fields.write_string("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n")
    for i in 1..<count {
      fields.write_string("X-\{i}: v\r\n")
    }
    let wire = @utf8.encode(fields.to_string() + "\r\nok")
    assert_eq(
      outcome(wire),
      if count == 100 {
        Ok("ok")
      } else {
        Err((Protocol, Head))
      },
    )
  }
  // A smaller configured limit applies to the response head too.
  let config = {
    ..@h1client.ClientConfig::default(),
    head_limits: { ..@h1.Limits::default(), max_head_bytes: 64, },
  }
  assert_eq(outcome(padded(head, 64, "\r\n\r\n") + b"ok", config~), Ok("ok"))
  assert_eq(
    outcome(padded(head, 65, "\r\n\r\n") + b"ok", config~),
    Err((Protocol, Head)),
  )
}

///|
test "chunk-size lines and trailers are read within their limits" {
  let limits = @h1client.ClientConfig::default().head_limits
  assert_eq(limits.max_chunk_line_bytes, 4096)
  assert_eq(limits.max_trailer_bytes, 16384)
  let head = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
  for total in [4096, 4097] {
    let wire = @utf8.encode(head) +
      padded("1;", total, "\r\n") +
      b"z\r\n0\r\n\r\n"
    assert_eq(
      outcome(wire),
      if total == 4096 {
        Ok("z")
      } else {
        Err((Protocol, Body))
      },
    )
  }
  for total in [16384, 16385] {
    let wire = @utf8.encode(head + "1\r\nz\r\n0\r\n") +
      padded("X: ", total, "\r\n\r\n")
    assert_eq(
      outcome(wire),
      if total == 16384 {
        Ok("z")
      } else {
        Err((Protocol, Body))
      },
    )
  }
  for count in [100, 101] {
    let trailers = StringBuilder()
    trailers.write_string(head + "1\r\nz\r\n0\r\n")
    for i in 0..<count {
      trailers.write_string("X-\{i}: v\r\n")
    }
    let wire = @utf8.encode(trailers.to_string() + "\r\n")
    assert_eq(
      outcome(wire),
      if count == 100 {
        Ok("z")
      } else {
        Err((Protocol, Body))
      },
    )
  }
}

///|
test "a buffered body admits max_bytes from the wire and refuses one more" {
  let length = (body : String) => {
    @utf8.encode(
      "HTTP/1.1 200 OK\r\nContent-Length: \{body.length()}\r\n\r\n\{body}",
    )
  }
  let chunked = (pieces : Array[String]) => {
    let wire = StringBuilder()
    wire.write_string("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n")
    for piece in pieces {
      wire.write_string("\{piece.length().to_string(radix=16)}\r\n\{piece}\r\n")
    }
    wire.write_string("0\r\n\r\n")
    @utf8.encode(wire.to_string())
  }
  let five = exchange(max_bytes=5)
  assert_eq(outcome(length("abcde"), options=five), Ok("abcde"))
  assert_eq(
    outcome(length("abcdef"), options=five),
    Err((TooLarge(limit=5), Body)),
  )
  assert_eq(outcome(chunked(["ab", "cde"]), options=five), Ok("abcde"))
  assert_eq(
    outcome(chunked(["ab", "cde", "f"]), options=five),
    Err((TooLarge(limit=5), Body)),
  )
  let zero = exchange(max_bytes=0)
  assert_eq(outcome(length(""), options=zero), Ok(""))
  assert_eq(outcome(chunked([]), options=zero), Ok(""))
  assert_eq(outcome(length("a"), options=zero), Err((TooLarge(limit=0), Body)))
  // A declared length past the limit is refused at the first read, before
  // any body byte is waited for.
  let h = Harness::new()
  let never = h.coordination.signal()
  let conn = h.scripted([
    Chunk(b"HTTP/1.1 200 OK\r\nContent-Length: 6\r\n\r\n"),
    Wait(never),
  ])
  h.run(() => {
    let response = h.client.send(
      @mttp_core.Request::get("http://example.test/"),
      five,
    )
    assert_eq(
      failing(() => ignore(body_of(response))),
      (TooLarge(limit=5), Body),
    )
    assert_eq(conn.closes(), 1)
    h.finish()
  })
}

///|
test "the configured wire ceiling bounds buffered and streamed bodies" {
  let config = { ..@h1client.ClientConfig::default(), max_body_bytes: Some(4), }
  let wire = (body : String) => {
    @utf8.encode(
      "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n\{body.length().to_string(radix=16)}\r\n\{body}\r\n0\r\n\r\n",
    )
  }
  assert_eq(outcome(wire("abcd"), config~), Ok("abcd"))
  assert_eq(outcome(wire("abcde"), config~), Err((TooLarge(limit=4), Body)))
  assert_eq(
    outcome(wire("abc"), config~, options=exchange(max_bytes=2)),
    Err((TooLarge(limit=2), Body)),
  )
  assert_eq(outcome(wire("abcd"), config~, options=streaming()), Ok("abcd"))
  assert_eq(
    outcome(wire("abcde"), config~, options=streaming()),
    Err((TooLarge(limit=4), Body)),
  )
  // Without a ceiling a stream is not bounded here: its reader bounds it.
  let big = "x".repeat(200000)
  assert_eq(outcome(wire(big), options=streaming()), Ok(big))
}

///|
test "body reads and request writes are sliced to 64 KiB" {
  let payload = Bytes::make(140000, b'x')
  let reply = b"HTTP/1.1 200 OK\r\nContent-Length: 140000\r\n\r\n"
  let h = Harness::new()
  let conn = h.scripted([Chunk(reply + payload)])
  h.run(() => {
    let response = h.client.send(
      @mttp_core.Request::post("http://example.test/").body_bytes(payload),
      exchange(),
    )
    guard response.body is Stream(body) else { fail("expected a stream") }
    let stream = body.take()
    let sizes = []
    while stream.read_some() is Some(piece) {
      sizes.push(piece.length())
    }
    // The read of the head already took the start of the body.
    let first = 65536 - reply.length()
    assert_eq(sizes, [first, 65536, 140000 - first - 65536])
    h.finish()
  })
  let writes = conn.written()
  let head = @utf8.encode(
    "POST / HTTP/1.1\r\nhost: example.test\r\ncontent-length: 140000\r\n\r\n",
  )
  let total = head.length() + 140000
  assert_eq(writes.map(w => w.length()), [65536, 65536, total - 2 * 65536])
  let sent = Buffer()
  for w in writes {
    sent.write_bytes(w)
  }
  assert_eq(sent.to_bytes(), head + payload)
}

///|
test "the default configuration pins the pool and cap defaults" {
  let config = @h1client.ClientConfig::default()
  assert_eq(config.max_idle_connections, 256)
  assert_eq(config.max_idle_per_origin, 4)
  assert_eq(config.idle_max_ms, 10000)
  assert_eq(config.max_connections, None)
  assert_eq(config.max_connections_per_origin, None)
  assert_eq(config.max_body_bytes, None)
  assert_eq(config.head_limits, @h1.Limits::default())
  assert_eq(
    [
      config.pool_timeout_ms,
      config.connect_timeout_ms,
      config.write_timeout_ms,
      config.read_timeout_ms,
    ],
    [None, None, None, None],
  )
}
