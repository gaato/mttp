///|
#cfg(all(not(target="wasm"), not(platform="windows")))
#warnings("-alert_internal")
async fn test_tls_server(tcp : @socket.Tcp) -> @tls.Tls {
  @tls.Tls::server(
    tcp,
    private_key_file="src/conn/testdata/localhost.key",
    private_key_type=PEM,
    certificate_file="src/conn/testdata/localhost.pem",
    certificate_type=PEM,
  )
}

///|
#cfg(all(not(target="wasm"), platform="windows"))
#warnings("-alert_internal")
async fn test_tls_server(tcp : @socket.Tcp) -> @tls.Tls {
  @tls.Tls::server(tcp, pfx_file="src/conn/testdata/localhost.pfx")
}

///|
#cfg(target="wasm")
#warnings("-alert_internal")
async fn test_tls_server(tcp : @socket.Tcp) -> @tls.Tls {
  @tls.Tls::server(
    tcp,
    private_key_file="src/conn/testdata/localhost.key",
    private_key_type=PEM,
    certificate_file="src/conn/testdata/localhost.pem",
    certificate_type=PEM,
    pfx_file="src/conn/testdata/localhost.pfx",
  )
}

///|
async test "TCP loopback pair satisfies the shared Conn contract" {
  @async.with_timeout(5000, () => {
    let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer server.close()
    let left = @conn.TcpDialer::new().connect(
      host="127.0.0.1",
      port=server.addr.port(),
    )
    defer left.close()
    let (accepted, _) = server.accept()
    let right = @socketconn.from_tcp(accepted)
    @sim.check_conn(
      left,
      right,
      coordination=@runtime.RuntimeCoordination::new(),
      suspend=() => @async.pause(),
    )
  })
}

///|
async test "dial refusal is Connect Dial and closed socket errors remain typed" {
  let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  let port = server.addr.port()
  server.close()
  try @conn.TcpDialer::new().connect(host="127.0.0.1", port~) catch {
    @mttp.TransportError(kind=Connect, phase=Dial, ..) => ()
    error => raise error
  } noraise {
    _ => fail("closed listener accepted a connection")
  }
}

///|
async test "cancelling TLS handshake propagates without closing caller owned tunnel" {
  let coordination = @runtime.RuntimeCoordination::new()
  let forever = coordination.signal()
  let inner = @sim.ScriptedConn::new([Wait(forever)])
  let clock = @runtime.VirtualClock()
  let caught = Ref(false)
  let returned = Ref(false)
  @async.with_task_group(group => {
    let task = group.spawn(() => {
      let _ = @conn.TcpDialer::new(trust=Insecure).start_tls(
        inner,
        host="localhost",
      ) catch {
        _ => {
          caught.val = true
          inner
        }
      }
      returned.val = true
    })
    clock.settle(until=() => inner.written().length() > 0)
    task.cancel()
    task.wait() catch {
      @async.WaitedTaskAlreadyCancelled => ()
      error => raise error
    }
  })
  assert_false(caught.val)
  assert_false(returned.val)
  assert_eq(inner.closes(), 0)
  inner.close()
  assert_eq(inner.closes(), 1)
}

///|
priv struct Tunnel {
  inner : &@rt.Conn
  closes : Ref[Int32]
}

///|
impl @rt.Conn for Tunnel with fn read(self, max_len~) {
  self.inner.read(max_len~)
}

///|
impl @rt.Conn for Tunnel with fn write(self, bytes) {
  self.inner.write(bytes)
}

///|
impl @rt.Conn for Tunnel with fn close(self) {
  self.closes.val += 1
  self.inner.close()
}

///|
async test "TLS upgrades arbitrary Conn tunnels with custom and insecure trust and owns success" {
  for
    trust in [
      @trust.Trust::PemFile("src/conn/testdata/localhost.pem"),
      Insecure,
    ] {
    @async.with_timeout(5000, () => {
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let tcp = @conn.TcpDialer::new().connect(
        host="127.0.0.1",
        port=server.addr.port(),
      )
      let closes = Ref(0)
      let tunnel = Tunnel::{ inner: tcp, closes, }
      defer tcp.close()
      let (accepted, _) = server.accept()
      defer accepted.close()
      @async.with_task_group(group => {
        group.spawn_bg(() => {
          let peer = test_tls_server(accepted)
          defer peer.close()
          assert_eq(peer.read_exactly(4), b"ping")
          peer.write(b"pong")
          peer.shutdown()
        })
        let secured = @conn.TcpDialer::new(trust~).start_tls(
          tunnel,
          host="localhost",
        )
        secured.write(b"ping")
        let output = Buffer()
        while secured.read(max_len=2) is Some(bytes) {
          output.write_bytes(bytes)
        }
        assert_eq(output.to_bytes(), b"pong")
        assert_eq(secured.read(max_len=1), None)
        secured.close()
        secured.close()
        assert_eq(closes.val, 1)
      })
    })
  }
}

///|
async test "TLS verification failure leaves tunnel owned by caller" {
  for
    (trust, host) in [
      (@trust.Trust::System, "localhost"),
      (PemFile("src/conn/testdata/localhost.pem"), "wrong.invalid"),
    ] {
    @async.with_timeout(5000, () => {
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let tcp = @conn.TcpDialer::new().connect(
        host="127.0.0.1",
        port=server.addr.port(),
      )
      defer tcp.close()
      let closes = Ref(0)
      let tunnel = Tunnel::{ inner: tcp, closes, }
      let (accepted, _) = server.accept()
      defer accepted.close()
      @async.with_task_group(group => {
        group.spawn_bg(no_wait=true, allow_failure=true, () => {
          let peer = test_tls_server(accepted)
          defer peer.close()
          let _ = peer.read()
        })
        try @conn.TcpDialer::new(trust~).start_tls(tunnel, host~) catch {
          @mttp.TransportError(kind=Connect, phase=Dial, ..) => ()
          error => raise error
        } noraise {
          _ => fail("certificate verification did not fail")
        }
        assert_eq(closes.val, 0)
        @rt.Conn::close(tunnel)
        assert_eq(closes.val, 1)
      })
    })
  }
}
