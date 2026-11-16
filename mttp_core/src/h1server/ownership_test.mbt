///|
test "cancelling a connection unwinds its handler and closes the request body" {
  let h = Harness::new()
  let cleaned = Ref(false)
  let bodies : Array[@mttp_core.StreamBody] = []
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
      @mttp_core.Response::new(200)
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
    @mttp_core.TransportError(kind=Unreplayable, ..) => true
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
      @mttp_core.Response::new(
        200,
        body=Stream(
          @mttp_core.StreamBody::new(Stall::{
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
test "response completion follows the final wire write including the last stream chunk" {
  @sim.explore(schedule => {
    for streamed in [false, true] {
      let h = Harness::new(schedule~)
      let pieces = Pieces::new([b"first"])
      let conn = BodyWriteStop::{
        reads: @sim.ScriptedConn::new([
          Chunk(
            @mttp_core.encode_utf8(get("/", fields="Connection: close\r\n")),
          ),
        ]),
        stuck: h.coordination.signal(),
        entered: h.coordination.signal(),
        sizes: [],
        completed: Ref(0),
        premature: false,
        closed: false,
      }
      h.run(() => {
        let task = h.serve_on(
          conn,
          _ => {
            @mttp_core.Response::new(
              200,
              body=if streamed {
                Stream(@mttp_core.StreamBody::new(pieces))
              } else {
                Bytes(Bytes::make(2 * 65536, b'x'))
              },
            )
          },
          on_response_complete=() => conn.completed.val += 1,
        )
        conn.entered.wait()
        assert_eq(conn.completed.val, 0)
        if streamed {
          // EOF has closed the producer, but the final chunk is still blocked.
          assert_eq(pieces.closes, 1)
          assert_eq(conn.sizes[2], 5)
        }
        conn.stuck.notify()
        ignore(task.wait())
        assert_eq(conn.completed.val, 1)
      })
      assert_true(conn.closed)
      assert_false(conn.premature)
      assert_eq(h.errors.length(), 0)
    }
  })
}

///|
test "response completion covers bodiless replies and failures before the head once" {
  for
    (meth, status, body) in [
      ("GET", 200, @mttp_core.Body::Empty),
      ("GET", 200, Bytes(b"")),
      ("HEAD", 200, Bytes(b"hidden")),
      ("GET", 204, Bytes(b"hidden")),
      ("GET", 304, Bytes(b"hidden")),
      ("GET", 199, Bytes(b"invalid")),
    ] {
    let h = Harness::new()
    let conn = @sim.ScriptedConn::new([
      Chunk(
        @mttp_core.encode_utf8(
          "\{meth} / HTTP/1.1\r\nHost: h\r\nConnection: close\r\n\r\n",
        ),
      ),
    ])
    let completed = Ref(0)
    h.run(() => {
      ignore(
        h
        .serve_on(conn, _ => @mttp_core.Response::new(status, body~), on_response_complete=() => {
          completed.val += 1
        })
        .wait(),
      )
    })
    assert_eq(completed.val, 1)
    assert_eq(conn.written().length(), 1)
    assert_true(
      conn.written()[0].has_prefix(
        @mttp_core.encode_utf8(
          "HTTP/1.1 \{if status == 199 { 500 } else { status }} ",
        ),
      ),
    )
  }
}

///|
test "response completion waits for unread request draining before keep alive" {
  @sim.explore(schedule => {
    let h = Harness::new(schedule~)
    let completed = Ref(0)
    h.run(() => {
      let (client, server) = @sim.pair(h.coordination)
      let task = h.serve_on(server, reply("ok"), on_response_complete=() => {
        completed.val += 1
      })
      let client = Client::{ conn: client, pending: b"", }
      client.send("POST / HTTP/1.1\r\nHost: h\r\nContent-Length: 3\r\n\r\n")
      assert_eq(client.expect().text(), "ok")
      h.driver.sleep(1)
      assert_eq(completed.val, 0)
      client.send("abc" + get("/next", fields="Connection: close\r\n"))
      assert_eq(client.expect().text(), "ok")
      ignore(task.wait())
      assert_eq(completed.val, 2)
      assert_eq(client.rest(), "")
      client.conn.close()
      assert_eq(server.closes(), 1)
    })
    assert_eq(h.errors.length(), 0)
  })
}

///|
test "a successful upgrade retains ownership without HTTP response completion" {
  let h = Harness::new()
  let completed = Ref(0)
  let entered = Ref(false)
  let observed = Ref(-1)
  let conn = @sim.ScriptedConn::new([
    Chunk(
      b"GET / HTTP/1.1\r\nHost: h\r\nConnection: upgrade\r\nUpgrade: test\r\n\r\n",
    ),
  ])
  h.run(() => {
    ignore(
      h
      .serve_on(
        conn,
        _ => {
          let response = @mttp_core.Response::new(
            101,
            headers=@mttp_core.Headers::of([
              ("connection", "upgrade"),
              ("upgrade", "test"),
            ]),
          )
          {
            ..response,
            attributes: response.attributes.put(@rt.upgrade, (_, _, _) => {
              entered.val = true
              observed.val = completed.val
              h.driver.sleep(10)
            }),
          }
        },
        on_response_complete=() => completed.val += 1,
      )
      .wait(),
    )
  })
  assert_true(entered.val)
  assert_eq(observed.val, 0)
  assert_eq(completed.val, 0)
  assert_eq(conn.closes(), 1)
  assert_eq(h.errors.length(), 0)
}

///|
test "a head read failure is reported in phase Head without an answer" {
  let h = Harness::new()
  let conn = @sim.ScriptedConn::new([
    Failure(
      @mttp_core.TransportError(kind=Network, phase=Unknown, detail="reset"),
    ),
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
        @mttp_core.Response::new(200)
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
