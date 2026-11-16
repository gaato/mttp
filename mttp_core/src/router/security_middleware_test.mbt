///|
test "rate limit sliding boundaries headers and problem response" {
  let clock = @sim.FakeClock::new()
  let calls = Ref(0)
  let router = @router.Router::new(
    [
      @endpoint.endpoint
      .get("/")
      .serve_public(_ => {
        calls.val += 1
        Ok(())
      }),
    ],
    options={
      ..@router.ServerOptions::default(),
      middleware: [
        @router.rate_limit(
          key=r => r.headers.get("key"),
          limit=2,
          window_ms=1000,
          clock~,
        ),
      ],
    },
  )
  let request = @mttp_core.Request::get("/").set_header("key", "a")
  @driver.run_sync(() => {
    let first = router.dispatch(request)
    assert_eq(
      first.headers.get("ratelimit-policy"),
      Some("\"default\";q=2;w=1"),
    )
    assert_eq(first.headers.get("ratelimit"), Some("\"default\";r=1;t=1"))
    assert_eq(router.dispatch(request).status, 200)
    let denied = router.dispatch(request)
    assert_eq(denied.status, 429)
    assert_eq(denied.headers.get("retry-after"), Some("1"))
    assert_eq(denied.headers.get("ratelimit"), Some("\"default\";r=0;t=1"))
    assert_eq(
      denied.headers.get("content-type"),
      Some("application/problem+json"),
    )
    guard denied.body is Bytes(bytes) else { fail("missing problem") }
    assert_true(
      @schema.jvalue.body().decode(bytes)
      is { "status": Number(429, ..), "title": String("Too Many Requests"), .. },
    )
    clock.advance(999)
    assert_eq(router.dispatch(request).status, 429)
    clock.advance(1)
    assert_eq(router.dispatch(request).status, 200)
    assert_eq(router.dispatch(request).status, 200)
    assert_eq(router.dispatch(request).status, 429)
    clock.advance(1000)
    assert_eq(router.dispatch(request).status, 200)
    let bypass = router.dispatch(@mttp_core.Request::get("/"))
    assert_eq(bypass.status, 200)
    assert_eq(bypass.headers.get("ratelimit"), None)
    assert_eq(router.dispatch(request.set_header("key", "b")).status, 200)
  })
  assert_eq(calls.val, 7)
}

///|
test "rate limit key table evicts least recently used past max keys" {
  let clock = @sim.FakeClock::new()
  let router = @router.Router::new([], options={
    ..@router.ServerOptions::default(),
    middleware: [
      @router.rate_limit(
        key=r => Some(r.url),
        limit=1,
        window_ms=2000,
        clock~,
        max_keys=2,
      ),
    ],
  })
  @driver.run_sync(() => {
    for
      (path, status) in [
        ("/a", 404),
        ("/b", 404),
        ("/a", 429),
        ("/c", 404),
        ("/a", 429),
        ("/b", 404),
      ] {
      let response = router.dispatch(@mttp_core.Request::get(path))
      assert_eq(response.status, status)
      assert_eq(
        response.headers.get("ratelimit-policy"),
        Some("\"default\";q=1;w=2"),
      )
    }
  })
  let clamped = @router.Router::new([], options={
    ..@router.ServerOptions::default(),
    middleware: [
      @router.rate_limit(
        key=_ => Some("a"),
        limit=0,
        window_ms=0,
        clock~,
        max_keys=0,
      ),
    ],
  })
  @driver.run_sync(() => {
    assert_eq(clamped.dispatch(@mttp_core.Request::get("/")).status, 404)
    assert_eq(clamped.dispatch(@mttp_core.Request::get("/")).status, 429)
    clock.advance(2)
    assert_eq(clamped.dispatch(@mttp_core.Request::get("/")).status, 404)
  })
}

///|
test "secure headers use connection scheme and preserve handler precedence" {
  let custom : @router.Middleware = (request, next) => {
    let response = next(request)
    if request.url == "/custom" {
      {
        ..response,
        headers: @mttp_core.Headers::of([
          ("Strict-Transport-Security", "max-age=7"),
          ("X-Content-Type-Options", "custom"),
          ("X-Frame-Options", "custom"),
          ("Referrer-Policy", "origin"),
          ("Content-Security-Policy", "custom"),
        ]),
      }
    } else {
      response
    }
  }
  let router = @router.Router::new([], options={
    ..@router.ServerOptions::default(),
    middleware: [
      @router.secure_headers(hsts=100, csp="default-src 'self'"),
      custom,
    ],
  })
  @driver.run_sync(() => {
    for scheme in [None, Some("http"), Some("https")] {
      let request = @mttp_core.Request::get("https://example.test/").set_header(
        "x-forwarded-proto", "https",
      )
      let request = match scheme {
        Some(s) => request.attribute(@mttp_core.connection_scheme, s)
        None => request
      }
      let response = router.dispatch(request)
      assert_eq(
        response.headers.get("strict-transport-security"),
        if scheme == Some("https") {
          Some("max-age=100")
        } else {
          None
        },
      )
      assert_eq(response.headers.get("x-frame-options"), Some("DENY"))
      assert_eq(response.headers.get("x-content-type-options"), Some("nosniff"))
      assert_eq(response.headers.get("referrer-policy"), Some("no-referrer"))
      assert_eq(
        response.headers.get("content-security-policy"),
        Some("default-src 'self'"),
      )
    }
    let response = router.dispatch(
      @mttp_core.Request::get("/custom").attribute(
        @mttp_core.connection_scheme, "https",
      ),
    )
    assert_eq(
      response.headers.get("strict-transport-security"),
      Some("max-age=7"),
    )
    assert_eq(response.headers.get("x-content-type-options"), Some("custom"))
    assert_eq(response.headers.get("x-frame-options"), Some("custom"))
    assert_eq(response.headers.get("referrer-policy"), Some("origin"))
    assert_eq(response.headers.get("content-security-policy"), Some("custom"))
  })
  let other = @router.Router::new([], options={
    ..@router.ServerOptions::default(),
    middleware: [
      @router.secure_headers(
        hsts=-1,
        content_type_options=false,
        frame_options=SameOrigin,
        referrer_policy="origin",
      ),
    ],
  })
  @driver.run_sync(() => {
    let response = other.dispatch(
      @mttp_core.Request::get("/").attribute(
        @mttp_core.connection_scheme, "https",
      ),
    )
    assert_eq(
      response.headers.get("strict-transport-security"),
      Some("max-age=0"),
    )
    assert_eq(response.headers.get("x-content-type-options"), None)
    assert_eq(response.headers.get("x-frame-options"), Some("SAMEORIGIN"))
    assert_eq(response.headers.get("content-security-policy"), None)
  })
}

///|
// Deliberately non-cryptographic authentication for deterministic codec tests.
fn session_router(
  clock : &@rt.Clock,
  action : (@router.Session) -> Unit raise,
  max_bytes~ : Int32 = 4096,
  secure~ : Bool = true,
  same_site~ : @router.SameSite = Lax,
  cookie_name~ : String = "session",
  max_age_ms~ : Int32 = 1000,
) -> @router.Router raise {
  @router.Router::new(
    [
      @endpoint.endpoint
      .get("/")
      .input(@endpoint.attribute(@router.session))
      .serve_public(s => {
        try! action(s.unwrap())
        Ok(())
      }),
    ],
    options={
      ..@router.ServerOptions::default(),
      middleware: [
        @router.sessions(
          sign=b => b,
          verify=(b, s) => b == s,
          clock~,
          max_age_ms~,
          max_bytes~,
          secure~,
          same_site~,
          cookie_name~,
        ),
      ],
    },
  )
}

///|
fn cookie_pair(response : @mttp_core.Response) -> String {
  response.headers.get("set-cookie").unwrap().split(";").collect()[0].to_owned()
}

///|
test "sessions round trip mutations renewal deletion and unchanged reads" {
  let clock = @sim.FakeClock::new()
  let mode = Ref("set")
  let observed : Array[String?] = []
  let router = session_router(clock, s => {
    observed.push(s.get("user"))
    assert_false(s.changed())
    match mode.val {
      "set" => s.set("user", "オリー;=\"")
      "remove" => s.remove("user")
      "clear" => s.clear()
      _ => {
        s.remove("absent")
        s.set("user", "オリー;=\"")
      }
    }
  })
  @driver.run_sync(() => {
    let first = router.dispatch(@mttp_core.Request::get("/"))
    let field = first.headers.get("set-cookie").unwrap()
    assert_true(field.contains("; HttpOnly; SameSite=Lax; Secure"))
    assert_true(field.contains("; Path=/; Max-Age=1;"))
    let request = @mttp_core.Request::get("/").set_header(
      "cookie",
      cookie_pair(first),
    )
    mode.val = "read"
    clock.advance(500)
    assert_eq(router.dispatch(request).headers.get("set-cookie"), None)
    assert_eq(observed.last(), Some(Some("オリー;=\"")))
    mode.val = "remove"
    let removed = router.dispatch(request)
    assert_eq(
      removed.headers.get("set-cookie"),
      Some("session=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax; Secure"),
    )
    mode.val = "clear"
    assert_eq(
      router.dispatch(request).headers.get("set-cookie"),
      removed.headers.get("set-cookie"),
    )
    assert_eq(
      router.dispatch(@mttp_core.Request::get("/")).headers.get("set-cookie"),
      None,
    )
    clock.advance(500)
    router.dispatch(request) |> ignore
    assert_eq(observed.last(), Some(None))
  })
}

///|
test "sessions reject tamper duplicates malformed expired and oversized cookies" {
  let clock = @sim.FakeClock::new()
  let issuer = session_router(clock, s => s.set("user", "alice"))
  let seen = Ref(None)
  let reader = session_router(clock, s => seen.val = s.get("user"))
  @driver.run_sync(() => {
    let pair = cookie_pair(issuer.dispatch(@mttp_core.Request::get("/")))
    for
      cookie in [
        "session=garbage",
        pair + "!",
        pair + "; " + pair,
        "session=....",
        "session=" + "a".repeat(4097),
      ] {
      let response = reader.dispatch(
        @mttp_core.Request::get("/").set_header("cookie", cookie),
      )
      assert_eq(seen.val, None)
      assert_eq(response.headers.get("set-cookie"), None)
    }
    let repeated = @mttp_core.Request::get("/").set_header("cookie", pair)
    let repeated = {
      ..repeated,
      headers: repeated.headers.add("cookie", pair),
    }
    reader.dispatch(repeated) |> ignore
    assert_eq(seen.val, None)
    clock.advance(999)
    reader.dispatch(@mttp_core.Request::get("/").set_header("cookie", pair))
    |> ignore
    assert_eq(seen.val, Some("alice"))
    clock.advance(1)
    reader.dispatch(@mttp_core.Request::get("/").set_header("cookie", pair))
    |> ignore
    assert_eq(seen.val, None)
  })
}

///|
test "session value map and outgoing cookie enforce byte bounds" {
  let clock = @sim.FakeClock::new()
  let router = session_router(
    clock,
    s => {
      s.set("a", "x".repeat(10))
      assert_true(s.changed())
      s.set("huge", "z".repeat(101))
      assert_eq(s.get("huge"), None)
      for i in 0..<100 {
        s.set(i.to_string(), "abcd")
      }
      assert_eq(s.get("99"), None)
    },
    max_bytes=100,
  )
  let byte_bound = session_router(
    clock,
    s => {
      s.set("x", "あ".repeat(40))
      assert_false(s.changed())
    },
    max_bytes=100,
  )
  @driver.run_sync(() => {
    assert_eq(
      router.dispatch(@mttp_core.Request::get("/")).headers.get("set-cookie"),
      None,
    )
    assert_eq(
      byte_bound.dispatch(@mttp_core.Request::get("/")).headers.get(
        "set-cookie",
      ),
      None,
    )
  })
}

///|
test "session cookie options and caller cookie coexist" {
  let clock = @sim.FakeClock::new()
  for same_site in [@router.SameSite::Strict, NoRestriction] {
    let router = session_router(
      clock,
      s => s.set("x", "y"),
      secure=false,
      same_site~,
      cookie_name="app",
      max_age_ms=1001,
    )
    @driver.run_sync(() => {
      let field = router.dispatch(@mttp_core.Request::get("/")).headers
        .get("set-cookie")
        .unwrap()
      assert_false(field.contains("; Secure"))
      assert_true(field.contains("Max-Age=2;"))
      assert_true(
        field.contains(
          if same_site == Strict {
            "SameSite=Strict"
          } else {
            "SameSite=None"
          },
        ),
      )
      assert_true(field.has_prefix("app="))
    })
  }
  let invalid = session_router(
    clock,
    s => s.set("a", "b"),
    cookie_name="bad;name",
  )
  @driver.run_sync(() => {
    assert_eq(
      invalid.dispatch(@mttp_core.Request::get("/")).headers.get("set-cookie"),
      None,
    )
  })
}

///|
test "sessions renew changed values from head time and allow key rotation" {
  let clock = @sim.FakeClock::new()
  let seen = Ref(None)
  let mutate = Ref(false)
  // Keep the request attributes while adding an independent handler cookie.
  let router = @router.Router::new(
    [
      @endpoint.endpoint
      .get("/")
      .input(@endpoint.attribute(@router.session))
      .serve_public(s => {
        let s = s.unwrap()
        seen.val = s.get("user")
        if mutate.val {
          clock.advance(400)
          s.clear()
          s.set("user", "new identity")
        }
        Ok(())
      }),
    ],
    options={
      ..@router.ServerOptions::default(),
      middleware: [
        @router.sessions(
          sign=_ => b"new",
          verify=(_, sig) => sig == b"new" || sig == b"old",
          max_age_ms=1000,
          clock~,
        ),
        (request, next) => {
          let response = next(request)
          {
            ..response,
            headers: response.headers.add("set-cookie", "other=1"),
          }
        },
      ],
    },
  )
  let issuer = session_router(clock, s => s.set("user", "old identity"))
  @driver.run_sync(() => {
    let old = cookie_pair(issuer.dispatch(@mttp_core.Request::get("/")))
    let payload = old.split(".").collect()[0].to_owned()
    // base64("old") is b2xk. The verifier owns the rotation policy.
    let request = @mttp_core.Request::get("/").set_header(
      "cookie",
      payload + ".b2xk",
    )
    assert_eq(router.dispatch(request).headers.get_all("set-cookie"), [
      "other=1",
    ])
    assert_eq(seen.val, Some("old identity"))
    mutate.val = true
    clock.advance(500)
    let response = router.dispatch(request)
    let fields = response.headers.get_all("set-cookie")
    assert_eq(fields.length(), 2)
    assert_eq(fields[0], "other=1")
    let renewed = fields[1].split(";").collect()[0].to_owned()
    assert_true(renewed.has_suffix(".bmV3"))
    mutate.val = false
    clock.advance(999)
    router.dispatch(@mttp_core.Request::get("/").set_header("cookie", renewed))
    |> ignore
    assert_eq(seen.val, Some("new identity"))
    clock.advance(1)
    router.dispatch(@mttp_core.Request::get("/").set_header("cookie", renewed))
    |> ignore
    assert_eq(seen.val, None)
  })
}
