///|
/// How a parked connection's peer went: a clean EOF, or a TLS session
/// closed without close_notify, which a reused connection treats the same.
let gone : Array[(String, @sim.ReadStep)] = [
  ("EOF", Eof),
  ("incomplete close", incomplete_close()),
]

///|
/// Parks `count` connections for `http://example.test` whose peers have gone:
/// each answered one request and then reached `tail` (EOF by default).
/// Returns them, oldest first.
async fn park_stale(
  h : Harness,
  count : Int32,
  tail~ : @sim.ReadStep = Eof,
) -> Array[@sim.ScriptedConn] {
  let conns = Array::makei(count, _ => h.scripted([Chunk(ok("old")), tail]))
  let responses = []
  for _ in 0..<count {
    responses.push(
      h.client.send(@mttp_core.Request::get("http://example.test/"), exchange()),
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
  for end in gone {
    let (label, tail) = end
    let h = Harness::new()
    h.run(() => {
      let stale = park_stale(h, 2, tail~)
      let fresh = h.peer()
      let server = h.driver.spawn(() => {
        let seen = fresh.serve(ok("new"))
        assert_eq(seen.length(), 2)
        assert_true(seen[0].raw.has_prefix(b"GET /?a=1 HTTP/1.1\r\n"))
      })
      let response = h.client.send(
        @mttp_core.Request::get("http://example.test/?a=1#fragment"),
        exchange(),
      )
      assert_eq(
        response.attributes.get(@h1client.stale_resend),
        Some(true),
        msg=label,
      )
      assert_eq(body_of(response), b"new")
      // The other connection parked as long was closed unused, not tried.
      assert_eq(stale.map(conn => conn.closes()), [1, 1])
      assert_eq(stale[0].written().length(), 1)
      assert_eq(stale[1].written().length(), 2)
      assert_eq(h.client.idle_connections(), 1)
      let again = h.client.send(
        @mttp_core.Request::get("http://example.test/"),
        exchange(),
      )
      assert_eq(again.attributes.get(@h1client.stale_resend), None)
      assert_eq(body_of(again), b"new")
      h.finish()
      ignore(server.wait())
    })
    assert_eq(h.dialer.dialed.length(), 3, msg=label)
  }
}

///|
test "only replayable idempotent requests are resent after a stale connection" {
  let rows : Array[(String, @mttp_core.Request, Bool)] = [
    ("GET", @mttp_core.Request::get("http://example.test/"), true),
    ("DELETE", @mttp_core.Request::delete("http://example.test/"), true),
    (
      "POST",
      @mttp_core.Request::post("http://example.test/").body_bytes(b"x"),
      false,
    ),
    (
      "POST marked replay_safe",
      @mttp_core.Request::post("http://example.test/")
      .body_bytes(b"x")
      .attribute(@mttp_core.replay_safe, true),
      true,
    ),
  ]
  for end in gone {
    let (how, tail) = end
    for row in rows {
      let (name, request, resent) = row
      let label = "\{name} after \{how}"
      let h = Harness::new()
      h.run(() => {
        ignore(park_stale(h, 1, tail~))
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
  }
  // A stream body is never resent, even on an idempotent method.
  let h = Harness::new()
  h.run(() => {
    ignore(park_stale(h, 1))
    let feed = @sim.Feed::bytes(h.driver, [b"x"])
    let request = @mttp_core.Request::put("http://example.test/").body_stream(
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
      fetch(h.client, @mttp_core.Request::get("http://example.test/")),
      "first",
    )
    assert_eq(
      failing(() => {
        ignore(fetch(h.client, @mttp_core.Request::get("http://example.test/")))
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
        ignore(fetch(h.client, @mttp_core.Request::get("http://example.test/")))
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
        ignore(fetch(h.client, @mttp_core.Request::get("http://example.test/")))
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
  for end in gone {
    let (label, tail) = end
    for meth in [@mttp_core.Method::Get, Post] {
      let h = Harness::new()
      h.run(() => {
        let stale = park_stale(h, 1, tail~)
        h.driver.sleep(1000)
        let fresh = h.peer()
        let server = h.driver.spawn(() => {
          let seen = fresh.serve(ok("new"))
          assert_eq(seen.length(), 1)
        })
        let request = @mttp_core.Request::new(meth, "http://example.test/")
        let request = if meth is Post {
          request.body_bytes(b"x")
        } else {
          request
        }
        let response = h.client.send(request, exchange())
        // Not a resend: the request went out once, on the fresh connection.
        assert_eq(
          response.attributes.get(@h1client.stale_resend),
          None,
          msg=label,
        )
        assert_eq(body_of(response), b"new")
        assert_eq(stale[0].written().length(), 1)
        assert_eq(stale[0].closes(), 1)
        h.finish()
        ignore(server.wait())
      })
      assert_eq(h.dialer.dialed.length(), 2, msg=label)
    }
  }
}

///|
test "a parked connection the server wrote to or that failed is not reused" {
  let reset = @mttp_core.TransportError(
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
        fetch(h.client, @mttp_core.Request::get("http://example.test/")),
        "old",
      )
      h.driver.sleep(1000)
      ignore(h.scripted([Chunk(ok("new"))]))
      let post = @mttp_core.Request::post("http://example.test/").body_bytes(
        b"x",
      )
      assert_eq(fetch(h.client, post), "new")
      assert_eq(idle.written().length(), 1)
      h.finish()
    })
    assert_eq(h.dialer.dialed.length(), 2)
  }
}

///|
/// The probe suspends while the connection is out of the pool: a send
/// cancelled there must still close it, or neither the pool nor
/// `Client::close` would ever reach it again.
test "a send cancelled during the check closes the connection it took" {
  let h = Harness::new()
  let idle = h.scripted([Chunk(ok("old")), Wait(h.coordination.signal())])
  h.run(() => {
    assert_eq(
      fetch(h.client, @mttp_core.Request::get("http://example.test/")),
      "old",
    )
    h.driver.sleep(1000)
    let send = h.driver.spawn(() => {
      ignore(fetch(h.client, @mttp_core.Request::get("http://example.test/")))
    })
    // The send took the connection and waits in the check's read.
    h.driver.pause()
    assert_true(send.is_parked())
    assert_eq(h.client.idle_connections(), 0)
    h.driver.cancel_and_join([send])
    assert_eq(idle.closes(), 1)
    h.finish()
  })
  assert_eq(h.dialer.dialed.length(), 1)
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
      @mttp_core.Request::post("http://example.test/").body_bytes(b"x")
    }
    assert_eq(fetch(h.client, post()), "same")
    // Reused at once: no check, no time spent.
    let start = h.driver.now()
    assert_eq(fetch(h.client, post()), "same")
    assert_eq(h.driver.now(), start)
    // Reused after a pause: the check waits its 2 ms, finds nothing to read
    // and leaves the connection usable.
    h.driver.sleep(1000)
    let start = h.driver.now()
    assert_eq(fetch(h.client, post()), "same")
    assert_eq(h.driver.now() - start, 2L)
    h.finish()
    ignore(server.wait())
  })
  assert_eq(h.dialer.dialed.length(), 1)
}

///|
/// A connection that reads its script and accepts `open_writes` writes;
/// later writes raise `Closed` and send nothing, as a TLS session the peer
/// shut down refuses them.
priv struct RefusingConn {
  inner : @sim.ScriptedConn
  mut open_writes : Int32
  writes : Array[Bytes]
}

///|
impl @rt.Conn for RefusingConn with fn read(self, max_len~) {
  self.inner.read(max_len~)
}

///|
impl @rt.Conn for RefusingConn with fn write(self, bytes) {
  if self.open_writes <= 0 {
    raise @mttp_core.TransportError(
      kind=Closed,
      phase=Unknown,
      detail="protocol is shutdown",
    )
  }
  self.open_writes -= 1
  self.writes.push(bytes)
}

///|
impl @rt.Conn for RefusingConn with fn close(self) {
  self.inner.close()
}

///|
/// Prepares a connection that answers one request and then refuses every
/// write after `open_writes` more.
fn Harness::refusing(self : Harness, open_writes~ : Int32) -> RefusingConn {
  let conn = RefusingConn::{
    inner: @sim.ScriptedConn::new([Chunk(ok("old"))]),
    open_writes: 1 + open_writes,
    writes: [],
  }
  self.dialer.queue.push(Hand(conn))
  self.closes.push(() => conn.inner.closes())
  conn
}

///|
/// The interop suite found this against nginx and Caddy over TLS under
/// load: the check's read was cut off by its deadline after it had taken
/// the server's close_notify, so the check passed, and the TLS session then
/// refused the POST before sending any of it. The failure was reported as
/// sent, so neither the engine nor the Client resent the POST. A first
/// write refused with nothing sent goes out on another connection, whatever
/// the method and however the request is written.
test "a reused connection that refuses the first write sends on another" {
  let rows : Array[(String, Bytes, Bool)] = [
    ("one write", b"x", false),
    ("concurrent upload", Bytes::make(70000, b'x'), false),
    ("Expect: 100-continue", b"x", true),
  ]
  for row in rows {
    let (label, payload, expect) = row
    let h = Harness::new()
    let refusing = h.refusing(open_writes=0)
    let fresh = h.peer()
    h.run(() => {
      let server = h.driver.spawn(() => {
        let seen = fresh.serve(ok("new"))
        assert_eq(seen.length(), 1, msg=label)
        assert_eq(seen[0].body, payload, msg=label)
      })
      assert_eq(
        fetch(h.client, @mttp_core.Request::get("http://example.test/")),
        "old",
      )
      // Reused at once, so no check runs: the refusal is the only sign.
      let post = @mttp_core.Request::post("http://example.test/").body_bytes(
        payload,
      )
      let post = if expect {
        post.header("expect", "100-continue")
      } else {
        post
      }
      let response = h.client.send(post, exchange())
      // Not a resend: nothing went out on the refused connection.
      assert_eq(
        response.attributes.get(@h1client.stale_resend),
        None,
        msg=label,
      )
      assert_eq(body_of(response), b"new", msg=label)
      assert_eq(refusing.writes.length(), 1, msg=label)
      assert_eq(refusing.inner.closes(), 1, msg=label)
      h.finish()
      ignore(server.wait())
    })
    assert_eq(h.dialer.dialed.length(), 2, msg=label)
  }
}

///|
/// A refusal after part of the request went out is a failure after
/// sending: the server may have the head, so a POST is not sent again.
test "a refusal after the first write is reported as sent" {
  let h = Harness::new()
  ignore(h.refusing(open_writes=1))
  h.run(() => {
    assert_eq(
      fetch(h.client, @mttp_core.Request::get("http://example.test/")),
      "old",
    )
    let post = @mttp_core.Request::post("http://example.test/").body_bytes(
      Bytes::make(70000, b'x'),
    )
    assert_eq(failing(() => ignore(fetch(h.client, post))), (Network, Write))
    h.finish()
  })
  assert_eq(h.dialer.dialed.length(), 1)
}
