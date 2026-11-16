///|
test "WebSocket JSON nesting accepts 128 containers and closes on 129" {
  for depth in [128, 129] {
    let driver = @driver.Driver::new()
    let (raw, peer) = @sim.WebSocketStub::pair(
      @sim.SimCoordination::new(driver),
    )
    let typed = @endpoint.TypedSession::new(
      raw,
      incoming=@endpoint.ws_json(@schema.jvalue),
      outgoing=@endpoint.ws_binary(),
    )
    driver.run(() => {
      peer.send(Text("[".repeat(depth) + "0" + "]".repeat(depth)))
      if depth == 128 {
        ignore(typed.recv())
        typed.send(b"\x00\xff")
        assert_eq(peer.recv(), Binary(b"\x00\xff"))
        typed.abort()
      } else {
        try typed.recv() catch {
          @endpoint.MessageDecode(code=InvalidPayload, ..) => ()
          _ => fail("wrong nesting failure")
        } noraise {
          _ => fail("JSON nesting bound exceeded")
        }
        try peer.recv() catch {
          @ws.WsError(kind=Closed(frame), ..) =>
            assert_eq(frame.code.to_int(), 1007)
          _ => fail("wrong Close")
        } noraise {
          _ => fail("peer did not close")
        }
      }
    })
  }
}
