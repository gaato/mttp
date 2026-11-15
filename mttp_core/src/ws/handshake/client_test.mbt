///|
let example_key : String = "dGhlIHNhbXBsZSBub25jZQ=="

///|
test "RFC key and accept examples" {
  assert_eq(
    @handshake.new_key(n => {
      if n == 16 {
        Some(Bytes::makei(n, i => i.to_byte()))
      } else {
        None
      }
    }),
    "AAECAwQFBgcICQoLDA0ODw==",
  )
  assert_eq(
    @handshake.accept_value(example_key),
    "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
  )
  assert_true(
    ws_error_detail(() => ignore(@handshake.new_key(_ => None))).contains(
      "no WebSocket key",
    ),
  )
  assert_true(
    ws_error_detail(() => ignore(@handshake.new_key(_ => Some(b"short")))).contains(
      "wrong length",
    ),
  )
}

///|
test "client request maps schemes and builds optional handshake fields" {
  let request = @handshake.client_request(
    "WSS://Example.COM:443/chat?room=1",
    key=example_key,
    subprotocols=["chat", "superchat"],
    extensions=["permessage-deflate; client_max_window_bits", "x-test; v=1"],
    origin="https://example.com",
    headers=@mttp_core.Headers::of([("cookie", "a=b")]),
  )
  assert_eq(request.meth, Get)
  assert_eq(request.url, "https://example.com/chat?room=1")
  assert_eq(request.headers.get("host"), Some("example.com"))
  assert_eq(request.headers.get("upgrade"), Some("websocket"))
  assert_eq(request.headers.get("connection"), Some("Upgrade"))
  assert_eq(request.headers.get("sec-websocket-key"), Some(example_key))
  assert_eq(request.headers.get("sec-websocket-version"), Some("13"))
  assert_eq(
    request.headers.get("sec-websocket-protocol"),
    Some("chat, superchat"),
  )
  assert_eq(
    request.headers.get("sec-websocket-extensions"),
    Some("permessage-deflate; client_max_window_bits, x-test; v=1"),
  )
  assert_eq(request.headers.get("origin"), Some("https://example.com"))
  assert_eq(request.headers.get("cookie"), Some("a=b"))
  request.validate()
  let plain = @handshake.client_request("ws://example.com", key=example_key)
  assert_eq(plain.url, "http://example.com/")
  assert_eq(plain.headers.get("host"), Some("example.com"))
  let query = @handshake.client_request(
    "ws://example.com?token=1",
    key=example_key,
  )
  assert_eq(query.url, "http://example.com/?token=1")
}

///|
test "client request refuses invalid URL key lists and header overrides" {
  for
    url in [
      "http://example.com/", "ws:///missing", "ws://[bad]/", "ws://user@example.com/",
      "ws://example.com/#fragment",
    ] {
    assert_true(
      ws_error_detail(() => {
        ignore(@handshake.client_request(url, key=example_key))
      }) !=
      "no error",
    )
  }
  for key in ["not-base64", "c2hvcnQ="] {
    assert_true(
      ws_error_detail(() => {
        ignore(@handshake.client_request("ws://example.com", key~))
      }) !=
      "no error",
    )
  }
  for protocols in [["bad value"], ["dup", "dup"]] {
    assert_true(
      ws_error_detail(() => {
        ignore(
          @handshake.client_request(
            "ws://example.com",
            key=example_key,
            subprotocols=protocols,
          ),
        )
      }) !=
      "no error",
    )
  }
  assert_true(
    ws_error_detail(() => {
      ignore(
        @handshake.client_request("ws://example.com", key=example_key, extensions=[
          "bad extension",
        ]),
      )
    }) !=
    "no error",
  )
  for
    name in [
      "host", "upgrade", "connection", "sec-websocket-key", "sec-websocket-version",
      "sec-websocket-protocol", "sec-websocket-extensions", "origin",
    ] {
    assert_true(
      ws_error_detail(() => {
        ignore(
          @handshake.client_request(
            "ws://example.com",
            key=example_key,
            headers=@mttp_core.Headers::of([(name, "override")]),
          ),
        )
      }).contains("overrides"),
    )
  }
  assert_true(
    ws_error_detail(() => {
      ignore(
        @handshake.client_request(
          "ws://example.com",
          key=example_key,
          headers=@mttp_core.Headers::of([("x-bad", " leading")]),
        ),
      )
    }).contains("invalid HTTP"),
  )
}
