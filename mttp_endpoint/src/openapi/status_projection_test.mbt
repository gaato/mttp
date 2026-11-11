///|
test "dynamic text 404 is included in the explicit framework response" {
  let ep = @endpoint.endpoint
    .get("/dynamic-404")
    .output(@endpoint.text_out().and_status())
  let response = dispatch(
    ep.serve_public(_ => Ok(("missing", 404))),
    ep.request((), ()).raw(),
  )
  assert_eq(response.status, 404)
  assert_eq(response.headers.get("content-type"), Some("text/plain"))
  assert_eq(response.body, @http.Body::Bytes(b"missing"))
  let spec = project(ep.doc())
  let selected = spec.paths["/dynamic-404"].operations["get"].responses["404"]
  assert_true(selected.content.contains("text/plain"))
  assert_true(selected.content.contains("application/problem+json"))
  assert_true(
    spec.paths["/dynamic-404"].operations["get"].responses["default"].content.contains(
      "text/plain",
    ),
  )
}

///|
enum StatusValue {
  Value(Int32, Int32)
  Idle
}

///|
enum StatusControl {
  Success(StatusValue)
  Declared(StatusValue)
  Rejected(StatusValue)
  Crash
}

///|
fn status_schema(role : Int32) -> Json {
  match role {
    0 => @schema.jint.schema().json
    1 => @schema.string.schema().json
    2 => @schema.raw_bytes.schema().json
    _ => @schema.jint.validate(@schema.minimum(10)).schema().json
  }
}

///|
fn status_header(role : Int32) -> String {
  ["x-fixed-success", "x-dynamic-success", "x-fixed-error", "x-dynamic-error"][role]
}

///|
fn status_variant(
  role : Int32,
  status : Int32,
) -> @endpoint.Variant[StatusValue] {
  let header = status_header(role)
  if status == 204 || status == 304 {
    return @endpoint.empty_variant(status)
      .fixed_header(header, "present")
      .contramap(
        v => {
          if v is Value(r, s) && r == role && s == status {
            Some(())
          } else {
            None
          }
        },
        _ => Value(role, status),
      )
  }
  if role == 0 {
    @endpoint.json_variant(status, @schema.jint.body())
    .fixed_header(header, "present")
    .contramap(
      v => if v is Value(0, s) && s == status { Some(20) } else { None },
      _ => Value(0, status),
    )
  } else {
    @endpoint.json_variant(status, @schema.raw_bytes)
    .fixed_header(header, "present")
    .contramap(
      v => if v is Value(2, s) && s == status { Some(b"error") } else { None },
      _ => Value(2, status),
    )
  }
}

///|
fn dynamic_status_variant(role : Int32) -> @endpoint.Variant[StatusValue] {
  let header = status_header(role)
  if role == 1 {
    @endpoint.json_variant(200, @schema.text_body)
    .fixed_header(header, "present")
    .and_status()
    .contramap(v => if v is Value(1, s) { Some(("reply", s)) } else { None }, pair => {
      Value(1, pair.1)
    })
  } else {
    @endpoint.json_variant(
      200,
      @schema.jint.validate(@schema.minimum(10)).body(),
    )
    .fixed_header(header, "present")
    .and_status()
    .contramap(v => if v is Value(3, s) { Some((20, s)) } else { None }, pair => {
      Value(3, pair.1)
    })
  }
}

///|
fn schema_alternatives(schema : Json) -> Array[Json] {
  let leaves = []
  match schema {
    { "anyOf": Array(alternatives), .. } =>
      for alternative in alternatives {
        for leaf in schema_alternatives(alternative) {
          if !leaves.contains(leaf) {
            leaves.push(leaf)
          }
        }
      }
    _ => leaves.push(schema)
  }
  leaves
}

///|
fn assert_status_projection(
  selected : @apispec.ResponseObject?,
  observed : Array[(@http.Response, Json?)],
  status : Int32,
) -> Unit raise {
  if observed.is_empty() {
    assert_eq(selected, None)
    return
  }
  guard selected is Some(selected) else {
    fail("missing response for \{status}")
  }
  let expected : Map[String, Array[Json]] = Map([])
  for (response, schema) in observed {
    assert_eq(response.status, status)
    if status == 204 || status == 304 {
      assert_eq(response.body, @http.Body::Empty)
    } else if schema is Some(schema) {
      let media = response.headers.get("content-type").unwrap()
      let alternatives = expected.get(media).unwrap_or([])
      if !alternatives.contains(schema) {
        alternatives.push(schema)
      }
      expected[media] = alternatives
    } else {
      assert_eq(response.body, @http.Body::Empty)
    }
  }
  assert_eq(selected.content.length(), expected.length())
  for media, schemas in expected {
    guard selected.content.get(media) is Some(content) else {
      fail("missing \{media} for \{status}")
    }
    let actual = schema_alternatives(content.schema.unwrap())
    assert_eq(actual.length(), schemas.length())
    for schema in schemas {
      assert_true(actual.contains(schema))
    }
  }
  let mut header_count = 0
  for role in 0..<4 {
    let name = status_header(role)
    let count = observed
      .iter()
      .filter(pair => pair.0.headers.get(name) is Some(_))
      .count()
    if count > 0 {
      header_count += 1
      let header = selected.headers[name]
      assert_eq(header.required, count == observed.length())
      assert_eq(
        header.schema,
        Some(@schema.string.schema().patch({ "const": "present" }).json),
      )
    } else {
      assert_false(selected.headers.contains(name))
    }
  }
  assert_eq(selected.headers.length(), header_count)
}

///|
test "status matrix selects exact fixed dynamic declared and framework representations" {
  let fixed_codes = [
    200, 201, 204, 304, 400, 401, 404, 405, 409, 413, 415, 422, 500, 503, 599,
  ]
  // Role bits are fixed success, dynamic success, fixed error, dynamic error.
  // Four independent switches cover both success and declared-error unions.
  // Reverse order as well: a later fixed variant must also inherit dynamics.
  for mask in 0..<16 {
    for profile in 0..<6 {
      for reversed in [false, true] {
        let secured = profile % 2 == 1
        let body_kind = profile / 2
        let enabled = (role : Int32) => (mask & (1 << role)) != 0
        let success : Array[@endpoint.Variant[StatusValue]] = []
        let errors : Array[@endpoint.Variant[StatusValue]] = []
        for role in 0..<4 {
          if enabled(role) {
            let variants = if role < 2 { success } else { errors }
            if role % 2 == 0 {
              for status in fixed_codes {
                variants.push(status_variant(role, status))
              }
            } else {
              variants.push(dynamic_status_variant(role))
            }
          }
        }
        let idle = success.is_empty()
        if idle {
          success.push(
            @endpoint.empty_variant(200).contramap(
              v => if v is Idle { Some(()) } else { None },
              _ => Idle,
            ),
          )
        }
        let reorder = (vs : Array[@endpoint.Variant[StatusValue]]) => {
          if reversed {
            Array::makei(vs.length(), i => vs[vs.length() - i - 1])
          } else {
            vs
          }
        }
        let security = if secured {
          @endpoint.bearer()
        } else {
          @endpoint.unit().map(_ => "public", _ => ())
        }
        let input = match body_kind {
          1 => @endpoint.raw_body().map(_ => (), _ => b"0")
          2 => @endpoint.body(@schema.jint.body()).map(_ => (), _ => 0)
          _ => @endpoint.unit()
        }
        let ep = @endpoint.endpoint
          .post("/status")
          .security(security)
          .input(input)
          .max_body_bytes(3)
          .output(@endpoint.one_of(reorder(success)))
          .errors(@endpoint.one_of(reorder(errors)))
        let control = Ref(StatusControl::Crash)
        let router = @router.Router::new([
          ep.serve(
            _ => {
              if control.val is Rejected(value) {
                Err(value)
              } else {
                Ok(())
              }
            },
            (_, _) => {
              match control.val {
                Success(value) => Ok(value)
                Declared(value) => Err(value)
                Rejected(_) => fail("authentication rejection reached handler")
                Crash => raise Failure("status audit")
              }
            },
          ),
        ])
        let request = ep.request("token", ()).raw()
        let op = project(ep.doc()).paths["/status"].operations["post"]
        let frameworks = [400, 404, 405, 500]
        if secured {
          frameworks.push(401)
        }
        if body_kind != 0 {
          frameworks.push(413)
        }
        if body_kind == 2 {
          frameworks.push(415)
        }
        let dynamic = enabled(1) || enabled(3)
        assert_eq(op.responses.contains("default"), dynamic)
        @driver.run_sync(() => {
          for status in 200..<600 {
            let observed : Array[(@http.Response, Json?)] = []
            for role in 0..<4 {
              if enabled(role) &&
                (role % 2 == 1 || fixed_codes.contains(status)) {
                let value = StatusValue::Value(role, status)
                for
                  rejection in (if role < 2 { [false] } else { [false, true] }) {
                  control.val = if role < 2 {
                    Success(value)
                  } else if rejection {
                    Rejected(value)
                  } else {
                    Declared(value)
                  }
                  let reply = router.dispatch(request)
                  assert_eq(
                    reply.headers.get(status_header(role)),
                    Some("present"),
                  )
                  if status != 204 && status != 304 {
                    assert_eq(
                      reply.body,
                      @http.Body::Bytes(
                        match role {
                          0 | 3 => b"20"
                          1 => b"reply"
                          _ => b"error"
                        },
                      ),
                    )
                  }
                  observed.push((reply, Some(status_schema(role))))
                }
              }
            }
            if idle && status == 200 {
              control.val = Success(Idle)
              observed.push((router.dispatch(request), None))
            }
            if frameworks.contains(status) {
              control.val = Crash
              let bad_request = match status {
                400 =>
                  {
                    ..request,
                    headers: request.headers.add("bad header", "invalid"),
                  }
                401 =>
                  {
                    ..request,
                    headers: request.headers.remove("authorization"),
                  }
                404 => { ..request, url: "/unknown", }
                405 => { ..request, meth: Get, }
                413 => { ..request, body: @http.Body::Bytes(b"1234"), }
                415 =>
                  {
                    ..request,
                    headers: request.headers.set("content-type", "text/plain"),
                  }
                _ => request
              }
              let reply = router.dispatch(bad_request)
              assert_eq(
                reply.headers.get("content-type"),
                Some("application/problem+json"),
              )
              observed.push(
                (reply, Some({ "$ref": "#/components/schemas/Problem" })),
              )
            }
            let explicit = frameworks.contains(status) ||
              ((enabled(0) || enabled(2)) && fixed_codes.contains(status)) ||
              (idle && status == 200) ||
              (dynamic && (status == 204 || status == 304))
            assert_eq(op.responses.contains(status.to_string()), explicit)
            let selected = match op.responses.get(status.to_string()) {
              Some(response) => Some(response)
              None => op.responses.get("default")
            }
            assert_status_projection(selected, observed, status)
          }
        })
      }
    }
  }
}

///|
test "ordinary auth inputs fail as 400 and do not invent framework 401 media" {
  let ep = @endpoint.endpoint
    .post("/ordinary-auth")
    .input(@endpoint.bearer())
    .output(@endpoint.text_out().and_status())
  let server = ep.serve_public(_ => Ok(("unauthorized", 401)))
  let request = ep.request((), "token").raw()
  let response = dispatch(server, {
    ..request,
    headers: request.headers.remove("authorization"),
  })
  assert_eq(response.status, 400)
  assert_eq(
    response.headers.get("content-type"),
    Some("application/problem+json"),
  )
  let response = dispatch(server, request)
  assert_eq(response.status, 401)
  assert_eq(response.headers.get("content-type"), Some("text/plain"))
  let responses = project(ep.doc()).paths["/ordinary-auth"].operations["post"].responses
  let selected = responses.get("401").unwrap_or(responses["default"])
  assert_eq(selected.content.length(), 1)
  assert_true(selected.content.contains("text/plain"))
}

///|
test "dynamic empty responses stay bodyless at explicit and default statuses" {
  let ep = @endpoint.endpoint
    .post("/empty-status")
    .output(
      @endpoint.one_of([
        @endpoint.empty_variant(200).fixed_header("x-empty", "yes").and_status(),
      ]),
    )
  let op = project(ep.doc()).paths["/empty-status"].operations["post"]
  for status in [200, 201, 204, 304, 400, 404, 405, 500, 599] {
    let response = dispatch(
      ep.serve_public(_ => Ok(((), status))),
      ep.request((), ()).raw(),
    )
    assert_eq(response.status, status)
    assert_eq(response.body, @http.Body::Empty)
    assert_eq(response.headers.get("x-empty"), Some("yes"))
    let selected = match op.responses.get(status.to_string()) {
      Some(response) => response
      None => op.responses["default"]
    }
    let framework = [400, 404, 405, 500].contains(status)
    assert_eq(selected.content.length(), if framework { 1 } else { 0 })
    assert_eq(selected.content.contains("application/problem+json"), framework)
    assert_eq(selected.headers["x-empty"].required, !framework)
  }
}

///|
test "dynamic media and streamed bodies overlay explicit statuses without bodyless content" {
  for streamed in [false, true] {
    for status in [201, 204, 304, 400, 404, 405, 500, 599] {
      let driver = @driver.Driver::new()
      let source = @sim.Feed::bytes(driver, [b"payload"])
      let ep = @endpoint.endpoint
        .post("/wild-status")
        .output(@endpoint.stream_body_out().and_status())
      let body = if streamed {
        @http.Body::Stream(@http.StreamBody::new(source))
      } else {
        @http.Body::Bytes(b"payload")
      }
      let response = dispatch(
        ep.serve_public(_ => Ok(((Some("application/custom"), body), status))),
        ep.request((), ()).raw(),
      )
      assert_eq(response.status, status)
      assert_eq(
        response.headers.get("content-type"),
        Some("application/custom"),
      )
      let op = project(ep.doc()).paths["/wild-status"].operations["post"]
      let selected = match op.responses.get(status.to_string()) {
        Some(response) => response
        None => op.responses["default"]
      }
      if status == 204 || status == 304 {
        assert_eq(response.body, @http.Body::Empty)
        assert_eq(selected.content.length(), 0)
        assert_eq(source.reads(), 0)
      } else {
        assert_eq(
          @driver.run_sync(() => @client.read_body(response.body, 100)),
          b"payload",
        )
        assert_eq(
          selected.content["*/*"].schema,
          Some(@schema.raw_bytes.schema().json),
        )
        let framework = [400, 404, 405, 500].contains(status)
        assert_eq(selected.content.length(), if framework { 2 } else { 1 })
        assert_eq(
          selected.content.contains("application/problem+json"),
          framework,
        )
      }
      assert_eq(source.closes(), if streamed { 1 } else { 0 })
      assert_eq(op.responses["default"].content.length(), 1)
      assert_true(op.responses["default"].content.contains("*/*"))
    }
  }
}

///|
test "dynamic statuses outside the final response range become framework 500" {
  let ep = @endpoint.endpoint
    .post("/invalid-status")
    .output(@endpoint.text_out().and_status())
  let op = project(ep.doc()).paths["/invalid-status"].operations["post"]
  for status in [-1, 0, 100, 199, 600, 1000] {
    let response = dispatch(
      ep.serve_public(_ => Ok(("invalid", status))),
      ep.request((), ()).raw(),
    )
    assert_eq(response.status, 500)
    assert_eq(
      response.headers.get("content-type"),
      Some("application/problem+json"),
    )
    assert_false(op.responses.contains(status.to_string()))
    assert_true(
      op.responses["500"].content.contains("application/problem+json"),
    )
    assert_true(op.responses["500"].content.contains("text/plain"))
    assert_eq(op.responses["default"].content.length(), 1)
    assert_true(op.responses["default"].content.contains("text/plain"))
  }
}

///|
test "dynamic media schemas survive more specific representations at each status" {
  let ep = @endpoint.endpoint
    .post("/specific-media")
    .output(@endpoint.body_out().and_status())
    .errors(@endpoint.json_out(@schema.jint.body(), status=409))
  let op = project(ep.doc()).paths["/specific-media"].operations["post"]
  for status in [400, 404, 405, 409, 500] {
    let media = if status == 409 {
      "application/json"
    } else {
      "application/problem+json"
    }
    let response = dispatch(
      ep.serve_public(_ => Ok(((media, b"\"opaque\""), status))),
      ep.request((), ()).raw(),
    )
    assert_eq(response.status, status)
    assert_eq(response.headers.get("content-type"), Some(media))
    assert_eq(response.body, @http.Body::Bytes(b"\"opaque\""))
    // OpenAPI chooses this exact media entry over */*. Both encoders can
    // produce it, so this entry must describe both schemas, too.
    let selected = op.responses[status.to_string()].content[media]
    let alternatives = schema_alternatives(selected.schema.unwrap())
    assert_eq(alternatives.length(), 2)
    assert_true(alternatives.contains(@schema.raw_bytes.schema().json))
    assert_true(
      alternatives.contains(
        if status == 409 {
          @schema.jint.schema().json
        } else {
          { "$ref": "#/components/schemas/Problem" }
        },
      ),
    )
  }
  assert_eq(op.responses["default"].content.length(), 1)
  assert_eq(
    op.responses["default"].content["*/*"].schema,
    Some(@schema.raw_bytes.schema().json),
  )
}

///|
test "dynamic declared-error media retains identical fixed media schemas" {
  let ep = @endpoint.endpoint
    .post("/wild-error")
    .output(@endpoint.bytes_out(status=201))
    .errors(@endpoint.body_out().and_status())
  let response = dispatch(
    ep.serve_public(_ => Err((("application/octet-stream", b"error"), 201))),
    ep.request((), ()).raw(),
  )
  assert_eq(response.status, 201)
  assert_eq(response.body, @http.Body::Bytes(b"error"))
  let content = project(ep.doc()).paths["/wild-error"].operations["post"].responses["201"].content
  assert_eq(content.length(), 2)
  assert_eq(
    content["application/octet-stream"].schema,
    Some(@schema.raw_bytes.schema().json),
  )
  assert_eq(content["*/*"].schema, Some(@schema.raw_bytes.schema().json))
}

///|
test "dynamic SSE status projects wire schemas and closes suppressed streams" {
  let ep = @endpoint.endpoint
    .post("/sse-status")
    .output(@endpoint.sse_out(@schema.jint).and_status())
  let op = project(ep.doc()).paths["/sse-status"].operations["post"]
  for status in [201, 204, 304, 404, 500, 599] {
    let closed = Ref(0)
    let sent = Ref(false)
    let events = @endpoint.EventStream::from_pull(
      () => {
        if sent.val {
          None
        } else {
          sent.val = true
          Some(7)
        }
      },
      () => closed.val += 1,
    )
    let response = dispatch(
      ep.serve_public(_ => Ok((events, status))),
      @http.Request::new(Post, "/sse-status"),
    )
    assert_eq(response.status, status)
    let selected = match op.responses.get(status.to_string()) {
      Some(response) => response
      None => op.responses["default"]
    }
    if status == 204 || status == 304 {
      assert_eq(response.body, @http.Body::Empty)
      assert_eq(selected.content.length(), 0)
      assert_false(sent.val)
    } else {
      assert_eq(response.headers.get("content-type"), Some("text/event-stream"))
      assert_eq(
        @driver.run_sync(() => @client.read_body(response.body, 100)),
        b"data: 7\n\n",
      )
      assert_eq(
        selected.content["text/event-stream"].schema,
        Some({ "type": "string" }),
      )
      assert_eq(
        selected.content["text/event-stream"].extensions.get("x-oai-itemSchema"),
        Some(sse_item_schema(@schema.jint.schema().json)),
      )
      assert_eq(
        selected.content.contains("application/problem+json"),
        status == 404 || status == 500,
      )
    }
    assert_eq(closed.val, 1)
  }
}
