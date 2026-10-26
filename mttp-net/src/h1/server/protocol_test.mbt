///|
test "peer read failure cancels an exchange and closes its connection" {
  let driver = @driver.Driver::new()
  let coordination = @sim.SimCoordination::new(driver)
  let conn = @sim.ScriptedConn::new([
    Chunk(b"GET / HTTP/1.1\r\nHost: x\r\n\r\n"),
    Failure(@model.TransportError(kind=Network, phase=Unknown, detail="reset")),
  ])
  let cleaned = Ref(false)
  driver.run(() => {
    @server.serve_conn(
      conn,
      _ => {
        defer {
          cleaned.val = true
        }
        driver.sleep(100)
        @model.Response::new(200)
      },
      clock=@fake.SimClock::new(driver),
      timer=@fake.SimTimer::new(driver),
      coordination~,
    )
  })
  assert_true(cleaned.val)
  assert_eq(conn.closes(), 1)
}

///|
fn exchange(
  bytes : Bytes,
  handler : @model.Handler,
  limits~ : @server.ServerLimits = @server.ServerLimits::default(),
) -> String raise {
  let driver = @driver.Driver::new()
  let coordination = @sim.SimCoordination::new(driver)
  let clock = @fake.SimClock::new(driver)
  let timer = @fake.SimTimer::new(driver)
  let (peer, conn) = @sim.pair(coordination, chunk_bytes=1)
  let result = driver.run(() => {
    let server = driver.spawn(() => {
      @server.serve_conn(conn, handler, clock~, timer~, coordination~, limits~)
    })
    peer.write(bytes)
    peer.shutdown_write()
    let out = Buffer()
    while peer.read(max_len=65536) is Some(bytes) {
      out.write_bytes(bytes)
    }
    assert_true(server.wait())
    peer.close()
    @utf8.decode(out.to_bytes())
  })
  assert_eq(conn.closes(), 1)
  assert_eq(peer.closes(), 1)
  result
}

///|
test "peer FIN preserves delayed response production" {
  let driver = @driver.Driver::new()
  let coordination = @sim.SimCoordination::new(driver)
  let (peer, conn) = @sim.pair(coordination, chunk_bytes=1)
  driver.run(() => {
    let server = driver.spawn(() => {
      @server.serve_conn(
        conn,
        _ => {
          driver.sleep(20)
          @model.Response::new(200, body=Bytes(b"reply"))
        },
        clock=@fake.SimClock::new(driver),
        timer=@fake.SimTimer::new(driver),
        coordination~,
      )
    })
    peer.write(b"GET / HTTP/1.1\r\nHost: x\r\n\r\n")
    peer.shutdown_write()
    let out = Buffer()
    while peer.read(max_len=2) is Some(bytes) {
      out.write_bytes(bytes)
    }
    assert_true(@utf8.decode(out.to_bytes()).has_suffix("reply"))
    assert_true(server.wait())
    peer.close()
  })
  assert_eq(conn.closes(), 1)
}

///|
test "ambiguous request framing is refused before the handler" {
  for
    request in [
      b"POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\nx",
      b"POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
      b"GET / HTTP/1.1\r\nBad Header: value\r\n\r\n",
    ] {
    let calls = Ref(0)
    let response = exchange(request, _ => {
      calls.val += 1
      @model.Response::new(200)
    })
    assert_true(response.has_prefix("HTTP/1.1 400"))
    assert_eq(calls.val, 0)
  }
}

///|
test "chunked request bounds and sticky failures survive the portable boundary" {
  let response = exchange(
    b"POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nabcd\r\n0\r\n\r\n",
    request => {
      ignore(@httpclient.read_body(request.body, 100) catch { _ => b"caught" })
      @model.Response::new(200)
    },
    limits={ ..@server.ServerLimits::default(), max_body_bytes: 3, },
  )
  assert_true(response.has_prefix("HTTP/1.1 413"))
  let response = exchange(
    b"GET / HTTP/1.1\r\nHost: x\r\nX: long\r\n\r\n",
    _ => @model.Response::new(200),
    limits={ ..@server.ServerLimits::default(), max_header_bytes: 20, },
  )
  assert_true(response.has_prefix("HTTP/1.1 431"))
}

///|
test "header body and handler deadlines use virtual time" {
  let defaults = @server.ServerLimits::default()
  let driver = @driver.Driver::new()
  let coordination = @sim.SimCoordination::new(driver)
  let (peer, conn) = @sim.pair(coordination)
  driver.run(() => {
    let server = driver.spawn(() => {
      @server.serve_conn(
        conn,
        _ => @model.Response::new(200),
        clock=@fake.SimClock::new(driver),
        timer=@fake.SimTimer::new(driver),
        coordination~,
        limits={ ..defaults, header_timeout_ms: 5, },
      )
    })
    peer.write(b"GET / HTTP/1.1\r\nHost:")
    let out = Buffer()
    while peer.read(max_len=65536) is Some(bytes) {
      out.write_bytes(bytes)
    }
    assert_true(@utf8.decode(out.to_bytes()).has_prefix("HTTP/1.1 408"))
    assert_true(server.wait())
    peer.close()
  })
  let response = exchange(
    b"POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 1\r\n\r\n",
    request => {
      ignore(@httpclient.read_body(request.body, 100) catch { _ => b"" })
      @model.Response::new(200)
    },
  )
  assert_true(response.has_prefix("HTTP/1.1 400"))
  for kind in ["body", "handler"] {
    let driver = @driver.Driver::new()
    let coordination = @sim.SimCoordination::new(driver)
    let (peer, conn) = @sim.pair(coordination)
    driver.run(() => {
      let server = driver.spawn(() => {
        @server.serve_conn(
          conn,
          request => {
            if kind == "body" {
              ignore(
                @httpclient.read_body(request.body, 100) catch {
                  _ => b""
                },
              )
            } else {
              driver.sleep(100)
            }
            @model.Response::new(200)
          },
          clock=@fake.SimClock::new(driver),
          timer=@fake.SimTimer::new(driver),
          coordination~,
          limits={
            ..defaults,
            body_timeout_ms: 5,
            handler_timeout_ms: if kind == "handler" {
              Some(5)
            } else {
              None
            },
          },
        )
      })
      peer.write(b"POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 1\r\n\r\n")
      let out = Buffer()
      while peer.read(max_len=65536) is Some(bytes) {
        out.write_bytes(bytes)
      }
      assert_true(
        @utf8.decode(out.to_bytes()).has_prefix(
          if kind == "body" {
            "HTTP/1.1 408"
          } else {
            "HTTP/1.1 504"
          },
        ),
      )
      assert_true(server.wait())
      peer.close()
    })
  }
}
