///|
test "known and unknown length uploads arrive with valid framing" {
  let payload = Bytes::makei(140000, i => (i % 251).to_byte())
  let pieces = [payload[:70000].to_owned(), payload[70000:].to_owned()]
  for mode in 0..<3 {
    let h = Harness::new()
    let peer = h.peer(chunk_bytes=4096)
    h.run(() => {
      let feed = @sim.Feed::bytes(h.driver, pieces)
      let request = @mttp_core.Request::post("http://example.test/up")
      let request = match mode {
        0 => request.body_bytes(payload)
        1 => request.body_stream(feed, length=140000L)
        _ => request.body_stream(feed)
      }
      let server = h.driver.spawn(() => {
        guard peer.request() is Some(received) else { fail("no request") }
        assert_eq(received.head.meth, Post)
        assert_eq(received.head.target, "/up")
        let head = @utf8.decode(received.raw)
        if mode == 2 {
          assert_true(head.contains("transfer-encoding: chunked"))
          assert_false(head.contains("content-length"))
        } else {
          assert_true(head.contains("content-length: 140000"))
        }
        assert_eq(received.body, payload)
        peer.respond(b"HTTP/1.1 204 No Content\r\n\r\n")
        ignore(peer.request())
      })
      let response = h.client.send(request, exchange())
      assert_eq(response.status, 204)
      // The whole request was written before the answer: reusable.
      assert_eq(h.client.idle_connections(), 1)
      assert_eq(feed.closes(), if mode == 0 { 0 } else { 1 })
      h.finish()
      ignore(server.wait())
    })
  }
}

///|
test "a chunked upload frames each piece and ends with the last chunk" {
  let h = Harness::new()
  let conn = h.scripted([Chunk(b"HTTP/1.1 204 No Content\r\n\r\n")])
  h.run(() => {
    let feed = @sim.Feed::bytes(h.driver, [b"ab", b"cde"])
    let request = @mttp_core.Request::post("http://example.test/").body_stream(
      feed,
    )
    h.client.send(request, exchange()).close()
    h.finish()
  })
  // The head goes out with the first piece.
  assert_eq(conn.written(), [
    b"POST / HTTP/1.1\r\ncontent-type: application/octet-stream\r\nhost: example.test\r\ntransfer-encoding: chunked\r\n\r\n2\r\nab\r\n",
    b"3\r\ncde\r\n", b"0\r\n\r\n",
  ])
}

///|
test "a stream body is validated by its first read before anything is sent" {
  for mode in 0..<3 {
    let h = Harness::new()
    let failing_feed = @sim.Feed::new(h.driver, [
      Fail(
        @mttp_core.TransportError(
          kind=Unreplayable,
          phase=Write,
          detail="nested body already taken",
        ),
      ),
    ])
    let lying = @sim.Feed::bytes(h.driver, [b"x"])
    let request = @mttp_core.Request::post("http://example.test/")
    let (request, source) = match mode {
      0 => (request.body_stream(lying, length=0L), lying)
      1 => (request.body_stream(failing_feed), failing_feed)
      _ => {
        let cell = @mttp_core.StreamBody::new(failing_feed)
        cell.take().close()
        ({ ..request, body: Stream(cell), }, failing_feed)
      }
    }
    h.run(() => {
      let outcome = failing(() => ignore(fetch(h.client, request)))
      assert_eq(
        outcome,
        match mode {
          0 => (Protocol, Body)
          1 => (Unreplayable, Write)
          _ => (Unreplayable, Pool)
        },
      )
      assert_eq(source.closes(), 1)
    })
    // Nothing was dialled, so nothing was sent.
    assert_eq(h.dialer.dialed, [])
  }
}

///|
test "empty known and unknown length streams are read exactly once" {
  for length in [Some(0L), None] {
    let h = Harness::new()
    let conn = h.scripted([Chunk(b"HTTP/1.1 204 No Content\r\n\r\n")])
    h.run(() => {
      let feed = @sim.Feed::bytes(h.driver, [])
      let request = @mttp_core.Request::post("http://example.test/").body_stream(
        feed,
        length?,
      )
      h.client.send(request, exchange()).close()
      assert_eq(feed.reads(), 1)
      assert_eq(feed.closes(), 1)
      assert_eq(h.client.idle_connections(), 1)
      h.finish()
    })
    let framing = if length is None {
      "transfer-encoding: chunked\r\n\r\n0\r\n\r\n"
    } else {
      "content-length: 0\r\n\r\n"
    }
    assert_eq(conn.written(), [
      @utf8.encode(
        "POST / HTTP/1.1\r\ncontent-type: application/octet-stream\r\nhost: example.test\r\n" +
        framing,
      ),
    ])
  }
}

///|
test "an early final response ends the upload and the connection is not reused" {
  let h = Harness::new()
  let peer = h.peer()
  h.run(() => {
    // The second piece never comes: only the answer can end the exchange.
    let feed = @sim.Feed::new(h.driver, [Chunk(b"x"), Wait(1000000)])
    let server = h.driver.spawn(() => {
      let decoder = @h1.HeadDecoder::new()
      while decoder.feed(peer.conn.read(max_len=65536).unwrap()).head is None {

      }
      peer.respond(ok("no!", status=413))
      // Keep the peer open: reuse must not depend on Connection: close.
      while peer.conn.read(max_len=65536) is Some(_) {

      }
    })
    let response = h.client.send(
      @mttp_core.Request::post("http://example.test/").body_stream(feed),
      exchange(),
    )
    assert_eq(response.status, 413)
    assert_eq(feed.cancellations(), 1)
    assert_eq(feed.closes(), 1)
    assert_eq(body_of(response), b"no!")
    assert_eq(h.client.idle_connections(), 0)
    assert_eq(h.driver.now(), 0L)
    h.finish()
    ignore(server.wait())
  })
}

///|
test "upload producer errors keep their kind and release the connection" {
  let h = Harness::new()
  let peer = h.peer()
  h.run(() => {
    let feed = @sim.Feed::new(h.driver, [
      Chunk(b"x"),
      Fail(
        @mttp_core.TransportError(
          kind=Unreplayable,
          phase=Write,
          detail="producer refused",
        ),
      ),
    ])
    let server = h.driver.spawn(() => {
      while peer.conn.read(max_len=65536) is Some(_) {

      }
    })
    assert_eq(
      failing(() => {
        ignore(
          fetch(
            h.client,
            @mttp_core.Request::post("http://example.test/").body_stream(feed),
          ),
        )
      }),
      (Unreplayable, Write),
    )
    assert_eq(feed.closes(), 1)
    assert_eq(h.client.idle_connections(), 0)
    h.finish()
    ignore(server.wait())
  })
}

///|
test "an answer sent before an upload's network failure is still delivered" {
  let big = Bytes::make(100000, b'x')
  let write_error = @mttp_core.TransportError(
    kind=Network,
    phase=Write,
    detail="connection reset",
  )
  for answered in [true, false] {
    let h = Harness::new()
    let steps : Array[@sim.ReadStep] = if answered {
      [Chunk(ok("too big", status=413))]
    } else {
      [Eof]
    }
    let conn = h.scripted(steps, write_error~)
    h.run(() => {
      let request = @mttp_core.Request::post("http://example.test/").body_bytes(
        big,
      )
      if answered {
        let response = h.client.send(request, exchange())
        assert_eq(response.status, 413)
        assert_eq(body_of(response), b"too big")
        // The request was not sent whole: the connection is not reused.
        assert_eq(h.client.idle_connections(), 0)
      } else {
        // Without an answer the write failure is the one reported.
        assert_eq(
          failing(() => ignore(h.client.send(request, exchange()))),
          (Network, Write),
        )
      }
      assert_eq(conn.closes(), 1)
      h.finish()
    })
  }
}

///|
test "a head deadline after a failed upload reports the write failure" {
  let h = Harness::new(config={
    ..@h1client.ClientConfig::default(),
    read_timeout_ms: Some(20),
  })
  ignore(
    h.scripted(
      [Wait(h.coordination.signal())],
      write_error=@mttp_core.TransportError(
        kind=Network,
        phase=Write,
        detail="upstream input failed",
      ),
    ),
  )
  h.run(() => {
    let request = @mttp_core.Request::post("http://example.test/").body_bytes(
      Bytes::make(100000, b'x'),
    )
    let detail = try {
      ignore(h.client.send(request, exchange()))
      ""
    } catch {
      @mttp_core.TransportError(kind=Network, phase=Write, detail~) => detail
      error => raise error
    }
    assert_eq(detail, "upstream input failed")
    assert_eq(h.driver.now(), 20L)
    h.finish()
  })
}

///|
test "the head limit starts once an upload has finished" {
  let h = Harness::new(config={
    ..@h1client.ClientConfig::default(),
    read_timeout_ms: Some(20),
  })
  let conn = h.scripted([Wait(h.coordination.signal())])
  h.run(() => {
    let feed = @sim.Feed::new(h.driver, [Chunk(b"a"), Wait(50), Chunk(b"b")])
    let request = @mttp_core.Request::post("http://example.test/").body_stream(
      feed,
    )
    assert_eq(
      failing(() => ignore(h.client.send(request, exchange()))),
      (Timeout(ms=20), Head),
    )
    // 50 ms of upload, then 20 ms waiting for the head.
    assert_eq(h.driver.now(), 70L)
    assert_eq(feed.closes(), 1)
    h.finish()
  })
  assert_eq(conn.written().length(), 3)
}

///|
/// A body stream that yields one piece, then fails with a network error
/// after `delay` ms, as a stream relaying another connection might.
fn relay(h : Harness, delay : Int32) -> @sim.Feed {
  @sim.Feed::new(h.driver, [
    Chunk(b"x"),
    Wait(delay),
    Fail(
      @mttp_core.TransportError(
        kind=Network,
        phase=Write,
        detail="upstream input failed",
      ),
    ),
  ])
}

///|
test "a stream failing mid-upload aborts the exchange at once with its own error" {
  // The server waits for the whole request and never answers an
  // incomplete one; without any deadline the send must still end. Also
  // when an answer would come after the stream failed, the stream's
  // failure is the outcome.
  for answer_after in [None, Some(20)] {
    let h = Harness::new()
    let peer = h.peer()
    h.run(() => {
      let feed = relay(h, 5)
      let server = h.driver.spawn(() => {
        let decoder = @h1.HeadDecoder::new()
        while decoder.feed(peer.conn.read(max_len=65536).unwrap()).head is None {

        }
        if answer_after is Some(ms) {
          h.driver.sleep(ms)
          peer.conn.write(ok("fine")) catch {
            _ => ()
          }
        }
        while (peer.conn.read(max_len=65536) catch { _ => None }) is Some(_) {

        }
      })
      let detail = try {
        ignore(
          h.client.send(
            @mttp_core.Request::post("http://example.test/").body_stream(feed),
            exchange(),
          ),
        )
        ""
      } catch {
        @mttp_core.TransportError(kind=Network, phase=Write, detail~) => detail
        error => raise error
      }
      assert_eq(detail, "upstream input failed")
      assert_eq(h.driver.now(), 5L)
      assert_eq(feed.closes(), 1)
      assert_eq(h.client.idle_connections(), 0)
      h.finish()
      ignore(server.wait())
    })
  }
}

///|
test "an answer before the stream fails ends the upload and wins" {
  let h = Harness::new()
  let peer = h.peer()
  h.run(() => {
    let feed = relay(h, 50)
    let server = h.driver.spawn(() => {
      let decoder = @h1.HeadDecoder::new()
      while decoder.feed(peer.conn.read(max_len=65536).unwrap()).head is None {

      }
      peer.respond(ok("no!", status=413))
      while (peer.conn.read(max_len=65536) catch { _ => None }) is Some(_) {

      }
    })
    let response = h.client.send(
      @mttp_core.Request::post("http://example.test/").body_stream(feed),
      exchange(),
    )
    assert_eq(response.status, 413)
    // The stream was cancelled before it could fail.
    assert_eq(feed.cancellations(), 1)
    assert_eq(feed.closes(), 1)
    assert_eq(body_of(response), b"no!")
    assert_eq(h.client.idle_connections(), 0)
    h.finish()
    ignore(server.wait())
  })
}
