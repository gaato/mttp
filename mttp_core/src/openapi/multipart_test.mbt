///|
let upload : @endpoint.Endpoint[
  Unit,
  (String, @multipart.ReadPart),
  @endpoint.NoError,
  String,
  @client.Buffered,
] = @endpoint.endpoint
  .post("/upload")
  .input(
    @endpoint.multipart_body(
      @endpoint.MultipartCodec::pair(
        @endpoint.multipart_field("title", @schema.text_body),
        @endpoint.multipart_file(
          "file",
          content_type="application/octet-stream",
        ),
      ),
    ),
  )
  .output(@endpoint.json_out(@schema.jstring.body()))

///|
test "typed multipart fields and file streams round trip through Router and client" {
  let router = @router.Router::new([
    upload.serve_public(pair => {
      let out = Buffer()
      while pair.1.body.read_some() is Some(bytes) {
        out.write_bytes(bytes)
      }
      Ok(
        pair.0 +
        ":" +
        pair.1.head.filename.unwrap_or("") +
        ":" +
        out.to_bytes().length().to_string(),
      )
    }),
  ])
  let client = @client.Client::new(router, @sim.FakeClock::new())
  let d = @driver.Driver::new()
  let source = @sim.Feed::bytes(d, [b"\x00\xff", b"hello"])
  let part : @multipart.ReadPart = {
    head: {
      name: "file",
      filename: Some("a.bin"),
      content_type: Some("application/octet-stream"),
      headers: @mttp_core.Headers::empty(),
    },
    body: source,
  }
  d.run(() => {
    assert_eq(
      upload.call(client, (), ("title", part)).unwrap().unwrap(),
      "title:a.bin:7",
    )
  })
  assert_eq(source.closes(), 1)
}

///|
test "multipart Router emits problem json for fields framing media and bounds" {
  let router = @router.Router::new([upload.serve_public(_ => Ok("ok"))])
  @driver.run_sync(() => {
    assert_eq(router.dispatch(@mttp_core.Request::post("/upload")).status, 400)
    let send = async fn(parts : Array[@multipart.Part], status : Int32) {
      let response = router.dispatch(
        @multipart.body(
          @mttp_core.Request::post("/upload"),
          parts,
          boundary="B",
        ),
      )
      assert_eq(response.status, status)
      assert_eq(
        response.headers.get("content-type"),
        Some("application/problem+json"),
      )
      response
    }
    let missing = send([], 400)
    ignore(
      send([@multipart.Part::file("title", "x", "application/json", b"1")], 400),
    )
    ignore(
      send(
        [
          @multipart.Part::{
            name: "title",
            filename: None,
            content_type: Some("text/plain"),
            body: Bytes(b"\xff"),
          },
        ],
        400,
      ),
    )
    ignore(send([@multipart.Part::text("file", "plain")], 400))
    let body = @schema.jvalue.body().decode(missing.body.as_bytes().unwrap())
    guard body is { "errors": Array(errors), .. } else {
      fail("missing issues")
    }
    assert_eq(errors.length(), 2)
    ignore(
      send(
        [
          @multipart.Part::text("title", "one"),
          @multipart.Part::text("title", "two"),
        ],
        400,
      ),
    )
    ignore(
      send(
        [
          @multipart.Part::text("title", "ok"),
          @multipart.Part::file("file", "x", "text/plain", b"x"),
        ],
        400,
      ),
    )
    let malformed = router.dispatch(
      @mttp_core.Request::post("/upload")
      .header("content-type", "multipart/form-data; boundary=B")
      .body_bytes(b"--B\r\n"),
    )
    assert_eq(malformed.status, 400)
    let wrong_media = router.dispatch(
      @mttp_core.Request::post("/upload").body_json({}),
    )
    assert_eq(wrong_media.status, 415)
    let no_boundary = router.dispatch(
      @mttp_core.Request::post("/upload")
      .header("content-type", "multipart/form-data")
      .body_bytes(b"x"),
    )
    assert_eq(no_boundary.status, 400)
    let limited = @endpoint.endpoint
      .post("/small")
      .input(
        @endpoint.multipart_body(
          @endpoint.multipart_field("title", @schema.text_body),
          max_part_bytes=2,
        ),
      )
      .serve_public(_ => Ok(()))
    let limited_router = @router.Router::new([limited])
    let large = limited_router.dispatch(
      @multipart.body(
        @mttp_core.Request::post("/small"),
        [@multipart.Part::text("title", "abc")],
        boundary="B",
      ),
    )
    assert_eq(large.status, 413)
  })
}

///|
test "multipart OpenAPI properties and per part encoding survive model round trip" {
  let duplicate = @endpoint.endpoint
    .post("/duplicate")
    .input(
      @endpoint.multipart_body(
        @endpoint.MultipartCodec::pair(
          @endpoint.multipart_field("x", @schema.text_body),
          @endpoint.multipart_field("x", @schema.text_body),
        ),
      ),
    )
  assert_true(
    @endpoint.check_definitions([duplicate.doc()])
    .iter()
    .any(problem => problem.message.contains("duplicate multipart field")),
  )
  let named = @schema.object1(
    "Meta",
    @schema.field("value", @schema.jint, (v : Int32) => v),
    value => value,
  )
  let named_ep = @endpoint.endpoint
    .post("/named")
    .input(
      @endpoint.multipart_body(
        @endpoint.multipart_field("metadata", named.body()),
      ),
    )
  let named_spec = @openapi.to_openapi(
    [named_ep.doc()],
    @apispec.Info::new("Named", "1"),
  )
  assert_true(named_spec.components.schemas.contains("Meta"))
  let optional = @endpoint.multipart_field("note", @schema.text_body).optional()
  let codec = @endpoint.MultipartCodec::pair(
    @endpoint.multipart_field("title", @schema.text_body),
    optional,
  ).map(pair => pair.0 + pair.1.unwrap_or(""), text => (text, None))
  let ep : @endpoint.Endpoint[
    Unit,
    String,
    @endpoint.NoError,
    String,
    @client.Buffered,
  ] = @endpoint.endpoint
    .post("/optional")
    .input(@endpoint.multipart_body(codec))
    .output(@endpoint.json_out(@schema.jstring.body()))
  let router = @router.Router::new([ep.serve_public(text => Ok(text))])
  let client = @client.Client::new(router, @sim.FakeClock::new())
  @driver.run_sync(() => {
    assert_eq(ep.call(client, (), "hi").unwrap().unwrap(), "hi")
  })
  let optional_schema = ep.doc().inputs[0].schema.json
  assert_true(optional_schema is { "required": ["title"], .. })
  @driver.run_sync(() => {
    let response = router.dispatch(
      @multipart.body(
        @mttp_core.Request::post("/optional"),
        [
          @multipart.Part::text("title", "t"),
          @multipart.Part::text("note", "a"),
          @multipart.Part::text("note", "b"),
        ],
        boundary="B",
      ),
    )
    assert_eq(response.status, 400)
  })
  let validated : @endpoint.Endpoint[
    Unit,
    (String, String),
    @endpoint.NoError,
    Unit,
    @client.Buffered,
  ] = @endpoint.endpoint
    .post("/validated")
    .input(
      @endpoint.multipart_body(
        @endpoint.MultipartCodec::pair(
          @endpoint.multipart_field(
            "name",
            @schema.jstring.validate(@schema.max_length(1)).body(),
          ),
          @endpoint.multipart_field("other", @schema.text_body),
        ),
      ),
    )
  let validation_router = @router.Router::new([
    validated.serve_public(_ => Ok(())),
  ])
  @driver.run_sync(() => {
    let response = validation_router.dispatch(
      @multipart.body(
        @mttp_core.Request::post("/validated"),
        [
          @multipart.Part::json("name", "long"),
          @multipart.Part::text("other", "ok"),
        ],
        boundary="B",
      ),
    )
    assert_eq(response.status, 400)
    let body = @schema.jvalue.body().decode(response.body.as_bytes().unwrap())
    assert_true(body is { "errors": [{ "path": "/name", .. }], .. })
  })
  let spec = @openapi.to_openapi(
    [upload.doc()],
    @apispec.Info::new("Upload", "1"),
  )
  let media = spec.paths["/upload"].operations["post"].request_body.unwrap().content["multipart/form-data"]
  guard media.schema
    is Some({ "properties": properties, "required": ["title", "file"], .. }) else {
    fail("no multipart properties")
  }
  assert_true(
    properties
    is {
      "title": { "type": "string", .. },
      "file": { "format": "binary", .. },
      ..
    },
  )
  assert_eq(media.encoding.unwrap()["file"], {
    "contentType": "application/octet-stream",
  })
  assert_eq(media.encoding.unwrap()["title"], { "contentType": "text/plain" })
  let decoded : @apispec.MediaTypeObject = @json.from_json(media.to_json())
  assert_eq(decoded, media)
}

///|
test "multipart pairs preserve TooLarge through either side and nested composition" {
  let bounded = @endpoint.multipart_field(
    "form",
    @schema.form_body(max_pairs=1),
  )
  let text = @endpoint.multipart_field("text", @schema.text_body)
  let left = @endpoint.endpoint
    .post("/left")
    .input(
      @endpoint.multipart_body(@endpoint.MultipartCodec::pair(bounded, text)),
    )
    .serve_public(_ => Ok(()))
  let right = @endpoint.endpoint
    .post("/right")
    .input(
      @endpoint.multipart_body(@endpoint.MultipartCodec::pair(text, bounded)),
    )
    .serve_public(_ => Ok(()))
  let nested = @endpoint.endpoint
    .post("/nested")
    .input(
      @endpoint.multipart_body(
        @endpoint.MultipartCodec::pair(
          @endpoint.MultipartCodec::pair(text, bounded),
          @endpoint.multipart_field("other", @schema.text_body),
        ),
      ),
    )
    .serve_public(_ => Ok(()))
  let router = @router.Router::new([left, right, nested])
  @driver.run_sync(() => {
    for path in ["/left", "/right", "/nested"] {
      let response = router.dispatch(
        @multipart.body(
          @mttp_core.Request::post(path),
          [
            @multipart.Part::{
              name: "form",
              filename: None,
              content_type: Some("application/x-www-form-urlencoded"),
              body: Bytes(b"a=1&b=2"),
            },
            @multipart.Part::text("text", "ok"),
            @multipart.Part::text("other", "ok"),
          ],
          boundary="B",
        ),
      )
      assert_eq(response.status, 413)
      assert_eq(
        response.headers.get("content-type"),
        Some("application/problem+json"),
      )
    }
  })
}

///|
test "typed multipart required optional and file names match writer escaping" {
  for name in ["a\"b", "a\rb", "a\nb", "a%22b"] {
    let ep : @endpoint.Endpoint[
      Unit,
      (String, String?),
      @endpoint.NoError,
      String,
      @client.Buffered,
    ] = @endpoint.endpoint
      .post("/names")
      .input(
        @endpoint.multipart_body(
          @endpoint.MultipartCodec::pair(
            @endpoint.multipart_field(name, @schema.text_body),
            @endpoint.multipart_field("optional-" + name, @schema.text_body).optional(),
          ),
        ),
      )
      .output(@endpoint.json_out(@schema.jstring.body()))
    let router = @router.Router::new([
      ep.serve_public(pair => Ok(pair.0 + ":" + pair.1.unwrap_or("absent"))),
    ])
    let client = @client.Client::new(router, @sim.FakeClock::new())
    @driver.run_sync(() => {
      assert_eq(
        ep.call(client, (), ("required", Some("present"))).unwrap().unwrap(),
        "required:present",
      )
      assert_eq(
        ep.call(client, (), ("required", None)).unwrap().unwrap(),
        "required:absent",
      )
    })
    let file_ep : @endpoint.Endpoint[
      Unit,
      @multipart.ReadPart,
      @endpoint.NoError,
      String,
      @client.Buffered,
    ] = @endpoint.endpoint
      .post("/file-name")
      .input(@endpoint.multipart_body(@endpoint.multipart_file(name)))
      .output(@endpoint.json_out(@schema.jstring.body()))
    let file_router = @router.Router::new([
      file_ep.serve_public(part => {
        let bytes = Buffer()
        while part.body.read_some() is Some(chunk) {
          bytes.write_bytes(chunk)
        }
        Ok(part.head.name + ":" + bytes.to_bytes().length().to_string())
      }),
    ])
    let client = @client.Client::new(file_router, @sim.FakeClock::new())
    let d = @driver.Driver::new()
    let source = @sim.Feed::bytes(d, [b"file"])
    let part : @multipart.ReadPart = {
      head: {
        name,
        filename: Some("file.bin"),
        content_type: Some("application/octet-stream"),
        headers: @mttp_core.Headers::empty(),
      },
      body: source,
    }
    d.run(() => {
      assert_eq(file_ep.call(client, (), part).unwrap().unwrap(), name + ":4")
    })
    assert_eq(source.closes(), 1)
  }
}
