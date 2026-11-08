///|
test "a read failure while the handler runs cancels it and closes the connection" {
  let h = Harness::new()
  let reset = h.coordination.signal()
  let conn = @sim.ScriptedConn::new([
    Chunk(@http.encode_utf8(get("/"))),
    Wait(reset),
    Failure(@http.TransportError(kind=Network, phase=Unknown, detail="reset")),
  ])
  let entered = Ref(false)
  let cleaned = Ref(false)
  let finished = Ref(false)
  h.run(() => {
    let task = h.serve_on(conn, _ => {
      defer {
        cleaned.val = true
      }
      entered.val = true
      h.driver.sleep(1000)
      finished.val = true
      @http.Response::new(200)
    })
    h.driver.sleep(10)
    assert_true(entered.val)
    reset.notify()
    ignore(task.wait())
    assert_eq(h.driver.now(), 10L)
  })
  assert_true(cleaned.val)
  assert_false(finished.val)
  assert_eq(conn.closes(), 1)
  assert_eq(conn.written(), [])
  assert_eq(h.errors.map(kind_phase), [(Network, Unknown)])
}

///|
test "a read failure in a body the handler reads fails that read" {
  let h = Harness::new()
  let conn = @sim.ScriptedConn::new([
    Chunk(
      @http.encode_utf8(
        "POST / HTTP/1.1\r\nHost: example.test\r\nContent-Length: 10\r\n\r\nab",
      ),
    ),
    Failure(@http.TransportError(kind=Network, phase=Unknown, detail="reset")),
  ])
  let seen = []
  h.run(() => {
    let task = h.serve_on(conn, request => {
      let body = body_of(request) catch {
        error => {
          seen.push(kind_phase(error))
          b""
        }
      }
      @http.Response::new(200, body=Bytes(body))
    })
    ignore(task.wait())
  })
  assert_eq(seen, [(Network, Body)])
  assert_eq(conn.closes(), 1)
}

///|
test "peer EOF keeps a delayed and streamed response" {
  let h = Harness::new()
  h.run(() => {
    let (client, task) = h.serve(
      request => {
        let body = body_of(request) catch {
          _ => return @http.Response::new(400)
        }
        // Suspend so that the peer monitor sees EOF before the response.
        h.driver.sleep(20)
        @http.Response::new(
          200,
          body=Stream(@http.StreamBody::new(Pieces::new([body, b"!"]))),
        )
      },
      chunk_bytes=2,
    )
    client.send(post("/", "half-closed"))
    client.conn.shutdown_write()
    let out = client.rest()
    assert_true(out.has_prefix("HTTP/1.1 200 "))
    assert_true(out.contains("half-closed\r\n1\r\n!\r\n0\r\n\r\n"))
    ignore(task.wait())
    client.conn.close()
  })
  assert_eq(h.errors.length(), 0)
}

///|
test "a peer that went away leaves the write failure reported" {
  let h = Harness::new()
  h.run(() => {
    let (client, task) = h.serve(_ => {
      h.driver.sleep(20)
      @http.Response::new(200, body=Bytes(b"too late"))
    })
    client.send(get("/"))
    h.driver.sleep(5)
    client.conn.close()
    ignore(task.wait())
  })
  assert_eq(h.errors.map(kind_phase), [(Network, Write)])
}

///|
test "head and body truncation are reported even when no answer arrives" {
  for
    wire in [
      "GET / HTTP/1.1\r\nHost:", "POST / HTTP/1.1\r\nHost: example.test\r\nContent-Length: 3\r\n\r\nx",
    ] {
    let h = Harness::new()
    h.run(() => {
      let (client, task) = h.serve(echo())
      client.send(wire)
      client.conn.close()
      ignore(task.wait())
    })
    assert_true(h.errors.length() >= 1)
    assert_eq(kind_phase(h.errors[0]).0, Protocol)
  }
}
