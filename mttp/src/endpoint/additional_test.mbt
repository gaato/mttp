///|
test "definition verification checks all schemas route shapes and metadata" {
  let schema = @schema.Schema::of({ "type": "string" }).named("Named")
  let codec = @schema.BodyCodec::new(
    "text/plain",
    bytes => @schema.text_body.decode(bytes),
    value => @schema.text_body.encode(value),
    schema,
  )
  let ep = @endpoint.endpoint
    .get("/items/{id}")
    .security(@endpoint.header("x-auth", @schema.string))
    .input(@endpoint.path("id", @schema.int))
    .output(@endpoint.json_out(codec).and_header("x-count", @schema.int))
    .operation_id("items")
    .summary("Get item")
    .description("Description")
    .tag("items")
    .deprecated()
  let doc = ep.serve(_ => Ok(()), (_, id) => Ok((id.to_string(), id))).doc()
  assert_eq(doc.info.summary, Some("Get item"))
  assert_eq(doc.info.description, Some("Description"))
  assert_eq(doc.info.tags, ["items"])
  assert_true(doc.info.deprecated)
  assert_eq(@endpoint.check_definitions([doc]), [])
  assert_eq(@endpoint.DefinitionProblem::new("/", "problem").fatal, true)
  let duplicate = @endpoint.check_definitions([doc, doc])
  assert_true(duplicate.iter().any(p => p.message.contains("operation_id")))
  assert_true(duplicate.iter().any(p => p.message.contains("conflicts")))
  let invalid = [
    @endpoint.endpoint.doc(),
    @endpoint.endpoint.get("relative").doc(),
    @endpoint.endpoint.get("/a?b").doc(),
    @endpoint.endpoint.get("/a#b").doc(),
    @endpoint.endpoint.get("/a/").doc(),
    @endpoint.endpoint.get("/a//b").doc(),
    @endpoint.endpoint.get("/").max_body_bytes(-1).doc(),
    @endpoint.endpoint
    .get("/{x}/{x}")
    .input(@endpoint.path("x", @schema.int))
    .doc(),
    @endpoint.endpoint.get("/{rest...}").input(@endpoint.paths("rest")).doc(),
    @endpoint.endpoint.get("/").operation_id("").doc(),
    @endpoint.endpoint
    .get("/other")
    .output(
      @endpoint.json_out(
        @schema.BodyCodec::new(
          "other/type",
          bytes => @schema.raw_bytes.decode(bytes),
          value => value,
          @schema.Schema::of({ "type": "integer" }).named("Named"),
        ),
      ),
    )
    .doc(),
  ]
  let problems = @endpoint.check_definitions([doc, ..invalid])
  assert_true(problems.iter().any(p => p.message.contains("schema")))
  assert_true(problems.iter().any(p => p.message.contains("no method")))
}

///|
test "input lists basic authentication rest paths and server attributes roundtrip" {
  let key : @http.AttributeKey[String] = @http.AttributeKey::new("local")
  let input = @endpoint.Input::map4(
    @endpoint.paths("tail"),
    @endpoint.query_list("q", @schema.int),
    @endpoint.header("x-value", @schema.string),
    @endpoint.attribute(key),
    (a, b, c, d) => (a, b, c, d),
    value => value,
  )
  let ep = @endpoint.endpoint
    .post("/{tail...}")
    .security(@endpoint.basic())
    .input(input)
    .output(@endpoint.text_out())
  let server = ep.serve(
    credentials => {
      assert_eq(credentials, ("user", "pass"))
      Ok(())
    },
    (_, value) => {
      assert_eq(value, (["a", "b"], [1, 2], "header", Some("server")))
      Ok("done")
    },
  )
  let client = @client.Client::new(
    @client.from_handler(req => {
      server.dispatch(
        req.attribute(key, "server"),
        { "tail": "/a/b" },
        @endpoint.DispatchContext::new(),
      )
    }),
    @sim.FakeClock::new(),
  )
  defer client.close()
  @driver.run_sync(() => {
    assert_eq(
      ep.call(client, ("user", "pass"), (["a", "b"], [1, 2], "header", None)),
      Ok(Ok("done")),
    )
    assert_eq(
      decoded(@endpoint.paths("tail"), @http.Request::post("/"), captures={
        "tail": "",
      }),
      [],
    )
  })
}

///|
test "default rejection lists field locations and security challenges" {
  let invalid = @schema.string.validate(@schema.custom(_ => Some("invalid")))
  let server = @endpoint.endpoint
    .post("/{p}")
    .input(
      @endpoint.Input::map4(
        @endpoint.path("p", invalid),
        @endpoint.query("q", invalid),
        @endpoint.header("h", invalid),
        @endpoint.cookie("c", invalid),
        (_, _, _, _) => (),
        _ => ("", "", "", ""),
      ),
    )
    .serve_public(_ => Ok(()))
  @driver.run_sync(() => {
    let response = server.dispatch(
      @http.Request::post("/?q=x").header("h", "x").header("cookie", "c=x"),
      { "p": "x" },
      @endpoint.DispatchContext::new(),
    )
    let text = @utf8.decode(@client.read_body(response.body, 2000))
    for location in ["path", "query", "header", "cookie"] {
      assert_true(text.contains(location))
    }
    for
      (security, expected) in [
        (
          @endpoint.basic().map(_ => (), _ => ("", "")),
          "Basic charset=\"UTF-8\"",
        ),
        (@endpoint.api_key_header("x-api-key").map(_ => (), _ => ""), "ApiKey"),
      ] {
      let response = @endpoint.endpoint
        .post("/")
        .security(security)
        .serve(_ => Ok(()), (_, _) => Ok(()))
        .dispatch(
          @http.Request::post("/"),
          {},
          @endpoint.DispatchContext::new(),
        )
      assert_eq(response.headers.get("www-authenticate"), Some(expected))
    }
    let derived = @endpoint.unit().map(
      _ => raise @schema.DecodeFailure(kind=Malformed, message="invalid"),
      _ => (),
    )
    let response = @endpoint.endpoint
      .post("/")
      .input(derived)
      .serve_public((_ : Unit) => Ok(()))
      .dispatch(@http.Request::post("/"), {}, @endpoint.DispatchContext::new())
    assert_eq(response.status, 400)
    let error = @endpoint.FailureContext::new(
      @http.Request::post("/"),
      server.doc(),
      [],
      @endpoint.Head,
    )
    assert_eq(error.stage, @endpoint.Head)
  })
}

///|
test "declared handler errors and dynamic buffered representations roundtrip" {
  let ep = @endpoint.endpoint
    .get("/")
    .errors(@endpoint.text_out(status=403))
    .output(@endpoint.body_out())
  let denied = Ref(false)
  let server = ep.serve_public(_ => {
    if denied.val {
      Err("denied")
    } else {
      Ok(("custom/type", b"bytes"))
    }
  })
  let client = @client.Client::new(
    @client.from_handler(req => {
      server.dispatch(req, {}, @endpoint.DispatchContext::new())
    }),
    @sim.FakeClock::new(),
  )
  defer client.close()
  @driver.run_sync(() => {
    assert_eq(ep.call(client, (), ()), Ok(Ok(("custom/type", b"bytes"))))
    denied.val = true
    assert_eq(ep.call(client, (), ()), Ok(Err("denied")))
  })
}

///|
test "external custom inputs use ready stages and all request sink setters" {
  let input = @endpoint.Input::new(
    [@endpoint.Atom::new(Header, "custom", @schema.string.schema())],
    head => {
      @endpoint.Staged::ready(head.request.headers.get("custom").unwrap_or(""))
    },
    (value, sink) => {
      sink.set_header("custom", value)
      sink.add_query("q", "value")
      sink.set_body(Bytes(b"body"))
    },
  )
  let ep = @endpoint.endpoint
    .post("/")
    .input(input)
    .output(@endpoint.text_out())
  let server = ep.serve_public(value => Ok(value))
  let client = @client.Client::new(
    @client.from_handler(req => {
      server.dispatch(req, {}, @endpoint.DispatchContext::new())
    }),
    @sim.FakeClock::new(),
  )
  defer client.close()
  @driver.run_sync(() => {
    assert_eq(ep.call(client, (), "custom"), Ok(Ok("custom")))
  })
  // A custom streamed input may explicitly accept an absent body.
  let custom = @endpoint.Input::new(
    [
      @endpoint.Atom::new(
        Body(media_type="application/octet-stream", streamed=true),
        "body",
        @schema.raw_bytes.schema(),
      ),
    ],
    _ => {
      @endpoint.Staged::after_body(value => {
        guard value is Streamed(reader) else { raise @endpoint.InputErrors([]) }
        reader
      })
    },
    (_, _) => (),
  )
  let server = @endpoint.endpoint
    .post("/")
    .input(custom)
    .serve_public(reader => {
      assert_eq(reader.read_some(), None)
      Ok(())
    })
  @driver.run_sync(() => {
    assert_eq(
      server.dispatch(
        @http.Request::post("/"),
        {},
        @endpoint.DispatchContext::new(),
      ).status,
      200,
    )
  })
}

///|
#derive(Eq, Debug)
enum ApiError {
  Missing(Int32)
  Message(String)
}

///|
test "same status declared errors decode in order while framework problems stay outer failures" {
  let errors = @endpoint.one_of([
    @endpoint.json_variant(404, @schema.jint.body()).contramap(
      (value : ApiError) => {
        match value {
          Missing(id) => Some(id)
          _ => None
        }
      },
      id => Missing(id),
    ),
    @endpoint.json_variant(404, @schema.jstring.body()).contramap(
      (value : ApiError) => {
        match value {
          Message(message) => Some(message)
          _ => None
        }
      },
      message => Message(message),
    ),
  ])
  let ep = @endpoint.endpoint
    .get("/")
    .input(@endpoint.query("q", @schema.int))
    .errors(errors)
    .output(@endpoint.text_out())
  let server = ep.serve_public(id => {
    Err(if id == 0 { Missing(id) } else { Message("missing") })
  })
  let framework = Ref(false)
  let client = @client.Client::new(
    @client.from_handler(req => {
      if framework.val {
        @http.Response::new(
          404,
          headers=@http.Headers::of([
            ("content-type", "application/problem+json"),
          ]),
          body=Bytes(b"{}"),
        )
      } else {
        server.dispatch(req, {}, @endpoint.DispatchContext::new())
      }
    }),
    @sim.FakeClock::new(),
  )
  defer client.close()
  @driver.run_sync(() => {
    assert_eq(ep.call(client, (), 0), Ok(Err(Missing(0))))
    assert_eq(ep.call(client, (), 1), Ok(Err(Message("missing"))))
    assert_eq(ep.call_with(client, (), 1, _ => ()), Ok(Err(Message("missing"))))
    framework.val = true
    assert_true(
      ep.call(client, (), 0)
      is Err(@client.UnexpectedStatus({ status: 404, .. }, ..)),
    )
  })
}

///|
test "SSE schema decoding refuses duplicate keys and excessive JSON nesting" {
  let response = Ref(b"data: {\"a\":1,\"a\":2}\n\n")
  let client = @client.Client::new(
    @client.from_handler(_ => {
      @http.Response::new(
        200,
        headers=@http.Headers::of([("content-type", "text/event-stream")]),
        body=Bytes(response.val),
      )
    }),
    @sim.FakeClock::new(),
  )
  defer client.close()
  let ep = @endpoint.endpoint.get("/").output(@endpoint.sse_out(@schema.jvalue))
  @driver.run_sync(() => {
    for text in ["{\"a\":1,\"a\":2}", "[".repeat(129) + "0" + "]".repeat(129)] {
      response.val = @http.encode_utf8("data: " + text + "\n\n")
      assert_true(
        ep.call_with(client, (), (), events => events.each(_ => ()))
        is Err(@client.Deserialization(_, ..)),
      )
    }
  })
}
