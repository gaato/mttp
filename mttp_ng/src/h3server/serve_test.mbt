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
    "/stream" =>
      @mttp_core.Response::new(
        200,
        body=Stream(@mttp_core.StreamBody::new({ left: 50, size: 20000, })),
      )
    "/early" => @mttp_core.Response::new(413, body=Bytes(b"early"))
    "/ignore" => {
      // Lets the request body arrive, and answers without reading it.
      @async.sleep(100)
      @mttp_core.Response::new(200, body=Bytes(b"ignored"))
    }
    "/stuck" =>
      // A response whose body stops yielding after its first piece (the
      // first is pulled before the head).
      @mttp_core.Response::new(
        200,
        body=Stream(@mttp_core.StreamBody::new(Stuck::{ started: false, })),
      )
    "/silent" =>
      // A response whose body never yields its first piece.
      @mttp_core.Response::new(
        200,
        body=Stream(@mttp_core.StreamBody::new(Stuck::{ started: true, })),
      )
    "/slow" => {
      @async.sleep(300)
      @mttp_core.Response::new(200, body=Bytes(b"slow"))
    }
    "/drained" => {
      drained_started.val += 1
      @async.sleep(300)
      @mttp_core.Response::new(200, body=Bytes(b"drained"))
    }
    "/hang" => {
      drained_started.val += 1
      @async.sleep(1000000)
      @mttp_core.Response::new(200)
    }
    "/events" =>
      // An endless event stream: one event, then silence.
      {
        ..@mttp_core.Response::new(
          200,
          body=Stream(@mttp_core.StreamBody::new(Stuck::{ started: false, })),
        ),
        attributes: @mttp_core.Attributes::empty().put(
          @mttp_core.close_on_shutdown, true,
        ),
      }
    _ => @mttp_core.Response::new(404)
  }
}

///|
/// How many `/drained` and `/hang` handlers started.
let drained_started : Ref[Int32] = Ref(0)

///|
/// `left` pieces of `size` bytes.
priv struct Pieces {
  mut left : Int32
  size : Int32
}

///|
impl @mttp_core.BodyStream for Pieces with fn read_some(self) {
  if self.left == 0 {
    return None
  }
  self.left -= 1
  Some(Bytes::make(self.size, b'p'))
}

///|
impl @mttp_core.BodyStream for Pieces with fn close(_) {
  ()
}

///|
/// A body source that yields one piece, then never again.
priv struct Stuck {
  mut started : Bool
}

///|
impl @mttp_core.BodyStream for Stuck with fn read_some(self) {
  if !self.started {
    self.started = true
    return Some(b"x")
  }
  @async.sleep(1000000)
  None
}

///|
impl @mttp_core.BodyStream for Stuck with fn close(_) {
  ()
}

///|
async fn with_server(
  run : async (Int32) -> Unit,
  limits~ : @h1server.ServerLimits = @h1server.ServerLimits::default(),
) -> Unit {
  let quic = @h3.ServerQuic::from_pem(
    chain=@fs.read_text(testdata("localhost.pem")),
    key=@fs.read_text(testdata("localhost.key")),
  )
  @async.with_timeout(30000, () => {
    @async.with_task_group(group => {
      let port : Ref[Int32?] = Ref(None)
      let listening = @cond_var.Cond()
      group.spawn_bg(() => {
        @h3server.serve(answer, addr="127.0.0.1:0", quic~, limits~, on_listen=addr => {
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

///|
async test "streamed response bodies, early answers and the limits over HTTP/3" {
  with_server(
    // No handler deadline here: how long a body takes to stream depends on
    // the host (ASan makes it several times slower), and the limits below
    // must not turn into 504s.
    limits={ ..@h1server.ServerLimits::default(), max_body_bytes: 100000, },
    port => {
      let b = client()
      defer b.close()
      let response = b.send(
        @mttp_core.Request::get("https://localhost:\{port}/stream"),
        defaults,
      )
      assert_eq(response.body.read_all(max=4 << 20).length(), 1000000)
      // Declared too large: 413 before the handler.
      let response = b.send(
        @mttp_core.Request::post("https://localhost:\{port}/echo").body_bytes(
          Bytes::make(200000, b'x'),
        ),
        defaults,
      )
      assert_eq(response.status, 413)
      ignore(text(response))
      // Streamed too large: the read that crosses it fails, and 413.
      let response = b.send(
        {
          ..@mttp_core.Request::post("https://localhost:\{port}/echo"),
          body: Stream(@mttp_core.StreamBody::new({ left: 20, size: 10000, })),
        },
        defaults,
      )
      assert_eq(response.status, 413)
      ignore(text(response))
      // An answer before the request body: the client stops sending.
      let response = b.send(
        {
          ..@mttp_core.Request::post("https://localhost:\{port}/early"),
          body: Stream(
            @mttp_core.StreamBody::new({ left: 100000, size: 16384, }),
          ),
        },
        defaults,
      )
      assert_eq(response.status, 413)
      assert_eq(text(response), "early")
    },
  )
  // A handler over its deadline: 504 (the handler sleeps 300 ms).
  with_server(
    limits={
      ..@h1server.ServerLimits::default(),
      handler_timeout_ms: Some(100),
    },
    port => {
      let b = client()
      defer b.close()
      let response = b.send(
        @mttp_core.Request::get("https://localhost:\{port}/slow"),
        defaults,
      )
      assert_eq(response.status, 504)
      ignore(text(response))
    },
  )
}

///|
/// QUIC counts the request streams of a connection's life: the server gives
/// one back for each that closes, so a connection carries more requests
/// than `max_streams_bidi` (Codex's review of #58).
async test "one connection carries more requests than the stream limit" {
  with_server(port => {
    let b = client()
    defer b.close()
    for _ in 0..<150 {
      let response = b.send(
        @mttp_core.Request::get("https://localhost:\{port}/hello"),
        defaults,
      )
      assert_eq(text(response), "hello")
    }
    assert_eq(b.connections(), 1)
  })
}

///|
/// A response body whose source stops yielding is cut off after
/// `body_timeout_ms`, as HTTP/1.1 and HTTP/2 do (Codex's review of #58).
async test "a stuck response body is reset after body_timeout_ms" {
  with_server(
    limits={ ..@h1server.ServerLimits::default(), body_timeout_ms: 200, },
    port => {
      let b = client()
      defer b.close()
      let response = b.send(
        @mttp_core.Request::get("https://localhost:\{port}/stuck"),
        defaults,
      )
      try response.body.read_all(max=1024) catch {
        @mttp_core.TransportError(phase~, ..) => assert_eq(phase, Body)
      } noraise {
        _ => fail("a stuck body ended")
      }
    },
  )
}

///|
/// A request body that sends a small piece every 40 ms, for 40 seconds.
priv struct Trickle {
  mut left : Int32
}

///|
impl @mttp_core.BodyStream for Trickle with fn read_some(self) {
  if self.left == 0 {
    return None
  }
  self.left -= 1
  @async.sleep(40)
  Some(Bytes::make(100, b't'))
}

///|
impl @mttp_core.BodyStream for Trickle with fn close(_) {
  ()
}

///|
async test "a request body that keeps trickling ends at body_timeout_ms" {
  // Each piece wakes the handler's read; the body's deadline runs from its
  // first read all the same. Were it reset by each piece, the upload would
  // outlast the test's 30 seconds.
  with_server(
    limits={ ..@h1server.ServerLimits::default(), body_timeout_ms: 300, },
    port => {
      let client = client()
      defer client.close()
      let response = client.send(
        {
          ..@mttp_core.Request::post("https://localhost:\{port}/echo"),
          body: Stream(@mttp_core.StreamBody::new({ left: 1000, })),
        },
        defaults,
      )
      // The body's failure decides the answer, as h1server's does.
      assert_eq(response.status, 408)
      response.close()
    },
  )
}

///|
/// Body bytes a handler never read give the connection's window back when
/// its stream ends, or a few such requests would hold the window shut for
/// every later one (the audit of #58).
async test "request bodies nobody read leave the connection's window open" {
  with_server(port => {
    let b = client()
    defer b.close()
    // More than the connection's window (1 MiB) in all.
    for _ in 0..<8 {
      let response = b.send(
        @mttp_core.Request::post("https://localhost:\{port}/ignore").body_bytes(
          Bytes::make(200000, b'x'),
        ),
        defaults,
      )
      assert_eq(text(response), "ignored")
    }
    let response = b.send(
      @mttp_core.Request::post("https://localhost:\{port}/echo").body_bytes(
        Bytes::make(200000, b'y'),
      ),
      defaults,
    )
    assert_eq(response.headers.get("x-received"), Some("200000"))
    ignore(text(response))
    assert_eq(b.connections(), 1)
  })
}

///|
/// The first piece of a streamed response is pulled before the head: a
/// producer silent for `body_timeout_ms` from the start is answered 500.
async test "a response body silent from its start is answered 500" {
  with_server(
    limits={ ..@h1server.ServerLimits::default(), body_timeout_ms: 200, },
    port => {
      let b = client()
      defer b.close()
      let response = b.send(
        @mttp_core.Request::get("https://localhost:\{port}/silent"),
        defaults,
      )
      assert_eq(response.status, 500)
      ignore(text(response))
    },
  )
}

///|
/// A connection on which no request starts (a client that completes its
/// handshake and then keeps the connection alive without a request) is
/// closed after `header_timeout_ms`, as HTTP/2's server ends a connection
/// without streams (Codex's review of #58).
async test "a connection on which no request starts is closed after header_timeout_ms" {
  with_server(
    limits={ ..@h1server.ServerLimits::default(), header_timeout_ms: 300, },
    port => {
      let addr = @socket.Addr::parse("127.0.0.1:\{port}")
      let udp = @socket.UdpClient(addr)
      defer udp.close()
      let quic = @h3.QuicConn::client(
        @h3.ClientQuic::new(trust=PemFile(testdata("root.pem"))),
        host="localhost",
        remote_address=addr.to_string(),
      )
      defer quic.free()
      let mut handshake = false
      let mut closed = None
      // Answers what the server sends, and sends no request; the QUIC
      // idle timeout (30 s) is far off.
      for _ in 0..<400 {
        for datagram in quic.datagrams() {
          udp.send(datagram)
        }
        let got : Ref[Bytes?] = Ref(None)
        @async.with_timeout(25, () => got.val = Some(udp.recv(max_len=65536))) catch {
          _ => ()
        }
        match got.val {
          Some(datagram) => quic.read(datagram) catch { _ => () }
          None =>
            if quic.expiry_ms() == Some(0) {
              quic.on_expiry() catch {
                _ => ()
              }
            }
        }
        for event in quic.events() {
          match event {
            HandshakeDone => handshake = true
            ConnectionClosed(by_peer~, code~) => closed = Some((by_peer, code))
            _ => ()
          }
        }
        if closed is Some(_) {
          break
        }
      }
      assert_true(handshake)
      assert_eq(closed, Some((true, @h3.H3_NO_ERROR)))
    },
  )
}

///|
/// A response still going out keeps its connection busy after its handler
/// returned: `header_timeout_ms` does not close the connection under a
/// slow download (Codex's review of #58).
async test "a slow download outlasts header_timeout_ms over HTTP/3" {
  with_server(
    limits={ ..@h1server.ServerLimits::default(), header_timeout_ms: 300, },
    port => {
      let b = client()
      defer b.close()
      let response = b.send(
        @mttp_core.Request::get("https://localhost:\{port}/big"),
        defaults,
      )
      guard response.body is Stream(cell) else { fail("no stream body") }
      let source = cell.take()
      let mut total = 0
      while source.read_some() is Some(bytes) {
        total += bytes.length()
        @async.sleep(20)
      }
      assert_eq(total, 2000000)
    },
  )
}

///|
/// A server's GOAWAY that leaves a request unprocessed, without a reset of
/// its stream (RFC 9114, section 5.2, lets it), fails the request with
/// `Refused` at once, not at its deadline (Codex's review of #58). The
/// server here sends GOAWAY as soon as its handshake is done, before it
/// reads any request, and then reads nothing more: nghttp3 itself would
/// reset a request that arrives after its GOAWAY, which other servers need
/// not do.
async test "a GOAWAY that leaves a request unprocessed refuses it at once" {
  let quic = @h3.ServerQuic::from_pem(
    chain=@fs.read_text(testdata("localhost.pem")),
    key=@fs.read_text(testdata("localhost.key")),
  )
  let udp = @socket.UdpServer(@socket.Addr::parse("127.0.0.1:0"))
  defer udp.close()
  let bound = udp.addr.to_string()
  let port = bound[bound.rev_find(":").unwrap() + 1:].to_owned()
  @async.with_timeout(10000, () => {
    @async.with_task_group(group => {
      group.spawn_bg(() => {
        let buffer = FixedArray::make(65536, b'\x00')
        let mut conn : @h3.QuicConn? = None
        let mut shut = false
        defer (if conn is Some(c) { c.free() })
        while true {
          let got : Ref[(Int32, @socket.Addr)?] = Ref(None)
          @async.with_timeout(20, () => {
            got.val = Some(udp.recv_into(buffer.mut_view()))
          }) catch {
            _ => ()
          }
          guard got.val is Some((n, peer)) else {
            if conn is Some(c) && c.expiry_ms() == Some(0) {
              c.on_expiry() catch {
                _ => ()
              }
            }
            continue
          }
          if shut {
            continue
          }
          let datagram = Bytes::from_array(buffer[:n])
          let c = match conn {
            Some(c) => c
            None => {
              let c = @h3.QuicConn::server(
                quic,
                datagram,
                local_address=bound,
                remote_address=peer.to_string(),
              ) catch {
                _ => continue
              }
              conn = Some(c)
              c
            }
          }
          c.read(datagram) catch {
            _ => ()
          }
          if !shut && c.events().contains(HandshakeDone) {
            // No request read yet: GOAWAY names stream 0.
            c.shutdown(notice=false)
            shut = true
          }
          for out in c.datagrams() {
            udp.send(out, peer)
          }
        }
      })
      let b = client()
      defer b.close()
      try
        b.send(
          @mttp_core.Request::get("https://localhost:\{port}/unprocessed"),
          defaults,
        )
      catch {
        @mttp_core.TransportError(kind~, ..) => assert_eq(kind, Refused)
      } noraise {
        _ => fail("a request the GOAWAY left unprocessed got an answer")
      }
      group.return_immediately()
    })
  })
}

///|
/// Runs `run` with a server on 127.0.0.1 and a function that stops it (as
/// cancelling `serve` does), then waits for the server to end; the
/// milliseconds from the stop to the end.
async fn with_stopped_server(
  run : async (Int32, () -> Unit) -> Unit,
  limits~ : @h1server.ServerLimits = @h1server.ServerLimits::default(),
) -> Int64 {
  let quic = @h3.ServerQuic::from_pem(
    chain=@fs.read_text(testdata("localhost.pem")),
    key=@fs.read_text(testdata("localhost.key")),
  )
  let mut stopped_at = 0L
  let mut ended_at = 0L
  @async.with_timeout(30000, () => {
    @async.with_task_group(group => {
      let port : Ref[Int32?] = Ref(None)
      let listening = @cond_var.Cond()
      let server = group.spawn(allow_failure=true, () => {
        defer {
          ended_at = @env.now().reinterpret_as_int64()
        }
        @h3server.serve(answer, addr="127.0.0.1:0", quic~, limits~, on_listen=addr => {
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
      run(port.val.unwrap(), () => {
        stopped_at = @env.now().reinterpret_as_int64()
        server.cancel()
      })
      server.wait() catch {
        _ => ()
      }
    })
  })
  ended_at - stopped_at
}

///|
/// Waits until a `/drained` or `/hang` handler started after `started`.
async fn handler_started(started : Int32) -> Unit {
  while drained_started.val == started {
    @async.sleep(10)
  }
}

///|
async test "a stop lets a request in flight finish over HTTP/3, and takes no new one" {
  let outcome : Ref[String?] = Ref(None)
  let refused : Ref[Bool] = Ref(false)
  ignore(
    with_stopped_server(
      limits={ ..@h1server.ServerLimits::default(), drain_ms: 10000, },
      (port, stop) => {
        let b = client()
        defer b.close()
        @async.with_task_group(group => {
          group.spawn_bg(() => {
            let response = b.send(
              @mttp_core.Request::get("https://localhost:\{port}/drained"),
              defaults,
            )
            outcome.val = Some(text(response))
          })
          handler_started(drained_started.val)
          stop()
          // A new client is not taken while the server stops.
          let late = client()
          defer late.close()
          (late.send(
            @mttp_core.Request::get("https://localhost:\{port}/hello"),
            { ..defaults, timeout_ms: Some(1000), },
          )
          |> ignore) catch {
            _ => refused.val = true
          }
        })
      },
    ),
  )
  assert_eq(outcome.val, Some("drained"))
  assert_true(refused.val)
}

///|
async test "a stop ends a close_on_shutdown stream over HTTP/3" {
  let body : Ref[String?] = Ref(None)
  let took = with_stopped_server(
    limits={ ..@h1server.ServerLimits::default(), drain_ms: 10000, },
    (port, stop) => {
      let b = client()
      defer b.close()
      let response = b.send(
        @mttp_core.Request::get("https://localhost:\{port}/events"),
        defaults,
      )
      guard response.body is Stream(cell) else { fail("no stream body") }
      let source = cell.take()
      let got = Buffer()
      if source.read_some() is Some(first) {
        got.write_bytes(first)
      }
      stop()
      while source.read_some() is Some(bytes) {
        got.write_bytes(bytes)
      }
      body.val = Some(@utf8.decode_lossy(got.to_bytes()))
    },
  )
  assert_eq(body.val, Some("x"))
  // Ended by the stop, not by the drain time.
  assert_true(took < 5000L, msg="the stop took \{took} ms")
}

///|
async test "a stop cuts what is still running when drain_ms is out over HTTP/3" {
  let failed : Ref[Bool] = Ref(false)
  let took = with_stopped_server(
    limits={ ..@h1server.ServerLimits::default(), drain_ms: 300, },
    (port, stop) => {
      let b = client()
      defer b.close()
      @async.with_task_group(group => {
        group.spawn_bg(() => {
          (b.send(
            @mttp_core.Request::get("https://localhost:\{port}/hang"),
            defaults,
          )
          |> ignore) catch {
            _ => failed.val = true
          }
        })
        handler_started(drained_started.val)
        stop()
      })
    },
  )
  assert_true(failed.val)
  assert_true(took >= 300L && took < 5000L, msg="the stop took \{took} ms")
}

///|
/// A connection the client drops (here retired by its age) is closed on
/// the server's side at once by the client's CONNECTION_CLOSE, not at the
/// server's idle timeout: under `max_connections: 1`, the next connection
/// is taken.
async test "a connection the client drops frees the server's slot at once" {
  with_server(
    limits={
      ..@h1server.ServerLimits::default(),
      max_connections: 1,
      header_timeout_ms: 20000,
    },
    port => {
      let b = @h3client.H3Backend::new(
        trust=PemFile(testdata("root.pem")),
        max_connection_age_ms=100,
      )
      defer b.close()
      let url = "https://localhost:\{port}/hello"
      assert_eq(text(b.send(@mttp_core.Request::get(url), defaults)), "hello")
      @async.sleep(200)
      // The first connection is retired: the send drops it and dials anew.
      let response = b.send(@mttp_core.Request::get(url), {
        ..defaults,
        timeout_ms: Some(3000),
      })
      assert_eq(text(response), "hello")
      assert_eq(b.connections(), 1)
    },
  )
}
