///|
async test "configuration is rejected before binding or calling on_listen" {
  let defaults = @server.ServerLimits::default()
  assert_eq(defaults.max_body_bytes, 1048576)
  assert_eq(defaults.header_timeout_ms, 5000)
  assert_eq(defaults.body_timeout_ms, 5000)
  assert_eq(defaults.max_header_bytes, 16384)
  assert_eq(defaults.max_connections, 256)
  assert_eq(defaults.drain_max_bytes, 65536)
  assert_eq(defaults.handler_timeout_ms, None)
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
    let failed = try {
      @server.serve(
        _ => @model.Response::new(200),
        addr="127.0.0.1:0",
        limits~,
        on_listen=_ => called.val = true,
      )
      false
    } catch {
      _ => true
    }
    assert_true(failed)
    assert_false(called.val)
  }
  let failed = try {
    @server.serve(_ => @model.Response::new(200), addr="invalid")
    false
  } catch {
    @server.ServerConfigError::Bind(..) => true
    _ => false
  }
  assert_true(failed)
}

///|
async test "header body and handler deadlines terminate their exchange" {
  let handler : @model.Handler = req => {
    if req.url.has_suffix("/slow") {
      @async.sleep(10000)
    }
    ignore(@client.read_body(req.body, 1024) catch { _ => b"" })
    @model.Response::new(200)
  }
  with_server(
    handler,
    address => {
      assert_true(
        raw(address, b"GET / HTTP/1.1\r\nHost:").has_prefix("HTTP/1.1 408"),
      )
      assert_true(
        raw(address, b"POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 1\r\n\r\n").has_prefix(
          "HTTP/1.1 408",
        ),
      )
      assert_true(
        raw(address, b"GET /slow HTTP/1.1\r\nHost: x\r\n\r\n").has_prefix(
          "HTTP/1.1 504",
        ),
      )
    },
    limits={
      ..@server.ServerLimits::default(),
      header_timeout_ms: 30,
      body_timeout_ms: 30,
      handler_timeout_ms: Some(200),
    },
  )
}

///|
async test "trickling request bytes do not renew the body deadline" {
  with_server(
    request => {
      ignore(@client.read_body(request.body, 1024) catch { _ => b"" })
      @model.Response::new(200)
    },
    address => {
      let tcp = @socket.Tcp::connect(@socket.Addr::parse(address))
      defer tcp.close()
      tcp.write(b"POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\n\r\n")
      @async.with_task_group(group => {
        let sent = Ref(0)
        let producer = group.spawn(no_wait=true, () => {
          for _ in 0..<10 {
            @async.sleep(40)
            tcp.write(b"x") catch {
              _ => return
            }
            sent.val += 1
          }
        })
        let response = tcp.read_until("\r\n\r\n").unwrap()
        assert_true(response.has_prefix("HTTP/1.1 408"))
        assert_true(sent.val < 10)
        producer.cancel()
        producer.wait() catch {
          _ => ()
        }
      })
    },
    limits={ ..@server.ServerLimits::default(), body_timeout_ms: 160, },
  )
}

///|
async test "32 slow header connections expire and release admission slots" {
  let handled = Ref(0)
  with_server(
    _ => {
      handled.val += 1
      @model.Response::new(200)
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
            let response = tcp.read_until("\r\n\r\n").unwrap()
            assert_true(response.has_prefix("HTTP/1.1 408"))
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
      ..@server.ServerLimits::default(),
      max_connections: 32,
      header_timeout_ms: 500,
    },
  )
}

///|
async test "Expect continue is lazy and oversized chunked bodies override caught read failures" {
  let handler : @model.Handler = req => {
    if req.headers.get("authorization") is None {
      return @model.Response::new(401)
    }
    let bytes = @client.read_body(req.body, 1024) catch { _ => b"caught" }
    @model.Response::new(200, body=Bytes(bytes))
  }
  with_server(
    handler,
    address => {
      let denied = raw(
        address, b"POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\nExpect: 100-continue\r\n\r\n",
      )
      assert_true(denied.has_prefix("HTTP/1.1 401"))
      assert_false(denied.contains("100 Continue"))
      let tcp = @socket.Tcp::connect(@socket.Addr::parse(address))
      defer tcp.close()
      tcp.write(
        b"POST / HTTP/1.1\r\nHost: x\r\nAuthorization: yes\r\nContent-Length: 3\r\nExpect: 100-continue\r\nConnection: close\r\n\r\n",
      )
      assert_eq(tcp.read_until("\r\n\r\n"), Some("HTTP/1.1 100 Continue"))
      tcp.write(b"abc")
      let result = Buffer()
      while tcp.read_some(max_len=4096) is Some(bytes) {
        result.write_bytes(bytes)
      }
      assert_true(@utf8.decode(result.to_bytes()).has_suffix("abc"))
      assert_true(
        raw(
          address, b"POST / HTTP/1.1\r\nHost: x\r\nAuthorization: yes\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nabcd\r\n0\r\n\r\n",
        ).has_prefix("HTTP/1.1 413"),
      )
    },
    limits={ ..@server.ServerLimits::default(), max_body_bytes: 3, },
  )
}

///|
async test "repeated header and chunk-line floods stay bounded and leave the server usable" {
  with_server(
    request => {
      ignore(@client.read_body(request.body, 1048576) catch { _ => b"" })
      @model.Response::new(200)
    },
    address => {
      for
        (wire, status) in [
          (
            b"GET / HTTP/1.1\r\nHost: x\r\n" +
            @model.encode_utf8("x: a\r\n".repeat(4096)),
            "431",
          ),
          (
            b"POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n1;" +
            Bytes::make(8193, b'x'),
            "400",
          ),
        ] {
        for _ in 0..<32 {
          let tcp = @socket.Tcp::connect(@socket.Addr::parse(address))
          defer tcp.close()
          tcp.write(wire)
          let response = tcp.read_until("\r\n\r\n").unwrap()
          assert_true(response.has_prefix("HTTP/1.1 " + status))
        }
      }
      assert_true(
        raw(address, b"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n").has_prefix(
          "HTTP/1.1 200",
        ),
      )
    },
  )
}
