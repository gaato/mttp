///|
async test "JS connect rejects unsupported extensions before attempting I/O" {
  for
    headers in [
      @mttp_core.Headers::of([("x-test", "value")]),
      @mttp_core.Headers::of([]),
    ] {
    try
      @ws.connect("ws://127.0.0.1:1/", headers~, origin="https://example.test")
    catch {
      @core_ws.WsError(kind=Handshake(status=0), detail~) =>
        assert_true(detail.contains("custom headers"))
      _ => fail("unexpected custom-header failure")
    } noraise {
      _ => fail("standard WebSocket silently dropped headers")
    }
  }
  try
    @ws.connect("ws://example.test/", extensions=["permessage-deflate"])
  catch {
    @core_ws.WsError(kind=Handshake(status=0), detail~) =>
      assert_true(detail.contains("extensions"))
    _ => fail("unexpected WebSocket error")
  } noraise {
    _ => fail("JS accepted WebSocket connect")
  }
}
