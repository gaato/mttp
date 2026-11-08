///|
/// Starts a peer task answering every request with `ok(body)`.
fn serving(h : Harness, peer : Peer, body : String) -> @driver.Task {
  h.driver.spawn(() => ignore(peer.serve(ok(body))))
}

///|
test "parked connections are reused per origin and User-Agent" {
  let h = Harness::new()
  let first = h.peer()
  let second = h.peer()
  let third = h.peer()
  let fourth = h.peer()
  h.run(() => {
    let servers = [
      serving(h, first, "1"),
      serving(h, second, "2"),
      serving(h, third, "3"),
      serving(h, fourth, "4"),
    ]
    let get = (url : String, agent : String?) => {
      match agent {
        Some(agent) => @http.Request::get(url).header("user-agent", agent)
        None => @http.Request::get(url)
      }
    }
    let answers = []
    for
      request in [
        get("http://a.test/", Some("x")),
        get("http://a.test/", Some("y")),
        get("http://a.test/other", Some("x")),
        get("http://a.test:80/", Some("y")),
        get("https://a.test/", Some("x")),
        get("http://a.test/", None),
      ] {
      answers.push(fetch(h.client, request))
    }
    // No User-Agent matches only a connection used without one.
    assert_eq(answers, ["1", "2", "1", "2", "3", "4"])
    assert_eq(h.client.idle_connections(), 4)
    h.finish()
    for server in servers {
      ignore(server.wait())
    }
  })
  assert_eq(h.dialer.dialed, [
    ("a.test", 80),
    ("a.test", 80),
    ("a.test", 443),
    ("a.test", 80),
  ])
}

///|
test "an idle connection expires after idle_max_ms" {
  let h = Harness::new(config={
    ..@h1client.ClientConfig::default(),
    idle_max_ms: 100,
  })
  let first = h.peer()
  let second = h.peer()
  h.run(() => {
    let servers = [serving(h, first, "1"), serving(h, second, "2")]
    let request = @http.Request::get("http://example.test/")
    assert_eq(fetch(h.client, request), "1")
    h.driver.sleep(99)
    assert_eq(fetch(h.client, request), "1")
    h.driver.sleep(100)
    assert_eq(fetch(h.client, request), "2")
    assert_eq(h.client.idle_connections(), 1)
    h.finish()
    for server in servers {
      ignore(server.wait())
    }
  })
  assert_eq(h.dialer.dialed.length(), 2)
}

///|
/// Opens `count` exchanges at once (one connection each, all to `url` but
/// the origins in `urls`), then finishes them all, and returns how many
/// connections stayed parked and how many were closed.
fn park_many(
  config : @h1client.ClientConfig,
  urls : Array[String],
) -> (Int32, Int32) raise {
  let h = Harness::new(config~)
  for _ in urls {
    ignore(h.scripted([Chunk(ok("x"))]))
  }
  let mut parked = 0
  h.run(() => {
    let responses = []
    for url in urls {
      responses.push(h.client.send(@http.Request::get(url), exchange()))
    }
    for response in responses {
      ignore(body_of(response))
    }
    parked = h.client.idle_connections()
    h.finish()
  })
  assert_eq(h.dialer.dialed.length(), urls.length())
  (parked, urls.length() - parked)
}

///|
test "the idle pool keeps at most the per-origin and total caps" {
  let default = @h1client.ClientConfig::default()
  // Four per origin by default: the fifth is closed.
  assert_eq(park_many(default, Array::make(5, "http://a.test/")), (4, 1))
  assert_eq(
    park_many({ ..default, max_idle_per_origin: 2, }, [
      "http://a.test/", "http://a.test/", "http://a.test/", "http://b.test/",
    ]),
    (3, 1),
  )
  // The total cap counts every origin.
  assert_eq(
    park_many({ ..default, max_idle_connections: 2, }, [
      "http://a.test/", "http://b.test/", "http://c.test/",
    ]),
    (2, 1),
  )
  // Zero disables reuse, whichever cap it is.
  assert_eq(
    park_many({ ..default, max_idle_connections: 0, }, ["http://a.test/"]),
    (0, 1),
  )
  assert_eq(
    park_many({ ..default, max_idle_per_origin: 0, }, ["http://a.test/"]),
    (0, 1),
  )
  assert_eq(
    park_many({ ..default, idle_max_ms: 0, }, ["http://a.test/"]),
    (0, 1),
  )
}

///|
test "the default idle pool parks 256 connections in total" {
  let urls = Array::makei(257, i => "http://h\{i}.test/")
  assert_eq(park_many(@h1client.ClientConfig::default(), urls), (256, 1))
}

///|
test "active connection caps queue requests until a slot frees" {
  let h = Harness::new(config={
    ..@h1client.ClientConfig::default(),
    max_connections: Some(1),
  })
  let peer = h.peer()
  h.run(() => {
    let server = serving(h, peer, "ok")
    let first = h.client.send(@http.Request::get("http://a.test/"), exchange())
    let mut answer = ""
    let queued = h.driver.spawn(() => {
      answer = fetch(h.client, @http.Request::get("http://a.test/"))
    })
    h.driver.pause()
    assert_true(queued.is_parked())
    assert_eq(h.dialer.dialed.length(), 1)
    // Reading the first body to its end frees the slot and parks the
    // connection, which the queued request then reuses.
    assert_eq(body_of(first), b"ok")
    ignore(queued.wait())
    assert_eq(answer, "ok")
    assert_eq(h.dialer.dialed.length(), 1)
    h.finish()
    ignore(server.wait())
  })
}

///|
test "per-origin caps queue only their own origin and caps below 1 count as 1" {
  let h = Harness::new(config={
    ..@h1client.ClientConfig::default(),
    max_connections_per_origin: Some(0),
  })
  let a = h.peer()
  ignore(h.scripted([Chunk(ok("b"))]))
  h.run(() => {
    let server = serving(h, a, "a")
    let held = h.client.send(@http.Request::get("http://a.test/"), exchange())
    let mut done = false
    let queued = h.driver.spawn(() => {
      ignore(fetch(h.client, @http.Request::get("http://a.test/")))
      done = true
    })
    // Another origin is not held up.
    assert_eq(fetch(h.client, @http.Request::get("http://b.test/")), "b")
    h.driver.pause()
    assert_false(done)
    assert_true(queued.is_parked())
    assert_eq(body_of(held), b"a")
    ignore(queued.wait())
    assert_true(done)
    h.finish()
    ignore(server.wait())
  })
  assert_eq(h.dialer.dialed, [("a.test", 80), ("b.test", 80)])
}

///|
test "a queued request leaves no slot behind on timeout, close or cancellation" {
  for mode in 0..<3 {
    let h = Harness::new(config={
      ..@h1client.ClientConfig::default(),
      max_connections: Some(1),
      pool_timeout_ms: Some(50),
    })
    let peer = h.peer()
    h.run(() => {
      let server = serving(h, peer, "held")
      let held = h.client.send(@http.Request::get("http://a.test/"), exchange())
      let mut outcome = None
      let queued = h.driver.spawn(() => {
        outcome = Some(
          failing(() => {
            ignore(fetch(h.client, @http.Request::get("http://a.test/")))
          }),
        )
      })
      h.driver.pause()
      match mode {
        0 => h.driver.sleep(50)
        1 => h.client.close()
        _ => queued.cancel()
      }
      ignore(queued.wait())
      assert_eq(
        outcome,
        match mode {
          0 => Some((Timeout(ms=50), Pool))
          1 => Some((Closed, Pool))
          _ => None
        },
      )
      assert_eq(body_of(held), b"held")
      if mode != 1 {
        // The slot is free again: the next request reuses the connection.
        assert_eq(fetch(h.client, @http.Request::get("http://a.test/")), "held")
      }
      h.finish()
      ignore(server.wait())
    })
    assert_eq(h.dialer.dialed.length(), 1)
  }
}

///|
test "closing the client while a slot is granted prevents a new dial" {
  let h = Harness::new(config={
    ..@h1client.ClientConfig::default(),
    max_connections: Some(1),
  })
  ignore(h.scripted([Chunk(ok("held"))]))
  h.run(() => {
    let held = h.client.send(@http.Request::get("http://a.test/"), exchange())
    let mut outcome = None
    let queued = h.driver.spawn(() => {
      outcome = Some(
        failing(() => {
          ignore(fetch(h.client, @http.Request::get("http://b.test/")))
        }),
      )
    })
    h.driver.pause()
    // Freeing the slot grants it to the queued request; closing before
    // that request runs again must keep it from dialling.
    held.close()
    h.client.close()
    ignore(queued.wait())
    assert_eq(outcome, Some((Closed, Pool)))
    h.finish()
  })
  assert_eq(h.dialer.dialed, [("a.test", 80)])
}
