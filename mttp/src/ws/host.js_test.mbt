///|
async test "JS connect refuses before attempting I/O" {
  try @ws.connect("ws://example.test/") catch {
    @core_ws.WsError(kind=Handshake(status=0), detail~) =>
      assert_true(detail.contains("not supported on JS"))
    _ => fail("unexpected WebSocket error")
  } noraise {
    _ => fail("JS accepted WebSocket connect")
  }
}
