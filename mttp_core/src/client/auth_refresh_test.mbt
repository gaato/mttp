// AuthRefresh over a server that accepts one token at a time: concurrent
// 401s share one refresh under every schedule, and the wrapper resends at
// most once.

///|
/// The credentials a test's refresh renews: the token `apply` sends, the
/// token the server accepts, and the refresh calls made.
priv struct Tokens {
  mut current : Int32
  accepted : Int32
  mut refreshes : Int32
  mut sends : Int32
}

///|
fn Tokens::new() -> Tokens {
  { current: 0, accepted: 1, refreshes: 0, sends: 0, }
}

///|
/// A backend answering 200 to the accepted token and 401 to any other,
/// pausing before the head so that sends interleave.
fn Tokens::backend(self : Tokens, d : @driver.Driver) -> &@mttp_core.Backend {
  @client.from_fn((request, _) => {
    self.sends += 1
    // Like a real backend, it takes a stream body and closes it.
    if request.body is Stream(stream) {
      stream.take().close()
    }
    let token = request.headers.get("authorization")
    d.pause()
    if token == Some("Bearer \{self.accepted}") {
      @mttp_core.Response::new(200, body=Bytes(b"ok"))
    } else {
      @mttp_core.Response::new(401, body=Bytes(b"first"))
    }
  })
}

///|
fn Tokens::apply(self : Tokens) -> (@mttp_core.Request) -> @mttp_core.Request {
  request => request.bearer("\{self.current}")
}

///|
test "AuthRefresh does not reapply credentials on a cross-origin Client redirect" {
  for
    destination in [
      "http://other.example/end", "http://api.example:81/end", "https://api.example/end",
    ] {
    let d = @driver.Driver::new()
    let seen = []
    let refreshes = Ref(0)
    let backend = @client.AuthRefresh::new(
      @client.from_fn((request, _) => {
        seen.push((request.url, request.headers.get("authorization")))
        if request.url == "http://api.example/start" {
          @mttp_core.Response::new(
            302,
            headers=@mttp_core.Headers::of([("location", destination)]),
          )
        } else {
          @mttp_core.Response::new(401)
        }
      }),
      origin=@mttp_core.Url::parse("HTTP://API.EXAMPLE:80/credentials"),
      refresh=() => refreshes.val += 1,
      apply=request => request.bearer("secret"),
      coordination=@sim.SimCoordination::new(d),
    )
    let client = @client.Client::new(backend, @sim.SimClock::new(d))
    let reply = d.run(() => client.send(@client.get("http://api.example/start")))
    assert_eq(reply.status, 401)
    assert_eq(seen, [
      ("http://api.example/start", Some("Bearer secret")),
      (destination, None),
    ])
    assert_eq(refreshes.val, 0)
    for url in [destination, "/relative", "http://["] {
      let response = d.run(() => {
        backend.send(
          @mttp_core.Request::get(url).bearer("caller-owned"),
          @mttp_core.SendOptions::default(),
        )
      })
      response.close()
      assert_eq(seen.last(), Some((url, Some("Bearer caller-owned"))))
    }
    assert_eq(refreshes.val, 0)
  }
}

///|
async fn auth_send(
  backend : @client.AuthRefresh,
  request : @mttp_core.Request,
) -> (Int32, Bytes) noraise {
  let response = backend.send(request, @mttp_core.SendOptions::default()) catch {
    error => abort("unexpected failure: \{error}")
  }
  (response.status, response.body.as_bytes().unwrap_or(b""))
}

///|
test "a late 401 reuses credentials refreshed since its send" {
  let d = @driver.Driver::new()
  let tokens = Tokens::new()
  let backend = @client.AuthRefresh::new(
    @client.from_fn((request, _) => {
      tokens.sends += 1
      let authorized = request.headers.get("authorization") == Some("Bearer 1")
      if !authorized && request.url.has_suffix("/late") {
        d.sleep(20)
      }
      @mttp_core.Response::new(if authorized { 200 } else { 401 })
    }),
    origin=@mttp_core.Url::parse("https://api.example/"),
    refresh=() => {
      tokens.refreshes += 1
      tokens.current = 1
    },
    apply=tokens.apply(),
    coordination=@sim.SimCoordination::new(d),
  )
  let statuses = []
  d.run(() => {
    let late = d.spawn(() => {
      statuses.push(
        auth_send(backend, @mttp_core.Request::get("https://api.example/late")).0,
      )
    })
    d.sleep(1)
    assert_eq(tokens.sends, 1)
    statuses.push(
      auth_send(backend, @mttp_core.Request::get("https://api.example/fast")).0,
    )
    assert_eq(tokens.refreshes, 1)
    assert_true(late.wait())
  })
  assert_eq(statuses, [200, 200])
  assert_eq((tokens.refreshes, tokens.sends), (1, 4))
}

///|
test "a request joining a failed refresh returns its original empty 401" {
  let d = @driver.Driver::new()
  let tokens = Tokens::new()
  let backend = @client.AuthRefresh::new(
    tokens.backend(d),
    origin=@mttp_core.Url::parse("https://api.example/"),
    refresh=() => {
      tokens.refreshes += 1
      d.sleep(20)
      fail("token endpoint down")
    },
    apply=tokens.apply(),
    coordination=@sim.SimCoordination::new(d),
  )
  let results = []
  d.run(() => {
    let first = d.spawn(() => {
      results.push(
        auth_send(backend, @mttp_core.Request::get("https://api.example/first")),
      )
    })
    d.sleep(1)
    assert_eq(tokens.refreshes, 1)
    results.push(
      auth_send(backend, @mttp_core.Request::get("https://api.example/join")),
    )
    assert_true(first.wait())
  })
  assert_eq(results, [(401, b""), (401, b"")])
  assert_eq((tokens.refreshes, tokens.sends), (1, 2))
}

///|
test "concurrent 401s share one refresh under every schedule" {
  @sim.explore(schedule => {
    let d = @driver.Driver::new(schedule~)
    let tokens = Tokens::new()
    let backend = @client.AuthRefresh::new(
      tokens.backend(d),
      origin=@mttp_core.Url::parse("https://api.example/"),
      refresh=() => {
        tokens.refreshes += 1
        d.pause()
        tokens.current = tokens.accepted
      },
      apply=tokens.apply(),
      coordination=@sim.SimCoordination::new(d),
    )
    let statuses = []
    d.run(() => {
      let tasks = []
      for i in 0..<4 {
        let request = @mttp_core.Request::post("https://api.example/\{i}").body_bytes(
          b"payload",
        )
        tasks.push(d.spawn(() => statuses.push(auth_send(backend, request).0)))
      }
      for task in tasks {
        ignore(task.wait())
      }
    })
    assert_eq(tokens.refreshes, 1)
    assert_eq(statuses, [200, 200, 200, 200])
    // Each request is sent at most twice.
    assert_true(tokens.sends >= 4 && tokens.sends <= 8)
  })
}

///|
test "a persistent 401 is resent once and a marked request never" {
  let d = @driver.Driver::new()
  let tokens = { ..Tokens::new(), accepted: -1, }
  let backend = @client.AuthRefresh::new(
    tokens.backend(d),
    origin=@mttp_core.Url::parse("https://api.example/"),
    refresh=() => tokens.refreshes += 1,
    apply=tokens.apply(),
    coordination=@sim.SimCoordination::new(d),
  )
  let first = d.run(() => {
    auth_send(backend, @mttp_core.Request::get("https://api.example/"))
  })
  assert_eq(first, (401, b"first"))
  assert_eq((tokens.refreshes, tokens.sends), (1, 2))
  let marked = d.run(() => {
    auth_send(
      backend,
      @mttp_core.Request::get("https://api.example/").attribute(
        @client.auth_refreshed, true,
      ),
    )
  })
  assert_eq(marked.0, 401)
  assert_eq((tokens.refreshes, tokens.sends), (1, 3))
}

///|
test "an unreplayable body gets its 401 without a refresh" {
  let d = @driver.Driver::new()
  let tokens = Tokens::new()
  let backend = @client.AuthRefresh::new(
    tokens.backend(d),
    origin=@mttp_core.Url::parse("https://api.example/"),
    refresh=() => tokens.refreshes += 1,
    apply=tokens.apply(),
    coordination=@sim.SimCoordination::new(d),
  )
  let source = @sim.Feed::bytes(d, [b"stream"])
  let result = d.run(() => {
    auth_send(
      backend,
      @mttp_core.Request::post("https://api.example/").body_stream(source),
    )
  })
  assert_eq(result, (401, b"first"))
  assert_eq((tokens.refreshes, tokens.sends), (0, 1))
  assert_eq(source.closes(), 1)
}

///|
test "a failing refresh returns the closed 401 head and the next 401 tries again" {
  let d = @driver.Driver::new()
  let tokens = Tokens::new()
  let failing = Ref(true)
  let backend = @client.AuthRefresh::new(
    tokens.backend(d),
    origin=@mttp_core.Url::parse("https://api.example/"),
    refresh=() => {
      tokens.refreshes += 1
      if failing.val {
        fail("token endpoint down")
      }
      tokens.current = tokens.accepted
    },
    apply=tokens.apply(),
    coordination=@sim.SimCoordination::new(d),
  )
  let first = d.run(() => {
    auth_send(backend, @mttp_core.Request::get("https://api.example/"))
  })
  assert_eq(first, (401, b""))
  assert_eq((tokens.refreshes, tokens.sends), (1, 1))
  failing.val = false
  let second = d.run(() => {
    auth_send(backend, @mttp_core.Request::get("https://api.example/"))
  })
  assert_eq(second, (200, b"ok"))
  assert_eq((tokens.refreshes, tokens.sends), (2, 3))
}

///|
test "AuthRefresh releases the 401 connection before refreshing through a one-slot HTTP client" {
  let d = @driver.Driver::new()
  let clock = @sim.SimClock::new(d)
  let timer = @sim.SimTimer::new(d)
  let rejected = @sim.ScriptedConn::new([
    Chunk(b"HTTP/1.1 401 Unauthorized\r\nContent-Length: 4\r\n\r\nbody"),
  ])
  let accepted = @sim.ScriptedConn::new([
    Chunk(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"),
    Chunk(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"),
  ])
  let engine = @h1client.Client::new(
    dialer=@sim.ScriptedDialer::new([rejected, accepted]),
    clock~,
    timer~,
    coordination=@sim.SimCoordination::new(d),
    config={ ..@h1client.ClientConfig::default(), max_connections: Some(1), },
  )
  let refreshed = Ref(false)
  let origin = @mttp_core.Url::parse("http://api.example/")
  let backend = @client.AuthRefresh::new(
    engine,
    origin~,
    refresh=() => {
      let response = engine.send(
        @mttp_core.Request::post("http://api.example/token"),
        @mttp_core.SendOptions::default(),
      )
      response.close()
      refreshed.val = true
    },
    apply=request => request.bearer(if refreshed.val { "new" } else { "old" }),
    coordination=@sim.SimCoordination::new(d),
  )
  d.run(() => {
    let completed = timer.within(100, () => {
      let response = backend.send(
        @mttp_core.Request::get("http://api.example/me"),
        { timeout_ms: None, body: Stream(idle_ms=None), },
      ) catch {
        error => abort(error.to_string())
      }
      defer response.close()
      assert_eq(response.status, 200) catch {
        error => abort(error.to_string())
      }
    })
    assert_true(completed)
    assert_true(refreshed.val)
    backend.close()
  })
}

///|
test "a refresh cancelled with its caller hands over to a waiting request" {
  let d = @driver.Driver::new()
  let tokens = Tokens::new()
  let coordination = @sim.SimCoordination::new(d)
  let blocked = coordination.signal()
  let backend = @client.AuthRefresh::new(
    tokens.backend(d),
    origin=@mttp_core.Url::parse("https://api.example/"),
    refresh=() => {
      tokens.refreshes += 1
      if tokens.refreshes == 1 {
        // The first refresh never finishes on its own.
        blocked.wait()
      }
      tokens.current = tokens.accepted
    },
    apply=tokens.apply(),
    coordination~,
  )
  let second = Ref((0, b""))
  d.run(() => {
    let first = d.spawn(() => {
      ignore(
        auth_send(backend, @mttp_core.Request::get("https://api.example/a")),
      )
    })
    let waiter = d.spawn(() => {
      second.val = auth_send(
        backend,
        @mttp_core.Request::get("https://api.example/b"),
      )
    })
    for _ in 0..<4 {
      d.pause()
    }
    assert_eq(tokens.refreshes, 1)
    first.cancel()
    assert_false(first.wait())
    assert_true(waiter.wait())
  })
  assert_eq(second.val, (200, b"ok"))
  assert_eq(tokens.refreshes, 2)
}

///|
test "the auth refresh wrapper keeps the backend contract" {
  @driver.run_sync(() => {
    let d = @driver.current()
    let origin = @mttp_core.Url::parse("https://example.test/")
    let wrap = (inner : &@mttp_core.Backend) => {
      @client.AuthRefresh::new(
        inner,
        origin~,
        refresh=() => (),
        apply=request => request,
        coordination=@sim.SimCoordination::new(d),
      )
    }
    @sim.check_backend_contract(
      () => wrap(@client.from_fn((_, _) => @mttp_core.Response::new(200))),
      wrap=inner => wrap(inner),
    )
  })
}
