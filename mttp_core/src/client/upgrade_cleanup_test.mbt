///|
priv struct LeakConn {
  closes : Ref[Int32]
  slots : Ref[Int32]
}

///|
impl @rt.Conn for LeakConn with fn read(_, max_len~) {
  ignore(max_len)
  None
}

///|
impl @rt.Conn for LeakConn with fn write(_, bytes) {
  ignore(bytes)
}

///|
impl @rt.Conn for LeakConn with fn close(self) {
  self.closes.val += 1
  self.slots.val = 0
}

///|
priv struct LeakUpgrade {
  conn : LeakConn
  mut taken : Bool
}

///|
impl @rt.Upgraded for LeakUpgrade with fn take_conn(self) {
  if self.taken {
    return None
  }
  self.taken = true
  Some((self.conn, b"pending"))
}

///|
fn leak_upgrade(
  status~ : Int32 = 101,
  headers~ : @mttp_core.Headers = @mttp_core.Headers::empty(),
) -> (LeakUpgrade, @mttp_core.Response) {
  let upgrade = LeakUpgrade::{
    conn: { closes: Ref(0), slots: Ref(1), },
    taken: false,
  }
  let response = @mttp_core.Response::new(status, headers~)
  (
    upgrade,
    { ..response, attributes: response.attributes.put(@rt.upgraded, upgrade), },
  )
}

///|
fn reclaimed(upgrade : LeakUpgrade) -> Unit raise {
  assert_eq(
    upgrade.conn.closes.val,
    1,
    msg="upgrade socket leaked or closed twice",
  )
  assert_eq(upgrade.conn.slots.val, 0, msg="upgrade slot leaked")
}

///|
fn decode_upgrade() -> @client.ResponseAs[Unit] {
  @client.ResponsePlan::new((_, _) => {
    raise @client.InvalidRequest(message="decoder failed")
  })
}

///|
test "retry disposes an unclaimed upgrade before starting its next attempt" {
  let (upgrade, response) = leak_upgrade(status=503)
  let seen_slots = []
  let c = @client.Client::new(
    @client.from_handler(_ => {
      seen_slots.push(upgrade.conn.slots.val)
      if seen_slots.length() == 1 {
        response
      } else {
        @mttp_core.Response::new(200)
      }
    }),
    @sim.FakeClock::new(),
    retry=@client.RetryPolicy::conservative().with_max_retries(1),
  )
  @driver.run_sync(() => assert_eq(c.send(@client.get("/")).status, 200))
  assert_eq(seen_slots, [1, 0])
  reclaimed(upgrade)
  c.close()
  reclaimed(upgrade)
}

///|
test "101 decoder failure reclaims the socket and slot before Client close" {
  let (upgrade, response) = leak_upgrade()
  let c = @client.Client::new(
    @client.from_handler(_ => response),
    @sim.FakeClock::new(),
  )
  @driver.run_sync(() => {
    try c.send(@client.get("/").response(decode_upgrade())) catch {
      @client.InvalidRequest(..) => ()
      _ => fail("wrong error")
    } noraise {
      _ => fail("decoder did not fail")
    }
  })
  reclaimed(upgrade)
  c.close()
  c.close()
  reclaimed(upgrade)
}

///|
test "101 cancellation during limiter release reclaims the socket and slot" {
  let d = @driver.Driver::new()
  let (upgrade, response) = leak_upgrade()
  let limiter = WaitingLimiter::{
    driver: d,
    gate: @sim.SimGate::new(d),
    releases: Ref(0),
  }
  let c = @client.Client::new(
    @client.from_handler(_ => response),
    @sim.SimClock::new(d),
    limiter~,
  )
  d.run(() => {
    let task = d.spawn(() => ignore(c.send(@client.get("/"))))
    d.pause()
    task.cancel()
    assert_false(task.wait())
  })
  reclaimed(upgrade)
  c.close()
  reclaimed(upgrade)
}

///|
test "101 limiter release failure reclaims the socket and slot" {
  let (upgrade, response) = leak_upgrade()
  let clock = @sim.FakeClock::new()
  let limiter = RecordingLimiter::{
    events: [],
    clock,
    delay: 0,
    fail_release: true,
  }
  let c = @client.Client::new(
    @client.from_handler(_ => response),
    clock,
    limiter~,
  )
  @driver.run_sync(() => {
    try c.send(@client.get("/")) catch {
      _ => ()
    } noraise {
      _ => fail("release passed")
    }
  })
  reclaimed(upgrade)
  c.close()
  reclaimed(upgrade)
}

///|
test "101 streaming decoder failure and cancellation reclaim the socket and slot" {
  for cancel in [false, true] {
    let d = @driver.Driver::new()
    let (upgrade, response) = leak_upgrade()
    let c = @client.Client::new(
      @client.from_handler(_ => response),
      @sim.SimClock::new(d),
    )
    d.run(() => {
      let reader : @client.StreamResponseAs[
        Result[Unit, @client.ResponseFailure],
      ] = @client.as_stream((_, _) => {
        if cancel {
          d.sleep(1000)
        }
        raise @client.InvalidRequest(message="stream decoder failed")
      }).any_status()
      let task = d.spawn(() => {
        try c.send(@client.get("/").response(reader)) catch {
          @client.InvalidRequest(..) => ()
          _ => fail("wrong error")
        } noraise {
          _ => fail("stream decoder passed")
        }
      })
      if cancel {
        d.pause()
        task.cancel()
        assert_false(task.wait())
      } else {
        assert_true(task.wait())
      }
    })
    reclaimed(upgrade)
    c.close()
    reclaimed(upgrade)
  }
}

///|
priv struct OuterReturnTimer {
  driver : @driver.Driver
  calls : Ref[Int32]
}

///|
impl @rt.Timer for OuterReturnTimer with fn within(self, _, callback) {
  self.calls.val += 1
  let outer = self.calls.val == 1
  callback()
  if outer {
    self.driver.sleep(1000)
  }
  true
}

///|
test "101 cancellation after an attempt or total timer callback reclaims the socket and slot" {
  for total in [false, true] {
    let d = @driver.Driver::new()
    let (upgrade, response) = leak_upgrade()
    let timer : &@rt.Timer = if total {
      OuterReturnTimer::{ driver: d, calls: Ref(0), } as &@rt.Timer
    } else {
      SlowReturnTimer::{ driver: d, } as &@rt.Timer
    }
    let c = @client.Client::new(
      @client.from_handler(_ => response),
      @sim.SimClock::new(d),
      timer~,
      timeout_ms?=if total { None } else { Some(2000) },
      total_ms?=if total { Some(2000) } else { None },
    )
    d.run(() => {
      let task = d.spawn(() => ignore(c.send(@client.get("/"))))
      d.pause()
      task.cancel()
      assert_false(task.wait())
    })
    reclaimed(upgrade)
    c.close()
    reclaimed(upgrade)
  }
}

///|
test "Client close reclaims returned unclaimed upgrades but leaves claimed ones alone" {
  for claim in [false, true] {
    let (upgrade, response) = leak_upgrade()
    let c = @client.Client::new(
      @client.from_handler(_ => response),
      @sim.FakeClock::new(),
      retry=@client.RetryPolicy::conservative(),
    )
    @driver.run_sync(() => {
      let reply = c.send(@client.get("/"), decide_retry=(_, _) => Wait(0))
      assert_eq(upgrade.conn.closes.val, 0)
      let conn = if claim {
        Some(reply.attributes.get(@rt.upgraded).unwrap().take_conn().unwrap().0)
      } else {
        None
      }
      c.close()
      c.close()
      if conn is Some(conn) {
        assert_eq(upgrade.conn.closes.val, 0)
        assert_eq(upgrade.conn.slots.val, 1)
        conn.close()
      }
      reclaimed(upgrade)
      assert_true(
        reply.attributes.get(@rt.upgraded).unwrap().take_conn() is None,
      )
    })
  }
}

///|
test "Client close while send is pending reclaims a later arriving 101" {
  let d = @driver.Driver::new()
  let (upgrade, response) = leak_upgrade()
  let c = @client.Client::new(
    @client.from_fn((_, _) => {
      d.sleep(1)
      response
    }),
    @sim.SimClock::new(d),
  )
  d.run(() => {
    let task = d.spawn(() => ignore(c.send(@client.get("/"))))
    d.pause()
    c.close()
    ignore(task.wait())
  })
  reclaimed(upgrade)
}

///|
test "redirect refusals and followed responses reclaim unclaimed upgrade sockets and slots" {
  for location in ["http://[bad", "/next"] {
    let (upgrade, response) = leak_upgrade(
      status=302,
      headers=@mttp_core.Headers::of([("location", location)]),
    )
    let calls = Ref(0)
    let backend = @client.FollowRedirects::new(
      @client.from_handler(_ => {
        calls.val += 1
        if calls.val == 1 {
          response
        } else {
          @mttp_core.Response::new(200)
        }
      }),
    )
    @driver.run_sync(() => {
      try
        backend.send(
          @mttp_core.Request::get("http://example.test/"),
          @mttp_core.SendOptions::default(),
        )
      catch {
        _ => ()
      } noraise {
        response => response.close()
      }
    })
    reclaimed(upgrade)
    backend.close()
    reclaimed(upgrade)
  }
}

///|
test "Cookies and redirects transfer a 101 without dropping or consuming its upgrade" {
  let (upgrade, response) = leak_upgrade(
    headers=@mttp_core.Headers::of([
      ("location", "/ignored"),
      ("set-cookie", "x=y"),
    ]),
  )
  let c = @client.Client::new(
    @client.from_handler(_ => response),
    @sim.FakeClock::new(),
    cookies=@cookie.CookieJar::new(@sim.FakeClock::new()),
  )
  @driver.run_sync(() => {
    let reply = c.send(@client.get("http://example.test/"))
    assert_eq(upgrade.conn.closes.val, 0)
    let (conn, _) = reply.attributes
      .get(@rt.upgraded)
      .unwrap()
      .take_conn()
      .unwrap()
    c.close()
    assert_eq(upgrade.conn.slots.val, 1)
    conn.close()
    reclaimed(upgrade)
  })
}

///|
priv struct CancelCookieClock {
  driver : @driver.Driver
  armed : Ref[Bool]
}

///|
impl @rt.Clock for CancelCookieClock with fn sleep(_, ms) {
  ignore(ms)
}

///|
impl @rt.Clock for CancelCookieClock with fn now_unix_ms(self) {
  if self.armed.val {
    let task = self.driver.current_task() catch { _ => abort("no cookie task") }
    task.cancel()
  }
  0L
}

///|
test "cancellation requested during cookie storage transfers ownership before delivery" {
  let d = @driver.Driver::new()
  let (upgrade, response) = leak_upgrade()
  let armed = Ref(false)
  let jar = @cookie.CookieJar::new(CancelCookieClock::{ driver: d, armed, })
  let c = @cookies.Cookies::new(
    @client.from_handler(_ => {
      armed.val = true
      response
    }),
    jar,
  )
  let delivered = Ref(false)
  d.run(() => {
    let task = d.spawn(() => {
      let response = c.send(
        @mttp_core.Request::get("http://example.test/"),
        @mttp_core.SendOptions::default(),
      )
      delivered.val = true
      response.attributes.get(@rt.upgraded).unwrap().take_conn().unwrap().0.close()
      d.pause()
    })
    assert_false(task.wait())
  })
  assert_true(delivered.val)
  reclaimed(upgrade)
  c.close()
  reclaimed(upgrade)
}

///|
test "upgrade cleanup covers buffered read errors and cancellation" {
  for cancel in [false, true] {
    let d = @driver.Driver::new()
    let (upgrade, response) = leak_upgrade()
    let feed = @sim.Feed::new(
      d,
      if cancel {
        [Wait(1000)]
      } else {
        [
          Fail(
            @mttp_core.TransportError(
              kind=Network,
              phase=Body,
              detail="read failed",
            ),
          ),
        ]
      },
    )
    let response = {
      ..response,
      body: Stream(@mttp_core.StreamBody::new(feed)),
    }
    let c = @client.Client::new(
      @client.from_handler(_ => response),
      @sim.SimClock::new(d),
    )
    d.run(() => {
      let task = d.spawn(() => {
        try
          c.send(@client.get("/").response(@client.as_bytes().any_status()))
        catch {
          @mttp_core.TransportError(..) => ()
          _ => fail("wrong error")
        } noraise {
          _ => fail("body read passed")
        }
      })
      if cancel {
        d.pause()
        task.cancel()
        assert_false(task.wait())
      } else {
        assert_true(task.wait())
      }
    })
    reclaimed(upgrade)
    assert_eq(feed.closes(), 1)
    c.close()
    reclaimed(upgrade)
  }
}

///|
test "upgrade cleanup covers attempt deadlines around decoding preparing and total stream deadlines" {
  for phase in 0..<4 {
    let (upgrade, response) = leak_upgrade()
    let clock = @sim.FakeClock::new()
    let c = @client.Client::new(
      @client.from_handler(_ => {
        if phase == 0 {
          clock.advance(10)
        }
        response
      }),
      clock,
      timer=PassthroughTimer::{ },
      timeout_ms=5,
      total_ms?=if phase == 2 { Some(5) } else { None },
    )
    @driver.run_sync(() => {
      try {
        if phase == 2 {
          ignore(
            c.send(
              @client.get("/").response(
                @client.as_stream((_, _) => clock.advance(10)).any_status(),
              ),
            ),
          )
        } else if phase == 3 {
          let reader : @client.StreamResponseAs[Unit] = @client.ResponsePlan::prepared_stream(
            (_, _) => {
              clock.advance(10)
              Ok(())
            },
            _ => (),
          )
          ignore(c.send(@client.get("/").response(reader.any_status())))
        } else {
          ignore(
            c.send(
              @client.get("/").response(
                @client.ResponsePlan::new((_, _) => clock.advance(10)),
              ),
            ),
          )
        }
      } catch {
        @mttp_core.TransportError(kind=Timeout(_), ..) => ()
        _ => fail("wrong deadline error")
      } noraise {
        _ => fail("deadline passed")
      }
    })
    reclaimed(upgrade)
    c.close()
    reclaimed(upgrade)
  }
}
