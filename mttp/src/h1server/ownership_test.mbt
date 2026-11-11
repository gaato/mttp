///|
test "cancelling a connection unwinds its handler and closes the request body" {
  let h = Harness::new()
  let cleaned = Ref(false)
  let bodies : Array[@mttp.StreamBody] = []
  h.run(() => {
    let entered = h.coordination.signal()
    let (client, task) = h.serve(request => {
      defer {
        cleaned.val = true
      }
      if request.body is Stream(stream) {
        bodies.push(stream)
      }
      entered.notify()
      h.driver.sleep(10000)
      @mttp.Response::new(200)
    })
    client.send(post("/", "unread"))
    entered.wait()
    task.cancel()
    ignore(task.wait() catch { _ => false })
    assert_eq(client.rest(), "")
    client.conn.close()
  })
  assert_true(cleaned.val)
  assert_eq(bodies.length(), 1)
  let refused = try bodies[0].take() catch {
    @mttp.TransportError(kind=Unreplayable, ..) => true
    _ => false
  } noraise {
    _ => false
  }
  assert_true(refused)
  assert_eq(h.errors.length(), 0)
}

///|
test "cancellation while producing a response closes its stream" {
  let h = Harness::new()
  let closes = Ref(0)
  h.run(() => {
    let (client, task) = h.serve(_ => {
      @mttp.Response::new(
        200,
        body=Stream(
          @mttp.StreamBody::new(Stall::{
            driver: h.driver,
            closes,
            step: 0,
            closed: false,
          }),
        ),
      )
    })
    client.send(get("/"))
    h.driver.sleep(1)
    task.cancel()
    ignore(task.wait() catch { _ => false })
    assert_true(client.rest().has_suffix("5\r\nfirst\r\n"))
    client.conn.close()
  })
  assert_eq(closes.val, 1)
  assert_eq(h.errors.length(), 0)
}

///|
test "a head read failure is reported in phase Head without an answer" {
  let h = Harness::new()
  let conn = @sim.ScriptedConn::new([
    Failure(@mttp.TransportError(kind=Network, phase=Unknown, detail="reset")),
  ])
  h.run(() => ignore(h.serve_on(conn, reply("never")).wait()))
  assert_eq(h.errors.map(kind_phase), [(Network, Head)])
  assert_eq(conn.written(), [])
  assert_eq(conn.closes(), 1)
}

///|
test "an invalid fallback authority is refused before the handler" {
  let h = Harness::new()
  let conn = @sim.ScriptedConn::new([Chunk(b"GET / HTTP/1.0\r\n\r\n")])
  let called = Ref(false)
  h.run(() => {
    @h1server.serve_conn(
      conn,
      _ => {
        called.val = true
        @mttp.Response::new(200)
      },
      clock=h.clock,
      timer=h.timer,
      coordination=h.coordination,
      scheme="http",
      authority="example.test:invalid",
      on_error=error => h.errors.push(error),
    )
  })
  assert_false(called.val)
  assert_eq(h.errors.map(kind_phase), [(Protocol, Head)])
  assert_true(conn.written()[0].has_prefix(b"HTTP/1.1 400 "))
  assert_eq(conn.closes(), 1)
}
