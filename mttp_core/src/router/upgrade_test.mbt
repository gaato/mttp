///|
test "in-process upgrade runs the real codec and isolates other attributes" {
  let driver = @driver.Driver::new()
  let clock = @sim.SimClock::new(driver)
  let timer = @sim.SimTimer::new(driver)
  let coordination = @sim.SimCoordination::new(driver)
  let tasks : Array[@driver.Task] = []
  let private_key : @mttp_core.AttributeKey[String] = @mttp_core.AttributeKey::new(
    "secret",
  )
  let router = @router.Router::new(
    [],
    clock~,
    timer~,
    coordination~,
    background=work => tasks.push(driver.spawn(work)),
    options={
      ..@router.ServerOptions::default(),
      middleware: [
        (request, _) => {
          let offer = @handshake.check_client_request(request) catch {
            _ => return @mttp_core.Response::new(400)
          }
          let response = offer.accept() catch {
            _ => return @mttp_core.Response::new(500)
          }
          {
            ..response,
            attributes: response.attributes
            .put(private_key, "secret")
            .put(@rt.upgrade, (conn, pending, stopping) => {
              let session = @ws.session_over_conn(
                conn,
                role=Server,
                pending~,
                clock~,
                timer~,
                coordination~,
                entropy=_ => None,
              )
              @ws.serve_session(
                session,
                s => {
                  s.send(s.recv())
                  s.close({ code: Normal, reason: "", })
                },
                stopping~,
                clock~,
                coordination~,
              )
            }),
          }
        },
      ],
    },
  )
  driver.run(() => {
    let request = @handshake.client_request(
      "ws://in-process/ws",
      key="dGhlIHNhbXBsZSBub25jZQ==",
    )
    let response = router.send(request, @mttp_core.SendOptions::default())
    assert_eq(response.status, 101)
    assert_eq(response.attributes.get(private_key), None)
    assert_true(response.attributes.get(@rt.upgrade) is None)
    let session = response.attributes.get(@ws.ws_session).unwrap()
    session.send(Text("hello 世界")) catch {
      e => fail("send: \{Repr(e)}")
    }
    assert_eq(
      session.recv() catch {
        e => fail("recv: \{Repr(e)}")
      },
      Text("hello 世界"),
    )
    session.close({ code: Normal, reason: "", })
    for task in tasks {
      ignore(task.wait())
    }
  })
  router.close()
}

///|
test "in-process 101 refuses absent handover request upgrade or scheduling ports" {
  for kind in 0..<3 {
    let router = @router.Router::new([], options={
      ..@router.ServerOptions::default(),
      middleware: [
        (_, _) => {
          let response = @mttp_core.Response::new(101)
          if kind == 0 {
            response
          } else {
            {
              ..response,
              attributes: response.attributes.put(@rt.upgrade, (_, _, _) => ()),
            }
          }
        },
      ],
    })
    @driver.run_sync(() => {
      let request = if kind == 1 {
        @mttp_core.Request::get("/")
      } else {
        @handshake.client_request(
          "ws://in-process/",
          key="dGhlIHNhbXBsZSBub25jZQ==",
        )
      }
      let refused = try {
        ignore(router.send(request, @mttp_core.SendOptions::default()))
        false
      } catch {
        @mttp_core.TransportError(kind=Invalid, phase=Head, ..) => kind == 2
        @mttp_core.TransportError(kind=Protocol, phase=Head, ..) => kind != 2
        e => raise e
      }
      assert_true(refused)
    })
    router.close()
  }
}
