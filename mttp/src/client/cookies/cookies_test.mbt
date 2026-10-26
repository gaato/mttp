///|
test "redirect wrapper stores cookies before following each hop" {
  @driver.run_sync(() => {
    let seen = []
    let jar = @cookie.CookieJar::new(@fake.FakeClock::new())
    let backend = @client.FollowRedirects::new(
      @cookies.Cookies::new(
        @client.from_fn((request, _) => {
          seen.push(request.headers.get("cookie"))
          match seen.length() {
            1 =>
              @model.Response::new(
                302,
                headers=@model.Headers::of([
                  ("location", "/b"),
                  ("set-cookie", "sid=one; Path=/"),
                ]),
              )
            2 =>
              @model.Response::new(
                302,
                headers=@model.Headers::of([
                  ("location", "https://other.example/"),
                  ("set-cookie", "sid=two; Path=/"),
                ]),
              )
            _ => @model.Response::new(200)
          }
        }),
        jar,
      ),
    )
    defer backend.close()
    backend
    .send(
      @model.Request::get("https://h.example/a"),
      @client.RequestOptions::default(),
    )
    .close()
    assert_eq(seen, [None, Some("sid=one"), None])
    assert_eq(jar.header_for("https://h.example/"), Some("sid=two"))
  })
}

///|
test "cookie backend implements the shared backend contract" {
  @driver.run_sync(() => {
    assert_eq(
      @testing.check_backend_contract(() => {
        @cookies.Cookies::new(
          @client.from_fn((_, _) => @model.Response::new(200)),
          @cookie.CookieJar::new(@fake.FakeClock::new()),
        )
      }),
      [],
    )
  })
}

///|
test "cookies store response heads and attach by URL without changing explicit headers" {
  @driver.run_sync(() => {
    let jar = @cookie.CookieJar::new(@fake.FakeClock::new())
    let seen = []
    let closes = Ref(0)
    let seen_options = []
    let backend = @cookies.Cookies::new(
      @client.from_fn(
        (request, options) => {
          seen.push((request.url, request.headers.get("cookie")))
          seen_options.push(options.max_redirects)
          @model.Response::new(
            200,
            headers=@model.Headers::of([("set-cookie", "sid=1; Path=/; Secure")]),
          )
        },
        on_close=() => closes.val += 1,
      ),
      jar,
    )
    let options = { ..@client.RequestOptions::default(), max_redirects: 3, }
    let request = @model.Request::get("https://a.example/one")
    backend.send(request, options).close()
    backend.send(@model.Request::get("https://a.example/two"), options).close()
    backend.send(@model.Request::get("https://b.example/"), options).close()
    backend.send(request.header("cookie", "caller=2"), options).close()
    assert_eq(seen, [
      ("https://a.example/one", None),
      ("https://a.example/two", Some("sid=1")),
      ("https://b.example/", None),
      ("https://a.example/one", Some("caller=2")),
    ])
    assert_eq(request.headers.get("cookie"), None)
    assert_eq(seen_options, [3, 3, 3, 3])
    backend.close()
    backend.close()
    assert_eq(closes.val, 1)
    try backend.send(request, options) catch {
      @model.TransportError(kind=Closed, ..) => ()
      _ => fail("wrong closed error")
    } noraise {
      _ => fail("accepted after close")
    }
  })
}

///|
test "failed and invalid requests do not store cookies or reach the inner backend" {
  @driver.run_sync(() => {
    let calls = Ref(0)
    let jar = @cookie.CookieJar::new(@fake.FakeClock::new())
    let backend = @cookies.Cookies::new(
      @client.from_fn((_, _) => {
        calls.val += 1
        raise @model.TransportError(kind=Network, phase=Head, detail="fixture")
      }),
      jar,
    )
    defer backend.close()
    try
      backend.send(
        @model.Request::get("https://a.example/"),
        @client.RequestOptions::default(),
      )
    catch {
      @model.TransportError(kind=Network, ..) => ()
      _ => fail("wrong transport error")
    } noraise {
      _ => fail("expected failure")
    }
    assert_eq(jar.length(), 0)
    try
      backend.send(
        @model.Request::get("https://a.example/").header("bad name", "x"),
        @client.RequestOptions::default(),
      )
    catch {
      @model.TransportError(kind=Invalid, ..) => ()
      _ => fail("wrong validation error")
    } noraise {
      _ => fail("expected validation")
    }
    assert_eq(calls.val, 1)
  })
}
