///|
using @engine {type RequestBody, respond, watch_peer, reject}

///|
fn test_wire(tcp : @socket.Tcp, pending~ : Bytes = b"") -> Wire {
  let clock = @runtime.AsyncClock::new()
  let wire = Wire::new(
    @socket_conn.from_tcp(tcp),
    clock~,
    timer=@runtime.ClockTimer::new(clock~),
    coordination=@runtime.RuntimeCoordination::new(),
  )
  wire.pending = pending
  wire
}

///|
priv struct TimeoutReply {
  source : RequestBody
  record_failure : Bool
}

///|
async test "body deadline is shared across chunks and consumer pauses" {
  let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  defer listener.close()
  let client = @socket.Tcp::connect(listener.addr)
  defer client.close()
  let (tcp, _) = listener.accept()
  let wire = test_wire(tcp, pending=b"a")
  defer wire.close()
  let now = Ref(0L)
  let source = RequestBody::new(
    wire,
    Length(3L),
    { ..ServerLimits::default(), body_timeout_ms: 100, },
    false,
    now=() => now.val,
  )
  assert_eq(source.next(), Some(b"a"))
  now.val = 60L
  wire.pending = b"b"
  assert_eq(source.next(), Some(b"b"))
  assert_eq(source.budget(), 40)
  now.val = 100L
  wire.pending = b"c"
  for _ in 0..<2 {
    let expired = try {
      ignore(source.next())
      false
    } catch {
      @model.TransportError(kind=Timeout(ms=100), phase=Body, ..) => true
      _ => false
    }
    assert_true(expired)
  }
  // An expired body cannot consume newly available bytes or become reusable.
  assert_eq(wire.pending, b"c")
  assert_false(source.drain())
}

///|
impl @model.BodyStream for TimeoutReply with fn read_some(self) {
  let error = @model.TransportError(
    kind=Timeout(ms=30),
    phase=Body,
    detail="request timed out during response production",
  )
  if self.record_failure {
    self.source.failure = Some(error)
  }
  raise error
}

///|
impl @model.BodyStream for TimeoutReply with fn close(_) {

}

///|
async test "a request timeout recorded during first response production still yields 408" {
  for record_failure in [true, false] {
    let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer listener.close()
    let client = @socket.Tcp::connect(listener.addr)
    defer client.close()
    let (tcp, _) = listener.accept()
    let wire = test_wire(tcp)
    defer wire.close()
    let limits = ServerLimits::default()
    let source = RequestBody::new(wire, Length(1L), limits, false)
    let handler : @model.Handler = _ => {
      @model.Response::new(
        200,
        body=Stream(
          @model.StreamBody::new(TimeoutReply::{ source, record_failure, }),
        ),
      )
    }
    assert_false(
      respond(
        wire,
        @model.Request::post("http://example/"),
        source,
        Http11,
        handler,
        limits,
        () => false,
        _ => (),
        false,
      ),
    )
    assert_true(
      client.read_until("\r\n\r\n").unwrap().has_prefix("HTTP/1.1 408"),
    )
  }
}

///|
async test "listener failures are surfaced as Accept without leaking runtime errors" {
  let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  listener.close()
  let refused = try {
    run_listener(
      listener,
      _ => @model.Response::new(200),
      _ => (),
      ServerLimits::default(),
      _ => (),
      false,
    )
    false
  } catch {
    @config.Accept(..) => true
    _ => false
  }
  assert_true(refused)
}

///|
async test "closed sockets preserve read and write error phases and body failures are sticky" {
  let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  defer listener.close()
  let client = @socket.Tcp::connect(listener.addr)
  defer client.close()
  let (tcp, _) = listener.accept()
  let wire = test_wire(tcp)
  wire.close()
  let read_failed = try {
    ignore(wire.read())
    false
  } catch {
    @model.TransportError(kind=Network, phase=Body, ..) => true
    _ => false
  }
  assert_true(read_failed)
  let head_failed = try {
    ignore(wire.head(ServerLimits::default()))
    false
  } catch {
    @model.TransportError(kind=Network, phase=Head, ..) => true
    _ => false
  }
  assert_true(head_failed)
  {
    let cleaned = Ref(false)
    let session = @engine.Connection::new(wire)
    session.set_busy(true)
    @runtime.RuntimeCoordination::new().supervise(
      primary=() => {
        defer {
          cleaned.val = true
        }
        @cond_var.Cond().wait()
      },
      monitor=() => {
        watch_peer(
          session,
          RequestBody::new(wire, NoBody, ServerLimits::default(), false),
        )
      },
    ) catch {
      _ => ()
    }
    assert_true(cleaned.val)
  }
  let write_failed = try {
    wire.write(b"x", 100)
    false
  } catch {
    @model.TransportError(kind=Network, phase=Write, ..) => true
    _ => false
  }
  assert_true(write_failed)
  reject(wire, 400, ServerLimits::default())
  let body = RequestBody::new(wire, Length(1L), ServerLimits::default(), false)
  assert_false(body.drain())
  assert_false(body.drain())
  let repeated = try {
    ignore(body.next())
    false
  } catch {
    @model.TransportError(kind=Network, phase=Body, ..) => true
    _ => false
  }
  assert_true(repeated)
  @model.BodyStream::close(body)
  assert_eq(@model.BodyStream::read_some(body), None)
}

///|
async test "write deadlines bound a peer which never reads" {
  let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  defer listener.close()
  let client = @socket.Tcp::connect(listener.addr)
  defer client.close()
  let (tcp, _) = listener.accept()
  let wire = test_wire(tcp)
  defer wire.close()
  let chunk = Bytes::make(65536, b'x')
  let timed_out = @async.with_timeout(2000, () => {
    for _ in 0..<1024 {
      wire.write(chunk, 20) catch {
        @model.TransportError(kind=Timeout(ms=20), phase=Write, ..) =>
          return true
        error => raise error
      }
    }
    false
  })
  assert_true(timed_out)
}
