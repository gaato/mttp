///|
test "keep-alive serves several requests on one connection with absolute URLs" {
  let h = Harness::new()
  let seen = []
  h.run(() => {
    let (client, task) = h.serve(
      request => {
        seen.push(
          (
            request.attributes.get(@mttp_core.remote_addr),
            request.attributes.get(@mttp_core.background) is Some(_),
          ),
        )
        @mttp_core.Response::new(
          200,
          headers=@mttp_core.Headers::of([
            ("set-cookie", "a=1"),
            ("set-cookie", "b=2"),
          ]),
          body=Bytes(@mttp_core.encode_utf8(request.url)),
        )
      },
      scheme="https",
      peer="192.0.2.1:4000",
    )
    for path in ["/one", "/two?x=1"] {
      client.send(get(path))
      let reply = client.expect()
      assert_eq(reply.status, 200)
      assert_eq(reply.headers.get_all("set-cookie"), ["a=1", "b=2"])
      assert_eq(reply.headers.get("connection"), None)
      assert_eq(reply.text(), "https://example.test\{path}")
    }
    client.conn.close()
    ignore(task.wait())
  })
  assert_eq(seen, [
    (Some("192.0.2.1:4000"), false),
    (Some("192.0.2.1:4000"), false),
  ])
  assert_eq(h.errors.length(), 0)
}

///|
test "exchanges survive 1 17 and 65536 byte fragments" {
  for chunk_bytes in [1, 17, 65536] {
    let h = Harness::new()
    let out = h.exchange(
      @mttp_core.encode_utf8(post("/upload", "hello world")),
      echo(),
      chunk_bytes~,
    )
    assert_true(out.has_prefix("HTTP/1.1 200 OK\r\n"))
    assert_true(out.has_suffix("\r\n\r\nhello world"))
  }
}

///|
test "Connection close and HTTP/1.0 end the connection after the response" {
  for
    (request, version) in [
      (get("/", fields="Connection: keep-alive, close\r\n"), "HTTP/1.1"),
      ("GET / HTTP/1.0\r\n\r\n", "HTTP/1.1"),
      ("GET / HTTP/1.0\r\nConnection: keep-alive, close\r\n\r\n", "HTTP/1.1"),
    ] {
    let h = Harness::new()
    h.run(() => {
      let (client, task) = h.serve(reply("ok"))
      client.send(request)
      let out = client.rest()
      assert_true(out.has_prefix(version + " 200 OK\r\n"), msg=out)
      assert_true(out.contains("connection: close\r\n"))
      assert_true(out.has_suffix("\r\n\r\nok"))
      ignore(task.wait())
      client.conn.close()
    })
  }
}

///|
test "HTTP/1.0 keeps the connection only when asked and is never chunked" {
  let h = Harness::new()
  h.run(() => {
    let (client, task) = h.serve(request => {
      if request.url.has_suffix("/stream") {
        @mttp_core.Response::new(
          200,
          body=Stream(@mttp_core.StreamBody::new(Pieces::new([b"ab", b"cd"]))),
        )
      } else {
        @mttp_core.Response::new(200, body=Bytes(b"fixed"))
      }
    })
    client.send(
      "GET /fixed HTTP/1.0\r\nHost: example.test\r\nConnection: Keep-Alive\r\n\r\n",
    )
    let reply = client.expect()
    assert_eq(reply.headers.get("connection"), Some("keep-alive"))
    assert_eq(reply.text(), "fixed")
    // A stream of unknown length can only be framed by closing.
    client.send(
      "GET /stream HTTP/1.0\r\nHost: example.test\r\nConnection: keep-alive\r\n\r\n",
    )
    let out = client.rest()
    assert_true(out.contains("connection: close\r\n"))
    assert_false(out.contains("transfer-encoding"))
    assert_true(out.has_suffix("\r\n\r\nabcd"))
    ignore(task.wait())
    client.conn.close()
  })
}

///|
test "the URL comes from the scheme and Host, an absolute target or the authority" {
  let h = Harness::new()
  let urls = []
  h.run(() => {
    let (client, task) = h.serve(request => {
      urls.push(request.url)
      @mttp_core.Response::new(204)
    })
    for
      request in [
        get("/a?b=c"),
        "GET http://other.test/abs HTTP/1.1\r\nHost: example.test\r\n\r\n",
        "OPTIONS * HTTP/1.1\r\nHost: example.test:8080\r\n\r\n",
        "GET /old HTTP/1.0\r\nConnection: keep-alive\r\n\r\n",
      ] {
      client.send(request)
      assert_eq(client.expect().status, 204)
    }
    client.conn.close()
    ignore(task.wait())
  })
  assert_eq(urls, [
    "http://example.test/a?b=c", "http://other.test/abs", "http://example.test:8080/*",
    "http://localhost/old",
  ])
}

///|
test "empty lines before a request line are skipped" {
  let h = Harness::new()
  let out = h.exchange(
    @mttp_core.encode_utf8("\r\n\r\n" + get("/after-empty-lines")),
    request => {
      @mttp_core.Response::new(
        200,
        body=Bytes(@mttp_core.encode_utf8(request.url)),
      )
    },
  )
  assert_true(out.has_prefix("HTTP/1.1 200 OK\r\n"))
  assert_true(out.has_suffix("/after-empty-lines"))
}

///|
test "refused heads are answered before the handler and close the connection" {
  for
    (request, status) in [
      ("GET / HTTP/1.1\r\nBad Header: value\r\n\r\n", "400"),
      ("GET / HTTP/1.1\r\n\r\n", "400"),
      ("GET / HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n", "400"),
      ("GET / HTTP/1.1\r\nHost: a\r\nX: one\r\n two\r\n\r\n", "400"),
      ("GET /a b HTTP/1.1\r\nHost: a\r\n\r\n", "400"),
      ("GET / HTTP/1.1\nHost: a\n\n", "400"),
      ("GET * HTTP/1.1\r\nHost: a\r\n\r\n", "400"),
      (
        "CONNECT example.test:443 HTTP/1.1\r\nHost: example.test:443\r\n\r\n", "501",
      ),
      (
        "CONNECT example.test:443 HTTP/1.1\r\nHost: example.test:443\r\nContent-Length: 0\r\nTransfer-Encoding: chunked\r\n\r\n",
        "400",
      ),
      ("GET / HTTP/2.0\r\nHost: a\r\n\r\n", "505"),
      ("POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: gzip\r\n\r\n", "501"),
      (
        "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 1\r\nExpect: other\r\n\r\nx",
        "417",
      ),
    ] {
    let h = Harness::new()
    let calls = Ref(0)
    let out = h.exchange(@mttp_core.encode_utf8(request), _ => {
      calls.val += 1
      @mttp_core.Response::new(200)
    })
    assert_true(
      out.has_prefix("HTTP/1.1 \{status} "),
      msg="\{request} -> \{out}",
    )
    assert_true(out.contains("connection: close\r\n"))
    assert_eq(out.split("HTTP/1.1").count(), 2)
    assert_eq(calls.val, 0)
    assert_eq(h.errors.length(), 1)
    assert_eq(kind_phase(h.errors[0]), (Protocol, Head))
  }
}

///|
test "HEAD 204 and 304 responses carry no body and leave the stream unread" {
  let streams = []
  let h = Harness::new()
  h.run(() => {
    let (client, task) = h.serve(request => {
      let pieces = Pieces::new([b"one", b"two"])
      streams.push(pieces)
      let status = if request.url.has_suffix("/204") {
        204
      } else if request.url.has_suffix("/304") {
        304
      } else {
        200
      }
      let length = if request.url.has_suffix("/sized") {
        Some(6L)
      } else {
        None
      }
      @mttp_core.Response::new(
        status,
        body=Stream(@mttp_core.StreamBody::new(pieces, length?)),
      )
    })
    client.send("HEAD / HTTP/1.1\r\nHost: example.test\r\n\r\n")
    let head = client.expect(meth=Head)
    assert_eq(head.headers.get("transfer-encoding"), None)
    assert_eq(head.headers.get("content-length"), None)
    client.send("HEAD /sized HTTP/1.1\r\nHost: example.test\r\n\r\n")
    assert_eq(client.expect(meth=Head).headers.get("content-length"), Some("6"))
    for path in ["/204", "/304"] {
      client.send(get(path))
      let reply = client.expect()
      assert_eq(reply.body, b"")
      assert_eq(reply.headers.get("content-length"), None)
    }
    // Nothing was left on the wire: the next request is still understood.
    client.send(get("/", fields="Connection: close\r\n"))
    assert_eq(client.expect().text(), "onetwo")
    ignore(task.wait())
    client.conn.close()
  })
  assert_eq(streams.map(s => s.closes), [1, 1, 1, 1, 1])
  assert_eq(streams.map(s => s.pieces.length()), [2, 2, 2, 2, 0])
}

///|
test "streamed responses are chunked unless their length is declared" {
  let h = Harness::new()
  h.run(() => {
    let (client, task) = h.serve(request => {
      let length = if request.url.has_suffix("/fixed") {
        Some(6L)
      } else {
        None
      }
      @mttp_core.Response::new(
        200,
        body=Stream(
          @mttp_core.StreamBody::new(Pieces::new([b"one", b"two"]), length?),
        ),
      )
    })
    client.send(get("/"))
    let reply = client.expect()
    assert_eq(reply.headers.get("transfer-encoding"), Some("chunked"))
    assert_eq(reply.text(), "onetwo")
    client.send(get("/fixed"))
    let reply = client.expect()
    assert_eq(reply.headers.get("content-length"), Some("6"))
    assert_eq(reply.text(), "onetwo")
    client.conn.close()
    ignore(task.wait())
  })
}

///|
test "responses the engine cannot write become 500 and are reported" {
  let taken = @mttp_core.StreamBody::new(Pieces::new([b"x"]))
  ignore(try! taken.take())
  for
    response in [
      @mttp_core.Response::new(100),
      @mttp_core.Response::new(101),
      @mttp_core.Response::new(
        200,
        headers=@mttp_core.Headers::of([("bad\n", "value")]),
      ),
      @mttp_core.Response::new(200, body=Stream(taken)),
      @mttp_core.Response::new(
        200,
        body=Stream(
          @mttp_core.StreamBody::new(
            Pieces::new(
              [],
              failure=@mttp_core.TransportError(
                kind=Network,
                phase=Body,
                detail="producer",
              ),
            ),
          ),
        ),
      ),
    ] {
    let h = Harness::new()
    let out = h.exchange(@mttp_core.encode_utf8(get("/")), _ => response)
    assert_true(out.has_prefix("HTTP/1.1 500 "), msg=out)
    assert_eq(out.split("HTTP/1.1").count(), 2)
    assert_eq(h.errors.length(), 1)
  }
}

///|
test "a stream that fails after the head ends the connection" {
  let h = Harness::new()
  let out = h.exchange(@mttp_core.encode_utf8(get("/") + get("/next")), _ => {
    @mttp_core.Response::new(
      200,
      body=Stream(
        @mttp_core.StreamBody::new(
          Pieces::new(
            [b"partial"],
            failure=@mttp_core.TransportError(
              kind=Network,
              phase=Body,
              detail="producer",
            ),
          ),
        ),
      ),
    )
  })
  assert_true(out.has_prefix("HTTP/1.1 200 OK\r\n"))
  assert_true(out.has_suffix("7\r\npartial\r\n"))
  assert_eq(h.errors.map(kind_phase), [(Network, Body)])
}

///|
test "pipelined requests are answered in order" {
  let h = Harness::new()
  let wire = StringBuilder()
  for i in 0..<20 {
    wire.write_string(get("/\{i}"))
  }
  let out = h.exchange(@mttp_core.encode_utf8(wire.to_string()), request => {
    @mttp_core.Response::new(
      200,
      body=Bytes(@mttp_core.encode_utf8(request.url)),
    )
  })
  assert_eq(out.split("HTTP/1.1 200 OK").count(), 21)
  let mut at = 0
  for i in 0..<20 {
    guard out[at:].find("example.test/\{i}") is Some(offset) else {
      fail("response \{i} missing or out of order")
    }
    at += offset + 1
  }
}

///|
test "a pipelined request arriving during a suspended handler is kept" {
  let h = Harness::new()
  let calls = Ref(0)
  h.run(() => {
    let release = h.coordination.signal()
    let entered = h.coordination.signal()
    let (client, task) = h.serve(_ => {
      calls.val += 1
      if calls.val == 1 {
        entered.notify()
        release.wait()
      }
      @mttp_core.Response::new(204)
    })
    client.send(get("/one"))
    entered.wait()
    client.send(get("/two", fields="Connection: close\r\n"))
    h.driver.sleep(5)
    release.notify()
    let out = client.rest()
    assert_eq(out.split("HTTP/1.1 204").count(), 3)
    ignore(task.wait())
    client.conn.close()
  })
  assert_eq(calls.val, 2)
}

///|
test "a stopping server answers with Connection close and ends" {
  let h = Harness::new()
  let stopping = Ref(false)
  h.run(() => {
    let (client, server) = @sim.pair(h.coordination)
    h.closes.push(() => server.closes())
    let task = h.serve_on(
      server,
      _ => {
        stopping.val = true
        @mttp_core.Response::new(204)
      },
      stopping=() => stopping.val,
    )
    client.write(@mttp_core.encode_utf8(get("/") + get("/never")))
    let out = { conn: client, pending: b"", }.rest()
    assert_eq(out.split("HTTP/1.1 204").count(), 2)
    assert_true(out.contains("connection: close\r\n"))
    ignore(task.wait())
    client.close()
  })
}

///|
test "the background attribute is advertised only with a scheduler" {
  let h = Harness::new()
  let ran = Ref(0)
  h.run(() => {
    let (client, task) = h.serve(
      request => {
        guard request.attributes.get(@mttp_core.background) is Some(schedule) else {
          return @mttp_core.Response::new(500)
        }
        schedule(() => ran.val += 1)
        @mttp_core.Response::new(204)
      },
      background=work => ignore(h.driver.spawn(work)),
    )
    client.send(get("/", fields="Connection: close\r\n"))
    assert_eq(client.expect().status, 204)
    ignore(task.wait())
    client.conn.close()
  })
  assert_eq(ran.val, 1)
}

///|
test "invalid limits or scheme are refused and the connection is closed" {
  let defaults = @h1server.ServerLimits::default()
  for
    (limits, scheme) in [
      ({ ..defaults, max_body_bytes: -1, }, "http"),
      ({ ..defaults, header_timeout_ms: 0, }, "http"),
    ] {
    let h = Harness::new()
    let conn = @sim.ScriptedConn::new([Chunk(@mttp_core.encode_utf8(get("/")))])
    let refused = h.driver.run(() => {
      try
        @h1server.serve_conn(
          conn,
          reply("never"),
          clock=h.clock,
          timer=h.timer,
          coordination=h.coordination,
          scheme~,
          limits~,
        )
      catch {
        _ => true
      } noraise {
        _ => false
      }
    })
    assert_true(refused)
    assert_eq(conn.closes(), 1)
    assert_eq(conn.written(), [])
  }
}

///|
test "an invalid scheme is reported before reading and closes the connection" {
  let h = Harness::new()
  let conn = @sim.ScriptedConn::new([Chunk(@mttp_core.encode_utf8(get("/")))])
  h.run(() => {
    @h1server.serve_conn(
      conn,
      reply("never"),
      clock=h.clock,
      timer=h.timer,
      coordination=h.coordination,
      scheme="ftp",
      on_error=error => h.errors.push(error),
    )
  })
  assert_eq(h.errors.map(kind_phase), [(Invalid, Head)])
  assert_eq(conn.closes(), 1)
  assert_eq(conn.written(), [])
}
