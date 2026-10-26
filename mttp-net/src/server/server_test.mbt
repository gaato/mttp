///|
async fn with_server(
  handler : @model.Handler,
  run : async (String) -> Unit,
  limits~ : @server.ServerLimits = @server.ServerLimits::default(),
  compression~ : Bool = false,
  on_error~ : (@server.ServeError) -> Unit = _ => (),
) -> Unit {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let ready : Ref[String?] = Ref(None)
      let wake = @cond_var.Cond()
      group.spawn_bg(no_wait=true, () => {
        @server.serve(
          handler,
          addr="127.0.0.1:0",
          limits~,
          compression~,
          on_error~,
          on_listen=address => {
            ready.val = Some(address)
            wake.signal()
          },
        )
      })
      while ready.val is None {
        wake.wait()
      }
      run(ready.val.unwrap())
    })
  })
}

///|
async fn raw(address : String, bytes : Bytes) -> String {
  let tcp = @socket.Tcp::connect(@socket.Addr::parse(address))
  defer tcp.close()
  tcp.write(bytes)
  let out = Buffer()
  while tcp.read_some(max_len=65536) is Some(bytes) {
    out.write_bytes(bytes)
    assert_true(out.length() <= 1048576)
  }
  @utf8.decode(out.to_bytes())
}

///|
async test "server roundtrips absolute targets duplicate headers compression and keepalive" {
  let requests = Ref(0)
  with_server(
    request => {
      requests.val += 1
      @model.Response::new(
        200,
        headers=@model.Headers::of([
          ("set-cookie", "a=1"),
          ("set-cookie", "b=2"),
          ("content-type", "text/plain"),
        ]),
        body=Bytes(@model.encode_utf8(request.url)),
      )
    },
    address => {
      let backend = @backend.H1Backend::new(trust_env=false)
      let client = @client.Client::new(backend, @runtime.AsyncClock::new())
      defer client.close()
      for _ in 0..<2 {
        let response = backend.send(
          @model.Request::get("http://" + address + "/hello"),
          @client.RequestOptions::default(),
        )
        assert_eq(response.head().headers.get_all("set-cookie"), ["a=1", "b=2"])
        let body = @client.read_body(response.body, 4096)
        assert_eq(@utf8.decode(body), "http://" + address + "/hello")
        assert_eq(response.headers.get("content-encoding"), None)
        response.close()
      }
    },
    compression=true,
  )
  assert_eq(requests.val, 2)
}

///|
async test "server rejects malformed oversized and unsupported request heads" {
  let called = Ref(false)
  with_server(
    _ => {
      called.val = true
      @model.Response::new(200)
    },
    address => {
      for
        (request, status) in [
          (b"GET / HTTP/1.1\r\nHost: x\r\nHost: y\r\n\r\n", "400"),
          (b"POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 4\r\n\r\n", "413"),
          (
            b"POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 1\r\nExpect: other\r\n\r\n",
            "417",
          ),
          (b"CONNECT x:443 HTTP/1.1\r\nHost: x\r\n\r\n", "501"),
          (
            @model.encode_utf8(
              "GET / HTTP/1.1\r\nHost: x\r\nX: " +
              String::make(128, 'a') +
              "\r\n\r\n",
            ),
            "431",
          ),
        ] {
        assert_true(raw(address, request).has_prefix("HTTP/1.1 " + status))
      }
    },
    limits={
      ..@server.ServerLimits::default(),
      max_body_bytes: 3,
      max_header_bytes: 128,
    },
  )
  assert_false(called.val)
}

///|
async test "unread small bodies drain before a pipelined request and larger bodies close" {
  let calls = Ref(0)
  with_server(
    _ => {
      calls.val += 1
      @model.Response::new(204)
    },
    address => {
      let result = raw(
        address, b"POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\nabcGET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
      )
      assert_eq(result.split("HTTP/1.1 204").count(), 3)
      assert_eq(calls.val, 2)
      ignore(
        raw(
          address, b"POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 4\r\n\r\nabcdGET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
        ),
      )
      assert_eq(calls.val, 3)
    },
    limits={ ..@server.ServerLimits::default(), drain_max_bytes: 3, },
  )
}
