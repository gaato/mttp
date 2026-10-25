///|
async fn[T] decoded(
  input : @endpoint.Input[T],
  request : @model.Request,
  captures~ : Map[String, String] = {},
) -> T {
  let result : Ref[T?] = Ref(None)
  let failures = []
  let endpoint = @endpoint.endpoint
    .post("/")
    .input(input)
    .serve_public(value => result.val = Some(value))
  let context = @endpoint.DispatchContext::new(decode_failure=context => {
    failures.append(context.failures)
    @model.Response::new(400)
  })
  let response = endpoint.dispatch(request, captures, context)
  defer response.close()
  match result.val {
    Some(value) => value
    None => raise @endpoint.InputErrors(failures)
  }
}

///|
async fn[T] refused(
  input : @endpoint.Input[T],
  request : @model.Request,
  captures~ : Map[String, String] = {},
) -> Array[@endpoint.InputFailure] {
  try {
    ignore(decoded(input, request, captures~))
    raise Failure("input was accepted")
  } catch {
    @endpoint.InputErrors(failures) => failures
    error => raise error
  }
}

///|
test "rest captures reject missing and malformed canonical segment encoding" {
  @driver.run_sync(() => {
    let input = @endpoint.paths("tail")
    let request = @model.Request::get("/")
    assert_eq(refused(input, request).length(), 1)
    for raw in ["no-slash", "/%GG"] {
      assert_eq(refused(input, request, captures={ "tail": raw }).length(), 1)
    }
  })
}

///|
test "head inputs distinguish absence repetition and malformed values" {
  @driver.run_sync(() => {
    let request = @model.Request::post("/?q=12")
    assert_eq(decoded(@endpoint.query("q", @schema.int), request), 12)
    assert_eq(
      decoded(@endpoint.query("q", @schema.int).optional(), request),
      Some(12),
    )
    assert_eq(
      decoded(@endpoint.query("missing", @schema.int).optional(), request),
      None,
    )
    assert_true(
      refused(@endpoint.query("q", @schema.int), @model.Request::post("/")).length() ==
      1,
    )
    assert_true(
      refused(
        @endpoint.query("q", @schema.int),
        @model.Request::post("/?q=1&q=2"),
      )[0].failure
      is @schema.DecodeFailure(kind=Multiple(_), ..),
    )
    assert_true(
      !refused(
        @endpoint.query("q", @schema.int).optional(),
        @model.Request::post("/?q=bad"),
      ).is_empty(),
    )
    assert_true(
      !refused(@endpoint.header("x", @schema.int), request.header("x", "bad")).is_empty(),
    )
    assert_true(!refused(@endpoint.path("id", @schema.int), request).is_empty())
    assert_true(
      !refused(@endpoint.path("id", @schema.int), request, captures={
        "id": "bad",
      }).is_empty(),
    )
    let pair = @endpoint.pair(
      @endpoint.query("a", @schema.int),
      @endpoint.header("b", @schema.int),
    )
    assert_eq(refused(pair, request).length(), 2)
    assert_eq(
      refused(
        @endpoint.query_list("q", @schema.int),
        @model.Request::post("/?q=a&q=b"),
      ).length(),
      2,
    )
    assert_eq(
      decoded(@endpoint.query_params(), @model.Request::post("/?q=a&q=b")),
      [("q", "a"), ("q", "b")],
    )
    assert_eq(
      decoded(@endpoint.headers(), request.header("x", "1")).get("x"),
      Some("1"),
    )
    assert_eq(
      decoded(
        @endpoint.last_event_id(),
        request.header("last-event-id", "event"),
      ),
      Some("event"),
    )
    let atoms = @endpoint.query("q", @schema.int).atoms()
    atoms.clear()
    assert_eq(@endpoint.query("q", @schema.int).atoms().length(), 1)
  })
}

///|
test "cookies API keys and Basic credentials reject ambiguous input" {
  @driver.run_sync(() => {
    let request = @model.Request::post("/")
    let cookie = @endpoint.cookie("session", @schema.int)
    assert_true(!refused(cookie, request).is_empty())
    assert_true(
      !refused(cookie, request.header("cookie", "session=1; session=2")).is_empty(),
    )
    assert_true(
      !refused(cookie, request.header("cookie", "session=x")).is_empty(),
    )
    assert_eq(
      decoded(cookie, request.header("cookie", "ignored; x=3; session=42")),
      42,
    )
    assert_eq(
      decoded(@endpoint.api_key_header("key"), request.header("key", "secret")),
      "secret",
    )
    assert_eq(
      decoded(
        @endpoint.api_key_query("key"),
        @model.Request::post("/?key=secret"),
      ),
      "secret",
    )
    assert_eq(
      decoded(
        @endpoint.api_key_cookie("key"),
        request.header("cookie", "key=secret"),
      ),
      "secret",
    )
    assert_true(!refused(@endpoint.api_key_cookie("key"), request).is_empty())
    for value in ["Bearer token", "Basic %%%", "Basic /w==", "Basic dXNlcg=="] {
      assert_true(
        !refused(@endpoint.basic(), request.header("authorization", value)).is_empty(),
      )
    }
    assert_eq(
      decoded(
        @endpoint.basic(),
        request.header("authorization", "bAsIc   dXNlcjo="),
      ),
      ("user", ""),
    )
    assert_eq(
      decoded(
        @endpoint.signature_header("signature"),
        request.header("signature", "signed"),
      ),
      "signed",
    )
  })
}

///|
test "body mappings report decode failures and optional body encoding is reversible" {
  @driver.run_sync(() => {
    let body = @endpoint.body(@schema.jint.body())
    let request = @model.Request::post("/")
      .header("content-type", "application/json")
      .body_bytes(b"1")
    assert_eq(decoded(body, request), 1)
    assert_true(!refused(body, request.body_bytes(b"bad")).is_empty())
    assert_eq(
      decoded(body.optional(), @model.Request::post("/").body_bytes(b"")),
      None,
    )
    let mapped = body.map(
      value => {
        if value < 2 {
          raise @schema.DecodeFailure(kind=Malformed, message="too small")
        }
        value.to_string()
      },
      _ => 2,
    )
    assert_eq(decoded(mapped, request.body_bytes(b"2")), "2")
    assert_true(!refused(mapped, request).is_empty())
    let head_mapped = @endpoint.unit().map(
      _ => raise @schema.DecodeFailure(kind=Malformed, message="derived"),
      (_ : Unit) => (),
    )
    assert_true(refused(head_mapped, request)[0].atom.location is Derived)
    let optional = @endpoint.endpoint.post("/").input(body.optional())
    assert_eq(optional.request((), Some(3)).raw().body, @model.Bytes(b"3"))
    assert_eq(optional.request((), None).raw().body, @model.Empty)
    let signed = @endpoint.endpoint
      .post("/")
      .security(
        @endpoint.pair(
          @endpoint.signature_header("signature"),
          @endpoint.raw_body(),
        ),
      )
    let called = Ref(false)
    let server = signed.serve(
      credentials => {
        assert_eq(credentials, ("sig", b"signed"))
        called.val = true
      },
      (_, _) => (),
    )
    let req = signed.request(("sig", b"signed"), ()).raw()
    assert_eq(
      server.dispatch(req, Map([]), @endpoint.DispatchContext::new()).status,
      200,
    )
    assert_true(called.val)
  })
}

///|
test "forwarded addresses are opt in and metadata inputs encode through the client" {
  let request = @model.Request::post("/")
    .attribute(@model.remote_addr, "peer")
    .header("x-forwarded-for", " client, proxy")
  @driver.run_sync(() => {
    assert_eq(decoded(@endpoint.client_ip(), request), Some("peer"))
    assert_eq(
      decoded(@endpoint.client_ip(trust_forwarded=true), request),
      Some("client"),
    )
    assert_eq(
      decoded(@endpoint.client_ip(trust_forwarded=true), {
        ..request,
        headers: request.headers.set("x-forwarded-for", ""),
      }),
      Some("peer"),
    )
  })
  let ep = @endpoint.endpoint
    .post("/")
    .input(@endpoint.pair(@endpoint.query_params(), @endpoint.headers()))
  let raw = ep
    .request((), ([("a", "a b"), ("a", "+")], @model.Headers::of([("x", "1")])))
    .raw()
  assert_eq(raw.url, "/?a=a+b&a=%2B")
  assert_eq(raw.headers.get("x"), Some("1"))
  let address = @endpoint.endpoint.post("/").input(@endpoint.client_ip())
  assert_eq(address.request((), Some("ignored")).raw().headers.length(), 0)
  let attribute = @endpoint.endpoint
    .post("/")
    .input(@endpoint.attribute(@model.remote_addr))
  assert_eq(attribute.request((), Some("ignored")).raw().headers.length(), 0)
  let auth = @endpoint.endpoint.get("/").security(@endpoint.bearer())
  assert_eq(
    auth.request("token", ()).raw().headers.get("authorization"),
    Some("Bearer token"),
  )
  let cookies = @endpoint.endpoint
    .get("/")
    .input(
      @endpoint.pair(
        @endpoint.cookie("a", @schema.string),
        @endpoint.cookie("b", @schema.string),
      ),
    )
  assert_eq(
    cookies.request((), ("one", "two")).raw().headers.get("cookie"),
    Some("a=one; b=two"),
  )
}

///|
test "custom staged encoders can supply captures query pairs and body bytes" {
  let input = @endpoint.Input::new(
    [
      @endpoint.Atom::new(Path, "id", @schema.string.schema()),
      @endpoint.Atom::new(
        Body(media_type="text/plain", streamed=false),
        "body",
        @schema.raw_bytes.schema(),
      ),
    ],
    head => {
      @endpoint.Staged::after_body(body => {
        let bytes = match body {
          Buffered(bytes) => bytes
          _ => b""
        }
        (head.captures.get("id").unwrap_or(""), head.query, bytes)
      })
    },
    (value, sink) => {
      sink.set_capture("id", value.0)
      for (key, value) in value.1 {
        sink.add_query(key, value)
      }
      sink.set_body(Bytes(value.2))
    },
  )
  let endpoint = @endpoint.endpoint.post("/{id}").input(input)
  let value = ("a/b", [("q", "+")], b"body")
  let request = endpoint.request((), value).raw()
  assert_eq(request.url, "/a%2Fb?q=%2B")
  @driver.run_sync(() => {
    assert_eq(decoded(input, request, captures={ "id": "a/b" }), value)
  })
  let driver = @driver.Driver::new()
  driver.run(() => {
    let stream = @feed.Feed::bytes(driver, [b"body"])
    let endpoint = @endpoint.endpoint.post("/").input(@endpoint.stream_body())
    let request = endpoint.request((), stream).raw()
    assert_eq(@client.read_body(request.body, 10), b"body")
  })
}
