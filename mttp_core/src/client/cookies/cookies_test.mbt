///|
test "redirect wrapper stores cookies before following each hop" {
  @driver.run_sync(() => {
    let seen = []
    let jar = @cookie.CookieJar::new(@sim.FakeClock::new())
    let backend = @client.FollowRedirects::new(
      @cookies.Cookies::new(
        @client.from_fn((request, _) => {
          seen.push(request.headers.get("cookie"))
          match seen.length() {
            1 =>
              @mttp_core.Response::new(
                302,
                headers=@mttp_core.Headers::of([
                  ("location", "/b"),
                  ("set-cookie", "sid=one; Path=/"),
                ]),
              )
            2 =>
              @mttp_core.Response::new(
                302,
                headers=@mttp_core.Headers::of([
                  ("location", "https://other.example/"),
                  ("set-cookie", "sid=two; Path=/"),
                ]),
              )
            _ => @mttp_core.Response::new(200)
          }
        }),
        jar,
      ),
    )
    defer backend.close()
    backend
    .send(
      @mttp_core.Request::get("https://h.example/a"),
      @mttp_core.SendOptions::default(),
    )
    .close()
    assert_eq(seen, [None, Some("sid=one"), None])
    assert_eq(jar.header_for("https://h.example/"), Some("sid=two"))
  })
}

///|
test "cookie backend implements the shared backend contract" {
  @driver.run_sync(() => {
    @sim.check_backend_contract(() => {
      @cookies.Cookies::new(
        @client.from_fn((_, _) => @mttp_core.Response::new(200)),
        @cookie.CookieJar::new(@sim.FakeClock::new()),
      )
    })
  })
}

///|
test "cookies store response heads and attach by URL without changing explicit headers" {
  @driver.run_sync(() => {
    let jar = @cookie.CookieJar::new(@sim.FakeClock::new())
    let seen = []
    let closes = Ref(0)
    let seen_options = []
    let backend = @cookies.Cookies::new(
      @client.from_fn(
        (request, options) => {
          seen.push((request.url, request.headers.get("cookie")))
          seen_options.push(options)
          @mttp_core.Response::new(
            200,
            headers=@mttp_core.Headers::of([
              ("set-cookie", "sid=1; Path=/; Secure"),
            ]),
          )
        },
        on_close=() => closes.val += 1,
      ),
      jar,
    )
    let options = { ..@mttp_core.SendOptions::default(), timeout_ms: Some(3), }
    let request = @mttp_core.Request::get("https://a.example/one")
    backend.send(request, options).close()
    backend
    .send(@mttp_core.Request::get("https://a.example/two"), options)
    .close()
    backend.send(@mttp_core.Request::get("https://b.example/"), options).close()
    backend.send(request.header("cookie", "caller=2"), options).close()
    assert_eq(seen, [
      ("https://a.example/one", None),
      ("https://a.example/two", Some("sid=1")),
      ("https://b.example/", None),
      ("https://a.example/one", Some("caller=2")),
    ])
    assert_eq(request.headers.get("cookie"), None)
    assert_eq(seen_options, [options, options, options, options])
    backend.close()
    backend.close()
    assert_eq(closes.val, 1)
    try backend.send(request, options) catch {
      @mttp_core.TransportError(kind=Closed, ..) => ()
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
    let jar = @cookie.CookieJar::new(@sim.FakeClock::new())
    let backend = @cookies.Cookies::new(
      @client.from_fn((_, _) => {
        calls.val += 1
        raise @mttp_core.TransportError(
          kind=Network,
          phase=Head,
          detail="fixture",
        )
      }),
      jar,
    )
    defer backend.close()
    try
      backend.send(
        @mttp_core.Request::get("https://a.example/"),
        @mttp_core.SendOptions::default(),
      )
    catch {
      @mttp_core.TransportError(kind=Network, ..) => ()
      _ => fail("wrong transport error")
    } noraise {
      _ => fail("expected failure")
    }
    assert_eq(jar.length(), 0)
    try
      backend.send(
        @mttp_core.Request::get("https://a.example/").header("bad name", "x"),
        @mttp_core.SendOptions::default(),
      )
    catch {
      @mttp_core.TransportError(kind=Invalid, ..) => ()
      _ => fail("wrong validation error")
    } noraise {
      _ => fail("expected validation")
    }
    assert_eq(calls.val, 1)
  })
}
