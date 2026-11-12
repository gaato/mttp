///|
test "the client keeps the shared backend contract" {
  let driver = @driver.Driver::new()
  let coordination = @sim.SimCoordination::new(driver)
  driver.run(() => {
    @sim.check_backend_contract(() => {
      @h1client.Client::new(
        dialer=@sim.ScriptedDialer::new([]),
        clock=@sim.SimClock::new(driver),
        timer=@sim.SimTimer::new(driver),
        coordination~,
        config=@h1client.ClientConfig::default(),
      )
    })
  })
}

///|
test "an exchange survives every fragmentation of the peer's bytes" {
  for chunk_bytes in [1, 7, 65536] {
    let h = Harness::new()
    let peer = h.peer(chunk_bytes~)
    h.run(() => {
      let server = h.driver.spawn(() => {
        let seen = peer.serve(ok("body"))
        assert_eq(seen.length(), 1)
        assert_true(seen[0].raw.has_prefix(b"GET / HTTP/1.1\r\n"))
      })
      assert_eq(
        fetch(h.client, @mttp_core.Request::get("http://example.test")),
        "body",
      )
      assert_eq(h.client.idle_connections(), 1)
      h.finish()
      ignore(server.wait())
    })
    assert_eq(h.dialer.dialed, [("example.test", 80)])
  }
}

///|
test "completed responses park their connection for the next request" {
  let h = Harness::new(config={
    ..@h1client.ClientConfig::default(),
    max_connections: Some(1),
  })
  let peer = h.peer()
  h.run(() => {
    let server = h.driver.spawn(() => {
      assert_eq(peer.serve(ok("pong")).length(), 3)
    })
    for _ in 0..<3 {
      let response = h.client.send(
        @mttp_core.Request::get("http://example.test/ping"),
        exchange(),
      )
      assert_eq(h.client.idle_connections(), 0)
      assert_eq(body_of(response), b"pong")
      assert_eq(h.client.idle_connections(), 1)
    }
    h.finish()
    h.client.close()
    ignore(server.wait())
  })
  assert_eq(h.dialer.dialed.length(), 1)
}

///|
test "chunked bodies consume trailers and informational heads before reuse" {
  let wire = b"HTTP/1.1 103 Early Hints\r\nlink: </a>\r\n\r\nHTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nab\r\n1;x=y\r\nc\r\n0\r\nX-Trailer: yes\r\n\r\n"
  for chunk_bytes in [1, 5, 65536] {
    let h = Harness::new()
    let peer = h.peer(chunk_bytes~)
    h.run(() => {
      let server = h.driver.spawn(() => ignore(peer.serve(wire)))
      let response = h.client.send(
        @mttp_core.Request::get("http://example.test/"),
        exchange(),
      )
      assert_eq(response.status, 200)
      assert_eq(body_of(response), b"abc")
      assert_eq(h.client.idle_connections(), 1)
      h.finish()
      ignore(server.wait())
    })
  }
}

///|
test "short or malformed bodies fail in phase Body and discard the connection" {
  for
    wire in [
      b"HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nabc", b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\na",
      b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nz\r\n",
    ] {
    let h = Harness::new()
    let conn = h.scripted([Chunk(wire), Eof])
    h.run(() => {
      let outcome = failing(() => {
        ignore(fetch(h.client, @mttp_core.Request::get("http://example.test/")))
      })
      assert_eq(outcome, (Protocol, Body))
      assert_eq(h.client.idle_connections(), 0)
      assert_eq(conn.closes(), 1)
      h.finish()
    })
  }
}

///|
test "close-delimited and explicitly closed responses are never parked" {
  for
    wire in [
      b"HTTP/1.0 200 OK\r\n\r\nabc", b"HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 3\r\n\r\nabc",
      b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: keep-alive, Close\r\n\r\n3\r\nabc\r\n0\r\n\r\n",
    ] {
    let h = Harness::new()
    let conn = h.scripted([Chunk(wire), Eof])
    h.run(() => {
      assert_eq(
        fetch(h.client, @mttp_core.Request::get("http://example.test/")),
        "abc",
      )
      assert_eq(h.client.idle_connections(), 0)
      assert_eq(conn.closes(), 1)
      h.finish()
    })
  }
  // A body closed before its end closes the connection; closing twice is
  // harmless, and a reader taken before the close then reads EOF.
  let h = Harness::new()
  let conn = h.scripted([
    Chunk(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n"),
  ])
  h.run(() => {
    let response = h.client.send(
      @mttp_core.Request::get("http://example.test/"),
      exchange(),
    )
    guard response.body is Stream(body) else { fail("expected a stream") }
    let reader = body.take()
    response.close()
    response.close()
    assert_eq(reader.read_some(), None)
    assert_eq(conn.closes(), 1)
    assert_eq(h.client.idle_connections(), 0)
    h.finish()
  })
}

///|
test "no-body framing and connection tokens follow the method and protocol" {
  let rows : Array[(@mttp_core.Method, Bytes, Bool)] = [
    (Head, b"HTTP/1.1 200 OK\r\nContent-Length: 900\r\n\r\n", true),
    (Get, b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n", true),
    (Get, b"HTTP/1.1 304 Not Modified\r\nContent-Length: 12\r\n\r\n", true),
    (
      Get,
      b"HTTP/1.0 200 OK\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n",
      true,
    ),
    (Get, b"HTTP/1.0 200 OK\r\nContent-Length: 0\r\n\r\n", false),
    (Connect, b"HTTP/1.1 200 OK\r\n\r\n", false),
    (Get, b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: x\r\n\r\n", false),
    (Get, b"HTTP/1.1 204 No Content\r\n\r\nunsolicited", false),
  ]
  for row in rows {
    let (meth, wire, reusable) = row
    let h = Harness::new()
    let conn = h.scripted([Chunk(wire)])
    h.run(() => {
      let response = h.client.send(
        @mttp_core.Request::new(meth, "http://example.test/"),
        exchange(),
      )
      assert_eq(response.body, Empty)
      assert_eq(
        h.client.idle_connections(),
        if reusable {
          1
        } else {
          0
        },
        msg="\{meth} \{wire}",
      )
      assert_eq(conn.closes(), if reusable { 0 } else { 1 })
      h.finish()
    })
  }
}

///|
test "the request head carries the origin-form target and a Host field" {
  let rows : Array[(@mttp_core.Request, String)] = [
    (
      @mttp_core.Request::get("http://example.test"),
      "GET / HTTP/1.1\r\nhost: example.test\r\n\r\n",
    ),
    (
      @mttp_core.Request::get("https://example.test:8443/a/b?c=d&e#frag"),
      "GET /a/b?c=d&e HTTP/1.1\r\nhost: example.test:8443\r\n\r\n",
    ),
    (
      @mttp_core.Request::get("http://[::1]:8080/").header("user-agent", "t/1"),
      "GET / HTTP/1.1\r\nuser-agent: t/1\r\nhost: [::1]:8080\r\n\r\n",
    ),
    (
      @mttp_core.Request::get("http://example.test/").header(
        "Host", "other.test",
      ),
      "GET / HTTP/1.1\r\nhost: other.test\r\n\r\n",
    ),
    (
      @mttp_core.Request::post("http://example.test/"),
      "POST / HTTP/1.1\r\nhost: example.test\r\ncontent-length: 0\r\n\r\n",
    ),
    (
      @mttp_core.Request::delete("http://example.test/x"),
      "DELETE /x HTTP/1.1\r\nhost: example.test\r\n\r\n",
    ),
    (
      @mttp_core.Request::put("http://example.test/").body_bytes(b"hi"),
      "PUT / HTTP/1.1\r\nhost: example.test\r\ncontent-length: 2\r\n\r\nhi",
    ),
  ]
  for row in rows {
    let (request, expected) = row
    let h = Harness::new()
    let conn = h.scripted([Chunk(b"HTTP/1.1 204 No Content\r\n\r\n")])
    h.run(() => {
      h.client.send(request, exchange()).close()
      h.finish()
    })
    assert_eq(conn.written(), [@utf8.encode(expected)])
  }
  let h = Harness::new()
  ignore(h.scripted([Chunk(b"HTTP/1.1 204 No Content\r\n\r\n")]))
  h.run(() => {
    h.client.send(@mttp_core.Request::get("https://[::1]/"), exchange()).close()
    h.finish()
  })
  assert_eq(h.dialer.dialed, [("::1", 443)])
  assert_eq(h.dialer.tls_hosts, ["::1"])
}

///|
test "raw content codings pass through untouched" {
  let h = Harness::new()
  let conn = h.scripted([
    Chunk(
      b"HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 3\r\n\r\nraw",
    ),
  ])
  h.run(() => {
    let response = h.client.send(
      @mttp_core.Request::get("http://example.test/"),
      exchange(),
    )
    assert_eq(response.headers.get("content-encoding"), Some("gzip"))
    assert_eq(response.headers.get("content-length"), Some("3"))
    guard response.body is Stream(stream) else { fail("expected a stream") }
    assert_eq(stream.length(), Some(3L))
    assert_eq(body_of(response), b"raw")
    h.finish()
  })
  let head = @utf8.decode(conn.written()[0])
  assert_false(head.contains("accept-encoding"))
}

///|
test "invalid requests and settings are refused before any dial" {
  let urls = [
    "/relative", "ftp://example.test/", "http://user:pass@example.test/", "http:///nohost",
    "http://example.test:99999/",
  ]
  for url in urls {
    let h = Harness::new()
    h.run(() => {
      assert_eq(
        failing(() => ignore(fetch(h.client, @mttp_core.Request::get(url)))),
        (Invalid, Pool),
        msg=url,
      )
    })
    assert_eq(h.dialer.dialed, [], msg=url)
  }
  let invalid = [
    @mttp_core.Request::get("http://example.test/").header("host", "bad\u{7f}"),
    @mttp_core.Request::get("http://example.test/").header("x-name", "日本"),
    // Valid fields, but not a valid HTTP/1.1 head.
    @mttp_core.Request::get("http://example.test/").header("host", "bad host"),
    @mttp_core.Request::get("http://example.test/")
    .header("host", "a.test")
    .header("host", "b.test"),
    @mttp_core.Request::new(Other("BAD METHOD"), "http://example.test/"),
  ]
  for request in invalid {
    let h = Harness::new()
    h.run(() => {
      assert_eq(
        failing(() => ignore(fetch(h.client, request))),
        (Invalid, Pool),
      )
    })
    assert_eq(h.dialer.dialed, [])
  }
  let h = Harness::new(config={
    ..@h1client.ClientConfig::default(),
    max_body_bytes: Some(-1),
  })
  h.run(() => {
    assert_eq(
      failing(() => {
        ignore(fetch(h.client, @mttp_core.Request::get("http://example.test/")))
      }),
      (Invalid, Pool),
    )
  })
  assert_eq(h.dialer.dialed, [])
}

///|
test "close refuses later sends and closes parked connections" {
  let h = Harness::new()
  let conn = h.scripted([Chunk(ok("x"))])
  h.run(() => {
    assert_eq(
      fetch(h.client, @mttp_core.Request::get("http://example.test/")),
      "x",
    )
    assert_eq(h.client.idle_connections(), 1)
    h.client.close()
    h.client.close()
    assert_eq(conn.closes(), 1)
    assert_eq(h.client.idle_connections(), 0)
    assert_eq(
      failing(() => {
        ignore(fetch(h.client, @mttp_core.Request::get("http://example.test/")))
      }),
      (Closed, Pool),
    )
  })
  assert_eq(h.dialer.dialed.length(), 1)
}

///|
test "a response in flight at close finishes and then closes its connection" {
  let h = Harness::new()
  let conn = h.scripted([Chunk(ok("abc"))])
  h.run(() => {
    let response = h.client.send(
      @mttp_core.Request::get("http://example.test/"),
      exchange(),
    )
    h.client.close()
    assert_eq(body_of(response), b"abc")
    assert_eq(conn.closes(), 1)
    assert_eq(h.client.idle_connections(), 0)
  })
}

///|
test "at most 16 informational heads precede the final one" {
  for count in [16, 17] {
    let informational = @utf8.encode(
      "HTTP/1.1 102 Processing\r\n\r\n".repeat(count),
    )
    let h = Harness::new()
    ignore(h.scripted([Chunk(informational + ok("done"))]))
    h.run(() => {
      let result = Ok(
        fetch(h.client, @mttp_core.Request::get("http://example.test/")),
      ) catch {
        error => Err(kind_phase(error))
      }
      assert_eq(
        result,
        if count == 16 {
          Ok("done")
        } else {
          Err((Protocol, Head))
        },
      )
      h.finish()
    })
  }
}

///|
test "unframeable responses and port failures are reported in their phase" {
  let heads = [
    b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\nTransfer-Encoding: chunked\r\n\r\n",
    b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nContent-Length: 2\r\n\r\nok", b"HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip\r\n\r\n",
    b"HTTP/1.1 bad\r\n\r\n",
  ]
  for wire in heads {
    let h = Harness::new()
    let conn = h.scripted([Chunk(wire)])
    h.run(() => {
      assert_eq(
        failing(() => {
          ignore(
            fetch(h.client, @mttp_core.Request::get("http://example.test/")),
          )
        }),
        (Protocol, Head),
      )
      assert_eq(conn.closes(), 1)
      h.finish()
    })
  }
  // A port failure without a phase takes the phase it happened in.
  let h = Harness::new()
  ignore(
    h.scripted([
      Failure(
        @mttp_core.TransportError(kind=Network, phase=Unknown, detail="reset"),
      ),
    ]),
  )
  h.run(() => {
    assert_eq(
      failing(() => {
        ignore(fetch(h.client, @mttp_core.Request::get("http://example.test/")))
      }),
      (Network, Head),
    )
    h.finish()
  })
  // A failed TLS upgrade is a Dial failure, and the connection is closed.
  let h = Harness::new()
  let conn = h.scripted([])
  h.dialer.tls_failure = Some(
    @mttp_core.TransportError(
      kind=Connect,
      phase=Dial,
      detail="bad certificate",
    ),
  )
  h.run(() => {
    assert_eq(
      failing(() => {
        ignore(
          fetch(h.client, @mttp_core.Request::get("https://example.test/")),
        )
      }),
      (Connect, Dial),
    )
  })
  assert_eq(conn.closes(), 1)
  assert_eq(h.dialer.tls_hosts, ["example.test"])
}
