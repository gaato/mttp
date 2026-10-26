///|
async test "body timeout parent cancellation and concurrent reads release their connection" {
  for mode in 0..<3 {
    let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer listener.close()
    let tcp = @socket.Tcp::connect_to_host(
      "127.0.0.1",
      port=listener.addr.port(),
    )
    let (peer, _) = listener.accept()
    defer peer.close()
    let wire = Wire::new(@accepted.from_tcp(tcp))
    let clock = ManualClock::new()
    let backend = H1Backend::new(trust_env=false, clock~)
    defer backend.close()
    backend.slots.take("origin")
    let reader : &@model.BodyStream = ResponseBody::new(
      backend.engine(),
      "origin",
      None,
      wire,
      Length(1L),
      None,
      phase_stream(clock, backend.limits),
      None,
      true,
    )
    @async.with_task_group(group => {
      group.spawn_bg(() => {
        try reader.read_some() catch {
          @model.TransportError(kind=Timeout(..), phase=Body, ..) =>
            assert_eq(mode, 0)
          error => raise error
        } noraise {
          _ => fail("unanswered body should not finish")
        }
      })
      ignore(clock.started.get())
      if mode == 0 {
        clock.wake.signal()
      } else {
        if mode == 2 {
          try reader.read_some() catch {
            @model.TransportError(kind=Invalid, phase=Body, ..) => ()
            error => raise error
          } noraise {
            _ => fail("concurrent read accepted")
          }
          assert_eq(backend.slots.control.in_use, 1)
        }
        group.return_immediately(())
      }
    })
    assert_true(wire.closed)
    assert_eq(backend.slots.control.in_use, 0)
    assert_eq(clock.pending, 0)
    assert_eq(reader.read_some(), None)
    reader.close()
  }
}

///|
async test "closing a backend while acquiring a granted slot prevents a new dial" {
  let clock = ManualClock::new()
  let backend = H1Backend::new(trust_env=false, clock~, max_connections=1)
  backend.slots.take("occupied")
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      try
        backend.send(
          @model.Request::get("http://127.0.0.1:1"),
          @client.RequestOptions::default(),
        )
      catch {
        @model.TransportError(kind=Closed, phase=Pool, ..) => ()
        error => raise error
      } noraise {
        _ => fail("closed backend sent")
      }
    })
    ignore(clock.started.get())
    backend.slots.release("occupied")
    backend.close()
  })
  assert_eq(backend.slots.control.in_use, 0)
  assert_eq(clock.pending, 0)
}

///|
async test "a stale pooled connection retries once on a fresh connection" {
  let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  defer server.close()
  let clock = ManualClock::new()
  let backend = H1Backend::new(trust_env=false, clock~, idle_max_ms=10)
  defer backend.close()
  let url = "http://127.0.0.1:\{server.addr.port()}"
  let origin = target(@model.Request::get(url)).origin
  // Both idle sockets have been closed remotely. The retry must skip the
  // remaining cached socket and dial, rather than try both stale entries.
  for _ in 0..<2 {
    let wire = dial_wire("127.0.0.1", server.addr.port(), false)
    let (peer, _) = server.accept()
    peer.close()
    assert_eq(backend.pool.put(origin, None, wire, now=0L).length(), 0)
  }
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      group.spawn_bg(no_wait=true, () => {
        let (peer, _) = server.accept()
        defer peer.close()
        assert_true(
          peer.read_until("\r\n\r\n").unwrap().has_prefix("GET /?a=1 HTTP/1.1"),
        )
        peer.write(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
        ignore(peer.read_until("\r\n\r\n"))
        peer.write(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
      })
      let response = backend.send(
        @model.Request::get(url + "?a=1#fragment"),
        @client.RequestOptions::default(),
      )
      response.close()
      assert_eq(backend.idle_connections(), 1)
      assert_eq(backend.slots.control.in_use, 0)
      let response = backend.send(
        @model.Request::get(url),
        @client.RequestOptions::default(),
      )
      backend.close()
      response.close()
      assert_eq(backend.idle_connections(), 0)
    })
  })
}

///|
async test "expired and disabled idle pools close rejected sockets" {
  for max_idle in [0, 1] {
    let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer server.close()
    let clock = ManualClock::new()
    let backend = H1Backend::new(
      trust_env=false,
      clock~,
      idle_max_ms=10,
      max_idle_connections=max_idle,
    )
    defer backend.close()
    let url = "http://127.0.0.1:\{server.addr.port()}"
    if max_idle == 1 {
      let wire = dial_wire("127.0.0.1", server.addr.port(), false)
      let (peer, _) = server.accept()
      peer.close()
      ignore(
        backend.pool.put(
          target(@model.Request::get(url)).origin,
          None,
          wire,
          now=0L,
        ),
      )
      clock.now = 10L
    }
    @async.with_timeout(5000, () => {
      @async.with_task_group(group => {
        group.spawn_bg(no_wait=true, () => {
          let (peer, _) = server.accept()
          defer peer.close()
          ignore(peer.read_until("\r\n\r\n"))
          peer.write(b"HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\nx")
        })
        let response = backend.send(
          @model.Request::get(url),
          @client.RequestOptions::default(),
        )
        guard response.body is Stream(stream) else { fail("expected body") }
        if max_idle == 1 {
          backend.close()
        }
        assert_eq(@model.read_bounded(stream.take(), 1), b"x")
        response.close()
        assert_eq(backend.idle_connections(), 0)
        assert_eq(backend.slots.control.in_use, 0)
      })
    })
  }
}
