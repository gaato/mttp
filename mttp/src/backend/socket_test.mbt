///|
/// The port `addr` is bound to, read from its text, which ends in `:port`.
/// core/async's `Addr` has a `port()` method on MoonBit 0.10.20 and a
/// `port` field on later toolchains; the text is what both share.
fn port_of(addr : @socket.Addr) -> Int32 {
  let text = addr.to_string()
  guard text.rev_find(":") is Some(colon) else {
    abort("no port in the address \{text}")
  }
  let mut port = 0
  for digit in text[colon + 1:] {
    port = port * 10 + (digit.to_int() - '0'.to_int())
  }
  port
}

///|
async fn body(response : @mttp_core.Response) -> Bytes {
  defer response.close()
  match response.body {
    Empty => b""
    Bytes(bytes) => bytes
    Stream(cell) => @mttp_core.read_bounded(cell.take(), 20 * 1024 * 1024)
    @mttp_core.Body::.. => fail("unsupported test body")
  }
}

///|
async fn with_server(
  handler : @mttp_core.Handler,
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
      action("http://127.0.0.1:\{port_of(listener.addr)}", accepts)
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
      @mttp_core.Response::new(
        200,
        body=@codings.encode_body(Bytes(b"decoded"), coding),
      ),
    )
    let accepted = Ref("")
    with_server(
      request => {
        accepted.val = request.headers.get("accept-encoding").unwrap_or("")
        @mttp_core.Response::new(
          200,
          body=Bytes(encoded),
          headers=@mttp_core.Headers::of([("content-encoding", coding.name())]),
        )
      },
      (url, _) => {
        let backend = new_backend()
        defer backend.close()
        let response = backend.send(
          @mttp_core.Request::get(url),
          @mttp_core.SendOptions::default(),
        )
        assert_eq(response.headers.get("content-encoding"), None)
        assert_eq(response.headers.get("content-length"), None)
        assert_eq(body(response), b"decoded")
        assert_eq(accepted.val, @codings.accept_encoding())
        let response = backend.send(
          @mttp_core.Request::get(url).header("accept-encoding", coding.name()),
          @mttp_core.SendOptions::default(),
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
      @mttp_core.Response::new(
        200,
        body=Bytes(zstd),
        headers=@mttp_core.Headers::of([("content-encoding", "zstd")]),
      )
    },
    (url, _) => {
      let backend = new_backend()
      defer backend.close()
      assert_eq(
        body(
          backend.send(
            @mttp_core.Request::get(url),
            @mttp_core.SendOptions::default(),
          ),
        ),
        b"hello, hello, hello",
      )
    },
  )
}

///|
async test "socket keep alive reuses one connection and early close discards it" {
  with_server(_ => @mttp_core.Response::new(200, body=Bytes(b"reuse")), (
    url,
    accepts,
  ) => {
    let backend = new_backend()
    defer backend.close()
    for _ in 0..<3 {
      assert_eq(
        body(
          backend.send(
            @mttp_core.Request::get(url),
            @mttp_core.SendOptions::default(),
          ),
        ),
        b"reuse",
      )
      assert_eq(backend.idle_connections(), 1)
    }
    assert_eq(accepts.val, 1)
    let response = backend.send(
      @mttp_core.Request::get(url),
      @mttp_core.SendOptions::default(),
    )
    response.close()
    response.close()
    assert_eq(backend.idle_connections(), 0)
    assert_eq(
      body(
        backend.send(
          @mttp_core.Request::get(url),
          @mttp_core.SendOptions::default(),
        ),
      ),
      b"reuse",
    )
    assert_eq(accepts.val, 2)
    backend.close()
    backend.close()
    assert_eq(backend.idle_connections(), 0)
  })
}

///|
/// With `Expect: 100-continue` the body waits for the server's 100 (found by
/// the interop suite: Apache over TLS lost its 413 to the reset a body sent
/// at once caused).
async test "socket upload with Expect waits for 100 Continue" {
  @async.with_timeout(5000, () => {
    let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer listener.close()
    let early : Ref[Bytes?] = Ref(None)
    let received = Ref(b"")
    @async.with_task_group(group => {
      group.spawn_bg(() => {
        let (tcp, _) = listener.accept()
        defer tcp.close()
        guard tcp.read_until(b"\r\n\r\n") is Some(_) else { return }
        // Nothing may follow the head before the 100.
        early.val = @async.with_timeout_opt(300, () => tcp.read()).bind(x => x)
        tcp.write(b"HTTP/1.1 100 Continue\r\n\r\n")
        received.val = tcp.read_exactly(7)
        tcp.write(b"HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nok")
      })
      let backend = new_backend()
      defer backend.close()
      let request = @mttp_core.Request::post(
          "http://127.0.0.1:\{port_of(listener.addr)}/",
        )
        .body_bytes(b"payload")
        .header("Expect", "100-continue")
      assert_eq(
        body(backend.send(request, @mttp_core.SendOptions::default())),
        b"ok",
      )
      assert_eq(early.val, None)
      assert_eq(received.val, b"payload")
      group.return_immediately()
    })
  })
}

///|
/// A server that closes an idle keep-alive connection, as Apache does after
/// 5 s: the next request, a POST that may not be resent, must not be
/// written to the closed connection (found by the interop suite).
async test "socket POST after the server closed the idle connection uses a new one" {
  @async.with_timeout(5000, () => {
    let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer listener.close()
    let requests = []
    @async.with_task_group(group => {
      group.spawn_bg(() => {
        while true {
          let (tcp, _) = listener.accept()
          group.spawn_bg(() => {
            // One request per connection, answered as kept alive, then the
            // server's idle timeout closes it.
            defer tcp.close()
            guard tcp.read_until(b"\r\n\r\n") is Some(head) else { return }
            let head = @utf8.decode_lossy(head).to_lower()
            requests.push(head.split("\r\n").next().unwrap_or("").to_owned())
            if head.contains("content-length: 1") {
              ignore(tcp.read_exactly(1))
            }
            tcp.write(b"HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nok")
          })
        }
      })
      let backend = new_backend()
      defer backend.close()
      let url = "http://127.0.0.1:\{port_of(listener.addr)}/"
      assert_eq(
        body(
          backend.send(
            @mttp_core.Request::get(url),
            @mttp_core.SendOptions::default(),
          ),
        ),
        b"ok",
      )
      assert_eq(backend.idle_connections(), 1)
      @async.sleep(300)
      let post = @mttp_core.Request::post(url).body_bytes(b"x")
      assert_eq(
        body(backend.send(post, @mttp_core.SendOptions::default())),
        b"ok",
      )
      assert_eq(requests, ["get / http/1.1", "post / http/1.1"])
      group.return_immediately()
    })
  })
}

///|
async test "injected clock expires parked sockets at the idle boundary" {
  with_server(_ => @mttp_core.Response::new(200, body=Bytes(b"reuse")), (
    url,
    accepts,
  ) => {
    let clock = @runtime.VirtualClock()
    let backend = @backend.AsyncBackend::new(
      config={ ..@h1client.ClientConfig::default(), idle_max_ms: 50, },
      clock~,
    )
    defer backend.close()
    for (elapsed, expected) in [(0, 1), (49, 1), (50, 2)] {
      clock.advance(elapsed)
      assert_eq(
        body(
          backend.send(
            @mttp_core.Request::get(url),
            @mttp_core.SendOptions::default(),
          ),
        ),
        b"reuse",
      )
      assert_eq(accepts.val, expected)
      assert_eq(backend.idle_connections(), 1)
    }
    assert_eq(clock.pending(), [])
  })
}

///|
async test "injected clock and optional timer drive the socket Head phase timeout" {
  for explicit_timer in [false, true] {
    let entered = Ref(false)
    with_server(
      _ => {
        entered.val = true
        @async.sleep(10000)
        @mttp_core.Response::new(200)
      },
      (url, _) => {
        let clock = @runtime.VirtualClock()
        let deadline_clock = if explicit_timer {
          @runtime.VirtualClock()
        } else {
          clock
        }
        let backend = @backend.AsyncBackend::new(
          config={
            ..@h1client.ClientConfig::default(),
            read_timeout_ms: Some(75),
          },
          clock~,
          timer?=if explicit_timer {
            Some(@runtime.ClockTimer::new(clock=deadline_clock))
          } else {
            None
          },
        )
        defer backend.close()
        let done = Ref(false)
        @async.with_task_group(group => {
          group.spawn_bg(() => {
            try
              backend.send(
                @mttp_core.Request::get(url),
                @mttp_core.SendOptions::default(),
              )
            catch {
              @mttp_core.TransportError(kind=Timeout(ms=75), phase=Head, ..) =>
                ()
              error => raise error
            } noraise {
              _ => fail("stalled head succeeded")
            }
            done.val = true
          })
          deadline_clock.settle(until=() => {
            entered.val && deadline_clock.pending() == [75]
          })
          deadline_clock.advance(74)
          assert_false(done.val)
          deadline_clock.advance(1)
          deadline_clock.settle(until=() => {
            done.val && deadline_clock.pending().is_empty()
          })
          assert_eq(clock.pending(), [])
          assert_eq(backend.idle_connections(), 0)
          group.return_immediately()
        })
      },
    )
  }
}

///|
async test "socket uploads bytes and known and unknown length streams once" {
  with_server(
    request => {
      let bytes = match request.body {
        Stream(cell) =>
          @mttp_core.read_bounded(cell.take(), 200000) catch {
            _ => b"failed"
          }
        Bytes(bytes) => bytes
        _ => b""
      }
      @mttp_core.Response::new(200, body=Bytes(bytes))
    },
    (url, _) => {
      let backend = new_backend()
      defer backend.close()
      let payload = Bytes::make(70000, b'x')
      assert_eq(
        body(
          backend.send(
            @mttp_core.Request::post(url).body_bytes(payload),
            @mttp_core.SendOptions::default(),
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
        let request = @mttp_core.Request::post(url).body_stream(
          stream,
          length?=if known { Some(70000L) } else { None },
        )
        assert_eq(
          body(backend.send(request, @mttp_core.SendOptions::default())),
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
impl @mttp_core.BodyStream for UploadSource with fn read_some(self) {
  self.reads += 1
  if self.failing {
    raise @mttp_core.TransportError(
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
impl @mttp_core.BodyStream for UploadSource with fn close(self) {
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
        @mttp_core.Request::post("http://127.0.0.1:\{port_of(listener.addr)}").body_stream(
          source,
          length?=if failing { None } else { Some(0L) },
        ),
        @mttp_core.SendOptions::default(),
      )
    catch {
      @mttp_core.TransportError(kind=Unreplayable, phase~, detail~) if failing =>
        assert_eq((phase, detail), (Write, "upload sentinel"))
      @mttp_core.TransportError(kind=Protocol, ..) if !failing => ()
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
  with_server(_ => @mttp_core.Response::new(413, body=Bytes(b"no")), (url, _) => {
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
      @mttp_core.Request::post(url).body_stream(source),
      @mttp_core.SendOptions::default(),
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
  let port = port_of(listener.addr)
  listener.close()
  let backend = new_backend()
  defer backend.close()
  try
    backend.send(
      @mttp_core.Request::get("http://127.0.0.1:\{port}"),
      @mttp_core.SendOptions::default(),
    )
  catch {
    @mttp_core.TransportError(kind=Connect, phase=Dial, ..) as error =>
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
      @mttp_core.Response::new(200)
    },
    (url, _) => {
      let backend = new_backend()
      defer backend.close()
      try
        backend.send(@mttp_core.Request::get(url), {
          ..@mttp_core.SendOptions::default(),
          timeout_ms: Some(30),
        })
      catch {
        @mttp_core.TransportError(kind=Timeout(ms=30), phase=Head, ..) => ()
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
            backend.send(
              @mttp_core.Request::get(url),
              @mttp_core.SendOptions::default(),
            ) catch {
              _ => {
                caught.val = true
                @mttp_core.Response::new(599)
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
impl @mttp_core.BodyStream for StalledBody with fn read_some(self) {
  if self.first {
    self.first = false
    return Some(b"x")
  }
  @async.sleep(10000)
  None
}

///|
impl @mttp_core.BodyStream for StalledBody with fn close(_) {
  ()
}

///|
async test "socket Exchange deadline and Stream idle deadline cover body reads" {
  for streaming in [false, true] {
    with_server(
      _ => {
        @mttp_core.Response::new(
          200,
          body=Stream(@mttp_core.StreamBody::new(StalledBody::{ first: true, })),
        )
      },
      (url, _) => {
        let backend = new_backend()
        defer backend.close()
        let response = backend.send(@mttp_core.Request::get(url), {
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
          @mttp_core.TransportError(kind=Timeout(ms~), phase=Body, ..) =>
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
    @mttp_core.Response::new(200, body=@codings.encode_body(Bytes(b"x"), Gzip)),
  )
  for streaming in [false, true] {
    with_server(
      _ => {
        @mttp_core.Response::new(
          200,
          body=Bytes(encoded),
          headers=@mttp_core.Headers::of([("content-encoding", "gzip")]),
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
            backend.send(@mttp_core.Request::get(url), {
              timeout_ms: None,
              body: if streaming {
                Stream(idle_ms=None)
              } else {
                Exchange(max_bytes=1000)
              },
            }),
          )
        catch {
          @mttp_core.TransportError(kind=TooLarge(limit~), phase=Body, ..) =>
            assert_eq(limit, encoded.length() - 1)
          error => raise error
        } noraise {
          _ => fail("wire ceiling ignored")
        }
        assert_eq(backend.idle_connections(), 0)
      },
    )
  }
  with_server(_ => @mttp_core.Response::new(200, body=Bytes(b"abcd")), (url, _) => {
    let backend = new_backend()
    defer backend.close()
    try
      body(
        backend.send(@mttp_core.Request::get(url), {
          timeout_ms: None,
          body: Exchange(max_bytes=3),
        }),
      )
    catch {
      @mttp_core.TransportError(kind=TooLarge(limit=3), phase=Body, ..) => ()
      error => raise error
    } noraise {
      _ => fail("Exchange cap ignored")
    }
  })
}
