///|
test "typed chat endpoint runs through Router byte pair with auth and handshake inputs" {
  let endpoint = @endpoint.ws_endpoint()
    .get("/chat/{room}")
    .input(@endpoint.path("room", @schema.string))
    .security(@endpoint.bearer())
    .messages(
      incoming=@endpoint.ws_json(@schema.jstring),
      outgoing=@endpoint.ws_json(@schema.jstring),
    )
    .subprotocols(["chat.v1"])
  let driver = @driver.Driver::new()
  let clock = @sim.SimClock::new(driver)
  let timer = @sim.SimTimer::new(driver)
  let coordination = @sim.SimCoordination::new(driver)
  let tasks : Array[@driver.Task] = []
  let router = @router.Router::new(
    [
      endpoint.serve(
        token => {
          if token == "ok" {
            Ok("user")
          } else {
            Err(@mttp_core.Response::new(401))
          }
        },
        (user, room, session) => {
          assert_eq(session.subprotocol(), Some("chat.v1"))
          session.send(user + "/" + room + ": " + session.recv())
          session.close({ code: Normal, reason: "done", })
        },
      ),
    ],
    clock~,
    timer~,
    coordination~,
    background=work => tasks.push(driver.spawn(work)),
  )
  defer router.close()
  assert_eq(
    router.docs()[0].websocket.unwrap().incoming,
    Some(@schema.jstring.schema()),
  )
  driver.run(() => {
    let connector : @endpoint.WsConnector = (request, protocols) => {
      let request = @handshake.client_request(
        @mttp_core.join_url("ws://in-process", request.url),
        key="dGhlIHNhbXBsZSBub25jZQ==",
        subprotocols=protocols,
        headers=request.headers,
      )
      let response = router.send(request, @mttp_core.SendOptions::default()) catch {
        e => raise @ws.WsError(kind=Transport(e), detail=e.message())
      }
      defer response.close()
      ignore(
        @handshake.check_server_response(
          response,
          key="dGhlIHNhbXBsZSBub25jZQ==",
          offered_subprotocols=protocols,
          offered_extensions=[],
        ),
      )
      response.attributes.get(@ws.ws_session).unwrap()
    }
    let session = endpoint.connect(connector, "ok", "main").unwrap()
    session.send("hello")
    assert_eq(session.recv(), "user/main: hello")
    session.close({ code: Normal, reason: "done", })
    for task in tasks {
      ignore(task.wait())
    }
    assert_true(
      endpoint.connect(connector, "bad", "main")
      is Err(ConnectFailed(@ws.WsError(kind=Handshake(status=401), ..))),
    )
  })
}

///|
test "Router refuses WebSocket missing codecs and HTTP GET path conflicts" {
  for
    routes in [
      [@endpoint.ws_endpoint().get("/chat").serve_public((_, _) => ())],
      [
        @endpoint.ws_endpoint()
        .get("/chat")
        .messages(incoming=@endpoint.ws_text(), outgoing=@endpoint.ws_text())
        .serve_public((_, _) => ()),
        @endpoint.endpoint.get("/chat").serve_public(_ => Ok(())),
      ],
    ] {
    try @router.Router::new(routes) catch {
      @endpoint.DefinitionError(problems) =>
        assert_true(problems.iter().any(p => p.fatal))
    } noraise {
      _ => fail("Router accepted bad routes")
    }
  }
}
