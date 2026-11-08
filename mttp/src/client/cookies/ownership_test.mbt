///|
// Deliberately does no validation or body cleanup: refusals and cancellation
// must be handled by Cookies rather than hidden by a conforming inner stub.
priv struct BareBackend {
  run : async (@http.Request, @http.SendOptions) -> @http.Response raise @http.TransportError
}

///|
impl @http.Backend for BareBackend with fn send(self, request, options) {
  (self.run)(request, options)
}

///|
test "Cookies validates every refusal before I/O and closes unread stream bodies" {
  let d = @driver.Driver::new()
  d.run(() => {
    let calls = Ref(0)
    let inner = BareBackend::{
      run: (_, _) => {
        calls.val += 1
        @http.Response::new(200)
      },
    }
    let backend = @cookies.Cookies::new(
      inner,
      @cookie.CookieJar::new(@sim.FakeClock::new()),
    )
    let options = @http.SendOptions::default()
    for scenario in 0..<7 {
      let feed = @sim.Feed::bytes(d, [b"body"])
      let base = @http.Request::post("https://example.test/").body_stream(feed)
      let (request, options, expected) : (
        @http.Request,
        @http.SendOptions,
        @http.Kind,
      ) = match scenario {
        0 => ({ ..base, meth: Other("BAD METHOD"), }, options, Invalid)
        1 => ({ ..base, url: "https://example.test/\r\n", }, options, Invalid)
        2 => (base.header("bad name", "value"), options, Invalid)
        3 => (base, { ..options, timeout_ms: Some(0), }, Timeout(ms=0))
        4 => (base, { ..options, body: Exchange(max_bytes=-1), }, Invalid)
        5 => (base, { ..options, body: Stream(idle_ms=Some(0)), }, Invalid)
        _ => {
          backend.close()
          (base, options, Closed)
        }
      }
      try backend.send(request, options) catch {
        @http.TransportError(kind~, phase~, ..) => {
          assert_eq(kind, expected)
          assert_eq(phase, Pool)
        }
      } noraise {
        _ => fail("expected refusal")
      }
      assert_eq(feed.reads(), 0)
      assert_true(feed.is_closed())
    }
    assert_eq(calls.val, 0)
  })
}

///|
test "Cookies stores every Set-Cookie on an error head without taking the response body" {
  let d = @driver.Driver::new()
  d.run(() => {
    let feed = @sim.Feed::bytes(d, [b"diagnostic"])
    let jar = @cookie.CookieJar::new(@sim.FakeClock::new())
    let options : @http.SendOptions = {
      timeout_ms: Some(17),
      body: Stream(idle_ms=Some(23)),
    }
    let backend = @cookies.Cookies::new(
      BareBackend::{
        run: (_, actual) => {
          assert_eq(actual, options) catch {
            _ => abort("options changed")
          }
          @http.Response::new(
            503,
            headers=@http.Headers::of([
              ("Set-Cookie", "a=1; Path=/"),
              ("Set-Cookie", "b=2; Path=/"),
            ]),
            body=Stream(@http.StreamBody::new(feed)),
          )
        },
      },
      jar,
    )
    let response = backend.send(
      @http.Request::get("https://example.test/"),
      options,
    )
    assert_eq(response.status, 503)
    assert_eq(jar.header_for("https://example.test/"), Some("a=1; b=2"))
    assert_eq(feed.reads(), 0)
    assert_false(feed.is_closed())
    response.close()
    assert_true(feed.is_closed())
  })
}

///|
test "Cookies cancellation propagates after closing the request without storing cookies" {
  let d = @driver.Driver::new()
  d.run(() => {
    let feed = @sim.Feed::bytes(d, [b"upload"])
    let jar = @cookie.CookieJar::new(@sim.FakeClock::new())
    let backend = @cookies.Cookies::new(
      BareBackend::{
        run: (_, _) => {
          d.sleep(100)
          @http.Response::new(
            200,
            headers=@http.Headers::of([("set-cookie", "late=1")]),
          )
        },
      },
      jar,
    )
    let task = d.spawn(() => {
      backend
      .send(
        @http.Request::post("https://example.test/").body_stream(feed),
        @http.SendOptions::default(),
      )
      .close()
    })
    d.sleep(10)
    task.cancel()
    assert_false(task.wait())
    assert_true(feed.is_closed())
    assert_eq(jar.length(), 0)
    assert_eq(d.pending_timers(), 0)
  })
}

///|
test "Cookies closes request bodies on success and preserves transport failure identity" {
  let d = @driver.Driver::new()
  d.run(() => {
    let sentinel = @http.TransportError(
      kind=Protocol,
      phase=Head,
      detail="sentinel",
    )
    for success in [false, true] {
      let feed = @sim.Feed::bytes(d, [b"upload"])
      let backend = @cookies.Cookies::new(
        BareBackend::{
          run: (_, _) => {
            if success {
              @http.Response::new(200)
            } else {
              raise sentinel
            }
          },
        },
        @cookie.CookieJar::new(@sim.FakeClock::new()),
      )
      try
        backend
        .send(
          @http.Request::post("https://example.test/").body_stream(feed),
          @http.SendOptions::default(),
        )
        .close()
      catch {
        error => {
          assert_false(success)
          assert_true(physical_equal(error, sentinel))
        }
      } noraise {
        _ => assert_true(success)
      }
      assert_true(feed.is_closed())
    }
  })
}
