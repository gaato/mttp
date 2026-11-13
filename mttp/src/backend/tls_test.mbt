///|
/// A TLS server session over `conn` with the test certificate. No Windows
/// server exists (internal/testtls/testtls.mbt), so the tests that need
/// one are not built there.
#cfg(not(platform="windows"))
async fn test_tls(conn : &@rt.Conn) -> @testtls.TestTls {
  @testtls.accept(
    conn,
    key_file="src/conn/testdata/localhost.key",
    cert_file="src/conn/testdata/localhost.pem",
  )
}

///|
#cfg(not(platform="windows"))
async fn with_tls_server(
  handler : @mttp_core.Handler,
  action : async (String) -> Unit,
) -> Unit {
  @async.with_timeout(5000, () => {
    let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer listener.close()
    @async.with_task_group(group => {
      group.spawn_bg(() => {
        while true {
          let (tcp, _) = listener.accept()
          group.spawn_bg(allow_failure=true, () => {
            defer tcp.close()
            @h1server.serve_conn(
              test_tls(@socketconn.from_tcp(tcp)),
              handler,
              clock=@runtime.AsyncClock::new(),
              timer=@runtime.ClockTimer::new(),
              coordination=@runtime.RuntimeCoordination::new(),
              scheme="https",
            )
          })
        }
      })
      action("https://localhost:\{port_of(listener.addr)}")
      group.return_immediately()
    })
  })
}

///|
#cfg(not(platform="windows"))
async test "socket TLS custom roots insecure mode and verification failures use root Trust" {
  with_tls_server(_ => @mttp_core.Response::new(200, body=Bytes(b"secured")), url => {
    for
      trust in [
        @trust.Trust::PemFile("src/conn/testdata/localhost.pem"),
        Insecure,
      ] {
      let backend = @backend.AsyncBackend::new(
        config=@h1client.ClientConfig::default(),
        trust~,
      )
      defer backend.close()
      assert_eq(
        body(
          backend.send(
            @mttp_core.Request::get(url),
            @mttp_core.SendOptions::default(),
          ),
        ),
        b"secured",
      )
    }
    for trust in [@trust.Trust::System] {
      let backend = @backend.AsyncBackend::new(
        config=@h1client.ClientConfig::default(),
        trust~,
      )
      defer backend.close()
      try
        backend.send(
          @mttp_core.Request::get(url),
          @mttp_core.SendOptions::default(),
        )
      catch {
        @mttp_core.TransportError(kind=Connect, phase=Dial, ..) => ()
        error => raise error
      } noraise {
        _ => fail("TLS verification was bypassed")
      }
      assert_eq(backend.idle_connections(), 0)
    }
  })
}

///|
async fn read_head(conn : &@rt.Conn) -> String {
  let buffer = Buffer()
  while buffer.length() < 16384 {
    guard conn.read(max_len=1) is Some(bytes) else { fail("EOF before head") }
    buffer.write_bytes(bytes)
    if buffer.to_bytes().has_suffix(b"\r\n\r\n") {
      return @utf8.decode(buffer.to_bytes())
    }
  }
  fail("oversized test head")
}

///|
async fn pump(from : &@rt.Conn, to : &@rt.Conn) -> Unit {
  while from.read(max_len=65536) is Some(bytes) {
    to.write(bytes)
  }
}

///|
#cfg(not(platform="windows"))
async test "socket CONNECT tunnels verified TLS through plain and TLS proxies" {
  let origin_auth = Ref(false)
  with_tls_server(
    request => {
      origin_auth.val = request.headers.contains("proxy-authorization")
      @mttp_core.Response::new(200, body=Bytes(b"tunnel"))
    },
    url => {
      let origin = @mttp_core.Url::parse(url)
      for secure in [false, true] {
        let proxy = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
        defer proxy.close()
        @async.with_task_group(group => {
          let connected = Ref(0)
          group.spawn_bg(() => {
            let (tcp, _) = proxy.accept()
            let outer = @socketconn.from_tcp(tcp)
            let tunnel = if secure {
              (test_tls(outer) : &@rt.Conn)
            } else {
              outer
            }
            defer tunnel.close()
            let head = read_head(tunnel).to_lower()
            assert_true(
              head.has_prefix(
                "connect localhost:\{origin.port_or_default().unwrap()} http/1.1\r\n",
              ),
            )
            assert_true(
              head.contains("proxy-authorization: basic dxnlcjpwyxnz"),
            )
            connected.val += 1
            let upstream = @conn.TcpDialer::new().connect(
              host="127.0.0.1",
              port=origin.port_or_default().unwrap(),
            )
            defer upstream.close()
            tunnel.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
            @async.with_task_group(relay => {
              relay.spawn_bg(() => pump(tunnel, upstream))
              pump(upstream, tunnel)
              relay.return_immediately()
            })
          })
          let scheme = if secure { "https" } else { "http" }
          let backend = @backend.AsyncBackend::new(
            config={
              ..@h1client.ClientConfig::default(),
              proxy: @h1client.ProxyConfig::fixed(
                "\{scheme}://user:pass@localhost:\{port_of(proxy.addr)}",
              ),
            },
            trust=PemFile("src/conn/testdata/localhost.pem"),
          )
          defer backend.close()
          assert_eq(
            body(
              backend.send(
                @mttp_core.Request::get(url),
                @mttp_core.SendOptions::default(),
              ),
            ),
            b"tunnel",
          )
          assert_eq(connected.val, 1)
          assert_false(origin_auth.val)
          assert_eq(backend.idle_connections(), 1)
          backend.close()
          group.return_immediately()
        })
      }
    },
  )
}

///|
async test "socket TLS handshake deadline stays in Dial and leaves no idle connection" {
  let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  defer listener.close()
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      let (tcp, _) = listener.accept()
      defer tcp.close()
      @async.sleep(10000)
    })
    let backend = @backend.AsyncBackend::new(
      config={
        ..@h1client.ClientConfig::default(),
        connect_timeout_ms: Some(30),
      },
      trust=Insecure,
    )
    defer backend.close()
    try
      backend.send(
        @mttp_core.Request::get("https://localhost:\{port_of(listener.addr)}"),
        @mttp_core.SendOptions::default(),
      )
    catch {
      @mttp_core.TransportError(kind=Timeout(ms=30), phase=Dial, ..) => ()
      error => raise error
    } noraise {
      _ => fail("stalled TLS handshake succeeded")
    }
    assert_eq(backend.idle_connections(), 0)
    group.return_immediately()
  })
}

///|
async test "socket proxy forwarding and NO_PROXY select separate routes" {
  with_server(_ => @mttp_core.Response::new(200, body=Bytes(b"origin")), (
    origin,
    _,
  ) => {
    let target = Ref("")
    with_server(
      request => {
        target.val = request.url
        @mttp_core.Response::new(200, body=Bytes(b"proxy"))
      },
      (proxy, _) => {
        let backend = new_backend(config={
          ..@h1client.ClientConfig::default(),
          proxy: {
            http: Some(proxy),
            https: Some(proxy),
            no_proxy: "127.0.0.1",
          },
        })
        defer backend.close()
        assert_eq(
          body(
            backend.send(
              @mttp_core.Request::get(origin),
              @mttp_core.SendOptions::default(),
            ),
          ),
          b"origin",
        )
        assert_eq(
          body(
            backend.send(
              @mttp_core.Request::get("http://remote.invalid/path?q=1"),
              @mttp_core.SendOptions::default(),
            ),
          ),
          b"proxy",
        )
        assert_eq(target.val, "http://remote.invalid/path?q=1")
        assert_eq(backend.idle_connections(), 2)
      },
    )
  })
}

///|
async test "socket default reads process proxy environment once and explicit config opts out" {
  let names = [
    "http_proxy", "HTTP_PROXY", "all_proxy", "ALL_PROXY", "no_proxy", "NO_PROXY",
    "REQUEST_METHOD",
  ]
  let saved = names.map(name => (name, @env.get_env_var(name)))
  defer (for (name, value) in saved {
    if value is Some(value) {
      @env.set_env_var(name, value)
    } else {
      @env.unset_env_var(name)
    }
  })
  for name in names {
    @env.unset_env_var(name)
  }
  with_server(_ => @mttp_core.Response::new(200, body=Bytes(b"env proxy")), (
    url,
    _,
  ) => {
    @env.set_env_var("http_proxy", url)
    let backend = @backend.AsyncBackend::new()
    defer backend.close()
    @env.set_env_var("http_proxy", "invalid://changed")
    assert_eq(
      body(
        backend.send(
          @mttp_core.Request::get("http://origin.invalid/"),
          @mttp_core.SendOptions::default(),
        ),
      ),
      b"env proxy",
    )
    let direct = new_backend()
    defer direct.close()
    assert_eq(
      body(
        direct.send(
          @mttp_core.Request::get(url),
          @mttp_core.SendOptions::default(),
        ),
      ),
      b"env proxy",
    )
  })
}

///|
/// The connection beneath TLS, with writes that take `delay_ms` when it is
/// set.
#cfg(all(not(target="wasm"), not(platform="windows")))
priv struct SlowWrites {
  inner : &@rt.Conn
  delay_ms : Ref[Int32]
}

///|
#cfg(all(not(target="wasm"), not(platform="windows")))
impl @rt.Conn for SlowWrites with fn read(self, max_len~) {
  self.inner.read(max_len~)
}

///|
#cfg(all(not(target="wasm"), not(platform="windows")))
impl @rt.Conn for SlowWrites with fn write(self, bytes) {
  if self.delay_ms.val > 0 {
    @async.sleep(self.delay_ms.val)
  }
  self.inner.write(bytes)
}

///|
#cfg(all(not(target="wasm"), not(platform="windows")))
impl @rt.Conn for SlowWrites with fn close(self) {
  self.inner.close()
}

///|
/// TcpDialer with SlowWrites beneath its TLS sessions.
#cfg(all(not(target="wasm"), not(platform="windows")))
priv struct SlowDialer {
  tcp : @conn.TcpDialer
  delay_ms : Ref[Int32]
}

///|
#cfg(all(not(target="wasm"), not(platform="windows")))
impl @rt.Dialer for SlowDialer with fn connect(self, host~, port~) {
  SlowWrites::{
    inner: self.tcp.connect(host~, port~),
    delay_ms: self.delay_ms,
  }
}

///|
#cfg(all(not(target="wasm"), not(platform="windows")))
impl @rt.Dialer for SlowDialer with fn start_tls(self, conn, host~) {
  self.tcp.start_tls(conn, host~)
}

///|
/// Found by the interop suite against nginx and Caddy under load. The
/// server closes the idle TLS connection with close_notify. The client's
/// check before reuse reads it, and OpenSSL answers with its own
/// close_notify, a write on the connection beneath; when that write is slow
/// (here made slow on purpose, under load by the scheduler), the check's
/// deadline cancels the read before it returns EOF. The check passed, and
/// the session, now shut down, refused the POST before sending any of it:
/// that was reported as sent, so the POST failed although the server never
/// saw it. Now the refusal sends the POST on a new connection.
///
/// OpenSSL only: core/async's TLS on wasm first flushes what the cut-off
/// read left unsent, so the session's refusal cannot be told from a write
/// that sent something, and the client stays with the failure; on Windows
/// Schannel aborts on that leftover. The check's 2 ms wait keeps the cut
/// rare on every target.
#cfg(all(not(target="wasm"), not(platform="windows")))
async test "socket TLS POST after the server's close_notify uses a new connection" {
  @async.with_timeout(5000, () => {
    let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer listener.close()
    let requests = []
    let closed = Ref(0)
    @async.with_task_group(group => {
      group.spawn_bg(() => {
        for connection = 0; ; connection = connection + 1 {
          let (tcp, _) = listener.accept()
          group.spawn_bg(allow_failure=true, () => {
            // One request per connection, answered as kept alive; 50 ms
            // later the server closes it with close_notify, as nginx and
            // Caddy close an idle connection.
            defer tcp.close()
            let tls = test_tls(@socketconn.from_tcp(tcp))
            defer tls.close()
            guard tls.read_until(b"\r\n\r\n") is Some(head) else { return }
            let head = @utf8.decode_lossy(head).to_lower()
            requests.push(
              (connection, head.split("\r\n").next().unwrap_or("").to_owned()),
            )
            if head.contains("content-length: 1") {
              ignore(tls.read_exactly(1))
            }
            tls.write(b"HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nok")
            @async.sleep(50)
            tls.shutdown()
            closed.val += 1
          })
        }
      })
      let delay_ms = Ref(0)
      let client = @h1client.Client::new(
        dialer=SlowDialer::{
          tcp: @conn.TcpDialer::new(
            trust=PemFile("src/conn/testdata/localhost.pem"),
          ),
          delay_ms,
        },
        clock=@runtime.AsyncClock::new(),
        timer=@runtime.ClockTimer::new(),
        coordination=@runtime.RuntimeCoordination::new(),
        config=@h1client.ClientConfig::default(),
      )
      defer client.close()
      let url = "https://localhost:\{port_of(listener.addr)}/"
      assert_eq(
        body(
          client.send(
            @mttp_core.Request::get(url),
            @mttp_core.SendOptions::default(),
          ),
        ),
        b"ok",
      )
      assert_eq(client.idle_connections(), 1)
      while closed.val == 0 {
        @async.sleep(5)
      }
      // Past the pause after which a parked connection is checked.
      @async.sleep(150)
      delay_ms.val = 20
      let post = @mttp_core.Request::post(url).body_bytes(b"x")
      assert_eq(
        body(client.send(post, @mttp_core.SendOptions::default())),
        b"ok",
      )
      assert_eq(requests, [(0, "get / http/1.1"), (1, "post / http/1.1")])
      group.return_immediately()
    })
  })
}
