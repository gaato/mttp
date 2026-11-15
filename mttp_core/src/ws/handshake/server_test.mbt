///|
fn refusal(
  request : @mttp_core.Request,
  origins~ : @handshake.OriginPolicy = SameOrigin,
) -> (Int32, @mttp_core.Headers, String) {
  try @handshake.check_client_request(request, origins~) catch {
    @handshake.Refusal(status~, headers~, detail~) => (status, headers, detail)
  } noraise {
    _ => (0, @mttp_core.Headers::empty(), "accepted")
  }
}

///|
fn valid_request() -> @mttp_core.Request {
  try! @handshake.client_request(
    "ws://Example.COM/chat",
    key=example_key,
    subprotocols=["chat", "superchat"],
    extensions=["permessage-deflate; client_max_window_bits", "x-test; v=1"],
    origin="http://example.com",
  )
}

///|
priv struct UnknownBody {}

///|
impl @mttp_core.BodyStream for UnknownBody with fn read_some(_) {
  None
}

///|
impl @mttp_core.BodyStream for UnknownBody with fn close(_) {
  ()
}

///|
test "server accepts case insensitive Upgrade and Connection list forms" {
  let request = {
    ..valid_request(),
    headers: valid_request().headers
    .set("upgrade", "h2c, WebSocket")
    .set("connection", "keep-alive, uPgRaDe"),
  }
  let offer = @handshake.check_client_request(request, subprotocols=["chat"], extensions=[
    "permessage-deflate",
  ])
  assert_eq(offer.key, example_key)
  assert_eq(offer.subprotocols, ["chat", "superchat"])
  assert_eq(offer.extensions.map(extension => extension.name), [
    "permessage-deflate", "x-test",
  ])
}

///|
test "server refusal paths map to 400 403 and 426" {
  let base = valid_request()
  let cases : Array[(@mttp_core.Request, Int32)] = [
    ({ ..base, meth: Post, }, 400),
    ({ ..base, headers: base.headers.remove("host"), }, 400),
    ({ ..base, headers: base.headers.add("host", "other.test"), }, 400),
    ({ ..base, headers: base.headers.set("host", ""), }, 400),
    ({ ..base, headers: base.headers.remove("upgrade"), }, 400),
    ({ ..base, headers: base.headers.set("upgrade", "h2c"), }, 400),
    ({ ..base, headers: base.headers.remove("connection"), }, 400),
    ({ ..base, headers: base.headers.set("connection", "close"), }, 400),
    ({ ..base, headers: base.headers.remove("sec-websocket-key"), }, 400),
    (
      { ..base, headers: base.headers.add("sec-websocket-key", example_key), },
      400,
    ),
    (
      { ..base, headers: base.headers.set("sec-websocket-key", "not-base64"), },
      400,
    ),
    (
      { ..base, headers: base.headers.set("sec-websocket-key", "c2hvcnQ="), },
      400,
    ),
    ({ ..base, headers: base.headers.set("content-length", "1"), }, 400),
    ({ ..base, headers: base.headers.set("content-length", "bad"), }, 400),
    ({ ..base, headers: base.headers.set("content-length", "-1"), }, 400),
    (
      { ..base, headers: base.headers.set("transfer-encoding", "chunked"), },
      400,
    ),
    ({ ..base, body: Bytes(b"x"), }, 400),
    (
      { ..base, body: Stream(@mttp_core.StreamBody::new(UnknownBody::{ })), },
      400,
    ),
    ({ ..base, headers: base.headers.set("origin", "http://other.test"), }, 403),
  ]
  for (request, expected) in cases {
    assert_eq(refusal(request).0, expected)
  }
  for
    headers in [
      base.headers.remove("sec-websocket-version"),
      base.headers.set("sec-websocket-version", "12"),
      base.headers.add("sec-websocket-version", "13"),
    ] {
    let result = refusal({ ..base, headers, })
    assert_eq(result.0, 426)
    assert_eq(result.1.get("sec-websocket-version"), Some("13"))
  }
}

///|
test "server refuses malformed protocol extension and HTTP headers" {
  let base = valid_request()
  for
    headers in [
      base.headers.set("sec-websocket-protocol", "bad value"),
      base.headers.set("sec-websocket-protocol", "chat, chat"),
      base.headers.set("sec-websocket-extensions", "x; a="),
      base.headers.add("origin", "http://example.com"),
      base.headers.set("x-invalid", " leading"),
    ] {
    assert_eq(refusal({ ..base, headers, }).0, 400)
  }
  assert_eq(
    refusal({
      ..base,
      url: "http://[bad]/",
      headers: base.headers.set("origin", "http://example.com"),
    }).0,
    400,
  )
  assert_eq(
    refusal({ ..base, headers: base.headers.set("origin", "http://[bad]/"), }).0,
    403,
  )
  try @handshake.check_client_request(base, subprotocols=["bad value"]) catch {
    @handshake.Refusal(status~, ..) => assert_eq(status, 500)
  } noraise {
    _ => fail("invalid supported subprotocol was accepted")
  }
  try @handshake.check_client_request(base, extensions=["x; a="]) catch {
    @handshake.Refusal(status~, ..) => assert_eq(status, 500)
  } noraise {
    _ => fail("invalid supported extension was accepted")
  }
}

///|
test "Origin policy covers scheme host default ports allow lists and absence" {
  let base = valid_request()
  let origins : Array[(String, Bool)] = [
    ("http://EXAMPLE.com", true),
    ("http://example.com:80", true),
    ("http://example.com:81", false),
    ("https://example.com", false),
    ("http://other.test", false),
  ]
  for (origin, allowed) in origins {
    let result = refusal({
      ..base,
      headers: base.headers.set("origin", origin),
    })
    assert_eq(result.0 == 0, allowed)
  }
  assert_eq(refusal({ ..base, headers: base.headers.remove("origin"), }).0, 0)
  let other = {
    ..base,
    headers: base.headers.set("origin", "https://allowed.test:443"),
  }
  assert_eq(
    refusal(
      other,
      origins=Allow(["https://other.test", "https://ALLOWED.test"]),
    ).0,
    0,
  )
  assert_eq(refusal(other, origins=Allow(["https://other.test"])).0, 403)
  assert_eq(
    refusal(other, origins=Allow(["https://[bad]/", "https://allowed.test"])).0,
    0,
  )
  assert_eq(refusal(other, origins=Any).0, 0)
}

///|
fn response_with(
  headers : @mttp_core.Headers,
  status~ : Int32 = 101,
) -> @mttp_core.Response {
  @mttp_core.Response::new(status, headers~)
}

///|
fn valid_response() -> @mttp_core.Response {
  response_with(
    @mttp_core.Headers::of([
      ("upgrade", "websocket"),
      ("connection", "Upgrade"),
      ("sec-websocket-accept", @handshake.accept_value(example_key)),
      ("sec-websocket-protocol", "chat"),
      (
        "sec-websocket-extensions", "permessage-deflate; server_no_context_takeover",
      ),
    ]),
  )
}

///|
fn response_error(response : @mttp_core.Response) -> (Int32, String) {
  try
    @handshake.check_server_response(
      response,
      key=example_key,
      offered_subprotocols=["chat", "superchat"],
      offered_extensions=[
        "permessage-deflate; client_max_window_bits", "x-test",
      ],
    )
  catch {
    @ws.WsError(kind=Handshake(status~), detail~) => (status, detail)
    error => (599, "unexpected: \{@debug.to_string(error)}")
  } noraise {
    _ => (0, "accepted")
  }
}

///|
test "client validates 101 tokens accept subprotocol and extension subset" {
  let response = {
    ..valid_response(),
    headers: valid_response().headers
    .set("upgrade", "h2c, WebSocket")
    .set("connection", "keep-alive, uPgRaDe"),
  }
  let accepted = @handshake.check_server_response(
    response,
    key=example_key,
    offered_subprotocols=["chat", "superchat"],
    offered_extensions=["permessage-deflate; client_max_window_bits", "x-test"],
  )
  assert_eq(accepted.subprotocol, Some("chat"))
  assert_eq(accepted.extensions[0].name, "permessage-deflate")
  assert_eq(accepted.extensions[0].params[0].name, "server_no_context_takeover")
}

///|
test "client response validation covers every handshake field refusal" {
  let base = valid_response()
  let cases : Array[(@mttp_core.Response, Int32)] = [
    (response_with(base.headers, status=200), 200),
    ({ ..base, headers: base.headers.remove("upgrade"), }, 101),
    ({ ..base, headers: base.headers.set("upgrade", "h2c"), }, 101),
    ({ ..base, headers: base.headers.remove("connection"), }, 101),
    ({ ..base, headers: base.headers.set("connection", "close"), }, 101),
    ({ ..base, headers: base.headers.remove("sec-websocket-accept"), }, 101),
    (
      { ..base, headers: base.headers.set("sec-websocket-accept", "wrong"), },
      101,
    ),
    (
      {
        ..base,
        headers: base.headers.add(
          "sec-websocket-accept",
          @handshake.accept_value(example_key),
        ),
      },
      101,
    ),
    (
      { ..base, headers: base.headers.set("sec-websocket-protocol", "other"), },
      101,
    ),
    (
      {
        ..base,
        headers: base.headers.set("sec-websocket-protocol", "chat, superchat"),
      },
      101,
    ),
    (
      {
        ..base,
        headers: base.headers.add("sec-websocket-protocol", "superchat"),
      },
      101,
    ),
    (
      {
        ..base,
        headers: base.headers.set("sec-websocket-extensions", "unknown"),
      },
      101,
    ),
    (
      {
        ..base,
        headers: base.headers.set("sec-websocket-extensions", "x; a="),
      },
      101,
    ),
    (
      {
        ..base,
        headers: base.headers.add("sec-websocket-extensions", "x-test"),
      },
      101,
    ),
  ]
  for (response, expected) in cases {
    assert_eq(response_error(response).0, expected)
  }
}

///|
test "client request server offer and 101 response round trip random choices" {
  let protocols = ["p0", "p1", "p2"]
  let extensions = ["x0; a=1", "x1; flag", "x2; note=\"a b\""]
  let mut state = 0x12345U
  for _ in 0..<128 {
    state = state * 1664525U + 1013904223U
    let request = @handshake.client_request(
      "ws://example.com/socket",
      key=example_key,
      subprotocols=protocols,
      extensions~,
      origin="http://example.com",
    )
    let offer = @handshake.check_client_request(
      request,
      subprotocols=protocols,
      extensions~,
    )
    let chosen_protocol = if (state & 1U) == 0U {
      None
    } else {
      Some(
        protocols[((state >> 1) & 0x7fffffffU).reinterpret_as_int() %
        protocols.length()],
      )
    }
    let chosen_extensions = []
    for i, extension in offer.extensions {
      if (state & (1U << (i + 4))) != 0U {
        chosen_extensions.push(extension)
      }
    }
    let response = match chosen_protocol {
      Some(value) =>
        offer.accept(subprotocol=value, extensions=chosen_extensions)
      None => offer.accept(extensions=chosen_extensions)
    }
    let accepted = @handshake.check_server_response(
      response,
      key=example_key,
      offered_subprotocols=protocols,
      offered_extensions=extensions,
    )
    assert_eq(accepted.subprotocol, chosen_protocol)
    assert_eq(accepted.extensions, chosen_extensions)
  }
}

///|
test "Offer accept refuses selections outside client or server support" {
  let offer = @handshake.check_client_request(
    valid_request(),
    subprotocols=["chat"],
    extensions=["permessage-deflate"],
  )
  assert_true(
    ws_error_detail(() => ignore(offer.accept(subprotocol="superchat"))).contains(
      "selected subprotocol",
    ),
  )
  assert_true(
    ws_error_detail(() => {
      ignore(
        offer.accept(extensions=[
          ({ name: "x-test", params: [], } : @handshake.Extension),
        ]),
      )
    }).contains("selected extension"),
  )
}
