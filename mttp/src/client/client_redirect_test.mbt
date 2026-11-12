///|
/// Counts admissions and records the status each one was released with.
priv struct HopLimiter {
  mut acquired : Int32
  released : Array[Int32]
}

///|
fn HopLimiter::new() -> HopLimiter {
  HopLimiter::{ acquired: 0, released: [], }
}

///|
impl @client.RateLimiter for HopLimiter with fn acquire(
  self,
  bucket,
  global_exempt~,
) {
  let _ = global_exempt
  self.acquired += 1
  @client.Admission::new(bucket, sequence=self.acquired.to_int64())
}

///|
impl @client.RateLimiter for HopLimiter with fn release(
  self,
  admission,
  status~,
  headers~,
) {
  let _ = (admission, headers)
  self.released.push(status)
}

///|
/// A stub that redirects `/old` to `/new` and answers everything else 200.
fn redirecting_stub(seen : Array[String]) -> &@mttp.Backend {
  @client.from_fn((request, _) => {
    seen.push(request.url)
    if request.url.has_suffix("/old") {
      @mttp.Response::new(
        302,
        headers=@mttp.Headers::of([("location", "/new")]),
      )
    } else {
      @mttp.Response::new(200)
    }
  })
}

///|
test "a Client follows redirects over any backend by default" {
  let seen = []
  let client = @client.Client::new(
    redirecting_stub(seen),
    @sim.FakeClock::new(),
  )
  let reply = @driver.run_sync(() => client.send(@client.get("https://h/old")))
  assert_eq(reply.status, 200)
  assert_eq(seen, ["https://h/old", "https://h/new"])
  assert_eq(reply.attributes.get(@client.final_url), Some("https://h/new"))
  assert_eq(
    reply.attributes.get(@client.redirect_history).map(h => h.length()),
    Some(1),
  )
  // The hop limit is the Client's `redirect` configuration.
  let looping = @client.from_fn((_, _) => {
    @mttp.Response::new(302, headers=@mttp.Headers::of([("location", "/n")]))
  })
  let limited = @client.Client::new(looping, @sim.FakeClock::new(), redirect={
    ..@client.RedirectConfig::default(),
    max_redirects: 2,
  })
  let failure = try {
    ignore(@driver.run_sync(() => limited.send(@client.get("https://h/"))))
    None
  } catch {
    @mttp.TransportError(kind~, ..) => Some(kind)
    error => raise error
  }
  assert_eq(failure, Some(TooManyRedirects(max=2)))
}

///|
test "redirects turn off for the whole Client and for one request" {
  let seen = []
  let client = @client.Client::new(
    redirecting_stub(seen),
    @sim.FakeClock::new(),
  )
  let reply = @driver.run_sync(() => {
    client.send(@client.get("https://h/old").follow_redirects(false))
  })
  assert_eq(reply.status, 302)
  assert_eq(seen, ["https://h/old"])
  seen.clear()
  let off = @client.Client::new(
    redirecting_stub(seen),
    @sim.FakeClock::new(),
    redirect=@client.RedirectConfig::none(),
  )
  let reply = @driver.run_sync(() => off.send(@client.get("https://h/old")))
  assert_eq(reply.status, 302)
  assert_eq(seen, ["https://h/old"])
  // Off means no redirect layer: nothing is recorded on the reply.
  assert_eq(reply.attributes.get(@client.redirect_history), None)
  assert_eq(reply.attributes.get(@client.final_url), None)
}

///|
test "a Client with redirects off keeps the history of a stack that follows them" {
  let seen = []
  let client = @client.Client::new(
    @client.FollowRedirects::new(redirecting_stub(seen)),
    @sim.FakeClock::new(),
    redirect=@client.RedirectConfig::none(),
  )
  let reply = @driver.run_sync(() => client.send(@client.get("https://h/old")))
  assert_eq(reply.status, 200)
  assert_eq(seen, ["https://h/old", "https://h/new"])
  assert_eq(reply.attributes.get(@client.final_url), Some("https://h/new"))
  assert_eq(
    reply.attributes.get(@client.redirect_history).map(h => h.length()),
    Some(1),
  )
  // The per-request limit reaches the stack's own wrapper.
  seen.clear()
  let reply = @driver.run_sync(() => {
    client.send(@client.get("https://h/old").follow_redirects(false))
  })
  assert_eq(reply.status, 302)
  assert_eq(seen, ["https://h/old"])
}

///|
test "retries wrap the whole redirect chain and the limiter admits once per attempt" {
  let sends = []
  let backend = @client.from_fn((request, _) => {
    sends.push(request.url)
    if request.url == "https://h/a" {
      @mttp.Response::new(302, headers=@mttp.Headers::of([("location", "/b")]))
    } else if sends.length() == 2 {
      @mttp.Response::new(503)
    } else {
      @mttp.Response::new(200)
    }
  })
  let limiter = HopLimiter::new()
  let attempts = []
  let client = @client.Client::new(
    backend,
    @sim.FakeClock::new(),
    retry=@client.RetryPolicy::default(),
    limiter~,
    observer=attempt => attempts.push((attempt.request.url, attempt.status)),
  )
  let reply = @driver.run_sync(() => client.send(@client.get("https://h/a")))
  assert_eq(reply.status, 200)
  // The 503 on the second hop resends the original request.
  assert_eq(sends, ["https://h/a", "https://h/b", "https://h/a", "https://h/b"])
  // One admission and one release per attempt, never per hop, released with
  // the final hop's status.
  assert_eq(limiter.acquired, 2)
  assert_eq(limiter.released, [503, 200])
  assert_eq(attempts, [("https://h/a", 503), ("https://h/a", 200)])
}

///|
test "the attempt deadline covers every redirect hop" {
  let d = @driver.Driver::new()
  let backend = @client.from_fn((request, _) => {
    d.sleep(30)
    if request.url.has_suffix("/a") {
      @mttp.Response::new(302, headers=@mttp.Headers::of([("location", "/b")]))
    } else {
      @mttp.Response::new(200)
    }
  })
  let client = @client.Client::new(
    backend,
    @sim.SimClock::new(d),
    timer=@sim.SimTimer::new(d),
    timeout_ms=50,
  )
  let failure = try {
    ignore(d.run(() => client.send(@client.get("https://h/a"))))
    None
  } catch {
    @mttp.TransportError(kind~, ..) => Some(kind)
    error => raise error
  }
  // Each hop takes 30 ms; the two together pass the 50 ms attempt deadline.
  assert_eq(failure, Some(Timeout(ms=50)))
}

///|
test "a Client with a jar sends a cookie set on a redirect to the next hop and later calls" {
  let seen : Array[(String, String?)] = []
  let closes = Ref(0)
  let backend = @client.from_fn(
    (request, _) => {
      seen.push((request.url, request.headers.get("cookie")))
      if request.url.has_suffix("/login") {
        @mttp.Response::new(
          302,
          headers=@mttp.Headers::of([
            ("location", "/home"),
            ("set-cookie", "session=abc; Path=/; HttpOnly"),
          ]),
        )
      } else {
        @mttp.Response::new(200)
      }
    },
    on_close=() => closes.val += 1,
  )
  let jar = @cookie.CookieJar::new(@sim.FakeClock::new())
  let client = @client.Client::new(
    backend,
    @sim.FakeClock::new(),
    base_url="https://site.test",
    cookies=jar,
  )
  assert_eq(
    @driver.run_sync(() => client.send(@client.get("/login"))).status,
    200,
  )
  assert_eq(@driver.run_sync(() => client.send(@client.get("/me"))).status, 200)
  assert_eq(seen, [
    ("https://site.test/login", None),
    ("https://site.test/home", Some("session=abc")),
    ("https://site.test/me", Some("session=abc")),
  ])
  assert_eq(jar.header_for("https://site.test/"), Some("session=abc"))
  // Closing the Client closes the backend once; the jar stays the caller's.
  client.close()
  client.close()
  assert_eq(closes.val, 1)
  assert_eq(jar.length(), 1)
}
