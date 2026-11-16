///|
async test "socket upgrade holds its only admission slot past the handler deadline" {
  let entered = Ref(false)
  let release = Ref(false)
  let finished = Ref(false)
  with_server(
    request => {
      if request.headers.contains("upgrade") {
        @ws.upgrade(request, handler=session => {
          entered.val = true
          assert_eq(session.recv(), Text("hello"))
          while !release.val {
            @async.sleep(1)
          }
          session.send(Text("hello"))
          session.close({ code: Normal, reason: "", })
        })
      } else {
        finished.val = true
        @mttp_core.Response::new(204)
      }
    },
    address => {
      let tcp = @socket.Tcp::connect(@socket.Addr::parse(address))
      defer tcp.close()
      // Handshake and a masked text frame in the same write test read-ahead.
      tcp.write(
        b"GET / HTTP/1.1\r\nHost: x\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n\x81\x85\x00\x00\x00\x00hello",
      )
      let out = Buffer()
      while !out.to_bytes().has_suffix(b"\r\n\r\n") {
        out.write_bytes(tcp.read().unwrap())
      }
      assert_true(out.to_bytes().has_prefix(b"HTTP/1.1 101 "))
      @async.with_task_group(group => {
        let second = group.spawn(() => {
          ignore(
            raw(
              address, b"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
            ),
          )
        })
        @async.sleep(40)
        assert_true(entered.val)
        assert_false(finished.val)
        release.val = true
        let bytes = tcp.read().unwrap()
        assert_true(bytes.has_prefix(b"\x81\x05hello"))
        // Masked Close(1000) acknowledges the server's closing handshake.
        tcp.write(b"\x88\x82\x00\x00\x00\x00\x03\xe8")
        second.wait()
        assert_true(finished.val)
      })
    },
    limits={
      ..@h1server.ServerLimits::default(),
      max_connections: 1,
      handler_timeout_ms: Some(20),
    },
  )
}

///|
async test "upgraded sockets send 1001 on stop and are closed at drain expiry" {
  for drain in [40, 400] {
    let cleaned = Ref(false)
    controllable(
      request => {
        @ws.upgrade(request, handler=session => {
          defer {
            cleaned.val = true
          }
          ignore(session.recv())
        })
      },
      { ..@h1server.ServerLimits::default(), drain_ms: drain, },
      (address, server) => {
        let tcp = @socket.Tcp::connect(@socket.Addr::parse(address))
        defer tcp.close()
        tcp.write(
          b"GET / HTTP/1.1\r\nHost: x\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n",
        )
        assert_true(
          tcp.read_until(b"\r\n\r\n").unwrap().has_prefix(b"HTTP/1.1 101 "),
        )
        server.cancel()
        // The default session close wait is 5 s, so the listener's drain
        // deadline must end this silent peer first.
        @async.with_timeout(drain + 1000, () => stopped(server))
        let out = Buffer()
        while tcp.read() is Some(bytes) {
          out.write_bytes(bytes)
        }
        if drain > 250 {
          assert_eq(out.to_bytes(), b"\x88\x02\x03\xe9")
        }
        assert_true(cleaned.val)
      },
    )
  }
}
