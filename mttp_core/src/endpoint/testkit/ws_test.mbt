///|
test "typed WebSocket stub pairs chat JSON messages with a scripted peer" {
  let endpoint = @endpoint.ws_endpoint()
    .get("/chat")
    .messages(
      incoming=@endpoint.ws_json(@schema.jstring),
      outgoing=@endpoint.ws_json(@schema.jint),
    )
  let driver = @driver.Driver::new()
  let coordination = @sim.SimCoordination::new(driver)
  let (client, peer) = @testkit.websocket_pair(
    endpoint,
    coordination~,
    subprotocol="chat.v1",
  )
  driver.run(() => {
    assert_eq(client.subprotocol(), Some("chat.v1"))
    client.send("hello")
    assert_eq(peer.recv(), Text("\"hello\""))
    peer.send(Text("42"))
    assert_eq(client.recv(), 42)
    peer.send(Text("\"not an integer\""))
    try client.recv() catch {
      @endpoint.MessageDecode(code=InvalidPayload, ..) => ()
      _ => fail("lost typed decode error")
    } noraise {
      _ => fail("invalid integer decoded")
    }
  })
  try
    @testkit.websocket_pair(@endpoint.ws_endpoint().get("/chat"), coordination~)
  catch {
    @endpoint.DefinitionError(_) => ()
  } noraise {
    _ => fail("stub accepted missing codecs")
  }
}
