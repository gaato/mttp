///|
/// The 403 body naming the header field a refusal rests on.
fn same_origin_refusal_body(field : String) -> @mttp.Body {
  @mttp.Body::Bytes(
    @mttp.encode_utf8(
      "{\"type\":\"about:blank\",\"title\":\"Forbidden\",\"status\":403," +
      "\"errors\":[{\"in\":\"header\",\"name\":\"\{field}\"," +
      "\"message\":\"cross-origin request refused\"}]}",
    ),
  )
}

///|
test "same_origin decides by Sec-Fetch-Site, then Origin, for unsafe methods only" {
  let middleware = @router.same_origin(allowed_origins=["https://partner.test"])
  let ran = Ref(0)
  let next : @mttp.Handler = _ => {
    ran.val += 1
    @mttp.Response::new(200)
  }
  let app = "https://app.test/form"
  // (Sec-Fetch-Site values, Origin values, request URL, refused field)
  let table : Array[(Array[String], Array[String], String, String?)] = [
    // Without Sec-Fetch-Site: Origin against the request's own origin.
    ([], [], app, None),
    ([], ["https://app.test"], app, None),
    ([], ["https://app.test:443"], app, None),
    ([], ["https://app.test:8443"], "https://app.test:8443/form", None),
    ([], ["http://localhost:8080"], "http://localhost:8080/form", None),
    ([], ["https://partner.test"], app, None),
    ([], ["https://evil.test"], app, Some("origin")),
    ([], ["null"], app, Some("origin")),
    ([], ["http://app.test"], app, Some("origin")),
    ([], ["https://app.test"], "http://app.test/form", Some("origin")),
    ([], ["https://app.test"], "https://app.test:8443/form", Some("origin")),
    ([], ["https://app.test:8443"], app, Some("origin")),
    ([], ["https://app.test/form"], app, Some("origin")),
    ([], ["https://user@app.test"], app, Some("origin")),
    ([], ["https://app.test"], "/form", Some("origin")),
    ([], ["https://bad host"], app, Some("origin")),
    ([], ["https://app.test", "https://app.test"], app, Some("origin")),
    // With Sec-Fetch-Site: it decides, and Origin only adds listed origins.
    (["same-origin"], [], app, None),
    (["same-origin"], ["https://evil.test"], app, None),
    (["same-origin"], ["a", "b"], app, None),
    (["none"], [], app, None),
    (["same-site"], ["https://sub.app.test"], app, Some("sec-fetch-site")),
    (["same-site"], ["https://partner.test"], app, None),
    (["cross-site"], [], app, Some("sec-fetch-site")),
    (["cross-site"], ["https://evil.test"], app, Some("sec-fetch-site")),
    (["cross-site"], ["https://app.test"], app, Some("sec-fetch-site")),
    (["cross-site"], ["null"], app, Some("sec-fetch-site")),
    (["cross-site"], ["https://partner.test"], app, None),
    (
      ["cross-site"],
      ["https://partner.test", "https://partner.test"],
      app,
      Some("sec-fetch-site"),
    ),
    (["Same-Origin"], [], app, Some("sec-fetch-site")),
    (["same-origin", "same-origin"], [], app, Some("sec-fetch-site")),
    ([""], [], app, Some("sec-fetch-site")),
  ]
  let methods : Array[(@mttp.Method, Bool)] = [
    (Get, true),
    (Head, true),
    (Options, true),
    (Trace, true),
    (Post, false),
    (Put, false),
    (Patch, false),
    (Delete, false),
    (Connect, false),
    (Other("PROPFIND"), false),
  ]
  @driver.run_sync(() => {
    for i, row in table {
      let (sites, origins, url, refused) = row
      for j, entry in methods {
        let (meth, safe) = entry
        let headers = @mttp.Headers::of(
          sites.map(v => ("sec-fetch-site", v)) +
          origins.map(v => ("origin", v)),
        )
        let before = ran.val
        let response = middleware(
          { ..@mttp.Request::new(meth, url), headers, },
          next,
        )
        match (safe, refused) {
          (true, _) | (false, None) =>
            assert_eq((i, j, response.status, ran.val - before), (i, j, 200, 1))
          (false, Some(field)) => {
            assert_eq((i, j, response.status, ran.val - before), (i, j, 403, 0))
            assert_eq(
              response.headers.get("content-type"),
              Some("application/problem+json"),
            )
            assert_eq(response.body, same_origin_refusal_body(field))
          }
        }
      }
    }
  })
}

///|
test "same_origin never lists null and defaults to no extra origins" {
  let ran = Ref(0)
  let next : @mttp.Handler = _ => {
    ran.val += 1
    @mttp.Response::new(200)
  }
  @driver.run_sync(() => {
    let listed_null = @router.same_origin(allowed_origins=["null"])
    let null_origin = @mttp.Request::post("https://app.test/").header(
      "origin", "null",
    )
    assert_eq(listed_null(null_origin, next).status, 403)
    assert_eq(
      listed_null(null_origin.header("sec-fetch-site", "cross-site"), next).status,
      403,
    )
    let default = @router.same_origin()
    let partner = @mttp.Request::post("https://app.test/").header(
      "origin", "https://partner.test",
    )
    assert_eq(default(partner, next).status, 403)
    let options = @mttp.Request::options("https://app.test/").header(
      "sec-fetch-site", "cross-site",
    )
    assert_eq(default(options, next).status, 200)
  })
  assert_eq(ran.val, 1)
}

///|
test "same_origin in a router refuses a cross-site form post before its handler" {
  let posted = Ref(0)
  let ep = @endpoint.endpoint
    .post("/notes")
    .serve_public(_ => {
      posted.val += 1
      Ok(())
    })
  let read = @endpoint.endpoint.get("/notes").serve_public(_ => Ok(()))
  let router = @router.Router::new([ep, read], options={
    ..@router.ServerOptions::default(),
    middleware: [@router.same_origin()],
  })
  @driver.run_sync(() => {
    let form = @mttp.Request::post("https://app.test/notes").body_form([
      ("text", "hi"),
    ])
    let cross = router.dispatch(
      form
      .header("sec-fetch-site", "cross-site")
      .header("origin", "https://evil.test"),
    )
    assert_eq(cross.status, 403)
    assert_eq(cross.body, same_origin_refusal_body("sec-fetch-site"))
    let old_browser = router.dispatch(
      form.header("origin", "https://evil.test"),
    )
    assert_eq(old_browser.status, 403)
    assert_eq(old_browser.body, same_origin_refusal_body("origin"))
    assert_eq(posted.val, 0)
    let same = router.dispatch(
      form
      .header("sec-fetch-site", "same-origin")
      .header("origin", "https://app.test"),
    )
    assert_eq(same.status, 200)
    assert_eq(router.dispatch(form).status, 200)
    assert_eq(posted.val, 2)
    let link = @mttp.Request::get("https://app.test/notes").header(
      "sec-fetch-site", "cross-site",
    )
    assert_eq(router.dispatch(link).status, 200)
  })
  router.close()
}
