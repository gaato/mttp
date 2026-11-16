///|
fn typed_chat() -> @endpoint.WsEndpoint[String, (String, Int32), String, String] {
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
fn typed_chat_server() -> @endpoint.ServerEndpoint {
  typed_chat().serve(
    token => {
      if token == "ok" {
        Ok("user")
      } else {
        Err(@mttp_core.Response::new(401))
      }
    },
    (user, input, session) => {
      session.send(
        user + "/" + input.0 + "/" + input.1.to_string() + ": " + session.recv(),
      )
      session.close({ code: Normal, reason: "done", })
    },
  )
}

///|
test "one typed chat definition serves Router connector stub and OpenAPI" {
  let ep = typed_chat()
  let driver = @driver.Driver::new()
  let clock = @sim.SimClock::new(driver)
  let timer = @sim.SimTimer::new(driver)
  let coordination = @sim.SimCoordination::new(driver)
  let tasks : Array[@driver.Task] = []
  let router = @router.Router::new(
    [typed_chat_server()],
    clock~,
    timer~,
    coordination~,
    background=work => tasks.push(driver.spawn(work)),
  )
  defer router.close()
  let connect = @ws.connector(base_url="ws://in-process", backend=router)
  driver.run(() => {
    let session = ep.connect(connect, "ok", ("main", 7)).unwrap()
    defer session.abort()
    session.send("hello")
    assert_eq(session.recv(), "user/main/7: hello")
    assert_eq(session.subprotocol(), Some("chat.v1"))
    session.close({ code: Normal, reason: "done", })
    for task in tasks {
      ignore(task.wait())
    }
    assert_true(
      ep.connect(connect, "bad", ("main", 0))
      is Err(ConnectFailed(@core_ws.WsError(kind=Handshake(status=401), ..))),
    )
    let (stub, peer) = @testkit.websocket_pair(ep, coordination~)
    stub.send("hello")
    assert_eq(peer.recv(), Text("\"hello\""))
    peer.send(Text("\"scripted\""))
    assert_eq(stub.recv(), "scripted")
    peer.send(Text("bad JSON"))
    try stub.recv() catch {
      @endpoint.MessageDecode(code=InvalidPayload, ..) => ()
      _ => fail("unexpected decode error")
    } noraise {
      _ => fail("accepted invalid JSON")
    }
  })
  let spec = @openapi.to_openapi(router.docs(), @apispec.Info::new("Chat", "1"))
  let operation = spec.paths["/chat/{room}"].operations["get"]
  assert_true(operation.responses.contains("101"))
  assert_eq(operation.security, Some([{ "bearer": [] }]))
  assert_eq(operation.extensions, {
    "x-websocket": { "subprotocols": ["chat.v1"] },
  })
  assert_true(router.docs()[0].websocket.unwrap().incoming is Some(_))
}

///|
#cfg(not(target="js"))
async test "typed chat server and client round trip over real sockets" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let ready = @runtime.RuntimeCoordination::new().signal()
      let address = Ref("")
      let router = @router.Router::new([typed_chat_server()])
      let server = group.spawn(allow_failure=true, () => {
        @server.serve(router.handler(), addr="127.0.0.1:0", on_listen=addr => {
          address.val = addr
          ready.notify()
        })
      })
      ready.wait()
      let connect = @ws.connector(base_url="ws://" + address.val)
      let session = typed_chat().connect(connect, "ok", ("main", 9)).unwrap()
      defer session.abort()
      assert_eq(session.subprotocol(), Some("chat.v1"))
      session.send("hello 世界")
      assert_eq(session.recv(), "user/main/9: hello 世界")
      session.close({ code: Normal, reason: "done", })
      assert_true(
        typed_chat().connect(connect, "bad", ("main", 0))
        is Err(ConnectFailed(@core_ws.WsError(kind=Handshake(status=401), ..))),
      )
      try
        @ws.connect(
          "ws://" + address.val + "/chat/main?since=0",
          origin="http://other.test",
          headers=@mttp_core.Headers::of([("authorization", "Bearer ok")]),
        )
      catch {
        @core_ws.WsError(kind=Handshake(status=403), ..) => ()
        _ => fail("wrong Origin refusal")
      } noraise {
        _ => fail("cross-origin connection accepted")
      }
      server.cancel()
      server.wait() catch {
        @async.WaitedTaskAlreadyCancelled => ()
        error => raise error
      }
    })
  })
}
