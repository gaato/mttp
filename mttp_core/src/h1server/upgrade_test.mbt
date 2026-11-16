///|
fn switching(
  callback : async (&@rt.Conn, Bytes, () -> Bool) -> Unit noraise,
) -> @mttp_core.Response {
  let response = @mttp_core.Response::new(
    101,
    headers=@mttp_core.Headers::of([
      ("upgrade", "websocket"),
      ("connection", "Upgrade"),
    ]),
  )
  { ..response, attributes: response.attributes.put(@rt.upgrade, callback), }
}

///|
test "101 requires both request upgrade and response handover" {
  for asked in [false, true] {
    for offered in [false, true] {
      let h = Harness::new()
      let called = Ref(false)
      let out = h.exchange(
        @mttp_core.encode_utf8(
          get(
            "/",
            fields=if asked {
              "Connection: Upgrade\r\nUpgrade: websocket\r\n"
            } else {
              ""
            },
          ),
        ),
        _ => {
          if offered {
            switching((_, _, _) => called.val = true)
          } else {
            @mttp_core.Response::new(101)
          }
        },
      )
      assert_eq(called.val, asked && offered)
      assert_true(
        out.has_prefix(
          if asked && offered {
            "HTTP/1.1 101 "
          } else {
            "HTTP/1.1 500 "
          },
        ),
      )
      if asked && offered {
        assert_false(out.to_lower().contains("content-length"))
        assert_false(out.to_lower().contains("transfer-encoding"))
      }
    }
  }
  for
    request in [
      get("/", fields="Upgrade: websocket\r\n"),
      get("/", fields="Connection: Upgrade\r\n"),
      get("/", fields="Upgrade: websocket\r\nConnection: upgraded\r\n"),
      "GET / HTTP/1.0\r\nHost: example.test\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n",
    ] {
    let h = Harness::new()
    let called = Ref(false)
    let out = h.exchange(@mttp_core.encode_utf8(request), _ => {
      switching((_, _, _) => called.val = true)
    })
    assert_true(out.has_prefix("HTTP/1.1 500 "))
    assert_false(called.val)
  }
}

///|
test "invalid upgrade response fields become 500 and never call handover" {
  for invalid_head in [false, true] {
    let h = Harness::new()
    let called = Ref(false)
    let out = h.exchange(
      @mttp_core.encode_utf8(
        get(
          "/",
          fields=if invalid_head {
            "Connection: Upgrade\r\nUpgrade: websocket\r\n"
          } else {
            "Connection: Upgrade\r\nUpgrade: \r\n"
          },
        ),
      ),
      _ => {
        let response = switching((_, _, _) => called.val = true)
        if invalid_head {
          {
            ..response,
            headers: response.headers.set("x-invalid", " leading"),
          }
        } else {
          response
        }
      },
    )
    assert_true(out.has_prefix("HTTP/1.1 500 "))
    assert_false(called.val)
  }
  for supplied_date in [false, true] {
    let h = Harness::new()
    h.run(() => {
      let (client, task) = h.serve(
        _ => {
          let response = switching((_, _, _) => ())
          if supplied_date {
            {
              ..response,
              headers: response.headers.set(
                "date", "Sun, 15 Nov 2026 00:00:00 GMT",
              ),
            }
          } else {
            response
          }
        },
        auto_date=false,
      )
      client.send(
        get("/", fields="Connection: Upgrade\r\nUpgrade: websocket\r\n"),
      )
      let response = client.expect()
      assert_eq(response.status, 101)
      assert_eq(response.headers.contains("date"), supplied_date)
      ignore(task.wait())
      client.conn.close()
    })
  }
}

///|
test "upgrade refuses body before handler including chunked and Expect" {
  for
    fields in [
      "Content-Length: 1\r\n", "Transfer-Encoding: chunked\r\n", "Content-Length: 1\r\nExpect: 100-continue\r\n",
    ] {
    let h = Harness::new()
    let called = Ref(false)
    let out = h.exchange(
      @mttp_core.encode_utf8(
        get(
          "/",
          fields="Upgrade: websocket\r\nConnection: Upgrade\r\n" + fields,
        ),
      ),
      _ => {
        called.val = true
        @mttp_core.Response::new(200)
      },
    )
    assert_true(out.has_prefix("HTTP/1.1 400 "))
    assert_false(called.val)
  }
}

///|
test "handover preserves pending bytes and joins the HTTP reader before callback" {
  @sim.explore(schedule => {
    let h = Harness::new(schedule~)
    let payload = b"\x00\xff\x81\x80\x00\x01\x02\x03"
    h.run(() => {
      let (client, server) = @sim.pair(h.coordination)
      let recording = Recording::new(server)
      let got = Ref(b"")
      let task = h.serve_on(recording, _ => {
        switching((conn, pending, _) => {
          let out = Buffer()
          out.write_bytes(pending)
          while out.length() < payload.length() {
            let next = conn.read(max_len=1024) catch { _ => None }
            match next {
              Some(bytes) => out.write_bytes(bytes)
              None => break
            }
          }
          got.val = out.to_bytes()
        })
      })
      client.write(
        @mttp_core.encode_utf8(
          get("/", fields="Connection: Upgrade\r\nUpgrade: websocket\r\n"),
        ) +
        payload,
      )
      ignore(task.wait())
      assert_eq(got.val, payload)
      assert_true(recording.max_readers <= 1)
      client.close()
    })
  })
}

///|
test "HTTP handler header and body deadlines end at handover" {
  let h = Harness::new()
  h.run(() => {
    let (client, task) = h.serve(
      _ => switching((_, _, _) => h.clock.sleep(101)),
      limits={
        ..@h1server.ServerLimits::default(),
        handler_timeout_ms: Some(10),
        header_timeout_ms: 10,
        body_timeout_ms: 10,
      },
    )
    client.send(
      get("/", fields="Connection: Upgrade\r\nUpgrade: websocket\r\n"),
    )
    assert_eq(client.expect().status, 101)
    h.driver.sleep(100)
    assert_false(task.is_finished())
    ignore(task.wait())
    assert_eq(h.clock.now_unix_ms(), 101L)
    assert_true(h.errors.is_empty())
    client.conn.close()
  })
}

///|
test "shutdown sends GoingAway and waits exactly the session close bound" {
  let h = Harness::new()
  let stopping = Ref(false)
  h.run(() => {
    let (client, server) = @sim.pair(h.coordination)
    let limits = { ..@ws.WsLimits::default(), close_timeout_ms: 20, }
    let task = h.serve_on(
      server,
      _ => {
        switching((conn, pending, probe) => {
          let session = @ws.session_over_conn(
            conn,
            role=Server,
            pending~,
            clock=h.clock,
            timer=h.timer,
            coordination=h.coordination,
            entropy=_ => None,
            limits~,
          )
          @ws.serve_session(
            session,
            _ => h.clock.sleep(10000),
            stopping=probe,
            clock=h.clock,
            coordination=h.coordination,
          )
        })
      },
      stopping=() => stopping.val,
    )
    let client = Client::{ conn: client, pending: b"", }
    client.send(
      get("/", fields="Connection: Upgrade\r\nUpgrade: websocket\r\n"),
    )
    assert_eq(client.expect().status, 101)
    h.driver.sleep(1)
    stopping.val = true
    let bytes = client.conn.read(max_len=1024).unwrap()
    assert_eq(bytes, b"\x88\x02\x03\xe9")
    assert_eq(h.clock.now_unix_ms(), 250L)
    h.driver.sleep(19)
    assert_false(task.is_finished())
    ignore(task.wait())
    assert_eq(h.clock.now_unix_ms(), 270L)
    client.conn.close()
  })
}
