///|
/// Parks `count` connections for `http://example.test` whose peers have gone:
/// each answered one request and then reached EOF. Returns them, oldest
/// first.
async fn park_stale(h : Harness, count : Int32) -> Array[@sim.ScriptedConn] {
  let conns = Array::makei(count, _ => h.scripted([Chunk(ok("old")), Eof]))
  let responses = []
  for _ in 0..<count {
    responses.push(
      h.client.send(@mttp.Request::get("http://example.test/"), exchange()),
    )
  }
  for response in responses {
    ignore(body_of(response))
  }
  assert_eq(h.client.idle_connections(), count)
  conns
}

///|
test "a stale parked connection is replaced once by a fresh one" {
  let h = Harness::new()
  h.run(() => {
    let stale = park_stale(h, 2)
    let fresh = h.peer()
    let server = h.driver.spawn(() => {
      let seen = fresh.serve(ok("new"))
      assert_eq(seen.length(), 2)
      assert_true(seen[0].raw.has_prefix(b"GET /?a=1 HTTP/1.1\r\n"))
    })
    let response = h.client.send(
      @mttp.Request::get("http://example.test/?a=1#fragment"),
      exchange(),
    )
    assert_eq(response.attributes.get(@h1client.stale_resend), Some(true))
    assert_eq(body_of(response), b"new")
    // The other connection parked as long was closed unused, not tried.
    assert_eq(stale.map(conn => conn.closes()), [1, 1])
    assert_eq(stale[0].written().length(), 1)
    assert_eq(stale[1].written().length(), 2)
    assert_eq(h.client.idle_connections(), 1)
    let again = h.client.send(
      @mttp.Request::get("http://example.test/"),
      exchange(),
    )
    assert_eq(again.attributes.get(@h1client.stale_resend), None)
    assert_eq(body_of(again), b"new")
    h.finish()
    ignore(server.wait())
  })
  assert_eq(h.dialer.dialed.length(), 3)
}

///|
test "only replayable idempotent requests are resent after a stale connection" {
  let rows : Array[(String, @mttp.Request, Bool)] = [
    ("GET", @mttp.Request::get("http://example.test/"), true),
    ("DELETE", @mttp.Request::delete("http://example.test/"), true),
    (
      "POST",
      @mttp.Request::post("http://example.test/").body_bytes(b"x"),
      false,
    ),
    (
      "POST marked replay_safe",
      @mttp.Request::post("http://example.test/")
      .body_bytes(b"x")
      .attribute(@mttp.replay_safe, true),
      true,
    ),
  ]
  for row in rows {
    let (label, request, resent) = row
    let h = Harness::new()
    h.run(() => {
      ignore(park_stale(h, 1))
      ignore(h.scripted([Chunk(ok("new"))]))
      let result = Ok(fetch(h.client, request)) catch {
        error => Err(kind_phase(error))
      }
      assert_eq(
        result,
        if resent {
          Ok("new")
        } else {
          Err((Network, Head))
        },
        msg=label,
      )
      h.finish()
    })
    assert_eq(h.dialer.dialed.length(), if resent { 2 } else { 1 }, msg=label)
  }
  // A stream body is never resent, even on an idempotent method.
  let h = Harness::new()
  h.run(() => {
    ignore(park_stale(h, 1))
    let feed = @sim.Feed::bytes(h.driver, [b"x"])
    let request = @mttp.Request::put("http://example.test/").body_stream(
      feed,
      length=1L,
    )
    assert_eq(failing(() => ignore(fetch(h.client, request))), (Network, Head))
    assert_eq(feed.closes(), 1)
    h.finish()
  })
  assert_eq(h.dialer.dialed.length(), 1)
}

///|
test "a failure after a response byte or on a fresh connection is not resent" {
  // The reused connection had started a response.
  let h = Harness::new()
  let partial = h.peer()
  h.run(() => {
    let server = h.driver.spawn(() => {
      ignore(partial.request())
      partial.respond(ok("first"))
      ignore(partial.request())
      partial.respond(b"HTTP/1.1 2")
      partial.conn.close()
    })
    assert_eq(
      fetch(h.client, @mttp.Request::get("http://example.test/")),
      "first",
    )
    assert_eq(
      failing(() => {
        ignore(fetch(h.client, @mttp.Request::get("http://example.test/")))
      }),
      (Network, Head),
    )
    h.finish()
    ignore(server.wait())
  })
  assert_eq(h.dialer.dialed.length(), 1)
  // A fresh connection that fails is the failure.
  let h = Harness::new()
  ignore(h.scripted([Eof]))
  h.run(() => {
    assert_eq(
      failing(() => {
        ignore(fetch(h.client, @mttp.Request::get("http://example.test/")))
      }),
      (Network, Head),
    )
    h.finish()
  })
  assert_eq(h.dialer.dialed.length(), 1)
  // The repair happens once: a second failure surfaces.
  let h = Harness::new()
  h.run(() => {
    ignore(park_stale(h, 1))
    ignore(h.scripted([Eof]))
    assert_eq(
      failing(() => {
        ignore(fetch(h.client, @mttp.Request::get("http://example.test/")))
      }),
      (Network, Head),
    )
    h.finish()
  })
  assert_eq(h.dialer.dialed.length(), 2)
}

///|
/// The interop suite found this against nginx, Caddy and Apache: a POST
/// sent a few seconds after the server closed the idle connection was
/// written to that connection and failed as sent, so neither the engine
/// nor the Client could resend it, though the server never saw it.
test "a connection the server closed while parked is not written to" {
  for meth in [@mttp.Method::Get, Post] {
    let h = Harness::new()
    h.run(() => {
      let stale = park_stale(h, 1)
      h.driver.sleep(1000)
      let fresh = h.peer()
      let server = h.driver.spawn(() => {
        let seen = fresh.serve(ok("new"))
        assert_eq(seen.length(), 1)
      })
      let request = @mttp.Request::new(meth, "http://example.test/")
      let request = if meth is Post {
        request.body_bytes(b"x")
      } else {
        request
      }
      let response = h.client.send(request, exchange())
      // Not a resend: the request went out once, on the fresh connection.
      assert_eq(response.attributes.get(@h1client.stale_resend), None)
      assert_eq(body_of(response), b"new")
      assert_eq(stale[0].written().length(), 1)
      assert_eq(stale[0].closes(), 1)
      h.finish()
      ignore(server.wait())
    })
    assert_eq(h.dialer.dialed.length(), 2)
  }
}

///|
test "a parked connection the server wrote to or that failed is not reused" {
  let reset = @mttp.TransportError(
    kind=Network,
    phase=Unknown,
    detail="connection reset",
  )
  for
    after in [
      // Without the check, this 408 was read as the answer to the POST.
      @sim.ReadStep::Chunk(
        b"HTTP/1.1 408 Request Timeout\r\ncontent-length: 0\r\n\r\n",
      ),
      Failure(reset),
    ] {
    let h = Harness::new()
    let idle = h.scripted([Chunk(ok("old")), after])
    h.run(() => {
      assert_eq(
        fetch(h.client, @mttp.Request::get("http://example.test/")),
        "old",
      )
      h.driver.sleep(1000)
      ignore(h.scripted([Chunk(ok("new"))]))
      let post = @mttp.Request::post("http://example.test/").body_bytes(b"x")
      assert_eq(fetch(h.client, post), "new")
      assert_eq(idle.written().length(), 1)
      h.finish()
    })
    assert_eq(h.dialer.dialed.length(), 2)
  }
}

///|
test "an open parked connection is checked only after it idled" {
  let h = Harness::new()
  let peer = h.peer()
  h.run(() => {
    let server = h.driver.spawn(() => {
      let seen = peer.serve(ok("same"))
      assert_eq(seen.length(), 3)
    })
    let post = () => {
      @mttp.Request::post("http://example.test/").body_bytes(b"x")
    }
    assert_eq(fetch(h.client, post()), "same")
    // Reused at once: no check, no time spent.
    let start = h.driver.now()
    assert_eq(fetch(h.client, post()), "same")
    assert_eq(h.driver.now(), start)
    // Reused after a pause: the check waits its millisecond, finds nothing
    // to read and leaves the connection usable.
    h.driver.sleep(1000)
    let start = h.driver.now()
    assert_eq(fetch(h.client, post()), "same")
    assert_eq(h.driver.now() - start, 1L)
    h.finish()
    ignore(server.wait())
  })
  assert_eq(h.dialer.dialed.length(), 1)
}
