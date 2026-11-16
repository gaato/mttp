///|
async test "connect echoes masked messages over an independent TCP peer and negotiates subprotocol" {
  for default_backend in [false, true] {
    @async.with_timeout(5000, () => {
      let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer listener.close()
      @async.with_task_group(group => {
        let peer = group.spawn(() => {
          let (tcp, _) = listener.accept()
          defer tcp.close()
          let head = @utf8.decode(tcp.read_until(b"\r\n\r\n").unwrap())
          let mut key = ""
          for line in head.split("\r\n") {
            if line.to_lower().has_prefix("sec-websocket-key:") {
              key = line[18:].trim().to_owned()
            }
          }
          assert_false(key.is_empty())
          assert_true(head.contains("sec-websocket-protocol: echo"))
          // A real TCP peer, with no mttp server or Session implementation.
          tcp.write(
            @utf8.encode(
              "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: \{@handshake.accept_value(key)}\r\nSec-WebSocket-Protocol: echo\r\n\r\n",
            ) +
            b"\x81\x05hello",
          )
          let frame = tcp.read_exactly(11)
          assert_eq(frame[0], 0x81)
          assert_eq(frame[1], 0x85)
          let payload = Bytes::makei(5, i => frame[6 + i] ^ frame[2 + i % 4])
          assert_eq(payload, b"world")
          tcp.write(b"\x81\x05" + payload)
          let close = tcp.read_exactly(8)
          assert_eq(close[0], 0x88)
          assert_eq(close[1], 0x82)
          tcp.write(b"\x88\x02\x03\xe8")
        })
        let backend = @backend.AsyncBackend::new(
          config=@h1client.ClientConfig::default(),
        )
        defer backend.close()
        let url = "ws://\{listener.addr}/echo"
        let session = if default_backend {
          @ws.connect(url, subprotocols=["echo"])
        } else {
          @ws.connect(url, backend~, subprotocols=["echo"])
        }
        defer session.abort()
        assert_eq(session.subprotocol(), Some("echo"))
        assert_eq(session.recv(), Text("hello"))
        session.send(Text("world"))
        assert_eq(session.recv(), Text("world"))
        session.close({ code: Normal, reason: "", })
        peer.wait()
      })
    })
  }
}
