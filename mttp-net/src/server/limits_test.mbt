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
    @server.Bind(..) => true
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
