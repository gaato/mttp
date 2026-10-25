///|
test "redirects close intermediate streams and preserve final attributes and history" {
  let d = @driver.Driver::new()
  let first = @feed.Feed::bytes(d, [b"unread"])
  let last = @feed.Feed::bytes(d, [b"final"])
  let seen = []
  let hops = []
  let closes = Ref(0)
  let key : @model.AttributeKey[String] = @model.AttributeKey::new("server")
  let backend : &@client.Backend = @client.FollowRedirects::new(
    @client.from_fn(
      (request, options) => {
        seen.push((request.head(), options.follow_redirects))
        if seen.length() == 1 {
          @model.Response::new(
            302,
            headers=@model.Headers::of([("location", "/b")]),
            body=Stream(@model.StreamBody::new(first)),
          )
        } else {
          {
            ..@model.Response::new(
              200,
              body=Stream(@model.StreamBody::new(last)),
            ),
            attributes: @model.Attributes::empty().put(key, "kept"),
          }
        }
      },
      on_close=() => closes.val += 1,
    ),
    on_redirect=hop => hops.push(hop),
  )
  let response = d.run(() => {
    backend.send(
      @model.Request::post("https://h/a").body_text("data"),
      @client.RequestOptions::default(),
    )
  })
  assert_eq(first.closes(), 1)
  assert_eq(first.reads(), 0)
  assert_eq(last.closes(), 0)
  assert_eq(seen.length(), 2)
  assert_eq(seen[1].0.meth, Get)
  assert_eq(seen[1].0.url, "https://h/b")
  assert_eq(seen[0].1, false)
  assert_eq(seen[1].1, false)
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
        @model.Request::get("https://h/"),
        @client.RequestOptions::default(),
      )
    })
  catch {
    @model.TransportError(kind=Closed, ..) => ()
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
      ("/b", 302, 0, @model.Kind::TooManyRedirects(max=0)),
      ("http://h/b", 302, 10, RedirectRefused),
      ("ftp://h/b", 302, 10, RedirectRefused),
      ("/b", 307, 10, Unreplayable),
    ] {
    let (location, status, max, expected) = case
    let body = @feed.Feed::bytes(d, [b"unread"])
    let upload = @feed.Feed::bytes(d, [b"sent"])
    let backend = @client.FollowRedirects::new(
      @client.from_fn((request, _) => {
        if request.body is Stream(stream) {
          stream.take().close()
        }
        @model.Response::new(
          status,
          headers=@model.Headers::of([("location", location)]),
          body=Stream(@model.StreamBody::new(body)),
        )
      }),
    )
    defer backend.close()
    try
      d.run(() => {
        backend.send(@model.Request::post("https://h/a").body_stream(upload), {
          ..@client.RequestOptions::default(),
          max_redirects: max,
        })
      })
    catch {
      @model.TransportError(kind~, phase~, ..) => {
        assert_eq(kind, expected)
        assert_eq(phase, Head)
      }
      _ => fail("wrong error")
    } noraise {
      _ => fail("expected refusal")
    }
    assert_eq(body.closes(), 1)
    assert_eq(body.reads(), 0)
  }
}

///|
test "redirect request overrides survive reader replacement and preserve defaults" {
  let seen = []
  let backend = @client.from_fn((_, options) => {
    seen.push(options)
    @model.Response::new(200)
  })
  let client = @client.Client::new(backend, @fake.FakeClock::new(), options={
    ..@client.RequestOptions::default(),
    max_body_bytes: 7,
    timeout_ms: Some(80),
  })
  @driver.run_sync(() => {
    let _ = client.send(
      @client.request(@model.Request::get("https://h/"))
      .follow_redirects(false)
      .max_redirects(2)
      .response(@client.ignore_body()),
    )
  })
  assert_eq(seen[0].follow_redirects, false)
  assert_eq(seen[0].max_redirects, 2)
  assert_eq(seen[0].max_body_bytes, 7)
  assert_eq(seen[0].timeout_ms, Some(80))
}

///|
test "disabled redirects return the first stream and transport failures pass through" {
  let d = @driver.Driver::new()
  let body = @feed.Feed::bytes(d, [b"unread"])
  let backend = @client.FollowRedirects::new(
    @client.from_fn((_, _) => {
      @model.Response::new(
        302,
        headers=@model.Headers::of([("location", "/next")]),
        body=Stream(@model.StreamBody::new(body)),
      )
    }),
  )
  let response = d.run(() => {
    backend.send(@model.Request::get("https://h/"), {
      ..@client.RequestOptions::default(),
      follow_redirects: false,
    })
  })
  assert_eq(response.status, 302)
  assert_eq(body.closes(), 0)
  assert_eq(response.attributes.get(@client.redirect_history), Some([]))
  response.close()
  backend.close()
  let failed = @client.FollowRedirects::new(
    @client.from_fn((_, _) => {
      raise @model.TransportError(kind=Network, phase=Dial, detail="fixture")
    }),
  )
  try
    d.run(() => {
      failed.send(
        @model.Request::get("https://h/"),
        @client.RequestOptions::default(),
      )
    })
  catch {
    @model.TransportError(kind=Network, phase=Dial, detail="fixture") => ()
    _ => fail("wrong failure")
  } noraise {
    _ => fail("expected failure")
  }
  failed.close()
}
