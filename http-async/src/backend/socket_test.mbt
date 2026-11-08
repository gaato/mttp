///|
async fn body(response : @http.Response) -> Bytes {
  defer response.close()
  match response.body {
    Empty => b""
    Bytes(bytes) => bytes
    Stream(cell) => @http.read_bounded(cell.take(), 20 * 1024 * 1024)
    @http.Body::.. => fail("unsupported test body")
  }
}

///|
async fn with_server(
  handler : @http.Handler,
  action : async (String, Ref[Int32]) -> Unit,
) -> Unit {
  @async.with_timeout(5000, () => {
    let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer listener.close()
    let accepts = Ref(0)
    @async.with_task_group(group => {
      group.spawn_bg(() => {
        while true {
          let (tcp, _) = listener.accept()
          accepts.val += 1
          group.spawn_bg(() => {
            @h1server.serve_conn(
              @socketconn.from_tcp(tcp),
              handler,
              clock=@runtime.AsyncClock::new(),
              timer=@runtime.ClockTimer::new(),
              coordination=@runtime.RuntimeCoordination::new(),
              scheme="http",
            )
          })
        }
      })
      action("http://127.0.0.1:\{listener.addr.port()}", accepts)
      group.return_immediately()
    })
  })
}

///|
fn new_backend(config? : @h1client.ClientConfig) -> @backend.AsyncBackend {
  @backend.AsyncBackend::new(
    config=config.unwrap_or_else(@h1client.ClientConfig::default),
  )
}

///|
async test "socket wiring decodes gzip deflate and brotli and preserves explicit opt out" {
  for coding in [@codings.Coding::Gzip, Deflate, Brotli] {
    let encoded = body(
      @http.Response::new(
        200,
        body=@codings.encode_body(Bytes(b"decoded"), coding),
      ),
    )
    let accepted = Ref("")
    with_server(
      request => {
        accepted.val = request.headers.get("accept-encoding").unwrap_or("")
        @http.Response::new(
          200,
          body=Bytes(encoded),
          headers=@http.Headers::of([("content-encoding", coding.name())]),
        )
      },
      (url, _) => {
        let backend = new_backend()
        defer backend.close()
        let response = backend.send(
          @http.Request::get(url),
          @http.SendOptions::default(),
        )
        assert_eq(response.headers.get("content-encoding"), None)
        assert_eq(response.headers.get("content-length"), None)
        assert_eq(body(response), b"decoded")
        assert_eq(accepted.val, @codings.accept_encoding())
        let response = backend.send(
          @http.Request::get(url).header("accept-encoding", coding.name()),
          @http.SendOptions::default(),
        )
        assert_eq(response.headers.get("content-encoding"), Some(coding.name()))
        assert_eq(body(response), encoded)
        assert_eq(accepted.val, coding.name())
      },
    )
  }
  let zstd = b"\x28\xb5\x2f\xfd\x20\x13\x6d\x00\x00\x38\x68\x65\x6c\x6c\x6f\x2c\x20\x01\x00\xe2\x8a\x11"
  with_server(
    _ => {
      @http.Response::new(
        200,
        body=Bytes(zstd),
        headers=@http.Headers::of([("content-encoding", "zstd")]),
      )
    },
    (url, _) => {
      let backend = new_backend()
      defer backend.close()
      assert_eq(
        body(
          backend.send(@http.Request::get(url), @http.SendOptions::default()),
        ),
        b"hello, hello, hello",
      )
    },
  )
}

///|
async test "socket keep alive reuses one connection and early close discards it" {
  with_server(_ => @http.Response::new(200, body=Bytes(b"reuse")), (
    url,
    accepts,
  ) => {
    let backend = new_backend()
    defer backend.close()
    for _ in 0..<3 {
      assert_eq(
        body(
          backend.send(@http.Request::get(url), @http.SendOptions::default()),
        ),
        b"reuse",
      )
      assert_eq(backend.idle_connections(), 1)
    }
    assert_eq(accepts.val, 1)
    let response = backend.send(
      @http.Request::get(url),
      @http.SendOptions::default(),
    )
    response.close()
    response.close()
    assert_eq(backend.idle_connections(), 0)
    assert_eq(
      body(backend.send(@http.Request::get(url), @http.SendOptions::default())),
      b"reuse",
    )
    assert_eq(accepts.val, 2)
    backend.close()
    backend.close()
    assert_eq(backend.idle_connections(), 0)
  })
}

///|
async test "socket uploads bytes and known and unknown length streams once" {
  with_server(
    request => {
      let bytes = match request.body {
        Stream(cell) =>
          @http.read_bounded(cell.take(), 200000) catch {
            _ => b"failed"
          }
        Bytes(bytes) => bytes
        _ => b""
      }
      @http.Response::new(200, body=Bytes(bytes))
    },
    (url, _) => {
      let backend = new_backend()
      defer backend.close()
      let payload = Bytes::make(70000, b'x')
      assert_eq(
        body(
          backend.send(
            @http.Request::post(url).body_bytes(payload),
            @http.SendOptions::default(),
          ),
        ),
        payload,
      )
      for known in [true, false] {
        let stream = UploadSource::{
          reads: 0,
          closes: 0,
          first: payload,
          wait: false,
          failing: false,
        }
        let request = @http.Request::post(url).body_stream(
          stream,
          length?=if known { Some(70000L) } else { None },
        )
        assert_eq(
          body(backend.send(request, @http.SendOptions::default())),
          payload,
        )
        assert_eq(stream.closes, 1)
        assert_eq(stream.reads, 2)
      }
    },
  )
}

///|
priv struct UploadSource {
  mut reads : Int32
  mut closes : Int32
  first : Bytes
  wait : Bool
  failing : Bool
}

///|
impl @http.BodyStream for UploadSource with fn read_some(self) {
  self.reads += 1
  if self.failing {
    raise @http.TransportError(
      kind=Unreplayable,
      phase=Write,
      detail="upload sentinel",
    )
  }
  if self.reads == 1 {
    return Some(self.first)
  }
  if self.wait {
    @async.sleep(10000)
  }
  None
}

///|
impl @http.BodyStream for UploadSource with fn close(self) {
  self.closes += 1
}

///|
async test "socket first read failure and false empty stream write no head" {
  for failing in [true, false] {
    let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer listener.close()
    let source = UploadSource::{
      reads: 0,
      closes: 0,
      first: b"x",
      wait: false,
      failing,
    }
    let backend = new_backend()
    defer backend.close()
    try
      backend.send(
        @http.Request::post("http://127.0.0.1:\{listener.addr.port()}").body_stream(
          source,
          length?=if failing { None } else { Some(0L) },
        ),
        @http.SendOptions::default(),
      )
    catch {
      @http.TransportError(
        kind=Unreplayable,
        phase=Write,
        detail="upload sentinel"
      ) if failing => ()
      @http.TransportError(kind=Protocol, ..) if !failing => ()
      error => raise error
    } noraise {
      _ => fail("invalid upload succeeded")
    }
    assert_eq(source.closes, 1)
    // Some engines connect before preflight; if connected, no head may arrive.
    let connected = @runtime.with_timeout_opt(@runtime.AsyncClock::new(), 20, () => {
      listener.accept()
    })
    if connected is Some((tcp, _)) {
      defer tcp.close()
      assert_eq(tcp.read(), None)
    }
  }
}

///|
async test "socket early final response cancels a blocked upload and prevents reuse" {
  with_server(_ => @http.Response::new(413, body=Bytes(b"no")), (url, _) => {
    let backend = new_backend()
    defer backend.close()
    let source = UploadSource::{
      reads: 0,
      closes: 0,
      first: b"x",
      wait: true,
      failing: false,
    }
    let response = backend.send(
      @http.Request::post(url).body_stream(source),
      @http.SendOptions::default(),
    )
    assert_eq(response.status, 413)
    assert_eq(body(response), b"no")
    assert_eq(source.closes, 1)
    assert_eq(backend.idle_connections(), 0)
  })
}

///|
async test "socket refusal carries unsent Dial phase" {
  let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  let port = listener.addr.port()
  listener.close()
  let backend = new_backend()
  defer backend.close()
  try
    backend.send(
      @http.Request::get("http://127.0.0.1:\{port}"),
      @http.SendOptions::default(),
    )
  catch {
    @http.TransportError(kind=Connect, phase=Dial, ..) as error =>
      assert_true(error.is_unsent())
    error => raise error
  } noraise {
    _ => fail("closed listener accepted")
  }
}

///|
async test "socket response head deadline and caller cancellation unwind sends" {
  let entered = @runtime.RuntimeCoordination::new().signal()
  with_server(
    _ => {
      entered.notify()
      @async.sleep(10000)
      @http.Response::new(200)
    },
    (url, _) => {
      let backend = new_backend()
      defer backend.close()
      try
        backend.send(@http.Request::get(url), {
          ..@http.SendOptions::default(),
          timeout_ms: Some(30),
        })
      catch {
        @http.TransportError(kind=Timeout(ms=30), phase=Head, ..) => ()
        error => raise error
      } noraise {
        _ => fail("stalled head succeeded")
      }
      let caught = Ref(false)
      let cleaned = Ref(false)
      @async.with_task_group(group => {
        group.spawn_bg(() => {
          defer {
            cleaned.val = true
          }
          ignore(
            backend.send(@http.Request::get(url), @http.SendOptions::default()) catch {
              _ => {
                caught.val = true
                @http.Response::new(599)
              }
            },
          )
        })
        entered.wait()
        @async.pause()
        group.return_immediately()
      })
      assert_true(cleaned.val)
      assert_false(caught.val)
      assert_eq(backend.idle_connections(), 0)
    },
  )
}

///|
priv struct StalledBody {
  mut first : Bool
}

///|
impl @http.BodyStream for StalledBody with fn read_some(self) {
  if self.first {
    self.first = false
    return Some(b"x")
  }
  @async.sleep(10000)
  None
}

///|
impl @http.BodyStream for StalledBody with fn close(_) {
  ()
}

///|
async test "socket Exchange deadline and Stream idle deadline cover body reads" {
  for streaming in [false, true] {
    with_server(
      _ => {
        @http.Response::new(
          200,
          body=Stream(@http.StreamBody::new(StalledBody::{ first: true, })),
        )
      },
      (url, _) => {
        let backend = new_backend()
        defer backend.close()
        let response = backend.send(@http.Request::get(url), {
          timeout_ms: if streaming {
            Some(1000)
          } else {
            Some(50)
          },
          body: if streaming {
            Stream(idle_ms=Some(30))
          } else {
            Exchange(max_bytes=100)
          },
        })
        try body(response) catch {
          @http.TransportError(kind=Timeout(ms~), phase=Body, ..) =>
            assert_eq(ms, if streaming { 30 } else { 50 })
          error => raise error
        } noraise {
          _ => fail("stalled body succeeded")
        }
        assert_eq(backend.idle_connections(), 0)
      },
    )
  }
}

///|
async test "socket wire caps apply before decompression and in Stream mode" {
  let encoded = body(
    @http.Response::new(200, body=@codings.encode_body(Bytes(b"x"), Gzip)),
  )
  for streaming in [false, true] {
    with_server(
      _ => {
        @http.Response::new(
          200,
          body=Bytes(encoded),
          headers=@http.Headers::of([("content-encoding", "gzip")]),
        )
      },
      (url, _) => {
        let backend = new_backend(config={
          ..@h1client.ClientConfig::default(),
          max_body_bytes: Some(encoded.length() - 1),
        })
        defer backend.close()
        try
          body(
            backend.send(@http.Request::get(url), {
              timeout_ms: None,
              body: if streaming {
                Stream(idle_ms=None)
              } else {
                Exchange(max_bytes=1000)
              },
            }),
          )
        catch {
          @http.TransportError(kind=TooLarge(limit~), phase=Body, ..) =>
            assert_eq(limit, encoded.length() - 1)
          error => raise error
        } noraise {
          _ => fail("wire ceiling ignored")
        }
        assert_eq(backend.idle_connections(), 0)
      },
    )
  }
  with_server(_ => @http.Response::new(200, body=Bytes(b"abcd")), (url, _) => {
    let backend = new_backend()
    defer backend.close()
    try
      body(
        backend.send(@http.Request::get(url), {
          timeout_ms: None,
          body: Exchange(max_bytes=3),
        }),
      )
    catch {
      @http.TransportError(kind=TooLarge(limit=3), phase=Body, ..) => ()
      error => raise error
    } noraise {
      _ => fail("Exchange cap ignored")
    }
  })
}
