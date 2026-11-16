///|
priv struct ReplyBackend {
  run : async (@mttp_core.Request) -> @mttp_core.Response raise @mttp_core.TransportError
}

///|
impl @mttp_core.Backend for ReplyBackend with fn send(self, request, _) {
  (self.run)(request)
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
