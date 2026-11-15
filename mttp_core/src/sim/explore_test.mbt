///|
/// Two readers on two connections; the peers write to the first one, then
/// to the second. Returns the order the readers saw their bytes in.
fn two_readers(schedule : @driver.Schedule) -> String raise {
  let d = @driver.Driver::new(schedule~)
  let coordination = @sim.SimCoordination::new(d)
  let (a_peer, a) = @sim.pair(coordination)
  let (b_peer, b) = @sim.pair(coordination)
  let log = []
  d.run(() => {
    let read = (name : String, conn : @sim.SimConn) => {
      d.spawn(() => {
        guard conn.read(max_len=8) is Some(bytes) else { return }
        log.push(name + bytes.length().to_string())
      })
    }
    let readers = [read("a", a), read("b", b)]
    d.pause()
    a_peer.write(b"1")
    b_peer.write(b"2")
    for r in readers {
      ignore(r.wait())
    }
  })
  log.join(" ")
}

///|
test "explore passes a scenario that holds under every schedule" {
  @sim.explore(schedule => {
    let order = two_readers(schedule)
    assert_true(order == "a1 b1" || order == "b1 a1")
  })
}

///|
test "explore reports the seed, the shrunk choices and how to replay them" {
  let scenario = (schedule : @driver.Schedule) => {
    assert_eq(two_readers(schedule), "a1 b1")
  }
  let message = try @sim.explore(scenario) catch {
    Failure(message) => message
    _ => "unexpected error"
  } noraise {
    _ => "passed"
  }
  let lines = message.split("\n").map(line => line.to_owned()).collect()
  assert_true(lines[0].has_suffix("FAILED: seed 0 of 32 fails:"))
  assert_true(lines.contains("its choices: [1]"))
  assert_true(
    lines.contains("ddmin shrank them to [1] in 1 run, which fail with:"),
  )
  assert_eq(
    lines.last(),
    Some("replay: scenario(@driver.Schedule::replay([1]))"),
  )
  // The printed call replays the failure.
  try scenario(@driver.Schedule::replay([1])) catch {
    _ => ()
  } noraise {
    _ => fail("the shrunk schedule passed")
  }
}

///|
test "explore reports a FIFO failure without seeds" {
  let message = try @sim.explore(_ => fail("always"), seeds=4) catch {
    Failure(message) => message
    _ => "unexpected error"
  } noraise {
    _ => "passed"
  }
  assert_true(message.contains("FAILED: fails in FIFO order, before any seed:"))
}

///|
test "explore skips the seeds when the scenario meets no decision point" {
  let runs = Ref(0)
  @sim.explore(schedule => {
    runs.val += 1
    @driver.run_sync(() => @driver.pause(), schedule~) |> ignore
  })
  assert_eq(runs.val, 1)
}

///|
test "explore notices a scenario that does not depend on its schedule alone" {
  let runs = Ref(0)
  let message = try
    @sim.explore(seeds=64, schedule => {
      runs.val += 1
      let order = two_readers(schedule)
      // Fails on its first seeded failure only: a replay passes.
      if order == "b1 a1" && runs.val < 1000 {
        runs.val = 1000
        fail("flaky")
      }
    })
  catch {
    Failure(message) => message
    _ => "unexpected error"
  } noraise {
    _ => "passed"
  }
  assert_true(message.contains("does not depend on its schedule alone"))
}

///|
test "explore reports a driver error by its debug form" {
  let message = try
    @sim.explore(schedule => {
      @driver.run_sync(schedule~, () => @driver.Driver::new().park(_ => ()))
    })
  catch {
    Failure(message) => message
    _ => "unexpected error"
  } noraise {
    _ => "passed"
  }
  assert_true(message.contains("NotInTask"), msg=message)
}
