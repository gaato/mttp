///|
test "a read failure while the handler runs cancels it and closes the connection" {
  let h = Harness::new()
  let reset = h.coordination.signal()
  let conn = @sim.ScriptedConn::new([
    Chunk(@mttp.encode_utf8(get("/"))),
    Wait(reset),
    Failure(@mttp.TransportError(kind=Network, phase=Unknown, detail="reset")),
  ])
  let entered = Ref(false)
  let cleaned = Ref(false)
  let finished = Ref(false)
  h.run(() => {
    let task = h.serve_on(conn, _ => {
      defer {
        cleaned.val = true
      }
      entered.val = true
      h.driver.sleep(1000)
      finished.val = true
      @mttp.Response::new(200)
    })
    h.driver.sleep(10)
    assert_true(entered.val)
    reset.notify()
    ignore(task.wait())
    assert_eq(h.driver.now(), 10L)
  })
  assert_true(cleaned.val)
  assert_false(finished.val)
  assert_eq(conn.closes(), 1)
  assert_eq(conn.written(), [])
  assert_eq(h.errors.map(kind_phase), [(Network, Unknown)])
}

///|
test "a reset cancels a handler that leaves a nonempty request body unread" {
  for prefix in ["", "ab"] {
    let h = Harness::new()
    let reset = h.coordination.signal()
    let steps : Array[@sim.ReadStep] = [
      Chunk(b"POST / HTTP/1.1\r\nHost: h\r\nContent-Length: 10\r\n\r\n"),
    ]
    if prefix != "" {
      steps.push(Chunk(@mttp.encode_utf8(prefix)))
    }
    steps.push(Wait(reset))
    steps.push(
      Failure(@mttp.TransportError(kind=Network, phase=Unknown, detail="reset")),
    )
    let conn = @sim.ScriptedConn::new(steps)
    let entered = Ref(false)
    let cleaned = Ref(false)
    let finished = Ref(false)
    h.run(() => {
      let task = h.serve_on(
        conn,
        _ => {
          defer {
            cleaned.val = true
          }
          entered.val = true
          h.driver.sleep(1000)
          finished.val = true
          @mttp.Response::new(200)
        },
        limits={
          ..@h1server.ServerLimits::default(),
          handler_timeout_ms: None,
        },
      )
      h.driver.sleep(10)
      assert_true(entered.val)
      reset.notify()
      ignore(task.wait())
      assert_eq(h.driver.now(), 10L)
    })
    assert_true(cleaned.val)
    assert_false(finished.val)
    assert_eq(conn.closes(), 1)
    assert_eq(conn.written(), [])
    assert_eq(h.errors.map(kind_phase), [(Network, Unknown)])
  }
}

///|
test "read ahead hands off a pending read and preserves body and pipeline bytes" {
  for chunk_bytes in [1, 17, 65536] {
    for chunked in [false, true] {
      let h = Harness::new()
      let (client, server) = @sim.pair(h.coordination, chunk_bytes~)
      let recording = Recording::new(server)
      h.closes.push(() => server.closes())
      h.run(() => {
        let task = h.serve_on(recording, request => {
          h.driver.sleep(10)
          echo()(request)
        })
        let c = Client::{ conn: client, pending: b"", }
        c.send(
          if chunked {
            "POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n"
          } else {
            "POST / HTTP/1.1\r\nHost: h\r\nContent-Length: 3\r\n\r\n"
          },
        )
        // Some bytes are prefetched; the body claims while the monitor is
        // blocked waiting for more, so cancellation must finish first.
        c.send(if chunked { "1\r\na\r\n" } else { "a" })
        h.driver.sleep(20)
        c.send(
          (if chunked { "2\r\nbc\r\n0\r\n\r\n" } else { "bc" }) + get("/next"),
        )
        client.shutdown_write()
        assert_eq(c.expect().text(), "abc")
        assert_eq(c.expect().status, 200)
        assert_eq(c.rest(), "")
        ignore(task.wait())
        client.close()
      })
      assert_eq(recording.max_readers, 1)
      assert_eq(recording.active_reads, 0)
      assert_eq(h.errors.length(), 0)
    }
  }
}

///|
test "a full unread body read ahead stops at 64 KiB and the handler deadline cancels it" {
  for chunk_bytes in [17, 65536] {
    let h = Harness::new()
    let (client, server) = @sim.pair(h.coordination, chunk_bytes~)
    let recording = Recording::new(server)
    h.closes.push(() => server.closes())
    let cleaned = Ref(false)
    h.run(() => {
      let task = h.serve_on(
        recording,
        _ => {
          defer {
            cleaned.val = true
          }
          h.driver.sleep(10000)
          @mttp.Response::new(200)
        },
        limits={
          ..@h1server.ServerLimits::default(),
          handler_timeout_ms: Some(30),
        },
      )
      let c = Client::{ conn: client, pending: b"", }
      let head = "POST / HTTP/1.1\r\nHost: h\r\nContent-Length: 100000\r\n\r\n"
      c.send(head)
      h.driver.sleep(1)
      let before = recording.bytes_read
      client.write(Bytes::make(100000, b'x'))
      h.driver.sleep(10)
      assert_eq(recording.bytes_read - before, 65536)
      let reads = recording.read_sizes.length()
      h.driver.sleep(10)
      assert_eq(recording.read_sizes.length(), reads)
      assert_eq(c.expect().status, 504)
      assert_eq(c.rest(), "")
      ignore(task.wait())
      assert_eq(h.driver.now(), 30L)
      client.close()
    })
    assert_true(cleaned.val)
    assert_eq(recording.max_readers, 1)
    assert_eq(h.errors.map(kind_phase), [(Timeout(ms=30), Unknown)])
  }
}

///|
test "clean EOF during unread body read ahead preserves a delayed response" {
  for consume in [false, true] {
    let h = Harness::new()
    let out = h.exchange(
      @mttp.encode_utf8(post("/", "abc", fields="Connection: close\r\n")),
      request => {
        // Read-ahead neither starts the lazy body deadline nor treats a
        // sending half-close as a reason to cancel the handler.
        h.driver.sleep(20)
        if consume {
          echo()(request)
        } else {
          @mttp.Response::new(204)
        }
      },
      limits={ ..@h1server.ServerLimits::default(), body_timeout_ms: 5, },
      chunk_bytes=1,
    )
    assert_true(
      out.has_prefix(if consume { "HTTP/1.1 200 " } else { "HTTP/1.1 204 " }),
      msg=out,
    )
    if consume {
      assert_true(out.has_suffix("\r\n\r\nabc"))
    }
    assert_eq(h.errors.length(), 0)
  }
}

///|
test "a read failure in a body the handler reads fails that read" {
  let h = Harness::new()
  let conn = @sim.ScriptedConn::new([
    Chunk(
      @mttp.encode_utf8(
        "POST / HTTP/1.1\r\nHost: example.test\r\nContent-Length: 10\r\n\r\nab",
      ),
    ),
    Failure(@mttp.TransportError(kind=Network, phase=Unknown, detail="reset")),
  ])
  let seen = []
  h.run(() => {
    let task = h.serve_on(conn, request => {
      let body = body_of(request) catch {
        error => {
          seen.push(kind_phase(error))
          b""
        }
      }
      @mttp.Response::new(200, body=Bytes(body))
    })
    ignore(task.wait())
  })
  assert_eq(seen, [(Network, Body)])
  assert_eq(conn.closes(), 1)
}

///|
test "peer EOF keeps a delayed and streamed response" {
  let h = Harness::new()
  h.run(() => {
    let (client, task) = h.serve(
      request => {
        let body = body_of(request) catch {
          _ => return @mttp.Response::new(400)
        }
        // Suspend so that the peer monitor sees EOF before the response.
        h.driver.sleep(20)
        @mttp.Response::new(
          200,
          body=Stream(@mttp.StreamBody::new(Pieces::new([body, b"!"]))),
        )
      },
      chunk_bytes=2,
    )
    client.send(post("/", "half-closed"))
    client.conn.shutdown_write()
    let out = client.rest()
    assert_true(out.has_prefix("HTTP/1.1 200 "))
    assert_true(out.contains("half-closed\r\n1\r\n!\r\n0\r\n\r\n"))
    ignore(task.wait())
    client.conn.close()
  })
  assert_eq(h.errors.length(), 0)
}

///|
test "a peer that went away leaves the write failure reported" {
  let h = Harness::new()
  h.run(() => {
    let (client, task) = h.serve(_ => {
      h.driver.sleep(20)
      @mttp.Response::new(200, body=Bytes(b"too late"))
    })
    client.send(get("/"))
    h.driver.sleep(5)
    client.conn.close()
    ignore(task.wait())
  })
  assert_eq(h.errors.map(kind_phase), [(Network, Write)])
}

///|
test "head and body truncation are reported even when no answer arrives" {
  for
    wire in [
      "GET / HTTP/1.1\r\nHost:", "POST / HTTP/1.1\r\nHost: example.test\r\nContent-Length: 3\r\n\r\nx",
    ] {
    let h = Harness::new()
    h.run(() => {
      let (client, task) = h.serve(echo())
      client.send(wire)
      client.conn.close()
      ignore(task.wait())
    })
    assert_true(h.errors.length() >= 1)
    assert_eq(kind_phase(h.errors[0]).0, Protocol)
  }
}
