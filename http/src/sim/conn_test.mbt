///|
test "parent cancellation waits for both nested coordination cleanups" {
  let driver = @driver.Driver::new()
  let coordination = @sim.SimCoordination::new(driver)
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
  let coordination = @sim.SimCoordination::new(driver)
  let (left, right) = @sim.pair(coordination)
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
  let coordination = @sim.SimCoordination::new(driver)
  driver.run(() => {
    let fault = @http.TransportError(
      kind=Network,
      phase=Unknown,
      detail="injected",
    )
    let connection = @sim.ScriptedConn::new([
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
        @http.TransportError(detail="injected", ..) => true
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
    let blocked = @sim.ScriptedConn::new([Wait(coordination.signal()), Eof])
    let started = coordination.signal()
    let task = driver.spawn(() => {
      started.notify()
      assert_eq(blocked.read(max_len=1), None)
    })
    started.wait()
    blocked.close()
    assert_true(task.wait())
    assert_eq(@sim.ScriptedConn::new([]).read(max_len=1), None)
    assert_eq(@sim.ScriptedConn::new([Eof]).read(max_len=1), None)
    for
      bad in [
        @sim.ScriptedConn::new([], write_error=fault),
        @sim.ScriptedConn::new([]),
      ] {
      let invalid = try {
        ignore(bad.read(max_len=0))
        false
      } catch {
        @http.TransportError(kind=Invalid, ..) => true
        _ => false
      }
      assert_true(invalid)
      bad.close()
      let invalid = try {
        bad.write(b"x")
        false
      } catch {
        @http.TransportError(kind=Network, ..) => true
        _ => false
      }
      assert_true(invalid)
    }
    let fail_write = @sim.ScriptedConn::new([], write_error=fault)
    let failed = try {
      fail_write.write(b"x")
      false
    } catch {
      @http.TransportError(detail="injected", ..) => true
      _ => false
    }
    assert_true(failed)
    let (left, right) = @sim.pair(coordination)
    let invalid = try {
      ignore(left.read(max_len=0))
      false
    } catch {
      @http.TransportError(kind=Invalid, ..) => true
      _ => false
    }
    assert_true(invalid)
    right.close()
    let failed = try {
      left.write(b"x")
      false
    } catch {
      @http.TransportError(kind=Network, ..) => true
      _ => false
    }
    assert_true(failed)
    left.close()
    let failed = try {
      ignore(@sim.ScriptedDialer::new([]).connect(host="x", port=80))
      false
    } catch {
      @http.TransportError(kind=Connect, phase=Dial, ..) => true
      _ => false
    }
    assert_true(failed)
  })
}

///|
test "scripted dialer hands out connections in order and records upgrades" {
  let first = @sim.ScriptedConn::new([Chunk(b"one")])
  let second = @sim.ScriptedConn::new([Chunk(b"two")])
  let dialer = @sim.ScriptedDialer::new([first, second])
  @driver.run_sync(() => {
    let a = dialer.connect(host="proxy.test", port=8080)
    let tunnel = dialer.start_tls(a, host="proxy.test")
    let inner = dialer.start_tls(tunnel, host="origin.test")
    assert_eq(inner.read(max_len=8), Some(b"one"))
    let b = dialer.connect(host="origin.test", port=443)
    assert_eq(b.read(max_len=8), Some(b"two"))
    try dialer.connect(host="third.test", port=80) catch {
      @http.TransportError(kind~, phase~, ..) => {
        assert_eq(kind, Connect)
        assert_eq(phase, Dial)
      }
    } noraise {
      _ => fail("an exhausted script must refuse to dial")
    }
  })
  assert_eq(dialer.dialed(), [
    ("proxy.test", 8080),
    ("origin.test", 443),
    ("third.test", 80),
  ])
  assert_eq(dialer.tls_hosts(), ["proxy.test", "origin.test"])
}

///|
test "a pair fragments reads to chunk_bytes and the caller's bound" {
  let d = @driver.Driver::new()
  let (left, right) = @sim.pair(@sim.SimCoordination::new(d), chunk_bytes=0)
  d.run(() => {
    left.write(b"")
    left.write(b"abc")
    left.write(b"de")
    let reads = []
    for _ in 0..<5 {
      reads.push(right.read(max_len=4))
    }
    assert_eq(reads, [
      Some(b"a"),
      Some(b"b"),
      Some(b"c"),
      Some(b"d"),
      Some(b"e"),
    ])
    right.shutdown_write()
    assert_eq(left.read(max_len=4), None)
    left.write(b"still")
    assert_eq(right.read(max_len=1), Some(b"s"))
    left.close()
    left.close()
    assert_eq(left.read(max_len=4), None)
  })
  assert_eq(left.closes(), 1)
  assert_eq(right.closes(), 0)
}
