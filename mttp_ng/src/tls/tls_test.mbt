// TLS sessions over an in-memory pair: handshakes, ALPN, trust, both kinds
// of close and the Conn rules, with the test root and localhost certificate
// of mttp_ng/testdata (scripts/gen_curl_test_certs.sh).

///|
async fn testdata(name : String) -> String {
  // The tests run from the package, the module or the workspace.
  for dir in ["../../testdata", "testdata", "mttp_ng/testdata"] {
    if @fs.exists("\{dir}/\{name}") {
      return @fs.realpath("\{dir}/\{name}")
    }
  }
  fail("no testdata/\{name} below the working directory")
}

///|
async fn server_tls(
  alpn~ : Array[String] = ["h2", "http/1.1"],
) -> @tls.ServerTls {
  @tls.ServerTls::from_pem(
    chain=@fs.read_text(testdata("localhost.pem")),
    key=@fs.read_text(testdata("localhost.key")),
    alpn~,
  )
}

///|
async fn trusted(alpn~ : Array[String] = ["h2", "http/1.1"]) -> @tls.ClientTls {
  @tls.ClientTls::new(trust=PemFile(testdata("root.pem")), alpn~)
}

///|
/// A connected pair of sessions: the client's for `host`, and the server's.
async fn sessions(
  client : @tls.ClientTls,
  server : @tls.ServerTls,
  host~ : String = "localhost",
) -> (@tls.TlsConn, @tls.TlsConn) {
  let coordination = @runtime.RuntimeCoordination::new()
  let (left, right) = @sim.pair(coordination)
  let accepted : Ref[@tls.TlsConn?] = Ref(None)
  let connected : Ref[@tls.TlsConn?] = Ref(None)
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      accepted.val = Some(server.accept(right, coordination~))
    })
    connected.val = Some(client.connect(left, host~, coordination~))
  })
  (connected.val.unwrap(), accepted.val.unwrap())
}

///|
/// The failure of a client handshake for `host`, with the server's failure
/// ignored.
async fn handshake_failure(
  client : @tls.ClientTls,
  host~ : String = "localhost",
) -> @mttp_core.TransportError {
  let server = server_tls()
  let coordination = @runtime.RuntimeCoordination::new()
  let (left, right) = @sim.pair(coordination)
  defer left.close()
  defer right.close()
  let failure : Ref[@mttp_core.TransportError?] = Ref(None)
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      ignore(server.accept(right, coordination~)) catch {
        _ => ()
      }
      right.close()
    })
    try client.connect(left, host~, coordination~) catch {
      @mttp_core.TransportError(..) as error => {
        // The failed handshake leaves `left` to us; closing it ends the
        // server's wait for the next flight.
        left.close()
        failure.val = Some(error)
      }
    } noraise {
      conn => {
        conn.close()
        fail("the handshake for \{host} succeeded")
      }
    }
  })
  failure.val.unwrap()
}

///|
async test "a handshake chooses h2 by ALPN and moves bytes both ways" {
  @async.with_timeout(10000, () => {
    let (client, server) = sessions(trusted(), server_tls())
    defer client.close()
    defer server.close()
    assert_eq(client.alpn(), Some("h2"))
    assert_eq(server.alpn(), Some("h2"))
    assert_eq(client.version(), "TLSv1.3")
    client.write(b"PRI * HTTP/2.0")
    assert_eq(server.read(max_len=3), Some(b"PRI"))
    assert_eq(server.read(max_len=64), Some(b" * HTTP/2.0"))
    server.write(b"ok")
    assert_eq(client.read(max_len=64), Some(b"ok"))
  })
}

///|
async test "the server's preference decides, and no common protocol means no ALPN" {
  @async.with_timeout(10000, () => {
    let (client, server) = sessions(
      trusted(alpn=["http/1.1", "h2"]),
      server_tls(),
    )
    assert_eq(client.alpn(), Some("h2"))
    client.close()
    server.close()
    let (client, server) = sessions(trusted(alpn=["http/1.1"]), server_tls())
    assert_eq(client.alpn(), Some("http/1.1"))
    client.close()
    server.close()
    let (client, server) = sessions(trusted(alpn=["spdy/3"]), server_tls())
    assert_eq(client.alpn(), None)
    assert_eq(server.alpn(), None)
    client.close()
    server.close()
    let (client, server) = sessions(trusted(alpn=[]), server_tls())
    assert_eq(client.alpn(), None)
    client.close()
    server.close()
  })
}

///|
async test "certificates are checked against the trust and the host" {
  @async.with_timeout(10000, () => {
    // The system's roots do not include the test root.
    let error = handshake_failure(@tls.ClientTls::new())
    guard error is @mttp_core.TransportError(kind=Connect, phase=Dial, detail~) else {
      fail("unexpected \{error}")
    }
    assert_true(detail.contains("certificate verify failed"))
    // The test root, but a name the certificate does not carry.
    let error = handshake_failure(trusted(), host="example.com")
    guard error is @mttp_core.TransportError(kind=Connect, phase=Dial, ..) else {
      fail("unexpected \{error}")
    }
    // An address the certificate carries, and Insecure for any name.
    let (client, server) = sessions(trusted(), server_tls(), host="127.0.0.1")
    client.close()
    server.close()
    let (client, server) = sessions(
      @tls.ClientTls::new(trust=Insecure),
      server_tls(),
      host="example.com",
    )
    client.close()
    server.close()
    // An unreadable PEM file fails each handshake the same way.
    let error = handshake_failure(
      @tls.ClientTls::new(trust=PemFile("/nonexistent/root.pem")),
    )
    guard error is @mttp_core.TransportError(kind=Connect, phase=Dial, ..) else {
      fail("unexpected \{error}")
    }
  })
}

///|
async test "shutdown ends the peer's reads with EOF, close with IncompleteClose" {
  @async.with_timeout(10000, () => {
    let (client, server) = sessions(trusted(), server_tls())
    client.write(b"last")
    client.shutdown()
    assert_eq(server.read(max_len=64), Some(b"last"))
    assert_eq(server.read(max_len=64), None)
    assert_eq(server.read(max_len=64), None)
    // A session the peer shut down refuses writes, having sent nothing.
    try server.write(b"x") catch {
      @mttp_core.TransportError(kind~, ..) => assert_eq(kind, Closed)
    } noraise {
      _ => fail("a write after the peer's close_notify succeeded")
    }
    client.close()
    server.close()
    let (client, server) = sessions(trusted(), server_tls())
    client.close()
    for _ in 0..<2 {
      try server.read(max_len=64) catch {
        @mttp_core.TransportError(kind~, ..) => assert_eq(kind, IncompleteClose)
      } noraise {
        _ => fail("a read after an unclean close did not raise")
      }
    }
    server.close()
  })
}

///|
async test "a read and a write run at the same time, and a large write arrives whole" {
  @async.with_timeout(10000, () => {
    let (client, server) = sessions(trusted(), server_tls())
    defer client.close()
    defer server.close()
    let big = Bytes::makei(200000, i => (i % 251).to_byte())
    let received = Buffer()
    @async.with_task_group(group => {
      // The client waits to read while it writes; the server answers only
      // after the whole write arrived.
      group.spawn_bg(() => {
        while received.length() < big.length() {
          guard server.read(max_len=65536) is Some(chunk) else {
            fail("EOF before the whole write")
          }
          received.write_bytes(chunk)
        }
        server.write(b"done")
      })
      group.spawn_bg(() => assert_eq(client.read(max_len=64), Some(b"done")))
      client.write(big)
    })
    assert_true(received.to_bytes() == big)
  })
}

///|
async test "a cancelled read loses nothing, and a closed session refuses use" {
  @async.with_timeout(10000, () => {
    let (client, server) = sessions(trusted(), server_tls())
    defer server.close()
    let timed_out = try {
      @async.with_timeout(50, () => ignore(client.read(max_len=64)))
      false
    } catch {
      _ => true
    }
    assert_true(timed_out)
    server.write(b"after")
    assert_eq(client.read(max_len=64), Some(b"after"))
    client.close()
    client.close()
    try client.write(b"x") catch {
      @mttp_core.TransportError(kind~, ..) => assert_eq(kind, Closed)
    } noraise {
      _ => fail("a write after close succeeded")
    }
    try client.read(max_len=1) catch {
      @mttp_core.TransportError(kind~, ..) => assert_eq(kind, Closed)
    } noraise {
      _ => fail("a read after close succeeded")
    }
  })
}

///|
async test "configurations OpenSSL cannot use are refused" {
  let chain = @fs.read_text(testdata("localhost.pem"))
  let key = @fs.read_text(testdata("localhost.key"))
  let root = @fs.read_text(testdata("root.pem"))
  // The root's certificate with the leaf's key.
  try @tls.ServerTls::from_pem(chain=root, key~) catch {
    @tls.TlsConfigError(detail) =>
      assert_true(detail.contains("mismatch"), msg=detail)
  } noraise {
    _ => fail("a key that does not match was accepted")
  }
  try @tls.ServerTls::from_pem(chain="not PEM", key~) catch {
    @tls.TlsConfigError(_) => ()
  } noraise {
    _ => fail("a certificate that is not PEM was accepted")
  }
  try @tls.ServerTls::from_pem(chain~, key~, alpn=[""]) catch {
    @tls.TlsConfigError(_) => ()
  } noraise {
    _ => fail("an empty ALPN identifier was accepted")
  }
  try @tls.ClientTls::new(alpn=["x".repeat(256)]) catch {
    @tls.TlsConfigError(_) => ()
  } noraise {
    _ => fail("a 256-byte ALPN identifier was accepted")
  }
}
