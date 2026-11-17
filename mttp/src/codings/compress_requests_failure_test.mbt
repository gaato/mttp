///|
test "415 fallback failures cannot claim the original exchange was unsent" {
  for fail_at in [1, 2] {
    for phase in [@mttp_core.Phase::Pool, Dial, Write, Head, Body, Unknown] {
      for
        kind in [
          @mttp_core.Kind::Network,
          Connect,
          Proxy(status=407),
          Timeout(ms=5),
          Refused,
        ] {
        let sends = Ref(0)
        let original = @mttp_core.TransportError(
          kind~,
          phase~,
          detail="original failure",
        )
        let backend = @codings.CompressRequests::new(
          @client.from_fn((_, _) => {
            sends.val += 1
            if sends.val == fail_at {
              raise original
            }
            @mttp_core.Response::new(
              415,
              headers=@mttp_core.Headers::of([("accept-encoding", "identity")]),
            )
          }),
          min_bytes=0,
        )
        defer backend.close()
        try
          @driver.run_sync(() => {
            backend.send(upload(), @mttp_core.SendOptions::default())
          })
        catch {
          @mttp_core.TransportError(
            kind=actual_kind,
            phase=actual_phase,
            detail~
          ) as error =>
            if fail_at == 1 {
              assert_eq(actual_kind, kind)
              assert_eq(actual_phase, phase)
              assert_eq(detail, "original failure")
              assert_eq(error.is_unsent(), original.is_unsent())
            } else {
              assert_false(error.is_unsent())
              assert_eq(actual_phase, Unknown)
              assert_eq(
                actual_kind,
                if kind is (Connect | Proxy(_) | Refused) {
                  Network
                } else {
                  kind
                },
              )
              assert_true(detail.contains(original.message()))
            }
          error => raise error
        } noraise {
          _ => fail("expected transport failure")
        }
        assert_eq(sends.val, fail_at)
      }
    }
  }
}

///|
test "Client unsent_failures never retries a POST after the 415 resend fails" {
  let sends = []
  let rejected = @sim.Feed::bytes(@driver.Driver::new(), [b"rejected"])
  let closed_at_resend = Ref(0)
  let backend = @codings.CompressRequests::new(
    @client.from_fn((request, _) => {
      sends.push(request)
      if sends.length() == 1 {
        @mttp_core.Response::new(
          415,
          headers=@mttp_core.Headers::of([("accept-encoding", "identity")]),
          body=Stream(@mttp_core.StreamBody::new(rejected)),
        )
      } else {
        closed_at_resend.val = rejected.closes()
        raise @mttp_core.TransportError(
          kind=Connect,
          phase=Dial,
          detail="refused",
        )
      }
    }),
    min_bytes=0,
  )
  let retry = @client.RetryPolicy::from_rule({
    ..@retry.RetryRule::never(),
    max_retries: 2,
    unsent_failures: true,
  })
  let client = @client.Client::new(backend, @sim.FakeClock::new(), retry~)
  defer client.close()
  try
    @driver.run_sync(() => {
      client.send(
        @client.post("https://example.test/pay")
        .body_bytes(b"pay=1")
        .header("content-type", "application/json"),
      )
    })
  catch {
    @mttp_core.TransportError(kind~, phase~, detail~) as error => {
      assert_false(error.is_unsent())
      assert_eq(kind, Network)
      assert_eq(phase, Unknown)
      assert_true(detail.contains("Connect during Dial: refused"))
    }
    error => raise error
  } noraise {
    _ => fail("expected fallback failure")
  }
  assert_eq(sends.length(), 2)
  assert_eq(sends[0].headers.get("content-encoding"), Some("gzip"))
  assert_eq(sends[1].headers.get("content-encoding"), None)
  assert_eq(sends[1].body, Bytes(b"pay=1"))
  assert_eq(rejected.reads(), 0)
  assert_eq(closed_at_resend.val, 1)
}

///|
test "CompressRequests closes refused request streams unread before delegation" {
  @driver.run_sync(() => {
    // This fixture deliberately performs no validation or request cleanup,
    // so the wrapper's ownership guarantee cannot be supplied by its inner.
    let inner = fixture(@mttp_core.Response::new(200))
    let backend = @codings.CompressRequests::new(inner, streams=true)
    for problem in 0..<9 {
      let source = @sim.Feed::bytes(@driver.Driver::new(), [b"upload"])
      let request = upload().body_stream(
        source,
        content_type="application/json",
      )
      let options = @mttp_core.SendOptions::default()
      let (request, options) = match problem {
        0 => (request.header("bad name", "value"), options)
        1 => (request.header("x-bad", "\n"), options)
        2 => ({ ..request, meth: Other("BAD METHOD"), }, options)
        3 => ({ ..request, url: "https://example.test/\n", }, options)
        4 =>
          (
            {
              ..request,
              body: Stream(@mttp_core.StreamBody::new(source, length=-1L)),
            },
            options,
          )
        5 => (request, { ..options, body: Exchange(max_bytes=-1), })
        6 => (request, { ..options, timeout_ms: Some(0), })
        7 => (request, { ..options, body: Stream(idle_ms=Some(0)), })
        _ => {
          backend.close()
          (request, options)
        }
      }
      try backend.send(request, options) catch {
        @mttp_core.TransportError(kind~, phase~, ..) => {
          assert_eq(phase, Pool)
          assert_eq(
            kind,
            if problem == 8 {
              Closed
            } else if problem == 6 {
              Timeout(ms=0)
            } else {
              Invalid
            },
          )
        }
      } noraise {
        _ => fail("invalid or closed send accepted")
      }
      assert_eq(inner.sent.length(), 0)
      assert_eq(source.reads(), 0)
      assert_eq(source.closes(), 1)
    }
  })
}
