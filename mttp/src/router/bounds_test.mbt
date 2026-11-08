///|
test "router paths admit 64 segments and refuse 65 including empty segments" {
  let path = "/a".repeat(64)
  let endpoint = @endpoint.endpoint.get(path)
  assert_eq(@endpoint.check_definitions([endpoint.doc()]), [])
  assert_true(
    @endpoint.check_definitions([@endpoint.endpoint.get(path + "/a").doc()])
    .iter()
    .any(p => p.fatal && p.message == "path exceeds 64 segments"),
  )
  let rest = @endpoint.endpoint.get("/{tail...}").input(@endpoint.paths("tail"))
  let router = @router.Router::new([
    endpoint.serve_public(_ => Ok(())),
    rest.serve_public(_ => Ok(())),
  ])
  @driver.run_sync(() => {
    assert_eq(router.dispatch(@http.Request::get(path)).status, 200)
    assert_eq(router.dispatch(@http.Request::get(path + "/a")).status, 404)
    assert_eq(
      router.dispatch(@http.Request::get("http://in-process" + "/".repeat(64))).status,
      200,
    )
    assert_eq(
      router.dispatch(@http.Request::get("http://in-process" + "/".repeat(65))).status,
      404,
    )
  })
}

///|
test "known adapter body ceilings are advisory and actual upstream caps still win" {
  let ep = @endpoint.endpoint
    .post("/")
    .max_body_bytes(8)
    .input(@endpoint.raw_body())
    .output(@endpoint.bytes_out())
  for ceiling in [8, 9] {
    assert_eq(
      @endpoint.check_definitions([ep.doc()], adapter_max_body_bytes=ceiling),
      [],
    )
  }
  assert_eq(@endpoint.check_definitions([ep.doc()]), [])
  let findings = @endpoint.check_definitions(
    [ep.doc()],
    adapter_max_body_bytes=3,
  )
  assert_eq(findings.length(), 1)
  assert_false(findings[0].fatal)
  let router = @router.Router::new(
    [ep.serve_public(bytes => Ok(bytes))],
    adapter_max_body_bytes=3,
  )
  let driver = @driver.Driver::new()
  let feed = @sim.Feed::new(driver, [
    Chunk(b"abc"),
    Fail(
      @http.TransportError(
        kind=TooLarge(limit=3),
        phase=Body,
        detail="adapter ceiling",
      ),
    ),
  ])
  driver.run(() => {
    let response = router.dispatch(@http.Request::post("/").body_stream(feed))
    assert_eq(response.status, 413)
    assert_eq(response.headers.get("connection"), Some("close"))
  })
  assert_true(feed.is_closed())
  for
    options in [
      { ..@router.ServerOptions::default(), max_body_bytes: -1, },
      { ..@router.ServerOptions::default(), max_issues: 0, },
    ] {
    try ignore(@router.Router::new([], options~)) catch {
      @endpoint.DefinitionError(_) => ()
    } noraise {
      _ => fail("invalid limits accepted")
    }
  }
  try ignore(@router.Router::new([], adapter_max_body_bytes=-1)) catch {
    @endpoint.DefinitionError(_) => ()
  } noraise {
    _ => fail("negative ceiling accepted")
  }
}

///|
test "router and OpenAPI checker refuse schemas with duplicate union tags" {
  let case_ = @schema.case_("same", @schema.jint, (n : Int32) => Some(n), n => n)
  let codec = @schema.any_of("Duplicate", [case_, case_])
  let ep = @endpoint.endpoint.get("/").output(@endpoint.json_out(codec.body()))
  let problems = @endpoint.check_definitions([ep.doc()])
  assert_true(
    problems
    .iter()
    .any(p => p.fatal && p.message == "union Duplicate repeats the tag same"),
  )
  try ignore(@router.Router::new([ep.serve_public(_ => Ok(1))])) catch {
    @endpoint.DefinitionError(_) => ()
  } noraise {
    _ => fail("invalid union accepted")
  }
}
