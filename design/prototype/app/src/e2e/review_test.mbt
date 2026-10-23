///|
test "jint refuses fractional and out-of-range numbers" {
  assert_eq(@schema.jint.from_json(Json::number(42.0)), 42)
  assert_true(
    (Some(@schema.jint.from_json(Json::number(1.5))) catch { _ => None })
    is None,
  )
  assert_true(
    (Some(@schema.jint.from_json(Json::number(4294967296.0))) catch {
      _ => None
    })
    is None,
  )
}

///|
test "SSE events survive a UTF-8 sequence split across chunks, with an output header" {
  let ep = @endpoint.endpoint
    .get("/events")
    .output(
      @endpoint.sse_out(@api.user_json).and_header("x-cursor", @schema.string),
    )
  let event = @utf8.encode("data: {\"id\":1,\"name\":\"caf\u{e9}\"}\n\n")
  // cut inside the two bytes of U+00E9
  let cut = event.length() - 5
  let backend = @client.from_fn((_, _) => {
    let chunks = [
      Bytes::from_array(event.to_array()[0:cut]),
      Bytes::from_array(event.to_array()[cut:]),
    ]
    @model.Response::new(
      200,
      headers=@model.Headers::of([
        ("content-type", "text/event-stream"),
        ("x-cursor", "c1"),
      ]),
      body=Stream(@model.BytesStream::new(chunks), length=None),
    )
  })
  let got = @testing.run_sync(async fn() {
    ep.call_with(@e2e.client(backend), (), (), async fn(out) {
      let (es, cursor) = out
      let names = []
      es.each(async fn(u) { names.push(u.name) })
      (names, cursor)
    })
  })
  assert_eq(got, (["caf\u{e9}"], "c1"))
}

///|
test "SSE events survive a UTF-8 sequence split across chunks" {
  let event = @utf8.encode("data: {\"id\":1,\"name\":\"caf\u{e9}\"}\n\n")
  let cut = event.length() - 5
  let backend = @client.from_fn((_, _) => {
    @model.Response::new(
      200,
      headers=@model.Headers::of([("content-type", "text/event-stream")]),
      body=Stream(
        @model.BytesStream::new([
          Bytes::from_array(event.to_array()[0:cut]),
          Bytes::from_array(event.to_array()[cut:]),
        ]),
        length=None,
      ),
    )
  })
  let names = @testing.run_sync(async fn() {
    @api.user_events.call_with(@e2e.client(backend), (), (), async fn(es) {
      let names = []
      es.each(async fn(u) { names.push(u.name) })
      names
    })
  })
  assert_eq(names, ["caf\u{e9}"])
}

///|
test "mapping an input that reads nothing from the request does not abort" {
  let who = @endpoint.attribute(@model.remote_addr).map(
    o => o.unwrap_or("unknown"),
    s => Some(s),
  )
  let ep = @endpoint.endpoint.get("/who").input(who).output(@endpoint.json_out(@schema.jstring.body()))
  let router = @router.Router::new([ep.serve_public(async fn(addr) { addr })])
  let got = @testing.run_sync(async fn() { ep.call(@e2e.client(router), (), "ignored") })
  inspect(got, content="in-process")
}

///|
priv enum IntOrText {
  AnInt(Int)
  AText(String)
} derive(Eq, Debug)

///|
test "call_with tries every buffered variant that shares a status and media type" {
  let out = @endpoint.one_of([
    @endpoint.json_variant(200, @schema.jint.body()).contramap(
      v => if v is AnInt(i) { Some(i) } else { None },
      i => AnInt(i),
    ),
    @endpoint.json_variant(200, @schema.jstring.body()).contramap(
      v => if v is AText(s) { Some(s) } else { None },
      s => AText(s),
    ),
  ])
  let ep = @endpoint.endpoint.get("/either").output(out)
  let backend = @client.from_fn((_, _) => @model.Response::new(
    200,
    headers=@model.Headers::of([("content-type", "application/json")]),
    body=Bytes(@utf8.encode("\"hello\"")),
  ))
  let got = @testing.run_sync(async fn() {
    ep.call_with(@e2e.client(backend), (), (), async fn(v) { v })
  })
  assert_eq(got, AText("hello"))
}

///|
test "a mapped head input is checked before the body is read" {
  let positive = @endpoint.query("n", @schema.int).map(
    n => if n > 0 { n } else { raise @schema.Malformed("n must be positive") },
    n => n,
  )
  let ep = @endpoint.endpoint
    .post("/m")
    .input(@endpoint.pair(positive, @endpoint.body(@schema.jstring.body())))
    .output(@endpoint.no_content())
    .max_body_bytes(8)
  let router = @router.Router::new([ep.serve_public(async fn(_) { () })])
  let big = @utf8.encode("\"" + "x".repeat(100) + "\"")
  let body = @model.BytesStream::new([big])
  let r = @testing.run_sync(async fn() {
    router.dispatch(req(Post, "/m?n=-1", headers=[("content-type", "application/json")], body=Stream(body, length=None)))
  })
  // 400 for the query, not 413 for the body, and the body was never read
  assert_eq((r.status, body.reads()), (400, 0))
}

///|
test "an explicit HEAD endpoint is preferred over GET" {
  let head = @endpoint.endpoint.with_method(Head, "/health").output(@endpoint.no_content())
  let only_head = @router.Router::new([head.serve_public(async fn(_) { () })])
  let r = @testing.run_sync(async fn() { only_head.dispatch(req(Head, "/health")) })
  assert_eq(r.status, 204)
  let get = @endpoint.endpoint.get("/health").output(@endpoint.json_out(@schema.jstring.body()))
  let calls = []
  let both = @router.Router::new([
    get.serve_public(async fn(_) { calls.push("get"); "ok" }),
    head.serve_public(async fn(_) { calls.push("head") }),
  ])
  ignore(@testing.run_sync(async fn() { both.dispatch(req(Head, "/health")) }))
  assert_eq(calls, ["head"])
  let opt = @testing.run_sync(async fn() { both.dispatch(req(Options, "/health")) })
  assert_eq(opt.headers.get("allow"), Some("GET, HEAD, OPTIONS"))
}

///|
test "templates with empty path segments are refused" {
  let trailing = @endpoint.endpoint.get("/health/").output(@endpoint.no_content())
  let doubled = @endpoint.endpoint.get("/a//b").output(@endpoint.no_content())
  let root = @endpoint.endpoint.get("/").output(@endpoint.no_content())
  assert_true(trailing.doc().problems().length() == 1)
  assert_true(doubled.doc().problems().length() == 1)
  assert_true(root.doc().problems().is_empty())
  let refused = try Some(@router.Router::new([trailing.serve_public(async fn(_) { () })])) catch {
    _ => None
  }
  assert_true(refused is None)
}

///|
test "SSE events delimited by CRLF are delivered, even when the delimiter is split" {
  let backend = @client.from_fn((_, _) => @model.Response::new(
    200,
    headers=@model.Headers::of([("content-type", "text/event-stream")]),
    body=Stream(
      @model.BytesStream::new([
        @utf8.encode("data: {\"id\":1,\"name\":\"a\"}\r\n"),
        @utf8.encode("\r\ndata: {\"id\":2,\"name\":\"b\"}\r\n\r\n"),
      ]),
      length=None,
    ),
  ))
  let names = @testing.run_sync(async fn() {
    @api.user_events.call_with(@e2e.client(backend), (), (), async fn(es) {
      let names = []
      es.each(async fn(u) { names.push(u.name) })
      names
    })
  })
  assert_eq(names, ["a", "b"])
}

///|
priv struct FailingStream {
  mut closed : Bool
}

///|
impl @model.BodyStream for FailingStream with read_some(_) {
  raise @model.TransportError(kind=Network, phase=Body, detail="reset")
}

///|
impl @model.BodyStream for FailingStream with close(self) {
  self.closed = true
}

///|
test "read_bounded closes the stream when a read fails" {
  let s = FailingStream::{ closed: false }
  let r = @testing.run_sync(async fn() {
    try Some(@model.read_bounded(s, 10)) catch {
      _ => None
    }
  })
  assert_eq((r, s.closed), (None, true))
}

///|
test "HEAD responses are bodyless when the router rejects them" {
  let router = @e2e.app(@e2e.store(), [])
  let missing = @testing.run_sync(async fn() { router.dispatch(req(Head, "/missing")) })
  assert_eq(missing.status, 404)
  assert_true(missing.body is Empty)
}

///|
test "a request body that fails to read is a 400, not a 413" {
  let ep = @endpoint.endpoint.post("/r").input(@endpoint.body(@schema.jstring.body())).output(@endpoint.no_content())
  let router = @router.Router::new([ep.serve_public(async fn(_) { () })])
  let r = @testing.run_sync(async fn() {
    router.dispatch(req(Post, "/r", headers=[("content-type", "application/json")], body=Stream(FailingStream::{ closed: false }, length=None)))
  })
  assert_eq(r.status, 400)
}

///|
test "request media types are compared case-insensitively" {
  let ep = @endpoint.endpoint.post("/r").input(@endpoint.body(@schema.jstring.body())).output(@endpoint.no_content())
  let router = @router.Router::new([ep.serve_public(async fn(_) { () })])
  let r = @testing.run_sync(async fn() {
    router.dispatch(req(Post, "/r", headers=[("content-type", "Application/JSON; charset=utf-8")], body=Bytes(@utf8.encode("\"x\""))))
  })
  assert_eq(r.status, 204)
}

///|
test "SSE data fields are read around other fields and without a space" {
  let backend = @client.from_fn((_, _) => @model.Response::new(
    200,
    headers=@model.Headers::of([("content-type", "text/event-stream")]),
    body=Stream(
      @model.BytesStream::new([
        @utf8.encode(": comment\nevent: update\ndata: {\"id\":1,\"name\":\"a\"}\nid: 7\n\n"),
        @utf8.encode("data:{\"id\":2,\"name\":\"b\"}\n\nevent: ping\n\n"),
      ]),
      length=None,
    ),
  ))
  let names = @testing.run_sync(async fn() {
    @api.user_events.call_with(@e2e.client(backend), (), (), async fn(es) {
      let names = []
      es.each(async fn(u) { names.push(u.name) })
      names
    })
  })
  assert_eq(names, ["a", "b"])
}

///|
test "the NewUser schema lists each required field once" {
  let schema = @api.new_user_json.schema().json
  guard schema is { "required": Array(required), .. } else { fail("no required list") }
  assert_eq(required, [Json::string("name")])
}

///|
test "an optional body round-trips None, and a body without Content-Type is still 415" {
  let ep = @endpoint.endpoint
    .post("/o")
    .input(@endpoint.body(@schema.jstring.body()).optional())
    .output(@endpoint.json_out(@schema.jstring.body()))
  let router = @router.Router::new([ep.serve_public(async fn(o) { o.unwrap_or("none") })])
  let c = @e2e.client(router)
  let got = @testing.run_sync(async fn() { (ep.call(c, (), None), ep.call(c, (), Some("x"))) })
  assert_eq(got, ("none", "x"))
  let r = @testing.run_sync(async fn() {
    router.dispatch(req(Post, "/o", body=Bytes(@utf8.encode("\"x\""))))
  })
  assert_eq(r.status, 415)
}

///|
test "an SSE event ended by CR CR is delivered when the stream then closes" {
  let backend = @client.from_fn((_, _) => @model.Response::new(
    200,
    headers=@model.Headers::of([("content-type", "text/event-stream")]),
    body=Stream(@model.BytesStream::new([@utf8.encode("data: {\"id\":1,\"name\":\"a\"}\r\r")]), length=None),
  ))
  let names = @testing.run_sync(async fn() {
    @api.user_events.call_with(@e2e.client(backend), (), (), async fn(es) {
      let names = []
      es.each(async fn(u) { names.push(u.name) })
      names
    })
  })
  assert_eq(names, ["a"])
}

///|
test "max_length counts code points, as the JSON Schema keyword does" {
  let one = @schema.string.validate(@schema.max_length(1))
  assert_eq(one.decode("\u{1F600}"), "\u{1F600}")
}
