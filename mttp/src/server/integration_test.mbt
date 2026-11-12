///|
async fn with_server(
  handler : @mttp_core.Handler,
  run : async (String) -> Unit,
  limits~ : @h1server.ServerLimits = @h1server.ServerLimits::default(),
  on_error~ : (@mttp_core.TransportError) -> Unit = _ => (),
  addr~ : String = "127.0.0.1:0",
) -> Unit {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let ready : Ref[String?] = Ref(None)
      let wake = @cond_var.Cond()
      group.spawn_bg(no_wait=true, () => {
        @server.serve(handler, addr~, limits~, on_error~, on_listen=address => {
          ready.val = Some(address)
          wake.signal()
        })
      })
      while ready.val is None {
        wake.wait()
      }
      run(ready.val.unwrap())
      group.return_immediately()
    })
  })
}

///|
async fn raw(address : String, bytes : Bytes) -> String {
  let tcp = @socket.Tcp::connect(@socket.Addr::parse(address))
  defer tcp.close()
  tcp.write(bytes)
  let out = Buffer()
  while tcp.read() is Some(bytes) {
    out.write_bytes(bytes)
    assert_true(out.length() <= 1048576)
  }
  @utf8.decode(out.to_bytes())
}

///|
async test "configuration is rejected before binding or calling on_listen" {
  let defaults = @h1server.ServerLimits::default()
  assert_eq(defaults.max_connections, 256)
  assert_eq(defaults.drain_ms, 10000)
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
    let called = Ref(false)
    try
      @server.serve(
        _ => @mttp_core.Response::new(200),
        addr="invalid",
        limits~,
        on_listen=_ => called.val = true,
      )
    catch {
      @server.Config(_) => ()
      error => raise error
    } noraise {
      _ => fail("invalid configuration accepted")
    }
    assert_false(called.val)
  }
  // The parser's own error has no text, so the detail says what is expected;
  // an unknown IPv6 zone is a system error, whose text is kept.
  for
    invalid, cause in {
      "invalid": "expected an IP address and port",
      "127.0.0.1:99999": "expected an IP address and port",
      "[fe80::1%nosuchif0]:80": "nosuchif0",
    } {
    try @server.serve(_ => @mttp_core.Response::new(200), addr=invalid) catch {
      @server.Bind(detail~) => {
        assert_true(
          detail.has_prefix("invalid address \"\{invalid}\": "),
          msg=detail,
        )
        assert_true(detail.contains(cause), msg=detail)
      }
      error => raise error
    } noraise {
      _ => fail("invalid bind succeeded")
    }
  }
}

///|
async test "a bind failure names the address and the operating system's cause" {
  // Bound without SO_REUSEADDR: no listener may share an active port.
  let occupied = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  defer occupied.close()
  let address = occupied.addr.to_string()
  try @server.serve(_ => @mttp_core.Response::new(200), addr=address) catch {
    @server.Bind(detail~) => {
      assert_true(detail.has_prefix("could not bind \{address}: "), msg=detail)
      // strerror(EADDRINUSE): "Address already in use", or musl's
      // "Address in use".
      assert_true(detail.contains("in use"), msg=detail)
    }
    error => raise error
  } noraise {
    _ => fail("occupied bind succeeded")
  }
}

///|
async test "a restart binds the port while the last server's connection is in TIME-WAIT" {
  let address = Ref("")
  with_server(_ => @mttp_core.Response::new(200, body=Bytes(b"first")), bound => {
    address.val = bound
    // The server closes first, so its side of the connection, on the
    // listening port, goes to TIME-WAIT.
    let response = raw(
      bound, b"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
    )
    assert_true(response.has_prefix("HTTP/1.1 200"), msg=response)
    assert_true(response.has_suffix("first"), msg=response)
  })
  with_server(
    _ => @mttp_core.Response::new(200, body=Bytes(b"second")),
    addr=address.val,
    bound => {
      assert_eq(bound, address.val)
      let response = raw(
        bound, b"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
      )
      assert_true(response.has_suffix("second"), msg=response)
    },
  )
}

///|
async test "bound address peer metadata and repeated keep alive requests roundtrip" {
  let calls = Ref(0)
  with_server(
    request => {
      calls.val += 1
      assert_true(
        request.attributes
        .get(@mttp_core.remote_addr)
        .unwrap()
        .has_prefix("127.0.0.1:"),
      ) catch {
        _ => abort("peer address missing")
      }
      @mttp_core.Response::new(
        200,
        body=Bytes(@mttp_core.encode_utf8(request.url)),
      )
    },
    address => {
      assert_false(address.has_suffix(":0"))
      let tcp = @socket.Tcp::connect(@socket.Addr::parse(address))
      defer tcp.close()
      for i in 0..<3 {
        tcp.write(
          @mttp_core.encode_utf8(
            "GET /\{i} HTTP/1.1\r\nHost: example.test\r\n\r\n",
          ),
        )
        let head = @utf8.decode(tcp.read_until(b"\r\n\r\n").unwrap())
        assert_true(head.has_prefix("HTTP/1.1 200"))
        assert_false(head.to_lower().contains("connection: close"))
        let expected = @mttp_core.encode_utf8("http://example.test/\{i}")
        assert_eq(tcp.read_exactly(expected.length()), expected)
      }
      assert_eq(calls.val, 3)
    },
  )
}

///|
async test "32 slow header connections expire and release admission slots" {
  let handled = Ref(0)
  with_server(
    _ => {
      handled.val += 1
      @mttp_core.Response::new(200)
    },
    address => {
      @async.with_task_group(group => {
        let clients : Array[@socket.Tcp] = []
        defer (for tcp in clients {
          tcp.close()
        })
        for _ in 0..<32 {
          let tcp = @socket.Tcp::connect(@socket.Addr::parse(address))
          clients.push(tcp)
          tcp.write(b"GET / HTTP/1.1\r\nHost:")
        }
        let readers = clients.map(tcp => {
          group.spawn(() => {
            assert_true(
              tcp.read_until(b"\r\n\r\n").unwrap().has_prefix(b"HTTP/1.1 408"),
            )
          })
        })
        for reader in readers {
          reader.wait()
        }
      })
      assert_eq(handled.val, 0)
      assert_true(
        raw(address, b"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n").has_prefix(
          "HTTP/1.1 200",
        ),
      )
      assert_eq(handled.val, 1)
    },
    limits={
      ..@h1server.ServerLimits::default(),
      max_connections: 32,
      header_timeout_ms: 500,
    },
  )
}

///|
async test "concurrent background jobs report failures and remain owned after the response" {
  let started = Ref(0)
  let release = Ref(false)
  let cleaned = Ref(0)
  let errors : Array[@mttp_core.TransportError] = []
  let wake = @cond_var.Cond()
  with_server(
    request => {
      let schedule = request.attributes.get(@mttp_core.background).unwrap()
      for job in 0..<2 {
        schedule(() => {
          defer {
            cleaned.val += 1
          }
          started.val += 1
          wake.broadcast()
          while !release.val {
            wake.wait()
          }
          if job == 0 {
            raise Failure("private application detail")
          } else {
            raise @mttp_core.TransportError(
              kind=Timeout(ms=7),
              phase=Body,
              detail="original",
            )
          }
        })
      }
      @mttp_core.Response::new(204)
    },
    address => {
      assert_true(
        raw(address, b"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n").has_prefix(
          "HTTP/1.1 204",
        ),
      )
      while started.val < 2 {
        wake.wait()
      }
      assert_eq(cleaned.val, 0)
      release.val = true
      wake.broadcast()
      while errors.length() < 2 {
        wake.wait()
      }
      assert_eq(cleaned.val, 2)
      assert_true(
        errors
        .iter()
        .any(error => error is @mttp_core.TransportError(phase=Unknown, ..)),
      )
      assert_true(
        errors
        .iter()
        .any(error => {
          let @mttp_core.TransportError(kind~, phase~, detail~) = error
          (kind, phase, detail) == (Timeout(ms=7), Body, "original")
        }),
      )
      assert_false(errors[0].message().contains("private application detail"))
    },
    on_error=error => {
      errors.push(error)
      wake.broadcast()
    },
  )
}

///|
async test "shutdown waits for background completion and ignores scheduling after it returns" {
  let started = Ref(false)
  let release = Ref(false)
  let finished = Ref(false)
  let schedule : Ref[((async () -> Unit) -> Unit)?] = Ref(None)
  let wake = @cond_var.Cond()
  controllable(
    request => {
      schedule.val = request.attributes.get(@mttp_core.background)
      schedule.val.unwrap()(() => {
        started.val = true
        wake.broadcast()
        while !release.val {
          wake.wait()
        }
        finished.val = true
      })
      @mttp_core.Response::new(204)
    },
    { ..@h1server.ServerLimits::default(), drain_ms: 1000, },
    (address, server) => {
      ignore(
        raw(address, b"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"),
      )
      while !started.val {
        wake.wait()
      }
      server.cancel()
      @async.pause()
      assert_false(finished.val)
      release.val = true
      wake.broadcast()
      stopped(server)
      assert_true(finished.val)
    },
  )
  let late = Ref(false)
  schedule.val.unwrap()(() => late.val = true)
  @async.pause()
  assert_false(late.val)
}

///|
async test "shutdown closes an idle keep alive connection without waiting for its head deadline" {
  controllable(
    _ => @mttp_core.Response::new(204),
    {
      ..@h1server.ServerLimits::default(),
      drain_ms: 10000,
      header_timeout_ms: 10000,
    },
    (address, server) => {
      let tcp = @socket.Tcp::connect(@socket.Addr::parse(address))
      defer tcp.close()
      tcp.write(b"GET / HTTP/1.1\r\nHost: x\r\n\r\n")
      assert_true(
        tcp.read_until(b"\r\n\r\n").unwrap().has_prefix(b"HTTP/1.1 204"),
      )
      @async.pause()
      @async.with_timeout(500, () => {
        server.cancel()
        stopped(server)
        assert_eq(tcp.read(), None)
      })
    },
  )
}

///|
async test "shutdown cancels admission waiting behind a full connection cap" {
  controllable(
    _ => @mttp_core.Response::new(204),
    {
      ..@h1server.ServerLimits::default(),
      max_connections: 1,
      header_timeout_ms: 10000,
    },
    (address, server) => {
      let first = @socket.Tcp::connect(@socket.Addr::parse(address))
      defer first.close()
      first.write(b"GET / HTTP/1.1\r\nHost: x\r\n\r\n")
      assert_true(
        first.read_until(b"\r\n\r\n").unwrap().has_prefix(b"HTTP/1.1 204"),
      )
      let second = @socket.Tcp::connect(@socket.Addr::parse(address))
      defer second.close()
      second.write(b"GET / HTTP/1.1\r\nHost: x\r\n\r\n")
      @async.with_timeout(500, () => {
        server.cancel()
        stopped(server)
        assert_eq(first.read(), None)
      })
    },
  )
}

///|
async test "background work scheduled during expiry cleanup is cancelled and joined" {
  let started = Ref(false)
  let child_started = Ref(false)
  let child_cleaned = Ref(false)
  let wake = @cond_var.Cond()
  controllable(
    request => {
      let schedule = request.attributes.get(@mttp_core.background).unwrap()
      schedule(() => {
        defer schedule(() => {
          defer {
            child_cleaned.val = true
          }
          child_started.val = true
          @cond_var.Cond().wait()
        })
        started.val = true
        wake.broadcast()
        @cond_var.Cond().wait()
      })
      @mttp_core.Response::new(204)
    },
    { ..@h1server.ServerLimits::default(), drain_ms: 0, },
    (address, server) => {
      ignore(
        raw(address, b"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"),
      )
      while !started.val {
        wake.wait()
      }
      server.cancel()
      stopped(server)
      assert_true(child_started.val)
      assert_true(child_cleaned.val)
    },
  )
}
