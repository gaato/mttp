// The HTTP/3 server against this module's HTTP/3 client and curl, on
// 127.0.0.1, with the test certificate of mttp_ng/testdata.

///|
async fn testdata(name : String) -> String {
  for dir in ["../../testdata", "testdata", "mttp_ng/testdata"] {
    if @fs.exists("\{dir}/\{name}") {
      return @fs.realpath("\{dir}/\{name}")
    }
  }
  fail("no testdata/\{name} below the working directory")
}

///|
async fn answer(request : @mttp_core.Request) -> @mttp_core.Response noraise {
  let url = @mttp_core.Url::parse(request.url) catch {
    _ => return @mttp_core.Response::new(400)
  }
  match url.path {
    "/hello" =>
      @mttp_core.Response::new(
        200,
        headers=@mttp_core.Headers::of([
          (
            "x-protocol",
            request.attributes.get(@mttp_core.protocol).unwrap_or(""),
          ),
        ]),
        body=Bytes(b"hello"),
      )
    "/echo" => {
      let body = request.body.read_all(max=8 << 20) catch {
        _ => return @mttp_core.Response::new(400)
      }
      @mttp_core.Response::new(
        200,
        headers=@mttp_core.Headers::of([
          ("x-received", body.length().to_string()),
        ]),
        body=Bytes(body),
      )
    }
    "/big" =>
      @mttp_core.Response::new(
        200,
        body=Bytes(Bytes::makei(2000000, i => (i % 251).to_byte())),
      )
    _ => @mttp_core.Response::new(404)
  }
}

///|
async fn with_server(run : async (Int32) -> Unit) -> Unit {
  let quic = @h3.ServerQuic::from_pem(
    chain=@fs.read_text(testdata("localhost.pem")),
    key=@fs.read_text(testdata("localhost.key")),
  )
  @async.with_timeout(30000, () => {
    @async.with_task_group(group => {
      let port : Ref[Int32?] = Ref(None)
      let listening = @cond_var.Cond()
      group.spawn_bg(() => {
        @h3server.serve(answer, addr="127.0.0.1:0", quic~, on_listen=addr => {
          port.val = Some(
            @string.parse_int(addr[addr.rev_find(":").unwrap() + 1:]) catch {
              _ => 0
            },
          )
          listening.broadcast()
        })
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
async fn client() -> @h3client.H3Backend {
  @h3client.H3Backend::new(trust=PemFile(testdata("root.pem")))
}

///|
let defaults : @mttp_core.SendOptions = @mttp_core.SendOptions::default()

///|
async fn text(response : @mttp_core.Response) -> String {
  @utf8.decode_lossy(response.body.read_all(max=16 << 20))
}

///|
async test "HTTP/3 between this module's client and server" {
  with_server(port => {
    let b = client()
    defer b.close()
    let response = b.send(
      @mttp_core.Request::get("https://localhost:\{port}/hello"),
      defaults,
    )
    assert_eq(response.status, 200)
    assert_eq(response.attributes.get(@mttp_core.protocol), Some("h3"))
    assert_eq(response.headers.get("x-protocol"), Some("h3"))
    assert_eq(text(response), "hello")
    // The same connection carries the next ones, some at once.
    let answers = []
    @async.with_task_group(group => {
      for _ in 0..<10 {
        group.spawn_bg(() => {
          let response = b.send(
            @mttp_core.Request::get("https://localhost:\{port}/hello"),
            defaults,
          )
          answers.push(text(response))
        })
      }
    })
    assert_eq(answers, Array::make(10, "hello"))
    assert_eq(b.connections(), 1)
  })
}

///|
async test "bodies both ways over HTTP/3" {
  with_server(port => {
    let b = client()
    defer b.close()
    let big = Bytes::makei(500000, i => (i % 241).to_byte())
    let response = b.send(
      @mttp_core.Request::put("https://localhost:\{port}/echo").body_bytes(big),
      defaults,
    )
    assert_eq(response.headers.get("x-received"), Some("500000"))
    assert_true(response.body.read_all(max=1 << 20) == big)
    let response = b.send(
      @mttp_core.Request::get("https://localhost:\{port}/big"),
      defaults,
    )
    assert_eq(response.body.read_all(max=4 << 20).length(), 2000000)
  })
}

///|
async test "try_send declines an origin without HTTP/3, sending nothing" {
  let b = client()
  defer b.close()
  // Nothing listens on UDP port 1.
  let outcome = b.try_send(
    @mttp_core.Request::get("https://127.0.0.1:1/"),
    defaults,
  )
  assert_true(outcome is None)
  // And the origin is not tried again for a while.
  let outcome = b.try_send(
    @mttp_core.Request::get("https://127.0.0.1:1/"),
    defaults,
  )
  assert_true(outcome is None)
}

///|
async test "curl speaks HTTP/3 to it" {
  with_server(port => {
    let result = @process.run(
      "curl",
      [
        "--silent",
        "--show-error",
        "--http3-only",
        "--cacert",
        testdata("root.pem"),
        "--write-out",
        " %{http_version}",
        "https://localhost:\{port}/hello",
      ],
      stdout=Collect,
      stderr=Collect,
    )
    assert_eq(
      result.exit_code,
      0,
      msg=@utf8.decode_lossy(result.stderr_binary()),
    )
    assert_eq(@utf8.decode_lossy(result.stdout_binary()), "hello 3")
  })
}
