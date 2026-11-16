///|
priv struct ReplyBackend {
  run : async (@mttp_core.Request) -> @mttp_core.Response raise @mttp_core.TransportError
}

///|
async test "compression client validates response before handover and declines by default" {
  for
    response in [
      "permessage-deflate", "permessage-deflate; server_no_context_takeover; client_max_window_bits=14",
    ] {
    let conn = @sim.ScriptedConn::new([])
    let backend = ReplyBackend::{
      run: request => {
        let key = request.headers.get("sec-websocket-key").unwrap()
        assert_eq(
          request.headers.get("sec-websocket-extensions"),
          Some(
            "permessage-deflate; client_max_window_bits; server_no_context_takeover; client_no_context_takeover",
          ),
        ) catch {
          _ => abort("wrong offer")
        }
        let reply = @mttp_core.Response::new(
          101,
          headers=@mttp_core.Headers::of([
            ("connection", "Upgrade"),
            ("upgrade", "websocket"),
            ("sec-websocket-accept", @handshake.accept_value(key)),
            ("sec-websocket-extensions", response),
          ]),
        )
        {
          ..reply,
          attributes: reply.attributes.put(@rt.upgraded, TakenConn::{
            conn,
            taken: false,
          }),
        }
      },
    }
    try
      @ws.connect(
        "ws://example.test/",
        backend~,
        compression=@ws.Compression::new(),
      )
    catch {
      @core_ws.WsError(kind=Handshake(status=101), ..) => ()
      _ => fail("wrong negotiation failure")
    } noraise {
      _ => fail("invalid compression accepted")
    }
    assert_eq(conn.closes(), 1)
  }
  let request = @handshake.client_request(
    "ws://example.test/",
    key="dGhlIHNhbXBsZSBub25jZQ==",
    extensions=["permessage-deflate"],
  )
  let off = @ws.upgrade(request, handler=_ => ())
  assert_false(off.headers.contains("sec-websocket-extensions"))
  let on = @ws.upgrade(request, compression=@ws.Compression::new(), handler=_ => {
    ()
  })
  assert_eq(
    on.headers.get("sec-websocket-extensions"),
    Some(
      "permessage-deflate; server_no_context_takeover; client_no_context_takeover",
    ),
  )
}

///|
async test "compressed fragments allow interleaved controls and inflation past message bound sends 1009" {
  for size in [100, 101] {
    let raw = Bytes::make(size, b'a')
    // A final raw DEFLATE block plus the empty stored-block prefix, permitted
    // by RFC 7692. This is independent of our Extension encoder.
    let payload = @deflate.compress(raw) + b"\x00"
    let split = payload.length() / 2
    let packet = b"\x41" +
      Bytes::from_array([split.to_byte()]) +
      payload[:split].to_owned() +
      b"\x89\x01p" +
      b"\x80" +
      Bytes::from_array([(payload.length() - split).to_byte()]) +
      payload[split:].to_owned()
    let conn = @sim.ScriptedConn::new([Chunk(packet)])
    let backend = ReplyBackend::{
      run: request => {
        let key = request.headers.get("sec-websocket-key").unwrap()
        let reply = @mttp_core.Response::new(
          101,
          headers=@mttp_core.Headers::of([
            ("connection", "Upgrade"),
            ("upgrade", "websocket"),
            ("sec-websocket-accept", @handshake.accept_value(key)),
            (
              "sec-websocket-extensions", "permessage-deflate; server_no_context_takeover",
            ),
          ]),
        )
        {
          ..reply,
          attributes: reply.attributes.put(@rt.upgraded, TakenConn::{
            conn,
            taken: false,
          }),
        }
      },
    }
    let session = @ws.connect(
      "ws://example.test/",
      backend~,
      compression=@ws.Compression::new(),
      limits={
        ..@core_ws.WsLimits::default(),
        max_message_bytes: 100,
        ping_interval_ms: None,
        pong_timeout_ms: None,
      },
    )
    defer session.abort()
    if size == 100 {
      assert_eq(session.recv(), Text(String::make(100, 'a')))
      session.send(Binary(b"Hello"))
    } else {
      try session.recv() catch {
        @core_ws.WsError(kind=TooLarge(limit=100), ..) => ()
        _ => fail("wrong overflow")
      } noraise {
        _ => fail("accepted oversized inflation")
      }
    }
    let parser = @frame.Parser::new(
      role=Server,
      max_frame_bytes=100,
      allow_rsv1=true,
    )
    for wire in conn.written() {
      parser.feed(wire)
    }
    let mut saw_pong = false
    let mut saw_data = false
    let mut saw_close = false
    let mut close_payload = false
    while parser.next() is Some(event) {
      match event {
        Head(head) => {
          if head.opcode is Pong {
            assert_false(head.rsv1)
            saw_pong = true
          }
          if head.opcode is Binary {
            assert_true(head.rsv1)
            saw_data = true
          }
          if head.opcode is Close {
            assert_false(head.rsv1)
            close_payload = true
          }
        }
        Payload(bytes) =>
          if close_payload {
            assert_eq(@core_ws.CloseFrame::parse(bytes).code.to_int(), 1009)
            saw_close = true
          }
        End => close_payload = false
      }
    }
    if size == 100 {
      assert_true(saw_pong && saw_data)
    } else {
      assert_true(saw_close)
    }
  }
}

///|
impl @mttp_core.Backend for ReplyBackend with fn send(self, request, _) {
  (self.run)(request)
}

///|
async test "compression over Router backend hands the byte codec to the negotiating client" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let clock = @runtime.AsyncClock::new()
      let router = @router.Router::new(
        [],
        clock~,
        timer=@runtime.ClockTimer::new(clock~),
        coordination=@runtime.RuntimeCoordination::new(),
        background=work => ignore(group.spawn(work)),
        options={
          ..@router.ServerOptions::default(),
          middleware: [
            (request, _) => {
              @ws.upgrade(
                request,
                compression=@ws.Compression::new(
                  server_no_context_takeover=false,
                  client_no_context_takeover=false,
                ),
                handler=session => {
                  for ;; {
                    let message = session.recv() catch { _ => break }
                    session.send(message)
                  }
                },
              )
            },
          ],
        },
      )
      defer router.close()
      let session = @ws.connect(
        "ws://example.test/",
        backend=router,
        compression=@ws.Compression::new(
          server_no_context_takeover=false,
          client_no_context_takeover=false,
        ),
      )
      defer session.abort()
      for _ in 0..<3 {
        session.send(Text("Hello compressed Router"))
        assert_eq(session.recv(), Text("Hello compressed Router"))
      }
      session.close({ code: Normal, reason: "", })
    })
  })
}

///|
priv struct TakenConn {
  conn : &@rt.Conn
  mut taken : Bool
}

///|
impl @rt.Upgraded for TakenConn with fn take_conn(self) {
  if self.taken {
    return None
  }
  self.taken = true
  Some((self.conn, b""))
}

///|
async test "failed accept closes a handed connection and a transport failure keeps its kind" {
  let conn = @sim.ScriptedConn::new([])
  let handover : &@rt.Upgraded = TakenConn::{ conn, taken: false, }
  let backend = ReplyBackend::{
    run: _ => {
      ..@mttp_core.Response::new(101),
      attributes: @mttp_core.Attributes::empty().put(@rt.upgraded, handover),
    },
  }
  try @ws.connect("ws://example.test/", backend~) catch {
    @core_ws.WsError(kind=Handshake(_), ..) => ()
    _ => fail("unexpected error")
  } noraise {
    _ => fail("accepted invalid 101")
  }
  assert_eq(conn.closes(), 1)
  assert_true(handover.take_conn() is None)
  let backend = ReplyBackend::{
    run: _ => {
      raise @mttp_core.TransportError(
        kind=Connect,
        phase=Dial,
        detail="dial failed",
      )
    },
  }
  try @ws.connect("ws://example.test/", backend~) catch {
    @core_ws.WsError(
      kind=Transport(@mttp_core.TransportError(kind=Connect, phase=Dial, ..)),
      ..
    ) => ()
    _ => fail("lost transport failure")
  } noraise {
    _ => fail("accepted transport failure")
  }
}

///|
async test "connect accepts a backend session and refuses unimplemented extensions before I/O" {
  let (session, peer) = @sim.WebSocketStub::pair(
    @runtime.RuntimeCoordination::new(),
  )
  defer peer.abort()
  let calls = Ref(0)
  let backend = ReplyBackend::{
    run: request => {
      calls.val += 1
      let key = request.headers.get("sec-websocket-key").unwrap()
      let response = @mttp_core.Response::new(
        101,
        headers=@mttp_core.Headers::of([
          ("connection", "Upgrade"),
          ("upgrade", "websocket"),
          ("sec-websocket-accept", @handshake.accept_value(key)),
        ]),
      )
      {
        ..response,
        attributes: response.attributes.put(@core_ws.ws_session, session),
      }
    },
  }
  let connected = @ws.connect("ws://example.test/", backend~)
  defer connected.abort()
  connected.send(Text("in process"))
  assert_eq(peer.recv(), Text("in process"))
  try
    @ws.connect("ws://example.test/", backend~, extensions=[
      "permessage-deflate",
    ])
  catch {
    @core_ws.WsError(kind=Handshake(status=0), ..) => ()
    _ => fail("unexpected error")
  } noraise {
    _ => fail("accepted unsupported extension")
  }
  assert_eq(calls.val, 1)
  let (invalid, remote) = @sim.WebSocketStub::pair(
    @runtime.RuntimeCoordination::new(),
  )
  defer remote.abort()
  let backend = ReplyBackend::{
    run: _ => {
      let response = @mttp_core.Response::new(101)
      {
        ..response,
        attributes: response.attributes.put(@core_ws.ws_session, invalid),
      }
    },
  }
  try @ws.connect("ws://example.test/", backend~) catch {
    @core_ws.WsError(kind=Handshake(_), ..) => ()
    _ => fail("unexpected error")
  } noraise {
    _ => fail("accepted invalid backend session handshake")
  }
  try remote.recv() catch {
    @core_ws.WsError(kind=Closed(_), ..) => ()
    _ => fail("unexpected error")
  } noraise {
    _ => fail("failed handshake left its backend session open")
  }
}

///|
async test "connect refuses redirects and missing handovers and wraps transport failures" {
  for status in [302, 101, 503] {
    let calls = Ref(0)
    let backend = ReplyBackend::{
      run: request => {
        calls.val += 1
        assert_eq(request.attributes.get(@client.redirect_limit), Some(0)) catch {
          _ => abort("redirect limit missing")
        }
        let headers = if status == 101 {
          @mttp_core.Headers::of([
            ("connection", "Upgrade"),
            ("upgrade", "websocket"),
            (
              "sec-websocket-accept",
              @handshake.accept_value(
                request.headers.get("sec-websocket-key").unwrap(),
              ),
            ),
          ])
        } else {
          @mttp_core.Headers::of([("location", "http://other.test/")])
        }
        @mttp_core.Response::new(status, headers~)
      },
    }
    try @ws.connect("ws://example.test/", backend~) catch {
      @core_ws.WsError(kind=Handshake(status=actual), ..) =>
        assert_eq(actual, status)
      _ => fail("unexpected WebSocket error")
    } noraise {
      _ => fail("accepted missing handover")
    }
    assert_eq(calls.val, 1)
  }
}
