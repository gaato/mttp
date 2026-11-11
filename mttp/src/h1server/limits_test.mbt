///|
test "the default limits are pinned and validate refuses each disabled bound" {
  let defaults = @h1server.ServerLimits::default()
  debug_inspect(
    defaults,
    content=(
      #|{
      #|  max_body_bytes: 1048576,
      #|  header_timeout_ms: 5000,
      #|  body_timeout_ms: 5000,
      #|  max_header_bytes: 16384,
      #|  max_connections: 256,
      #|  drain_max_bytes: 65536,
      #|  handler_timeout_ms: None,
      #|  drain_ms: 10000,
      #|}
    ),
  )
  defaults.validate()
  // The smallest values that keep every bound are accepted.
  @h1server.ServerLimits::{
    max_body_bytes: 0,
    header_timeout_ms: 1,
    body_timeout_ms: 1,
    max_header_bytes: 1,
    max_connections: 1,
    drain_max_bytes: 0,
    handler_timeout_ms: Some(1),
    drain_ms: 0,
  }.validate()
  let refused = []
  for
    limits in [
      { ..defaults, max_body_bytes: -1, },
      { ..defaults, header_timeout_ms: 0, },
      { ..defaults, body_timeout_ms: 0, },
      { ..defaults, max_header_bytes: 0, },
      { ..defaults, max_connections: 0, },
      { ..defaults, drain_max_bytes: -1, },
      { ..defaults, handler_timeout_ms: Some(0), },
      { ..defaults, drain_ms: -1, },
    ] {
    try limits.validate() catch {
      error => refused.push(error)
    } noraise {
      _ => fail("expected \{Repr(limits)} to be refused")
    }
  }
  debug_inspect(
    refused,
    content=(
      #|[
      #|  InvalidMaxBodyBytes(value=-1),
      #|  InvalidHeaderTimeoutMs(value=0),
      #|  InvalidBodyTimeoutMs(value=0),
      #|  InvalidMaxHeaderBytes(value=0),
      #|  InvalidMaxConnections(value=0),
      #|  InvalidDrainMaxBytes(value=-1),
      #|  InvalidHandlerTimeoutMs(value=0),
      #|  InvalidDrainMs(value=-1),
      #|]
    ),
  )
}

///|
/// A GET whose head is exactly `size` bytes, final CRLF CRLF included.
fn head_of_size(size : Int32) -> String {
  let prefix = "GET / HTTP/1.1\r\nHost: example.test\r\nConnection: close\r\nX: "
  prefix + String::make(size - prefix.length() - 4, 'a') + "\r\n\r\n"
}

///|
test "a head of max_header_bytes is served and one byte more is 431" {
  for
    (limits, size) in [
      (@h1server.ServerLimits::default(), 16384),
      ({ ..@h1server.ServerLimits::default(), max_header_bytes: 128, }, 128),
    ] {
    let h = Harness::new()
    let served = h.exchange(
      @mttp.encode_utf8(head_of_size(size)),
      reply("ok"),
      limits~,
    )
    assert_true(served.has_prefix("HTTP/1.1 200 "), msg=served)
    let h = Harness::new()
    let refused = h.exchange(
      @mttp.encode_utf8(head_of_size(size + 1)),
      reply("ok"),
      limits~,
    )
    assert_true(refused.has_prefix("HTTP/1.1 431 "), msg=refused)
    assert_eq(h.errors.map(kind_phase), [(TooLarge(limit=size), Head)])
  }
}

///|
test "a head of 100 fields is served and 101 are 431" {
  for fields in [100, 101] {
    let head = StringBuilder()
    head.write_string("GET / HTTP/1.1\r\nHost: example.test\r\n")
    for i in 1..<fields {
      head.write_string("x-\{i}: v\r\n")
    }
    head.write_string("\r\n")
    let h = Harness::new()
    let out = h.exchange(@mttp.encode_utf8(head.to_string()), reply("ok"))
    let status = if fields == 100 { "200" } else { "431" }
    assert_true(out.has_prefix("HTTP/1.1 \{status} "), msg="\{fields}: \{out}")
  }
}

///|
test "header floods and chunk-line bombs are refused after one read" {
  for
    (wire, status) in [
      (
        "GET / HTTP/1.1\r\nHost: example.test\r\n" + "x: a\r\n".repeat(200000),
        "431",
      ),
      ("\r\n".repeat(600000), "431"),
      (
        "POST / HTTP/1.1\r\nHost: example.test\r\nTransfer-Encoding: chunked\r\n\r\n1;" +
        String::make(600000, 'x'),
        "400",
      ),
      (
        "POST / HTTP/1.1\r\nHost: example.test\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n" +
        "t: v\r\n".repeat(200000),
        "400",
      ),
    ] {
    let h = Harness::new()
    let (client, server) = @sim.pair(h.coordination)
    let recording = Recording::new(server)
    h.closes.push(() => server.closes())
    h.run(() => {
      let task = h.serve_on(recording, echo())
      client.write(@mttp.encode_utf8(wire))
      let out = { conn: client, pending: b"", }.rest()
      assert_true(out.has_prefix("HTTP/1.1 \{status} "), msg=out)
      ignore(task.wait())
      client.close()
    })
    // More than a megabyte arrived; the engine refused it within the first
    // reads instead of buffering it.
    assert_true(
      recording.bytes_read <= 2 * 65536,
      msg="read \{recording.bytes_read}",
    )
  }
}

///|
test "request bodies admit max_body_bytes and refuse one more" {
  let limits = { ..@h1server.ServerLimits::default(), max_body_bytes: 3, }
  let chunked = (body : String) => {
    @mttp.encode_utf8(
      "POST / HTTP/1.1\r\nHost: example.test\r\nTransfer-Encoding: chunked\r\n\r\n" +
      body,
    )
  }
  for
    (wire, status, calls) in [
      (@mttp.encode_utf8(post("/", "abc")), "200", 1),
      (@mttp.encode_utf8(post("/", "abcd")), "413", 0),
      (chunked("3\r\nabc\r\n0\r\n\r\n"), "200", 1),
      // The handler catches the failure; the answer is still 413.
      (chunked("2\r\nab\r\n2\r\ncd\r\n0\r\n\r\n"), "413", 1),
    ] {
    let h = Harness::new()
    let called = Ref(0)
    let out = h.exchange(
      wire,
      request => {
        called.val += 1
        echo()(request)
      },
      limits~,
    )
    assert_true(out.has_prefix("HTTP/1.1 \{status} "), msg=out)
    assert_eq(called.val, calls)
    if status == "413" {
      assert_eq(h.errors.map(e => kind_phase(e).0), [TooLarge(limit=3)])
    }
  }
}

///|
test "the default body ceiling admits 1 MiB" {
  for (size, status) in [(1048576, "204"), (1048577, "413")] {
    let h = Harness::new()
    let body = Bytes::make(size, b'x')
    let lengths = []
    let out = h.exchange(
      @mttp.encode_utf8(
        "POST / HTTP/1.1\r\nHost: example.test\r\nContent-Length: \{size}\r\n\r\n",
      ) +
      body,
      request => {
        let bytes = body_of(request, limit=2 << 20) catch { _ => b"" }
        lengths.push(bytes.length())
        @mttp.Response::new(204)
      },
    )
    assert_true(out.has_prefix("HTTP/1.1 \{status} "), msg=out)
    assert_eq(lengths, if status == "204" { [size] } else { [] })
  }
}

///|
test "drain reads at most drain_max_bytes of an unread body" {
  let unread : @mttp.Handler = _ => @mttp.Response::new(204)
  let partial : @mttp.Handler = request => {
    if request.body is Stream(stream) {
      let reader = stream.take() catch { _ => return @mttp.Response::new(500) }
      ignore(reader.read_some() catch { _ => None })
      reader.close()
    }
    @mttp.Response::new(204)
  }
  for chunk_bytes in [7, 65536] {
    for
      (limits, body, handler, responses) in [
        (3, post("/", "abc"), unread, 2),
        (3, post("/", "abcd"), unread, 1),
        (65536, post("/", String::make(65536, 'x')), unread, 2),
        (65536, post("/", String::make(65537, 'x')), unread, 1),
        // Chunks parsed from the last read count against the limit too.
        (
          3, "POST / HTTP/1.1\r\nHost: example.test\r\nTransfer-Encoding: chunked\r\n\r\n1\r\na\r\n5\r\nabcde\r\n0\r\n\r\n",
          partial, 1,
        ),
        (
          6, "POST / HTTP/1.1\r\nHost: example.test\r\nTransfer-Encoding: chunked\r\n\r\n1\r\na\r\n5\r\nabcde\r\n0\r\n\r\n",
          partial, 2,
        ),
      ] {
      let h = Harness::new()
      let out = h.exchange(
        @mttp.encode_utf8(body + get("/next")),
        handler,
        limits={ ..@h1server.ServerLimits::default(), drain_max_bytes: limits, },
        chunk_bytes~,
      )
      assert_eq(out.split("HTTP/1.1 204").count(), responses + 1, msg=out)
    }
  }
}

///|
test "reads ask for at most 64 KiB and writes are sliced to 64 KiB" {
  let h = Harness::new()
  let (client, server) = @sim.pair(h.coordination)
  let recording = Recording::new(server)
  h.closes.push(() => server.closes())
  let upload = String::make(200000, 'u')
  h.run(() => {
    let task = h.serve_on(recording, request => {
      if request.url.has_suffix("/big") {
        @mttp.Response::new(
          200,
          body=Stream(
            @mttp.StreamBody::new(Pieces::new([Bytes::make(131073, b'x')])),
          ),
        )
      } else {
        echo()(request)
      }
    })
    let c = { conn: client, pending: b"", }
    c.send(get("/big"))
    let big = c.expect()
    assert_eq(big.body.length(), 131073)
    c.send(post("/", upload))
    assert_eq(c.expect().body.length(), 200000)
    client.close()
    ignore(task.wait())
  })
  assert_true(recording.read_sizes.iter().all(n => n > 0 && n <= 65536))
  assert_true(recording.write_sizes.iter().all(n => n <= 65536))
  // The 131073-byte chunk went out as two 64 KiB chunks and one byte.
  assert_true(recording.write_sizes.length() >= 5)
}

///|
test "a running exchange reads at most one read ahead of its request" {
  let h = Harness::new()
  let (client, server) = @sim.pair(h.coordination)
  let recording = Recording::new(server)
  h.closes.push(() => server.closes())
  let calls = Ref(0)
  h.run(() => {
    let entered = h.coordination.signal()
    let release = h.coordination.signal()
    let task = h.serve_on(recording, _ => {
      calls.val += 1
      if calls.val == 1 {
        entered.notify()
        release.wait()
      }
      @mttp.Response::new(204)
    })
    client.write(@mttp.encode_utf8(get("/first")))
    entered.wait()
    let before = recording.read_sizes.length()
    // A flood of pipelined requests, far more than one read.
    for i in 0..<2000 {
      client.write(@mttp.encode_utf8(get("/\{i}")))
    }
    h.driver.sleep(10)
    // The peer monitor's one read may already have been pending.
    assert_true(recording.read_sizes.length() - before <= 1)
    assert_true(recording.bytes_read <= 65536 + 64)
    release.notify()
    client.shutdown_write()
    let out = { conn: client, pending: b"", }.rest()
    assert_eq(out.split("HTTP/1.1 204").count(), 2002)
    ignore(task.wait())
    client.close()
  })
}
