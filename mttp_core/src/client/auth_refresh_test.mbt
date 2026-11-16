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
test "concurrent 401s share one refresh under every schedule" {
  @sim.explore(schedule => {
    let d = @driver.Driver::new(schedule~)
    let tokens = Tokens::new()
    let backend = @client.AuthRefresh::new(
      tokens.backend(d),
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
test "a failing refresh returns the original 401 and the next 401 tries again" {
  let d = @driver.Driver::new()
  let tokens = Tokens::new()
  let failing = Ref(true)
  let backend = @client.AuthRefresh::new(
    tokens.backend(d),
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
  assert_eq(first, (401, b"first"))
  assert_eq((tokens.refreshes, tokens.sends), (1, 1))
  failing.val = false
  let second = d.run(() => {
    auth_send(backend, @mttp_core.Request::get("https://api.example/"))
  })
  assert_eq(second, (200, b"ok"))
  assert_eq((tokens.refreshes, tokens.sends), (2, 3))
}

///|
test "a refresh cancelled with its caller hands over to a waiting request" {
  let d = @driver.Driver::new()
  let tokens = Tokens::new()
  let coordination = @sim.SimCoordination::new(d)
  let blocked = coordination.signal()
  let backend = @client.AuthRefresh::new(
    tokens.backend(d),
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
    let wrap = (inner : &@mttp_core.Backend) => {
      @client.AuthRefresh::new(
        inner,
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
