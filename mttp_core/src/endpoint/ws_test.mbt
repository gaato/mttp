///|
fn ws_chat() -> @endpoint.WsEndpoint[String, (String, Int32), String, String] {
  @endpoint.ws_endpoint()
  .get("/chat/{room}")
  .security(@endpoint.bearer())
  .input(
    @endpoint.pair(
      @endpoint.path("room", @schema.string),
      @endpoint.query("since", @schema.int),
    ),
  )
  .messages(
    incoming=@endpoint.ws_json(@schema.jstring),
    outgoing=@endpoint.ws_json(@schema.jstring),
  )
  .subprotocols(["chat.v1"])
  .operation_id("chat")
  .summary("Join chat")
  .tag("chat")
}

///|
test "WebSocket definitions require codecs and conflict with HTTP GET" {
  assert_true(
    @endpoint.ws_endpoint()
    .doc()
    .problems()
    .contains("WebSocket handshake must use GET"),
  )
  let missing = @endpoint.ws_endpoint().get("/chat").doc()
  assert_true(
    missing
    .problems()
    .contains("WebSocket endpoint requires incoming and outgoing codecs"),
  )
  let doc = ws_chat().doc()
  assert_eq(doc.problems(), [])
  assert_eq(doc.websocket.unwrap().incoming, Some(@schema.jstring.schema()))
  assert_eq(doc.websocket.unwrap().outgoing, Some(@schema.jstring.schema()))
  assert_eq(doc.info.operation_id, Some("chat"))
  assert_eq(doc.info.summary, Some("Join chat"))
  assert_eq(doc.info.tags, ["chat"])
  let http = @endpoint.endpoint
    .get("/chat/{room}")
    .input(@endpoint.path("room", @schema.string))
  assert_true(
    @endpoint.check_definitions([doc, http.doc()])
    .iter()
    .any(p => p.message.contains("conflicts with")),
  )
  assert_eq(
    @endpoint.check_definitions([
      doc,
      @endpoint.endpoint
      .post("/chat/{room}")
      .input(@endpoint.path("room", @schema.string))
      .doc(),
    ]),
    [],
  )
  for protocols in [[""], ["has space"], ["same", "same"], ["é"]] {
    assert_true(
      ws_chat()
      .subprotocols(protocols)
      .doc()
      .problems()
      .contains("invalid or duplicate WebSocket subprotocol"),
    )
  }
  assert_eq(ws_chat().get("/extra").doc().problems(), ["method set twice"])
}

///|
test "WebSocket definition and server docs own subprotocol arrays" {
  let protocols = ["chat.v1"]
  let ep = ws_chat().subprotocols(protocols)
  protocols.push("later")
  let server = chat_server(ep)
  let doc = server.doc()
  doc.websocket.unwrap().subprotocols.push("mutated")
  assert_eq(server.doc().websocket.unwrap().subprotocols, ["chat.v1"])
  assert_eq(ep.doc().websocket.unwrap().subprotocols, ["chat.v1"])
}

///|
fn chat_server(
  ep : @endpoint.WsEndpoint[String, (String, Int32), String, String],
) -> @endpoint.ServerEndpoint {
  ep.serve(
    token => {
      if token == "ok" {
        Ok(token)
      } else {
        Err(@mttp_core.Response::new(401))
      }
    },
    (_, _, _) => (),
  )
}

///|
test "WebSocket server refuses origin security malformed upgrade and bad inputs before 101" {
  let ep = ws_chat()
  let called = Ref(false)
  let server = ep.serve(
    token => {
      if token == "ok" {
        Ok(token)
      } else {
        Err(@mttp_core.Response::new(401))
      }
    },
    (_, _, _) => called.val = true,
  )
  let base = @handshake.client_request(
    "ws://example.test/chat/main?since=1",
    key="dGhlIHNhbXBsZSBub25jZQ==",
    subprotocols=["chat.v1"],
    headers=@mttp_core.Headers::of([("authorization", "Bearer ok")]),
  )
  @driver.run_sync(() => {
    for
      (request, status) in [
        (
          { ..base, headers: base.headers.set("origin", "http://other.test"), },
          403,
        ),
        ({ ..base, headers: base.headers.remove("authorization"), }, 401),
        (
          { ..base, headers: base.headers.set("authorization", "Bearer bad"), },
          401,
        ),
        (
          { ..base, headers: base.headers.set("sec-websocket-version", "12"), },
          426,
        ),
        ({ ..base, headers: base.headers.remove("upgrade"), }, 400),
        ({ ..base, url: "ws://example.test/chat/main?since=bad", }, 400),
      ] {
      let response = server.dispatch(
        request,
        { "room": "main" },
        @endpoint.DispatchContext::new(),
      )
      assert_eq(response.status, status)
      assert_true(response.attributes.get(@ws.server_handler) is None)
      if status == 426 {
        assert_eq(response.headers.get("sec-websocket-version"), Some("13"))
      }
    }
    let response = server.dispatch(
      base,
      { "room": "main" },
      @endpoint.DispatchContext::new(),
    )
    assert_eq(response.status, 101)
    assert_eq(response.headers.get("sec-websocket-protocol"), Some("chat.v1"))
    assert_true(response.attributes.get(@ws.server_handler) is Some(_))
    assert_false(called.val)
    let allowed = chat_server(ep.origins(Any)).dispatch(
      { ..base, headers: base.headers.set("origin", "http://other.test"), },
      { "room": "main" },
      @endpoint.DispatchContext::new(),
    )
    assert_eq(allowed.status, 101)
    let origins = ["http://other.test"]
    let allowlisted = chat_server(ep.origins(Allow(origins)))
    origins.clear()
    assert_eq(
      allowlisted.dispatch(
        { ..base, headers: base.headers.set("origin", "http://other.test"), },
        { "room": "main" },
        @endpoint.DispatchContext::new(),
      ).status,
      101,
    )
    let incomplete = @endpoint.ws_endpoint().get("/").serve_public((_, _) => ())
    assert_eq(
      incomplete.dispatch(base, {}, @endpoint.DispatchContext::new()).status,
      500,
    )
    let fault = @endpoint.ws_endpoint()
      .get("/")
      .messages(incoming=@endpoint.ws_text(), outgoing=@endpoint.ws_text())
      .serve_public((_, _) => raise Failure("handler failed"))
    let callback = fault.dispatch(base, {}, @endpoint.DispatchContext::new()).attributes
      .get(@ws.server_handler)
      .unwrap()
    let (raw, _) = @sim.WebSocketStub::pair(
      @sim.SimCoordination::new(@driver.current()),
    )
    try callback(raw) catch {
      Failure(message) => assert_eq(message, "handler failed")
      _ => fail("lost application handler error")
    } noraise {
      _ => fail("application handler error swallowed")
    }
    raw.abort()
  })
}

///|
test "WebSocket typed client encodes handshake and reverses message directions" {
  let driver = @driver.Driver::new()
  let coordination = @sim.SimCoordination::new(driver)
  let (raw, peer) = @sim.WebSocketStub::pair(
    coordination,
    subprotocol="chat.v1",
  )
  let encoded : Ref[(@mttp_core.Request, Array[String])?] = Ref(None)
  driver.run(() => {
    let result = ws_chat().connect(
      (request, protocols) => {
        encoded.val = Some((request, protocols))
        raw
      },
      "ok",
      ("a/b", 2),
    )
    let (request, protocols) = encoded.val.unwrap()
    assert_eq(request.url, "/chat/a%2Fb?since=2")
    assert_eq(request.headers.get("authorization"), Some("Bearer ok"))
    assert_eq(protocols, ["chat.v1"])
    let session = result.unwrap()
    assert_eq(session.subprotocol(), Some("chat.v1"))
    session.send("hello")
    assert_eq(peer.recv(), Text("\"hello\""))
    peer.send(Text("\"welcome\""))
    assert_eq(session.recv(), "welcome")
    session.close({ code: Normal, reason: "done", })
    session.abort()
  })
}

///|
test "WebSocket connect failures are typed values before ownership transfer" {
  let called = Ref(false)
  let connector : @endpoint.WsConnector = (_, _) => {
    called.val = true
    raise @ws.WsError(kind=Handshake(status=403), detail="forbidden")
  }
  @driver.run_sync(() => {
    assert_true(
      @endpoint.ws_endpoint().get("/").connect(connector, (), ())
      is Err(InvalidDefinition(_)),
    )
    assert_false(called.val)
    assert_true(
      ws_chat().connect(connector, "ok", ("..", 0))
      is Err(InvalidHandshakeInput(_)),
    )
    assert_false(called.val)
    assert_true(
      ws_chat().connect(connector, "ok", ("main", 0))
      is Err(ConnectFailed(@ws.WsError(kind=Handshake(status=403), ..))),
    )
    assert_true(called.val)
  })
  let (raw, _) = @sim.WebSocketStub::pair(
    @sim.SimCoordination::new(@driver.Driver::new()),
  )
  try @endpoint.ws_endpoint().client_session(raw) catch {
    @endpoint.DefinitionError(problems) =>
      assert_true(problems.iter().any(p => p.fatal))
  } noraise {
    _ => fail("wrapped an invalid definition")
  }
  raw.abort()
}

///|
test "typed JSON decode closes with 1007 and wrong message type with 1003" {
  for
    (message, code) in [
      (@ws.Text("not JSON"), @ws.InvalidPayload),
      (@ws.Binary(b"\"hello\""), @ws.UnsupportedData),
    ] {
    let driver = @driver.Driver::new()
    let (raw, peer) = @sim.WebSocketStub::pair(
      @sim.SimCoordination::new(driver),
    )
    let session = ws_chat().client_session(raw)
    driver.run(() => {
      peer.send(message)
      try session.recv() catch {
        @endpoint.MessageDecode(code=actual, failure~) => {
          assert_eq(actual, code)
          assert_false(failure.message().is_empty())
        }
        _ => fail("wrong typed receive error")
      } noraise {
        _ => fail("decode unexpectedly succeeded")
      }
      try peer.recv() catch {
        @ws.WsError(kind=Closed(frame), ..) => assert_eq(frame.code, code)
        _ => fail("peer did not receive Close")
      } noraise {
        _ => fail("peer stayed open")
      }
      try session.recv() catch {
        @endpoint.SessionFailure(@ws.WsError(kind=Closed(_), ..)) => ()
        _ => fail("transport error lost")
      } noraise {
        _ => fail("closed session received a value")
      }
    })
    let (server_raw, scripted) = @sim.WebSocketStub::pair(
      @sim.SimCoordination::new(driver),
    )
    let server = @endpoint.ws_endpoint()
      .get("/")
      .messages(
        incoming=@endpoint.ws_json(@schema.jstring),
        outgoing=@endpoint.ws_json(@schema.jstring),
      )
      .serve_public((_, s) => ignore(s.recv()))
    driver.run(() => {
      let response = server.dispatch(
        @handshake.client_request(
          "ws://example.test/",
          key="dGhlIHNhbXBsZSBub25jZQ==",
        ),
        {},
        @endpoint.DispatchContext::new(),
      )
      let handler = response.attributes.get(@ws.server_handler).unwrap()
      scripted.send(message)
      handler(server_raw)
      try scripted.recv() catch {
        @ws.WsError(kind=Closed(frame), ..) => assert_eq(frame.code, code)
        _ => fail("typed server did not close gracefully")
      } noraise {
        _ => fail("typed server stayed open")
      }
      // A subsequent peer Close is unwrapped for the host adapter's normal
      // Session-level Close handling instead of becoming a handler failure.
      try handler(server_raw) catch {
        @ws.WsError(kind=Closed(_), ..) => ()
        _ => fail("typed server lost normal Close")
      } noraise {
        _ => fail("closed receive unexpectedly succeeded")
      }
    })
  }
}

///|
test "text and binary codecs preserve messages and reject the opposite type" {
  let driver = @driver.Driver::new()
  let (raw, peer) = @sim.WebSocketStub::pair(@sim.SimCoordination::new(driver))
  let session = @endpoint.TypedSession::new(
    raw,
    incoming=@endpoint.ws_binary(),
    outgoing=@endpoint.ws_text(),
  )
  assert_eq(@endpoint.ws_text().schema(), @schema.text_body.schema())
  assert_eq(@endpoint.ws_binary().schema(), @schema.raw_bytes.schema())
  driver.run(() => {
    session.send("hello 世界")
    assert_eq(peer.recv(), Text("hello 世界"))
    peer.send(Binary(b"\x00\xff"))
    assert_eq(session.recv(), b"\x00\xff")
    peer.send(Text("wrong"))
    try session.recv() catch {
      @endpoint.MessageDecode(code=UnsupportedData, ..) => ()
      _ => fail("wrong error")
    } noraise {
      _ => fail("accepted Text as Binary")
    }
  })
}
