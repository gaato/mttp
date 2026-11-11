///|
test "POST answered by a challenge is not retried as unsent after a dial failure" {
  let sends = []
  let unread = @sim.Feed::bytes(@driver.Driver::new(), [b"denied"])
  let closed_at_retry = Ref(0)
  let backend = wrap(
    @client.from_fn((request, _) => {
      sends.push(request)
      if sends.length() == 1 {
        @mttp.Response::new(
          401,
          headers=challenge(),
          body=Stream(@mttp.StreamBody::new(unread)),
        )
      } else {
        closed_at_retry.val = unread.closes()
        raise @mttp.TransportError(kind=Connect, phase=Dial, detail="refused")
      }
    }),
  )
  defer backend.close()
  let retry = @client.RetryPolicy::from_rule({
    ..@retry.RetryRule::never(),
    max_retries: 2,
    unsent_failures: true,
  })
  let client = @client.Client::new(backend, @sim.FakeClock::new(), retry~)
  try {
    ignore(
      @driver.run_sync(() => {
        client.send(@client.post("https://a.test/pay").body_bytes(b"pay=1"))
      }),
    )
    fail("expected a dial failure")
  } catch {
    @mttp.TransportError(kind~, phase~, detail~) as error => {
      assert_false(error.is_unsent())
      assert_eq(kind, Network)
      assert_eq(phase, Unknown)
      assert_true(detail.contains("Connect"))
      assert_true(detail.contains("Dial"))
      assert_true(detail.contains("refused"))
    }
    error => raise error
  }
  assert_eq(sends.length(), 2)
  assert_eq(sends.map(r => (r.meth, r.url, r.body)), [
    (@mttp.Method::Post, "https://a.test/pay", @mttp.Body::Bytes(b"pay=1")),
    (@mttp.Method::Post, "https://a.test/pay", @mttp.Body::Bytes(b"pay=1")),
  ])
  assert_eq(sends[0].headers.get("authorization"), None)
  assert_true(sends[1].headers.get("authorization") is Some(_))
  assert_eq(unread.reads(), 0)
  assert_eq(closed_at_retry.val, 1)
}

///|
test "first send failures stay unsent and stale response failures keep honest phases" {
  for fail_at in [1, 2, 3] {
    for kind in [@mttp.Kind::Connect, Proxy(status=407), Timeout(ms=5)] {
      let mut sends = 0
      let backend = wrap(
        @client.from_fn((_, _) => {
          sends += 1
          if sends == fail_at {
            raise @mttp.TransportError(kind~, phase=Dial, detail="original")
          }
          @mttp.Response::new(401, headers=challenge(stale=true))
        }),
      )
      defer backend.close()
      try {
        ignore(
          @driver.run_sync(() => {
            backend.send(
              @mttp.Request::get("https://a.test/"),
              @mttp.SendOptions::default(),
            )
          }),
        )
        fail("expected a transport failure")
      } catch {
        @mttp.TransportError(kind=actual, phase~, detail~) as error => {
          assert_eq(phase, if fail_at == 1 { Dial } else { Unknown })
          assert_eq(error.is_unsent(), fail_at == 1)
          assert_eq(
            actual,
            if fail_at > 1 && kind != Timeout(ms=5) {
              Network
            } else {
              kind
            },
          )
          assert_true(detail.contains("original"))
        }
        error => raise error
      }
      assert_eq(sends, fail_at)
    }
  }
}

///|
// Deliberately does no validation, so the wrapper's checks cannot be hidden
// by from_fn or BackendStub doing the same checks at the next layer.
struct UncheckedBackend {
  calls : Ref[Int32]
}

///|
impl @mttp.Backend for UncheckedBackend with fn send(self, _, _) {
  self.calls.val += 1
  @mttp.Response::new(200)
}

///|
test "Digest validates before delegation and closes refused request streams unread" {
  let calls = Ref(0)
  let backend = wrap(UncheckedBackend::{ calls, })
  for problem in 0..<7 {
    let upload = @sim.Feed::bytes(@driver.Driver::new(), [b"body"])
    let request = @mttp.Request::post("https://a.test/").body_stream(upload)
    let options = @mttp.SendOptions::default()
    let (request, options) = match problem {
      0 => ({ ..request, meth: Other("BAD METHOD"), }, options)
      1 => ({ ..request, url: "https://a.test/\n", }, options)
      2 => (request.header("bad name", "v"), options)
      3 => (request.header("x-bad", "\n"), options)
      4 => (request, { ..options, body: Exchange(max_bytes=-1), })
      5 => (request, { ..options, timeout_ms: Some(0), })
      _ => (request, { ..options, body: Stream(idle_ms=Some(0)), })
    }
    try {
      ignore(@driver.run_sync(() => backend.send(request, options)))
      fail("invalid send accepted")
    } catch {
      @mttp.TransportError(phase~, ..) => assert_eq(phase, Pool)
      error => raise error
    }
    assert_eq(calls.val, 0)
    assert_eq(upload.closes(), 1)
    assert_eq(upload.reads(), 0)
  }
  backend.close()
  let upload = @sim.Feed::bytes(@driver.Driver::new(), [b"body"])
  try {
    ignore(
      @driver.run_sync(() => {
        backend.send(
          @mttp.Request::post("https://a.test/").body_stream(upload),
          @mttp.SendOptions::default(),
        )
      }),
    )
    fail("closed send accepted")
  } catch {
    @mttp.TransportError(kind=Closed, phase=Pool, ..) => ()
    error => raise error
  }
  assert_eq(upload.closes(), 1)
  assert_eq(upload.reads(), 0)
  assert_eq(calls.val, 0)
}

///|
test "Digest preserves SendOptions and the final response belongs to its caller" {
  for
    body in [@mttp.BodyTiming::Exchange(max_bytes=17), Stream(idle_ms=Some(29))] {
    let options : @mttp.SendOptions = { timeout_ms: Some(43), body, }
    let d = @driver.Driver::new()
    let final_body = @sim.Feed::bytes(d, [b"ok"])
    let mut sends = 0
    let seen = []
    let backend = wrap(
      @client.from_fn((_, actual) => {
        seen.push(actual)
        sends += 1
        if sends <= 2 {
          @mttp.Response::new(401, headers=challenge(stale=sends == 2))
        } else {
          @mttp.Response::new(
            200,
            body=Stream(@mttp.StreamBody::new(final_body)),
          )
        }
      }),
    )
    let response = d.run(() => {
      backend.send(@mttp.Request::get("https://a.test/"), options)
    })
    assert_eq(sends, 3)
    assert_eq(seen, [options, options, options])
    assert_eq(final_body.closes(), 0)
    response.close()
    assert_eq(final_body.closes(), 1)
    backend.close()
  }
}

///|
test "Digest cancellation unwinds the inner send and closes an upload" {
  for with_challenge in [false, true] {
    let d = @driver.Driver::new()
    let upload = @sim.Feed::bytes(d, [b"upload"])
    let mut sends = 0
    let mut unwound = false
    let mut caught = false
    let mut returned = false
    let backend = wrap(
      @client.from_fn((_, _) => {
        sends += 1
        if with_challenge && sends == 1 {
          return @mttp.Response::new(401, headers=challenge())
        }
        defer {
          unwound = true
        }
        d.sleep(100)
        @mttp.Response::new(200)
      }),
    )
    d.run(() => {
      let task = d.spawn(() => {
        let request = if with_challenge {
          @mttp.Request::post("https://a.test/").body_bytes(b"body")
        } else {
          @mttp.Request::post("https://a.test/").body_stream(upload)
        }
        try {
          ignore(backend.send(request, @mttp.SendOptions::default()))
          returned = true
        } catch {
          _ => caught = true
        }
      })
      d.sleep(1)
      task.cancel()
      d.pause()
      assert_true(task.is_cancelled())
    })
    assert_true(unwound)
    assert_false(caught)
    assert_false(returned)
    assert_eq(sends, if with_challenge { 2 } else { 1 })
    if !with_challenge {
      assert_eq(upload.closes(), 1)
      assert_eq(upload.reads(), 0)
    }
    upload.close()
    backend.close()
  }
}
