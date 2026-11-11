///|
test "redirects close intermediate streams and preserve final attributes and history" {
  let d = @driver.Driver::new()
  let first = @sim.Feed::bytes(d, [b"unread"])
  let last = @sim.Feed::bytes(d, [b"final"])
  let seen = []
  let hops = []
  let closes = Ref(0)
  let key : @mttp.AttributeKey[String] = @mttp.AttributeKey::new("server")
  let backend : &@mttp.Backend = @client.FollowRedirects::new(
    @client.from_fn(
      (request, options) => {
        seen.push((request.head(), options))
        if seen.length() == 1 {
          @mttp.Response::new(
            302,
            headers=@mttp.Headers::of([("location", "/b")]),
            body=Stream(@mttp.StreamBody::new(first)),
          )
        } else {
          {
            ..@mttp.Response::new(200, body=Stream(@mttp.StreamBody::new(last))),
            attributes: @mttp.Attributes::empty().put(key, "kept"),
          }
        }
      },
      on_close=() => closes.val += 1,
    ),
    on_redirect=hop => hops.push(hop),
  )
  let response = d.run(() => {
    backend.send(
      @mttp.Request::post("https://h/a").body_text("data"),
      @mttp.SendOptions::default(),
    )
  })
  assert_eq(first.closes(), 1)
  assert_eq(first.reads(), 0)
  assert_eq(last.closes(), 0)
  assert_eq(seen.length(), 2)
  assert_eq(seen[1].0.meth, Get)
  assert_eq(seen[1].0.url, "https://h/b")
  // Every hop gets the options unchanged.
  assert_eq(seen[0].1, @mttp.SendOptions::default())
  assert_eq(seen[1].1, @mttp.SendOptions::default())
  assert_eq(response.attributes.get(@client.final_url), Some("https://h/b"))
  assert_eq(response.attributes.get(@client.redirect_history), Some(hops))
  assert_eq(response.attributes.get(key), Some("kept"))
  assert_eq(hops.length(), 1)
  assert_eq(hops[0].head.status, 302)
  assert_eq(d.run(() => @client.read_body(response.body, 100)), b"final")
  backend.close()
  backend.close()
  assert_eq(closes.val, 1)
  try
    d.run(() => {
      backend.send(
        @mttp.Request::get("https://h/"),
        @mttp.SendOptions::default(),
      )
    })
  catch {
    @mttp.TransportError(kind=Closed, ..) => ()
    _ => fail("wrong error")
  } noraise {
    _ => fail("accepted after close")
  }
}

///|
test "redirect refusals close received bodies and retain error classification" {
  let d = @driver.Driver::new()
  for
    case in [
      ("/b", 302, 1, @mttp.Kind::TooManyRedirects(max=1), 2),
      ("http://h/b", 302, 10, RedirectRefused, 1),
      ("ftp://h/b", 302, 10, RedirectRefused, 1),
      ("/b", 307, 10, Unreplayable, 1),
    ] {
    let (location, status, max, expected, responses) = case
    let bodies = []
    let upload = @sim.Feed::bytes(d, [b"sent"])
    let backend = @client.FollowRedirects::new(
      @client.from_fn((request, _) => {
        if request.body is Stream(stream) {
          stream.take().close()
        }
        let body = @sim.Feed::bytes(d, [b"unread"])
        bodies.push(body)
        @mttp.Response::new(
          status,
          headers=@mttp.Headers::of([("location", location)]),
          body=Stream(@mttp.StreamBody::new(body)),
        )
      }),
      config={ ..@client.RedirectConfig::default(), max_redirects: max, },
    )
    defer backend.close()
    // A 302 turns the POST into a GET, so only the 307 resends the stream.
    try
      d.run(() => {
        backend.send(
          @mttp.Request::post("https://h/a").body_stream(upload),
          @mttp.SendOptions::default(),
        )
      })
    catch {
      @mttp.TransportError(kind~, phase~, ..) => {
        assert_eq(kind, expected)
        assert_eq(phase, Head)
      }
      _ => fail("wrong error")
    } noraise {
      _ => fail("expected refusal")
    }
    // Every received body is closed unread, the refused one included.
    assert_eq(bodies.length(), responses)
    for body in bodies {
      assert_eq(body.closes(), 1)
      assert_eq(body.reads(), 0)
    }
  }
}

///|
test "a redirect limit of zero returns the redirect and failures pass through" {
  let d = @driver.Driver::new()
  let bodies = []
  let backend = @client.FollowRedirects::new(
    @client.from_fn((_, _) => {
      let body = @sim.Feed::bytes(d, [b"unread"])
      bodies.push(body)
      @mttp.Response::new(
        302,
        headers=@mttp.Headers::of([("location", "/next")]),
        body=Stream(@mttp.StreamBody::new(body)),
      )
    }),
  )
  for
    request in [
      @mttp.Request::get("https://h/").attribute(@client.redirect_limit, 0),
      @mttp.Request::get("https://h/").attribute(@client.redirect_limit, -1),
    ] {
    let response = d.run(() => {
      backend.send(request, @mttp.SendOptions::default())
    })
    assert_eq(response.status, 302)
    assert_eq(response.attributes.get(@client.redirect_history), Some([]))
    // The 3xx body is the caller's, unread and open.
    assert_eq(bodies[bodies.length() - 1].closes(), 0)
    response.close()
  }
  assert_eq(bodies.map(body => body.closes()), [1, 1])
  backend.close()
  let unfollowed = @client.FollowRedirects::new(
    @client.from_fn((_, _) => {
      @mttp.Response::new(302, headers=@mttp.Headers::of([("location", "/n")]))
    }),
    config={ ..@client.RedirectConfig::default(), max_redirects: 0, },
  )
  let response = d.run(() => {
    unfollowed.send(
      @mttp.Request::get("https://h/"),
      @mttp.SendOptions::default(),
    )
  })
  assert_eq(response.status, 302)
  let failed = @client.FollowRedirects::new(
    @client.from_fn((_, _) => {
      raise @mttp.TransportError(kind=Network, phase=Dial, detail="fixture")
    }),
  )
  try
    d.run(() => {
      failed.send(
        @mttp.Request::get("https://h/"),
        @mttp.SendOptions::default(),
      )
    })
  catch {
    @mttp.TransportError(kind=Network, phase=Dial, detail="fixture") => ()
    _ => fail("wrong failure")
  } noraise {
    _ => fail("expected failure")
  }
  failed.close()
}

///|
test "the configured hop limit and credential set apply, and a plan overrides the limit" {
  let d = @driver.Driver::new()
  let seen = []
  let backend = @client.FollowRedirects::new(
    @client.from_fn((request, _) => {
      seen.push(request.head())
      let next = if request.url.has_prefix("https://a.test/") {
        "https://b.test/"
      } else {
        "https://a.test/"
      }
      @mttp.Response::new(302, headers=@mttp.Headers::of([("location", next)]))
    }),
    config={
      ..@client.RedirectConfig::default(),
      max_redirects: 3,
      credential_headers: ["x-api-key"],
    },
  )
  let client = @client.Client::new(backend, @sim.SimClock::new(d))
  let request = @mttp.Request::get("https://a.test/")
    .header("x-api-key", "secret")
    .bearer("token")
  let failure = try {
    ignore(d.run(() => client.send(@client.request(request))))
    None
  } catch {
    @mttp.TransportError(kind~, ..) => Some(kind)
    error => raise error
  }
  assert_eq(failure, Some(TooManyRedirects(max=3)))
  assert_eq(seen.length(), 4)
  // Only the configured set is removed: Authorization is forwarded here.
  assert_eq(seen[1].headers.get("x-api-key"), None)
  assert_eq(seen[1].headers.get("authorization"), Some("Bearer token"))
  seen.clear()
  let failure = try {
    ignore(d.run(() => client.send(@client.request(request).max_redirects(1))))
    None
  } catch {
    @mttp.TransportError(kind~, ..) => Some(kind)
    error => raise error
  }
  assert_eq(failure, Some(TooManyRedirects(max=1)))
  assert_eq(seen.length(), 2)
  // The default set removes the usual credentials on an origin change.
  let defaults = @client.FollowRedirects::new(
    @client.from_fn((request, _) => {
      seen.push(request.head())
      if request.url == "https://a.test/" {
        @mttp.Response::new(
          302,
          headers=@mttp.Headers::of([("location", "https://b.test/")]),
        )
      } else {
        @mttp.Response::new(200)
      }
    }),
  )
  seen.clear()
  let response = d.run(() => {
    defaults.send(
      request.header("cookie", "a=1").header("proxy-authorization", "p"),
      @mttp.SendOptions::default(),
    )
  })
  assert_eq(response.status, 200)
  assert_eq(seen[1].headers.get("authorization"), None)
  assert_eq(seen[1].headers.get("cookie"), None)
  assert_eq(seen[1].headers.get("proxy-authorization"), None)
  assert_eq(seen[1].headers.get("x-api-key"), Some("secret"))
}

///|
test "the default configuration follows ten hops and refuses the eleventh" {
  let mut sends = 0
  let backend = @client.FollowRedirects::new(
    @client.from_fn((request, _) => {
      sends += 1
      let next = if request.url.has_suffix("/a") { "/b" } else { "/a" }
      @mttp.Response::new(302, headers=@mttp.Headers::of([("location", next)]))
    }),
  )
  let failure = try {
    ignore(
      @driver.run_sync(() => {
        backend.send(
          @mttp.Request::get("https://h/a"),
          @mttp.SendOptions::default(),
        )
      }),
    )
    None
  } catch {
    @mttp.TransportError(kind~, ..) => Some(kind)
    error => raise error
  }
  assert_eq(failure, Some(TooManyRedirects(max=10)))
  assert_eq(sends, 11)
  // Ten hops are allowed: a chain that ends after the tenth returns its answer.
  sends = 0
  let ten = @client.FollowRedirects::new(
    @client.from_fn((_, _) => {
      sends += 1
      if sends <= 10 {
        @mttp.Response::new(
          302,
          headers=@mttp.Headers::of([("location", "/n")]),
        )
      } else {
        @mttp.Response::new(200)
      }
    }),
  )
  let response = @driver.run_sync(() => {
    ten.send(@mttp.Request::get("https://h/a"), @mttp.SendOptions::default())
  })
  assert_eq(response.status, 200)
  assert_eq(
    response.attributes.get(@client.redirect_history).map(h => h.length()),
    Some(10),
  )
}

///|
test "a failure after a followed redirect is never unsent, so it is not resent" {
  let sends = []
  let backend = @client.FollowRedirects::new(
    @client.from_fn((request, _) => {
      sends.push(request.meth.to_string() + " " + request.url)
      if request.url == "https://h/form" {
        @mttp.Response::new(
          302,
          headers=@mttp.Headers::of([("location", "/done")]),
        )
      } else {
        raise @mttp.TransportError(kind=Connect, phase=Dial, detail="refused")
      }
    }),
  )
  // Retries only what provably was not sent.
  let retry = @client.RetryPolicy::from_rule({
    ..@retry.RetryRule::never(),
    max_retries: 2,
    unsent_failures: true,
  })
  let client = @client.Client::new(backend, @sim.FakeClock::new(), retry~)
  let failure = try {
    ignore(
      @driver.run_sync(() => {
        client.send(@client.post("https://h/form").body_bytes(b"pay=1"))
      }),
    )
    None
  } catch {
    @mttp.TransportError(..) as error => Some(error)
    error => raise error
  }
  guard failure is Some(@mttp.TransportError(kind~, phase~, ..) as error) else {
    fail("expected a transport failure")
  }
  assert_false(error.is_unsent())
  assert_eq(kind, Network)
  assert_eq(phase, Unknown)
  // The POST was answered once; nothing was resent.
  assert_eq(sends, ["POST https://h/form", "GET https://h/done"])
  // A failure of the first hop is still unsent, and is retried.
  sends.clear()
  let failure = try {
    ignore(
      @driver.run_sync(() => client.send(@client.post("https://h/elsewhere"))),
    )
    None
  } catch {
    @mttp.TransportError(kind~, phase~, ..) => Some((kind, phase))
    error => raise error
  }
  assert_eq(failure, Some((Connect, Dial)))
  assert_eq(sends.length(), 3)
  // Timeouts and other kinds keep their kind, with phase Unknown.
  let timed = @client.FollowRedirects::new(
    @client.from_fn((request, _) => {
      if request.url == "https://h/a" {
        @mttp.Response::new(
          307,
          headers=@mttp.Headers::of([("location", "/b")]),
        )
      } else {
        raise @mttp.TransportError(
          kind=Timeout(ms=5),
          phase=Head,
          detail="slow",
        )
      }
    }),
  )
  let failure = try {
    ignore(
      @driver.run_sync(() => {
        timed.send(
          @mttp.Request::get("https://h/a"),
          @mttp.SendOptions::default(),
        )
      }),
    )
    None
  } catch {
    @mttp.TransportError(kind~, phase~, ..) => Some((kind, phase))
    error => raise error
  }
  assert_eq(failure, Some((Timeout(ms=5), Unknown)))
}
