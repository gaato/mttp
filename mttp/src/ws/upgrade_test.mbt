///|
test "upgrade preserves handshake refusal statuses and headers" {
  let request = @handshake.client_request(
    "ws://example.test/",
    key="dGhlIHNhbXBsZSBub25jZQ==",
  )
  let denied = @ws.upgrade(
    { ..request, headers: request.headers.set("origin", "http://other.test"), },
    handler=_ => (),
  )
  assert_eq(denied.status, 403)
  let version = @ws.upgrade(
    { ..request, headers: request.headers.set("sec-websocket-version", "12"), },
    handler=_ => (),
  )
  assert_eq(version.status, 426)
  assert_eq(version.headers.get("sec-websocket-version"), Some("13"))
  assert_eq(
    @ws.upgrade({ ..request, meth: Post, }, handler=_ => ()).status,
    400,
  )
}

///|
#cfg(not(target="js"))
test "upgrade selects the first supported offered protocol and installs handover" {
  let request = @handshake.client_request(
    "ws://example.test/",
    key="dGhlIHNhbXBsZSBub25jZQ==",
    subprotocols=["first", "second"],
  )
  let response = @ws.upgrade(request, subprotocols=["second", "first"], handler=_ => {
    ()
  })
  assert_eq(response.status, 101)
  assert_eq(response.headers.get("sec-websocket-protocol"), Some("first"))
  assert_true(response.attributes.get(@rt.upgrade) is Some(_))
  assert_false(response.headers.contains("sec-websocket-extensions"))
}
