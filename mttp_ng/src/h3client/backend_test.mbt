// What H3Backend decides before any datagram: the network paths are tested
// in h3server and the root package, against servers of this module.

///|
let defaults : @mttp_core.SendOptions = @mttp_core.SendOptions::default()

///|
async test "try_send declines what HTTP/3 cannot send, before any I/O" {
  let b = @h3client.H3Backend::new()
  defer b.close()
  for
    request in [
      @mttp_core.Request::get("http://127.0.0.1:1/"),
      @mttp_core.Request::new(Connect, "https://127.0.0.1:1/"),
      @mttp_core.Request::get("https://127.0.0.1:1/").header(
        "upgrade", "websocket",
      ),
    ] {
    assert_true(b.try_send(request, defaults) is None)
  }
  assert_eq(b.connections(), 0)
}

///|
async test "invalid requests and options are refused in phase Pool" {
  let b = @h3client.H3Backend::new()
  defer b.close()
  for
    attempt in [
      () => {
        b.try_send(
          @mttp_core.Request::get("https://127.0.0.1:1/\r\n"),
          defaults,
        )
      },
      () => {
        b.try_send(@mttp_core.Request::get("https://127.0.0.1:1/"), {
          ..defaults,
          timeout_ms: Some(0),
        })
      },
    ] {
    try attempt() catch {
      @mttp_core.TransportError(phase~, ..) => assert_eq(phase, Pool)
    } noraise {
      _ => fail("an invalid send was not refused")
    }
  }
}

///|
async test "a closed backend refuses sends with Closed in phase Pool" {
  let b = @h3client.H3Backend::new()
  b.close()
  b.close()
  try b.send(@mttp_core.Request::get("https://127.0.0.1:1/"), defaults) catch {
    @mttp_core.TransportError(kind~, phase~, ..) => {
      assert_eq(kind, Closed)
      assert_eq(phase, Pool)
    }
  } noraise {
    _ => fail("a closed backend sent")
  }
}
