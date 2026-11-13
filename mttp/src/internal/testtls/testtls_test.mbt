///|
const KEY : String = "src/conn/testdata/localhost.key"

///|
const CERT : String = "src/conn/testdata/localhost.pem"

///|
/// Runs `server` on each connection to a loopback listener and hands
/// `client` a core TLS client connected to it.
#cfg(not(platform="windows"))
async fn with_pair(
  server : async (@testtls.TestTls) -> Unit,
  client : async (@tls.Tls, @socket.Tcp) -> Unit,
) -> Unit {
  @async.with_timeout(5000, () => {
    let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer listener.close()
    @async.with_task_group(group => {
      group.spawn_bg(() => {
        let (tcp, _) = listener.accept()
        let tls = @testtls.accept(
          @socketconn.from_tcp(tcp),
          key_file=KEY,
          cert_file=CERT,
        )
        defer tls.close()
        server(tls)
      })
      let tcp = @socket.Tcp::connect(listener.addr)
      defer tcp.close()
      let tls = @tls.Tls::client(
        tcp,
        host="localhost",
        trust=CustomPemFile(CERT),
      )
      defer tls.close()
      client(tls, tcp)
    })
  })
}

///|
#cfg(not(platform="windows"))
async test "a core TLS client talks to the test server both ways" {
  // Larger than the engine's buffers, so ciphertext waits in the engine.
  let big = Bytes::make(300000, b'x')
  with_pair(
    tls => {
      assert_eq(tls.read_until(b"\r\n"), Some(b"ping"))
      assert_eq(tls.read_exactly(big.length()), big)
      tls.write(b"pong")
      tls.write(big)
      tls.shutdown()
      try tls.write(b"late") catch {
        @mttp_core.TransportError(kind=Closed, phase=Write, ..) => ()
        error => raise error
      } noraise {
        _ => fail("the write after shutdown succeeded")
      }
      // The client answers close_notify with its own; closing before it
      // arrives would fail that write.
      assert_eq(tls.read(), None)
    },
    (tls, _) => {
      tls.write(b"ping\r\n")
      tls.write(big)
      assert_eq(tls.read_exactly(4), b"pong")
      assert_eq(tls.read_exactly(big.length()), big)
      assert_eq(tls.read_all().length(), 0)
    },
  )
}

///|
async test "a bad key file fails to start and closes the connection" {
  let inner = @sim.ScriptedConn::new([])
  try
    @testtls.accept(inner, key_file="no/such/key", cert_file=CERT) |> ignore
  catch {
    @mttp_core.TransportError(kind~, ..) => assert_eq(kind, Invalid)
  } noraise {
    _ => fail("the session started")
  }
  assert_eq(inner.closes(), 1)
}

///|
#cfg(not(platform="windows"))
async test "a client that leaves or breaks the handshake fails accept" {
  for
    (steps, detail) in [
      ([], "the client closed the connection during the handshake"),
      ([@sim.ReadStep::Chunk(b"GET / HTTP/1.1\r\n\r\n")], "TLS handshake: "),
    ] {
    let inner = @sim.ScriptedConn::new(steps)
    try @testtls.accept(inner, key_file=KEY, cert_file=CERT) |> ignore catch {
      @mttp_core.TransportError(kind=Network, detail=got, ..) =>
        assert_true(got.has_prefix(detail), msg=got)
      error => raise error
    } noraise {
      _ => fail("the session started")
    }
    assert_eq(inner.closes(), 1)
  }
}

///|
#cfg(not(platform="windows"))
async test "a client that closes early ends read_until and fails read_exactly" {
  with_pair(
    tls => {
      assert_eq(tls.read_until(b"\r\n"), None)
      // What read_until saw stays for the next read.
      try tls.read_exactly(20) |> ignore catch {
        @mttp_core.TransportError(kind=Network, detail~, ..) =>
          assert_eq(detail, "EOF after 11 of 20 bytes")
        error => raise error
      } noraise {
        _ => fail("read_exactly returned")
      }
    },
    (tls, _) => {
      tls.write(b"no line end")
      tls.shutdown()
    },
  )
}

///|
#cfg(not(platform="windows"))
async test "a broken record fails the read" {
  with_pair(
    tls => {
      try tls.read() |> ignore catch {
        @mttp_core.TransportError(kind=Network, detail~, ..) =>
          assert_true(detail.has_prefix("TLS read: "), msg=detail)
        error => raise error
      } noraise {
        _ => fail("the broken record was read")
      }
    },
    (_, tcp) => {
      // An application-data record header announcing 5 bytes, then 5 bytes
      // that no key decrypts.
      tcp.write(b"\x17\x03\x03\x00\x05hello")
      ignore(tcp.read_all())
    },
  )
}
