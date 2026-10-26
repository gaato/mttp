///|
priv struct WrongOutcome {
  inner : &@connection.Coordination
  fail_at : Int32
  calls : Ref[Int32]
}

///|
impl @connection.Coordination for WrongOutcome with fn signal(self) {
  self.inner.signal()
}

///|
impl @connection.Coordination for WrongOutcome with fn supervise(
  self,
  primary~,
  monitor~,
) {
  self.calls.val += 1
  if self.calls.val == self.fail_at {
    raise @model.TransportError(
      kind=Network,
      phase=Unknown,
      detail="wrong outcome",
    )
  }
  self.inner.supervise(primary~, monitor~)
}

///|
test "shared contract checks reject faulty error delivery and a lost writable half" {
  let driver = @driver.Driver::new()
  let coordination = @conn.SimCoordination::new(driver)
  driver.run(() => {
    for fail_at in [3, 4] {
      let bad = WrongOutcome::{ inner: coordination, fail_at, calls: Ref(0), }
      let refused = try {
        @testing.check_coordination_contract(bad, suspend=() => driver.sleep(1))
        false
      } catch {
        _ => true
      }
      assert_true(refused)
    }
    let refused = try {
      @testing.check_conn_pair_contract(
        @conn.ScriptedConn::new([Eof]),
        @conn.ScriptedConn::new([Chunk(b"abcdef"), Eof]),
        finish_left=() => (),
      )
      false
    } catch {
      _ => true
    }
    assert_true(refused)
  })
}

///|
test "simulated ports satisfy the shared coordination and connection contracts" {
  let driver = @driver.Driver::new()
  let coordination = @conn.SimCoordination::new(driver)
  let (left, right) = @conn.pair(coordination, chunk_bytes=1)
  driver.run(() => {
    @testing.check_coordination_contract(coordination, suspend=() => {
      driver.sleep(1)
    })
    @testing.check_conn_pair_contract(left, right, finish_left=() => {
      left.shutdown_write()
    })
  })
  assert_eq(left.closes(), 1)
  assert_eq(right.closes(), 1)
}

///|
test "parent cancellation waits for both nested coordination cleanups" {
  let driver = @driver.Driver::new()
  let coordination = @conn.SimCoordination::new(driver)
  let finished = Ref(false)
  let cleaned = Ref(0)
  driver.run(() => {
    let entered = coordination.signal()
    let forever = coordination.signal()
    let task = driver.spawn(() => {
      coordination.supervise(
        primary=() => {
          defer {
            cleaned.val += 1
          }
          coordination.supervise(
            primary=() => {
              defer {
                cleaned.val += 1
              }
              entered.notify()
              forever.wait()
            },
            monitor=() => {
              defer {
                cleaned.val += 1
              }
              forever.wait()
            },
          )
        },
        monitor=() => {
          defer {
            cleaned.val += 1
          }
          forever.wait()
        },
      )
      finished.val = true
    })
    entered.wait()
    task.cancel()
    assert_false(task.wait())
    assert_eq(cleaned.val, 4)
    assert_false(finished.val)
  })
  assert_eq(driver.ready_tasks(), 0)
}

///|
test "a cancelled reader unregisters before the next read and close wakes waiters" {
  let driver = @driver.Driver::new()
  let coordination = @conn.SimCoordination::new(driver)
  let (left, right) = @conn.pair(coordination)
  driver.run(() => {
    let started = coordination.signal()
    let read = driver.spawn(() => {
      started.notify()
      ignore(left.read(max_len=1))
    })
    started.wait()
    read.cancel()
    assert_false(read.wait())
    right.write(b"x")
    assert_eq(left.read(max_len=1), Some(b"x"))
    let started = coordination.signal()
    let read = driver.spawn(() => {
      started.notify()
      assert_eq(left.read(max_len=1), None)
    })
    started.wait()
    left.close()
    assert_true(read.wait())
    right.close()
  })
  assert_eq(left.closes(), 1)
}

///|
test "scripted reads bound chunks persist failures and wake on close" {
  let driver = @driver.Driver::new()
  let coordination = @conn.SimCoordination::new(driver)
  driver.run(() => {
    let fault = @model.TransportError(
      kind=Network,
      phase=Unknown,
      detail="injected",
    )
    let connection = @conn.ScriptedConn::new([
      Chunk(b""),
      Chunk(b"ab"),
      Failure(fault),
    ])
    assert_eq(connection.read(max_len=1), Some(b"a"))
    assert_eq(connection.read(max_len=1), Some(b"b"))
    for _ in 0..<2 {
      let failed = try {
        ignore(connection.read(max_len=1))
        false
      } catch {
        @model.TransportError(detail="injected", ..) => true
        _ => false
      }
      assert_true(failed)
    }
    connection.write(b"ok")
    assert_eq(connection.written(), [b"ok"])
    connection.close()
    connection.close()
    assert_eq(connection.read(max_len=1), None)
    assert_eq(connection.closes(), 1)
    let blocked = @conn.ScriptedConn::new([Wait(coordination.signal()), Eof])
    let started = coordination.signal()
    let task = driver.spawn(() => {
      started.notify()
      assert_eq(blocked.read(max_len=1), None)
    })
    started.wait()
    blocked.close()
    assert_true(task.wait())
    assert_eq(@conn.ScriptedConn::new([]).read(max_len=1), None)
    assert_eq(@conn.ScriptedConn::new([Eof]).read(max_len=1), None)
    for
      bad in [
        @conn.ScriptedConn::new([], write_error=fault),
        @conn.ScriptedConn::new([]),
      ] {
      let invalid = try {
        ignore(bad.read(max_len=0))
        false
      } catch {
        @model.TransportError(kind=Invalid, ..) => true
        _ => false
      }
      assert_true(invalid)
      bad.close()
      let invalid = try {
        bad.write(b"x")
        false
      } catch {
        @model.TransportError(kind=Network, ..) => true
        _ => false
      }
      assert_true(invalid)
    }
    let fail_write = @conn.ScriptedConn::new([], write_error=fault)
    let failed = try {
      fail_write.write(b"x")
      false
    } catch {
      @model.TransportError(detail="injected", ..) => true
      _ => false
    }
    assert_true(failed)
    let (left, right) = @conn.pair(coordination)
    let invalid = try {
      ignore(left.read(max_len=0))
      false
    } catch {
      @model.TransportError(kind=Invalid, ..) => true
      _ => false
    }
    assert_true(invalid)
    right.close()
    let failed = try {
      left.write(b"x")
      false
    } catch {
      @model.TransportError(kind=Network, ..) => true
      _ => false
    }
    assert_true(failed)
    left.close()
    let failed = try {
      ignore(@conn.ScriptedDialer::new([]).connect(host="x", port=80))
      false
    } catch {
      @model.TransportError(kind=Connect, phase=Dial, ..) => true
      _ => false
    }
    assert_true(failed)
  })
}
