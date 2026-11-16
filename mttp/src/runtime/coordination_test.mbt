///|
async test "runtime ports satisfy the shared coordination contract" {
  @sim.check_coordination_contract(@runtime.RuntimeCoordination::new(), suspend=() => {
    @async.pause()
  })
}

///|
async test "parent cancellation awaits both coordination children" {
  let coordination = @runtime.RuntimeCoordination::new()
  let entered = coordination.signal()
  let forever = coordination.signal()
  let cleaned = Ref(0)
  let completed = Ref(false)
  @async.with_task_group(group => {
    let task = group.spawn(allow_failure=true, () => {
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
      completed.val = true
    })
    entered.wait()
    @async.pause()
    task.cancel()
    task.wait() catch {
      @async.WaitedTaskAlreadyCancelled => ()
      error => raise error
    }
    assert_eq(cleaned.val, 2)
    assert_false(completed.val)
  })
}

///|
async test "synchronous primary completion still joins monitor cleanup and keeps its outcome" {
  let coordination = @runtime.RuntimeCoordination::new()
  for fails in [false, true] {
    let cleaned = Ref(false)
    let primary_error = @mttp_core.TransportError(
      kind=Invalid,
      phase=Head,
      detail="primary",
    )
    let result = try {
      coordination.supervise(primary=() => if fails { raise primary_error }, monitor=() => {
        defer {
          cleaned.val = true
        }
        // A child cancelled before starting still enters its body. A
        // late monitor error must not replace the delivered primary result.
        raise @mttp_core.TransportError(
          kind=Network,
          phase=Unknown,
          detail="late monitor",
        )
      })
      None
    } catch {
      error => Some(error)
    }
    assert_true(cleaned.val)
    if fails {
      assert_true(
        result is Some(@mttp_core.TransportError(detail="primary", ..)),
      )
    } else {
      assert_true(result is None)
    }
  }
}

///|
async test "caller cancellation racing primary completion remains a signal" {
  let coordination = @runtime.RuntimeCoordination::new()
  let cancel : Ref[(() -> Unit)?] = Ref(None)
  let cleaned = Ref(false)
  let returned = Ref(false)
  let caught = Ref(false)
  @async.with_task_group(group => {
    let task = group.spawn(() => {
      coordination.supervise(primary=() => cancel.val.unwrap()(), monitor=() => {
        defer {
          cleaned.val = true
        }
        coordination.signal().wait()
      }) catch {
        _ => caught.val = true
      }
      returned.val = true
    })
    cancel.val = Some(() => task.cancel())
    task.wait() catch {
      @async.WaitedTaskAlreadyCancelled => ()
      error => raise error
    }
  })
  assert_true(cleaned.val)
  assert_false(returned.val || caught.val)
}

///|
async test "an event channel waits on runtime signals" {
  let (sender, stream) = @endpoint.EventStream::channel(
    coordination=@runtime.RuntimeCoordination::new(),
    capacity=1,
  )
  let results = []
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      for i in 1..<=3 {
        results.push(sender.send(i))
      }
    })
    assert_eq(stream.next(), Some(1))
    @async.pause()
    // The second value is queued and the third send waits for room.
    assert_eq(results, [true, true])
    stream.close()
  })
  assert_eq(results, [true, true, false])
}
