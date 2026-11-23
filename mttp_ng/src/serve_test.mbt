// serve() and backend() together: one port with HTTP/1.1, HTTP/2 and
// HTTP/3, and a client that takes HTTP/3 where it is offered.

///|
async fn testdata(name : String) -> String {
  for dir in ["../testdata", "testdata", "mttp_ng/testdata"] {
    if @fs.exists("\{dir}/\{name}") {
      return @fs.realpath("\{dir}/\{name}")
    }
  }
  fail("no testdata/\{name} below the working directory")
}

///|
fn answer(request : @mttp_core.Request) -> @mttp_core.Response {
  @mttp_core.Response::new(
    200,
    headers=@mttp_core.Headers::of([
      ("x-protocol", request.attributes.get(@mttp_core.protocol).unwrap_or("")),
    ]),
    body=Bytes(b"hello"),
  )
}

///|
async fn with_server(run : async (Int32) -> Unit, h3~ : Bool = true) -> Unit {
  let cert = @fs.read_text(testdata("localhost.pem"))
  let key = @fs.read_text(testdata("localhost.key"))
  @async.with_timeout(30000, () => {
    @async.with_task_group(group => {
      let port : Ref[Int32?] = Ref(None)
      let listening = @cond_var.Cond()
      group.spawn_bg(() => {
        @mttp_ng.serve(
          request => answer(request),
          addr="127.0.0.1:0",
          cert~,
          key~,
          h3~,
          on_listen=addr => {
            port.val = Some(
              @string.parse_int(addr[addr.rev_find(":").unwrap() + 1:]) catch {
                _ => 0
              },
            )
            listening.broadcast()
          },
        )
      })
      while port.val is None {
        listening.wait()
      }
      run(port.val.unwrap())
      group.return_immediately()
    })
  })
}

///|
async fn client(http3~ : Bool = false) -> &@mttp_core.Backend {
  @mttp_ng.backend(
    trust=PemFile(testdata("root.pem")),
    config={
      ..@h1client.ClientConfig::default(),
      proxy: @h1client.ProxyConfig::none(),
    },
    http3~,
  )
}

///|
async fn get(b : &@mttp_core.Backend, url : String) -> @mttp_core.Response {
  b.send(@mttp_core.Request::get(url), @mttp_core.SendOptions::default())
}

///|
async test "one port: HTTP/2 that advertises HTTP/3, and HTTP/3" {
  with_server(port => {
    let tcp = client()
    defer tcp.close()
    let response = get(tcp, "https://localhost:\{port}/")
    assert_eq(response.headers.get("x-protocol"), Some("h2"))
    assert_eq(
      response.headers.get("alt-svc"),
      Some("h3=\":\{port}\"; ma=86400"),
    )
    ignore(response.body.read_all(max=1024))
    let quic = client(http3=true)
    defer quic.close()
    let response = get(quic, "https://localhost:\{port}/")
    assert_eq(response.headers.get("x-protocol"), Some("h3"))
    assert_eq(response.attributes.get(@mttp_core.protocol), Some("h3"))
    assert_eq(response.headers.get("alt-svc"), None)
    assert_eq(response.body.read_all(max=1024), b"hello")
  })
}

///|
async test "http3=true falls back to TCP where nothing speaks QUIC" {
  with_server(h3=false, port => {
    let quic = client(http3=true)
    defer quic.close()
    let response = get(quic, "https://localhost:\{port}/")
    assert_eq(response.headers.get("x-protocol"), Some("h2"))
    assert_eq(response.body.read_all(max=1024), b"hello")
  })
}

///|
async test "h3 without a certificate is refused" {
  try
    @mttp_ng.serve(request => answer(request), addr="127.0.0.1:0", h3=true)
  catch {
    @mttp_ng.ServeError::Config(_) => ()
    error => fail("unexpected \{error}")
  } noraise {
    _ => fail("served HTTP/3 without a certificate")
  }
}

///|
/// With `h3`, a UDP port that cannot be bound fails `serve`: the TCP
/// listener already bound to the same port stops with it, rather than
/// serving on and advertising an HTTP/3 that is not there (Codex's review
/// of #58).
async test "h3 on a UDP port in use fails serve, and stops its TCP listener" {
  let udp = @socket.UdpServer(@socket.Addr::parse("127.0.0.1:0"))
  defer udp.close()
  let address = udp.addr.to_string()
  let cert = @fs.read_text(testdata("localhost.pem"))
  let key = @fs.read_text(testdata("localhost.key"))
  let mut listened = false
  let outcome = @async.with_timeout_opt(5000, () => {
    @mttp_ng.serve(
      request => answer(request),
      addr=address,
      cert~,
      key~,
      h3=true,
      on_listen=_ => listened = true,
    ) catch {
      Listen(_) => return "refused"
      error => return "other: \{error}"
    }
    "served"
  })
  assert_eq(outcome, Some("refused"))
  assert_false(listened)
}
