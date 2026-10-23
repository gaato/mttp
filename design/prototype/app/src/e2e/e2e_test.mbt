///|
fn body_text(r : @model.Response) -> String {
  match r.body {
    Bytes(b) => @utf8.decode_lossy(b)
    _ => ""
  }
}

///|
fn req(
  meth : @model.Method,
  url : String,
  headers? : Array[(String, String)] = [],
  body? : @model.Body = Empty,
) -> @model.Request {
  { ..@model.Request::new(meth, "http://in-process" + url), headers: @model.Headers::of(headers), body }
}

///|
fn catch_all(f : async () -> Unit) -> Error? raise {
  @testing.run_sync(async fn() {
    f() catch {
      e => return Some(e)
    }
    None
  })
}

///|
test "200: Endpoint::call -> Client -> Router-as-Backend -> serve" {
  let router = @e2e.app(@e2e.store(), [])
  let c = @e2e.client(router)
  let u = @testing.run_sync(async fn() { @api.get_user.call(c, "secret", { id: 1, fields: Some("name") }) })
  debug_inspect(u, content="{ id: 1, name: \"gaato\" }")
  inspect(@testing.run_sync(async fn() { @e2e.client_usage(c) }), content="gaato")
}

///|
test "declared errors: raised on the client as the user's own ApiError" {
  let c = @e2e.client(@e2e.app(@e2e.store(), []))
  let e = catch_all(async fn() { ignore(@api.get_user.call(c, "secret", { id: 42, fields: None })) })
  assert_true(e is Some(@api.NotFound(42)))
  let e2 = catch_all(async fn() { ignore(@api.get_user.call(c, "wrong", { id: 1, fields: None })) })
  assert_true(e2 is Some(@api.Forbidden))
}

///|
test "SC-04: two declared 404 variants with one media type are both reachable" {
  let c = @e2e.client(@e2e.app(@e2e.store(), []))
  let e = catch_all(async fn() { ignore(@api.get_team.call(c, "secret", "nope")) })
  match e {
    Some(@api.NoTeam(n)) => inspect(n, content="nope")
    _ => fail("expected NoTeam, got \{e}")
  }
  let t = @testing.run_sync(async fn() { @api.get_team.call(c, "secret", "core") })
  inspect(t.lead.name, content="gaato")
}

///|
test "500: unclassified -> problem+json without details; on_unhandled sees it" {
  let unhandled = []
  let c = @e2e.client(@e2e.app(@e2e.store(), unhandled))
  let e = catch_all(async fn() { ignore(@api.get_user.call(c, "secret", { id: 500, fields: None })) })
  match e {
    Some(@client.UnexpectedStatus(h, body~)) => {
      inspect(h.status, content="500")
      inspect(@utf8.decode_lossy(body), content="{\"type\":\"about:blank\",\"title\":\"internal server error\",\"status\":500,\"errors\":[]}")
    }
    _ => fail("expected 500")
  }
  assert_eq(unhandled.length(), 1)
}

///|
test "400: every problem listed; through the client UnexpectedStatus(400)" {
  let router = @e2e.app(@e2e.store(), [])
  let r = @testing.run_sync(async fn() {
    router.dispatch(req(Get, "/api/v1/users/0?fields=a&fields=b", headers=[("authorization", "Bearer secret")]))
  })
  inspect(r.status, content="400")
  inspect(body_text(r), content="{\"type\":\"about:blank\",\"title\":\"bad request\",\"status\":400,\"errors\":[{\"in\":\"path\",\"name\":\"id\",\"message\":\": must be >= 1\"},{\"in\":\"query\",\"name\":\"fields\",\"message\":\"expected one value, got 2\"}]}")
  let e = catch_all(async fn() { ignore(@api.get_user.call(@e2e.client(router), "secret", { id: 0, fields: None })) })
  inspect(e.map(@client.status_of), content="Some(Some(400))")
}

///|
test "401: credentials first; outranks 400; body never read" {
  let router = @e2e.app(@e2e.store(), [])
  let stream = @model.BytesStream::new([b"{\"name\":\"x\"}"])
  let r = @testing.run_sync(async fn() {
    router.dispatch(req(Post, "/api/v1/users", headers=[("content-type", "application/json")], body=Stream(stream, length=None)))
  })
  inspect(r.status, content="401")
  assert_eq(r.headers.get("www-authenticate"), Some("Bearer"))
  inspect((stream.reads(), stream.is_closed()), content="(0, true)")
  let r2 = @testing.run_sync(async fn() { router.dispatch(req(Get, "/api/v1/users/abc")) })
  inspect(r2.status, content="401")
}

///|
test "404 / 405 + Allow / HEAD / OPTIONS at the router" {
  let router = @e2e.app(@e2e.store(), [])
  let r404 = @testing.run_sync(async fn() { router.dispatch(req(Get, "/api/v1/nope")) })
  assert_eq((r404.status, r404.headers.get("content-type")), (404, Some("application/problem+json")))
  let r405 = @testing.run_sync(async fn() { router.dispatch(req(Delete, "/api/v1/users/1")) })
  assert_eq((r405.status, r405.headers.get("allow")), (405, Some("GET, HEAD, OPTIONS")))
  let rhead = @testing.run_sync(async fn() {
    router.dispatch(req(Head, "/api/v1/users/1", headers=[("authorization", "Bearer secret")]))
  })
  inspect((rhead.status, rhead.body is Empty), content="(200, true)")
  let ropt = @testing.run_sync(async fn() { router.dispatch(req(Options, "/api/v1/users/1")) })
  assert_eq((ropt.status, ropt.headers.get("allow")), (204, Some("GET, HEAD, OPTIONS")))
}

///|
test "I-02: framework 404 (problem+json) is not decoded as the declared 404" {
  let empty = @router.Router::new([])
  let e = catch_all(async fn() { ignore(@api.get_user.call(@e2e.client(empty), "secret", { id: 1, fields: None })) })
  match e {
    Some(@client.UnexpectedStatus(h, ..)) => assert_eq(h.status, 404)
    _ => fail("got \{e}")
  }
}

///|
test "413 closes the connection; 415; 400 body; 201 + Location header output" {
  let router = @e2e.app(@e2e.store(), [])
  let auth = ("authorization", "Bearer secret")
  let big = @utf8.encode("{\"name\":\"" + "x".repeat(100) + "\"}")
  let r413 = @testing.run_sync(async fn() {
    router.dispatch(req(Post, "/api/v1/users", headers=[auth, ("content-type", "application/json")], body=Stream(@model.BytesStream::new([big]), length=None)))
  })
  assert_eq((r413.status, r413.closes_connection()), (413, true))
  let r415 = @testing.run_sync(async fn() {
    router.dispatch(req(Post, "/api/v1/users", headers=[auth, ("content-type", "text/plain")], body=Bytes(b"hi")))
  })
  inspect(r415.status, content="415")
  let r400 = @testing.run_sync(async fn() {
    router.dispatch(req(Post, "/api/v1/users", headers=[auth, ("content-type", "application/json")], body=Bytes(b"{\"nom\":1}")))
  })
  inspect(r400.status, content="400")
  let (created, location) = @testing.run_sync(async fn() {
    @api.create_user.call(@e2e.client(router), "secret", { name: "new" })
  })
  debug_inspect(created, content="{ id: 2, name: \"new\" }")
  inspect(location, content="/api/v1/users/2")
}

///|
test "signed webhook: raw_body in the security input" {
  let router = @e2e.app(@e2e.store(), [])
  let body = b"{\"name\":\"x\"}"
  let ok = @testing.run_sync(async fn() {
    router.dispatch(req(Post, "/hooks/signed", headers=[("x-signature", "len=12"), ("content-type", "application/json")], body=Bytes(body)))
  })
  inspect(ok.status, content="204")
  let bad = @testing.run_sync(async fn() {
    router.dispatch(req(Post, "/hooks/signed", headers=[("x-signature", "len=3"), ("content-type", "application/json")], body=Bytes(body)))
  })
  inspect(bad.status, content="403")
  let missing = @testing.run_sync(async fn() {
    router.dispatch(req(Post, "/hooks/signed", headers=[("content-type", "application/json")], body=Bytes(body)))
  })
  inspect(missing.status, content="401")
}

///|
fn flaky503(calls : Ref[Int]) -> @router.Middleware {
  async fn(r, next) noraise {
    calls.val += 1
    if calls.val == 1 {
      @router.problem(503, "busy")
    } else {
      next(r)
    }
  }
}

///|
test "retry: 503 then success, slept once; observer bucket = operation id" {
  let calls : Ref[Int] = { val: 0 }
  let router = @e2e.app(@e2e.store(), [], middleware=[flaky503(calls)])
  let clock = @fake.FakeClock::new()
  let attempts = []
  let c = @client.Client::new(router, clock, base_url="http://in-process", retry=@client.RetryPolicy::conservative(), random=() => 0.0, observer=a => attempts.push((a.attempt, a.status, a.bucket)))
  let u = @testing.run_sync(async fn() { @api.get_user.call(c, "secret", { id: 1, fields: None }) })
  inspect(u.name, content="gaato")
  inspect(clock.slept(), content="[500]")
  assert_eq(attempts, [(0, 503, "getUser"), (1, 200, "getUser")])
}

///|
test "I-03 fixed: call_with (streaming success) is retried on 503" {
  let calls : Ref[Int] = { val: 0 }
  let router = @e2e.app(@e2e.store(), [], middleware=[flaky503(calls)])
  let clock = @fake.FakeClock::new()
  let c = @e2e.client(router, clock~, retry=@client.RetryPolicy::conservative())
  let n = @testing.run_sync(async fn() {
    @api.user_events.call_with(c, (), (), async fn(es) {
      let seen = []
      es.each(async fn(u) { seen.push(u.name) })
      seen
    })
  })
  assert_eq(n, ["gaato"])
  assert_eq((calls.val, clock.slept()), (2, [500]))
}

///|
test "SSE pull body passes through Router-as-Backend unbuffered" {
  let s = @e2e.store()
  for i in 2..=50 {
    s[i] = { id: i, name: "u\{i}" }
  }
  let router = @e2e.app(s, [])
  // a buffered reader with a small limit refuses (never truncates) ...
  let e = catch_all(async fn() {
    ignore(@e2e.client(router).send(@client.ClientRequest::new(@model.Request::get("/api/v1/events"), @client.as_bytes()).max_body_bytes(100)))
  })
  assert_true(e is Some(@model.TransportError(kind=TooLarge(limit=100), ..)))
  // ... while the streaming reader sees every event
  let count = @testing.run_sync(async fn() {
    @api.user_events.call_with(@e2e.client(router), (), (), async fn(es) {
      let n : Ref[Int] = { val: 0 }
      es.each(async fn(_) { n.val += 1 })
      n.val
    })
  })
  inspect(count, content="50")
}

///|
test "I-09 fixed: the server never sees client attributes; remote_addr = in-process" {
  let seen : Ref[String?] = { val: Some("unset") }
  let spy : @router.Middleware = async fn(r, next) noraise {
    seen.val = r.attributes.get(@client.operation_id)
    next(r)
  }
  let c = @e2e.client(@e2e.app(@e2e.store(), [], middleware=[spy]))
  ignore(@testing.run_sync(async fn() { @api.get_user.call(c, "secret", { id: 1, fields: None }) }))
  assert_eq(seen.val, None)
  // SC-07: a handler reads an adapter-set attribute through an input
  let t = @testing.run_sync(async fn() { @api.whoami.call(c, (), None) })
  inspect(t.label, content="in-process")
}

///|
test "SC-06: request-level middleware reads the matched route after next" {
  let labels = []
  let metrics : @router.Middleware = async fn(r, next) noraise {
    let resp = next(r)
    labels.push((resp.attributes.get(@endpoint.route_template).unwrap_or("-"), resp.status))
    resp
  }
  let router = @e2e.app(@e2e.store(), [], middleware=[metrics])
  ignore(@testing.run_sync(async fn() { @api.get_user.call(@e2e.client(router), "secret", { id: 1, fields: None }) }))
  ignore(@testing.run_sync(async fn() { router.dispatch(req(Get, "/nope")) }))
  assert_eq(labels, [("/api/v1/users/{id}", 200), ("-", 404)])
}

///|
test "when_endpoint: stub one endpoint through its codecs, including a declared error" {
  let stub = @testing.BackendStub::new()
  let stub = @testkit.when_endpoint(stub, @api.get_user, async fn(q) {
    if q.id == 9 { raise @api.NotFound(9) }
    { id: q.id, name: "stubbed" }
  })
  let c = @e2e.client(stub)
  let u = @testing.run_sync(async fn() { @api.get_user.call(c, "anything", { id: 7, fields: None }) })
  debug_inspect(u, content="{ id: 7, name: \"stubbed\" }")
  let e = catch_all(async fn() { ignore(@api.get_user.call(c, "anything", { id: 9, fields: None })) })
  assert_true(e is Some(@api.NotFound(9)))
  inspect(stub.sent().length(), content="2")
}

///|
test "openapi: merged statuses, nested and recursive schemas, header outputs, AND security" {
  let router = @e2e.app(@e2e.store(), [])
  let spec = @openapi.to_openapi(router.docs(), { title: "t", version: "1" })
  let op = spec.paths.get("/api/v1/users/{id}").unwrap().get("get").unwrap()
  let r404 = op.responses.get("404").unwrap()
  assert_eq(r404.content.keys().collect(), ["application/json", "application/problem+json"])
  // two declared 404 variants with one media type -> oneOf
  let one_of = r404.content.get("application/json").unwrap().schema
  assert_true(one_of is { "oneOf": Array([_, _]), .. })
  let statuses = op.responses.keys().collect()
  statuses.sort()
  assert_eq(statuses, ["200", "400", "401", "403", "404", "405", "500"])
  for s in [200, 400, 401, 403, 404, 405, 500] {
    assert_eq(@openapi.check_documented(spec, "/api/v1/users/{id}", Get, s), None)
  }
  // Team references User by $ref; Tree references itself
  let names = spec.components.schemas.keys().collect()
  names.sort()
  assert_eq(names, ["Team", "Tree", "User", "NewUser", "Problem"]) // String order is length-first
  let team = spec.components.schemas.get("Team").unwrap()
  assert_true(team is { "properties": { "lead": { "$ref": "#/components/schemas/User", .. }, .. }, .. })
  let tree = spec.components.schemas.get("Tree").unwrap()
  assert_true(tree is { "properties": { "children": { "items": { "$ref": "#/components/schemas/Tree", .. }, .. }, .. }, .. })
  // header output documented
  let created = spec.paths.get("/api/v1/users").unwrap().get("post").unwrap().responses.get("201").unwrap()
  assert_eq(created.headers.keys().collect(), ["location"])
  // a signature atom is a required header parameter, not an invented scheme
  let hook = spec.paths.get("/hooks/signed").unwrap().get("post").unwrap()
  assert_eq(hook.security.length(), 0)
  assert_true(hook.parameters.iter().any(p => p.name == "x-signature" && p.in_ == "header" && p.required))
  assert_eq(@testkit.verify(router.docs()).map(p => (p.template, p.fatal)), [("/api/v1/users/{id}", false), ("/api/v1/teams/{name}", false), ("/api/v1/users", false), ("/hooks/signed", false)])
  let docs_router = @router.Router::new([@openapi.docs_endpoint(spec)])
  let r = @testing.run_sync(async fn() { docs_router.dispatch(req(Get, "/openapi.json")) })
  inspect(r.status, content="200")
}

///|
test "one checker: Router::new refuses bad definitions and conflicts" {
  let bad = @endpoint.endpoint.get("/x/{id}").serve_public(async fn(_) { () })
  let a = @endpoint.endpoint.get("/a/{x}").input(@endpoint.path("x", @schema.int)).serve_public(async fn(_) { () })
  let b = @endpoint.endpoint.get("/a/{y}").input(@endpoint.path("y", @schema.int)).serve_public(async fn(_) { () })
  let r = try { Ok(@router.Router::new([bad, a, b])) } catch { e => Err(e) }
  match r {
    Err(@endpoint.DefinitionError(ps)) =>
      assert_eq(ps.map(p => p.message), [
        "{id} in the template /x/{id} has no path input (a base endpoint's captures must be re-declared in each endpoint's input)",
        "conflicts with /a/{x}",
      ])
    _ => fail("expected DefinitionError")
  }
}

///|
test "I-07 (documented limit): set-once is not enforced while a slot is Unit" {
  let e = @endpoint.endpoint.get("/x").output(@endpoint.no_content()).output(@endpoint.json_out(@schema.jint.body()))
  ignore(e)
}
