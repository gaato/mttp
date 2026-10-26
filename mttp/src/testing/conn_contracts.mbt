///|
/// Shared delivery and cleanup checks for runtime and deterministic ports.
/// Each implementation supplies its own cooperative suspension operation.
pub async fn check_coordination_contract(
  coordination : &@conn.Coordination,
  suspend~ : async () -> Unit noraise,
) -> Unit {
  let sticky = coordination.signal()
  sticky.notify()
  sticky.notify()
  sticky.wait()
  sticky.wait()
  let cleaned = Ref(0)
  let started = coordination.signal()
  coordination.supervise(
    primary=() => {
      started.wait()
      suspend()
    },
    monitor=() => {
      defer {
        cleaned.val += 1
      }
      started.notify()
    },
  )
  assert_eq(cleaned.val, 1)
  let forever = coordination.signal()
  let started = coordination.signal()
  coordination.supervise(primary=() => started.wait(), monitor=() => {
    defer {
      cleaned.val += 1
    }
    started.notify()
    forever.wait()
  })
  assert_eq(cleaned.val, 2)
  let started = coordination.signal()
  let failure = try {
    coordination.supervise(
      primary=() => {
        defer {
          cleaned.val += 1
        }
        started.notify()
        forever.wait()
      },
      monitor=() => {
        started.wait()
        raise @model.TransportError(kind=Protocol, phase=Body, detail="monitor")
      },
    )
    false
  } catch {
    @model.TransportError(detail="monitor", ..) => true
    _ => false
  }
  assert_true(failure)
  assert_eq(cleaned.val, 3)
  let started = coordination.signal()
  let failure = try {
    coordination.supervise(
      primary=() => {
        started.wait()
        raise @model.TransportError(kind=Invalid, phase=Write, detail="primary")
      },
      monitor=() => {
        defer {
          cleaned.val += 1
        }
        started.notify()
        forever.wait()
      },
    )
    false
  } catch {
    @model.TransportError(detail="primary", ..) => true
    _ => false
  }
  assert_true(failure)
  assert_eq(cleaned.val, 4)
  // A primary success delivered before a late monitor error is final.
  coordination.supervise(primary=() => (), monitor=() => {
    raise @model.TransportError(
      kind=Protocol,
      phase=Body,
      detail="late monitor",
    )
  })
}

///|
/// Whole writes, bounded nonempty reads, sticky EOF and a writable half after
/// peer FIN. The adapter supplies its own write-half shutdown operation.
pub async fn check_conn_pair_contract(
  left : &@conn.Conn,
  right : &@conn.Conn,
  finish_left~ : () -> Unit,
) -> Unit {
  defer left.close()
  defer right.close()
  left.write(b"abcdef")
  finish_left()
  let out = Buffer()
  while right.read(max_len=2) is Some(bytes) {
    assert_true(bytes.length() > 0 && bytes.length() <= 2)
    out.write_bytes(bytes)
  }
  assert_eq(out.to_bytes(), b"abcdef")
  assert_eq(right.read(max_len=2), None)
  right.write(b"reply")
  let reply = Buffer()
  while reply.length() < 5 {
    guard left.read(max_len=2) is Some(bytes) else {
      fail("FIN closed writable half")
    }
    reply.write_bytes(bytes)
  }
  assert_eq(reply.to_bytes(), b"reply")
  left.close()
  left.close()
}
