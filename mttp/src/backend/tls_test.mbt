///|
#cfg(all(not(target="wasm"), not(platform="windows")))
#warnings("-alert_internal")
async fn test_tls(tcp : @socket.Tcp) -> @tls.Tls {
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
async fn test_tls(tcp : @socket.Tcp) -> @tls.Tls {
  @tls.Tls::server(tcp, pfx_file="src/conn/testdata/localhost.pfx")
}

///|
#cfg(target="wasm")
#warnings("-alert_internal")
async fn test_tls(tcp : @socket.Tcp) -> @tls.Tls {
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
            let tls = test_tls(tcp)
            @h1server.serve_conn(
              @socketconn.from_tls(tls, @socketconn.from_tcp(tcp)),
              handler,
              clock=@runtime.AsyncClock::new(),
              timer=@runtime.ClockTimer::new(),
              coordination=@runtime.RuntimeCoordination::new(),
              scheme="https",
            )
          })
        }
      })
      action("https://localhost:\{listener.addr.port()}")
      group.return_immediately()
    })
  })
}

///|
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
              @socketconn.from_tls(test_tls(tcp), outer)
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
                "\{scheme}://user:pass@localhost:\{proxy.addr.port()}",
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
        @mttp_core.Request::get("https://localhost:\{listener.addr.port()}"),
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
