///|
priv struct StillClock {}

///|
test "origin keys normalize an unknown scheme without inventing a port" {
  assert_eq(
    origin_key("CUSTOM://EXAMPLE.COM/path"),
    Some("custom://example.com"),
  )
  assert_eq(
    origin_key("custom://example.com/other"),
    Some("custom://example.com"),
  )
  assert_eq(
    origin_key("custom://example.com:123/path"),
    Some("custom://example.com:123"),
  )
}

///|
impl @rt.Clock for StillClock with fn now_unix_ms(_) {
  0L
}

///|
impl @rt.Clock for StillClock with fn sleep(_, _) {
  ()
}

///|
test "the circuit table keeps max_origins and evicts the least recently used" {
  let breaker = CircuitBreaker::new(
    from_fn((_, _) => @mttp_core.Response::new(503)),
    clock=StillClock::{ },
    min_requests=1,
    max_origins=2,
  )
  let send = (url : String) => {
    @driver.run_sync(() => {
      let response = breaker.send(
        @mttp_core.Request::get(url),
        @mttp_core.SendOptions::default(),
      ) catch {
        @mttp_core.TransportError(kind~, ..) => return @debug.to_string(kind)
      }
      response.close()
      response.status.to_string()
    })
  }
  // a and b open their circuits; a is used again, so c evicts b.
  assert_eq(send("http://a.example/"), "503")
  assert_eq(send("http://b.example/"), "503")
  assert_eq(send("http://a.example/"), "CircuitOpen")
  assert_eq(breaker.circuits.keys().collect(), [
    "http://b.example:80", "http://a.example:80",
  ])
  assert_eq(send("http://c.example/"), "503")
  assert_eq(breaker.circuits.length(), 2)
  assert_eq(breaker.circuits.keys().collect(), [
    "http://a.example:80", "http://c.example:80",
  ])
  // The evicted origin forgot its open circuit; a is still open.
  assert_eq(send("http://b.example/"), "503")
  assert_eq(breaker.circuits.keys().collect(), [
    "http://c.example:80", "http://b.example:80",
  ])
  assert_eq(send("http://c.example/"), "CircuitOpen")
  // The default bound is 1024 origins.
  let default = CircuitBreaker::new(
    from_fn((_, _) => @mttp_core.Response::new(200)),
    clock=StillClock::{ },
  )
  assert_eq(default.max_origins, 1024)
  assert_eq(
    CircuitBreaker::new(default, clock=StillClock::{ }, max_origins=0).max_origins,
    1,
  )
}
