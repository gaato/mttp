// Self-tests of the contract checks: each check passes on the doubles of this
// package and fails on a double that breaks one of its rules, so a check that
// stopped looking would fail here.

///|
/// How `f` ended: the broken rule of a check's Failure, the detail of a
/// TransportError, or "passed".
async fn outcome(f : async () -> Unit) -> String {
  try f() catch {
    Failure(rule) => rule
    @mttp.TransportError(detail~, ..) => "raised: \{detail}"
    error => "other: \{error}"
  } noraise {
    _ => "passed"
  }
}

// ------------------------------------------------------------ coordination

///|
test "sim coordination satisfies the coordination contract" {
  let d = @driver.Driver::new()
  let coordination = @sim.SimCoordination::new(d)
  d.run(() => {
    @sim.check_coordination_contract(coordination, suspend=() => d.pause())
    @sim.check_coordination_contract(coordination, suspend=() => d.sleep(1))
  })
  assert_eq(d.live_tasks(), 0)
  assert_eq(d.pending_timers(), 0)
}

///|
/// Raises a wrong error from the `fail_at`-th supervision.
priv struct WrongOutcome {
  inner : &@rt.Coordination
  fail_at : Int32
  calls : Ref[Int32]
}

///|
impl @rt.Coordination for WrongOutcome with fn signal(self) {
  self.inner.signal()
}

///|
impl @rt.Coordination for WrongOutcome with fn supervise(
  self,
  primary~,
  monitor~,
) {
  self.calls.val += 1
  if self.calls.val == self.fail_at {
    raise @mttp.TransportError(
      kind=Network,
      phase=Unknown,
      detail="wrong outcome",
    )
  }
  self.inner.supervise(primary~, monitor~)
}

///|
test "coordination check refuses a supervision that delivers the wrong outcome" {
  let d = @driver.Driver::new()
  let coordination = @sim.SimCoordination::new(d)
  let rules = []
  d.run(() => {
    for fail_at in 1..<=7 {
      let bad = WrongOutcome::{ inner: coordination, fail_at, calls: Ref(0), }
      rules.push(
        outcome(() => {
          @sim.check_coordination_contract(bad, suspend=() => d.pause())
        }),
      )
    }
  })
  debug_inspect(
    rules,
    content=(
      #|[
      #|  "raised: wrong outcome",
      #|  "raised: wrong outcome",
      #|  "check_coordination_contract: a monitor failure was replaced by another error",
      #|  "check_coordination_contract: a primary failure was replaced by another error",
      #|  "check_coordination_contract: a monitor failure after primary finished must be ignored",
      #|  "check_coordination_contract: the outer monitor's failure was replaced by another error",
      #|  "check_coordination_contract: the outer monitor's failure was replaced by another error",
      #|]
    ),
  )
}

///|
/// Returns when primary does, cancelling the monitor without waiting for its
/// cleanup.
priv struct Leaky {
  driver : @driver.Driver
  inner : &@rt.Coordination
}

///|
impl @rt.Coordination for Leaky with fn signal(self) {
  self.inner.signal()
}

///|
impl @rt.Coordination for Leaky with fn supervise(self, primary~, monitor~) {
  let watching = self.driver.spawn(
    () => monitor() catch { _ => () },
    allow_failure=true,
  )
  primary()
  watching.cancel()
}

///|
test "coordination check refuses a supervision that does not join the monitor" {
  let d = @driver.Driver::new()
  let leaky = Leaky::{ driver: d, inner: @sim.SimCoordination::new(d), }
  let rule = d.run(() => {
    outcome(() => {
      @sim.check_coordination_contract(leaky, suspend=() => d.pause())
    })
  })
  inspect(
    rule,
    content="check_coordination_contract: primary finishing must cancel the monitor and join its cleanup",
  )
}

///|
/// How a Flawed coordination breaks the contract.
priv enum Flaw {
  /// A monitor that completes cancels primary.
  KillsPrimary
  /// A monitor failure cancels primary but is not raised.
  SwallowsMonitorFailure
  /// A primary failure is not raised.
  SwallowsPrimaryFailure
  /// A monitor failure is raised without cancelling primary.
  LeavesPrimaryRunning
  /// After a primary failure, the monitor is cancelled but not joined.
  SkipsJoinOnPrimaryFailure
  /// A cancelled supervision cancels its children but does not join them.
  SkipsJoinWhenCancelled
}

///|
/// A coordination on a Driver with one flaw; otherwise it supervises as
/// SimCoordination does.
priv struct Flawed {
  driver : @driver.Driver
  inner : &@rt.Coordination
  flaw : Flaw
}

///|
impl @rt.Coordination for Flawed with fn signal(self) {
  self.inner.signal()
}

///|
/// Sets `flag` and returns `error`.
fn noted(
  flag : Ref[Bool],
  error : @mttp.TransportError,
) -> @mttp.TransportError {
  flag.val = true
  error
}

///|
impl @rt.Coordination for Flawed with fn supervise(self, primary~, monitor~) {
  match self.flaw {
    KillsPrimary =>
      self.inner.supervise(primary~, monitor=() => {
        monitor()
        raise @mttp.TransportError(kind=Closed, phase=Unknown, detail="stop")
      }) catch {
        @mttp.TransportError(detail="stop", ..) => ()
        error => raise error
      }
    SwallowsMonitorFailure | SwallowsPrimaryFailure => {
      let from_monitor = Ref(false)
      // Not errdefer: that also runs when the monitor is cancelled.
      self.inner.supervise(primary~, monitor=() => {
        monitor() catch {
          error => raise noted(from_monitor, error)
        }
      }) catch {
        error =>
          if from_monitor.val != (self.flaw is SwallowsMonitorFailure) {
            raise error
          }
      }
    }
    _ => {
      // (error, raised by the monitor)
      let failure : Ref[(@mttp.TransportError, Bool)?] = Ref(None)
      let completed = Ref(false)
      let done = self.inner.signal()
      let work = self.driver.spawn(
        () => {
          primary() catch {
            error =>
              if failure.val is None {
                failure.val = Some((error, false))
              }
          }
          completed.val = true
          done.notify()
        },
        allow_failure=true,
      )
      let watching = self.driver.spawn(
        () => {
          monitor() catch {
            error =>
              if !completed.val && failure.val is None {
                failure.val = Some((error, true))
                if !(self.flaw is LeavesPrimaryRunning) {
                  work.cancel()
                }
                done.notify()
              }
          }
        },
        allow_failure=true,
      )
      let mut join = true
      defer (if join {
        self.driver.cancel_and_join([work, watching])
      } else {
        if !(self.flaw is LeavesPrimaryRunning) {
          work.cancel()
        }
        watching.cancel()
      })
      join = !(self.flaw is SkipsJoinWhenCancelled)
      done.wait()
      join = true
      if failure.val is Some((error, from_monitor)) {
        join = match self.flaw {
          LeavesPrimaryRunning => !from_monitor
          SkipsJoinOnPrimaryFailure => from_monitor
          _ => true
        }
        raise error
      }
    }
  }
}

///|
test "coordination check refuses each flawed supervision" {
  let rules = []
  for
    flaw in [
      KillsPrimary,
      SwallowsMonitorFailure,
      SwallowsPrimaryFailure,
      LeavesPrimaryRunning,
      SkipsJoinOnPrimaryFailure,
      SkipsJoinWhenCancelled,
    ] {
    let d = @driver.Driver::new()
    let flawed = Flawed::{
      driver: d,
      inner: @sim.SimCoordination::new(d),
      flaw,
    }
    rules.push(
      d.run(() => {
        outcome(() => {
          @sim.check_coordination_contract(flawed, suspend=() => d.pause())
        })
      }),
    )
  }
  debug_inspect(
    rules,
    content=(
      #|[
      #|  "check_coordination_contract: a monitor that completes must let primary finish",
      #|  "check_coordination_contract: a monitor failure must be raised",
      #|  "check_coordination_contract: a primary failure must be raised",
      #|  "check_coordination_contract: a monitor failure must cancel primary and join its cleanup",
      #|  "check_coordination_contract: a primary failure must cancel the monitor and join its cleanup",
      #|  "check_coordination_contract: a cancelled supervision must join both children's cleanup",
      #|]
    ),
  )
}

///|
/// A correct coordination that starts the monitor before primary, as a
/// runtime may: the port promises no order between the children.
priv struct MonitorFirst {
  driver : @driver.Driver
  inner : &@rt.Coordination
}

///|
impl @rt.Coordination for MonitorFirst with fn signal(self) {
  self.inner.signal()
}

///|
impl @rt.Coordination for MonitorFirst with fn supervise(
  self,
  primary~,
  monitor~,
) {
  let failure : Ref[@mttp.TransportError?] = Ref(None)
  let completed = Ref(false)
  let primary_task : Ref[@driver.Task?] = Ref(None)
  let watching = self.driver.spawn(() => {
    monitor() catch {
      error =>
        if !completed.val {
          if failure.val is None {
            failure.val = Some(error)
          }
          if primary_task.val is Some(work) {
            work.cancel()
          }
        }
    }
  })
  let work = self.driver.spawn(() => {
    primary() catch {
      error => if failure.val is None { failure.val = Some(error) }
    }
    completed.val = true
  })
  primary_task.val = Some(work)
  defer self.driver.cancel_and_join([work, watching])
  let _ = work.wait() catch { _ => false }
  if failure.val is Some(error) {
    raise error
  }
}

///|
test "a monitor-first coordination passes the coordination and connection checks" {
  let d = @driver.Driver::new()
  let coordination = MonitorFirst::{
    driver: d,
    inner: @sim.SimCoordination::new(d),
  }
  let (left, right) = @sim.pair(@sim.SimCoordination::new(d))
  d.run(() => {
    @sim.check_coordination_contract(coordination, suspend=() => d.pause())
    @sim.check_coordination_contract(coordination, suspend=() => d.sleep(1))
    @sim.check_conn(left, right, coordination~, suspend=() => d.pause(), shutdown_left=() => {
      left.shutdown_write()
    })
  })
  assert_eq(d.live_tasks(), 0)
}

// -------------------------------------------------------------- connections

///|
test "sim pairs satisfy the connection contract with and without half close" {
  for chunk_bytes in [1, 3, 65536] {
    let d = @driver.Driver::new()
    let coordination = @sim.SimCoordination::new(d)
    let (left, right) = @sim.pair(coordination, chunk_bytes~)
    d.run(() => {
      @sim.check_conn(left, right, coordination~, suspend=() => d.pause())
    })
    assert_eq(left.closes(), 1)
    assert_eq(right.closes(), 1)
    let (left, right) = @sim.pair(coordination, chunk_bytes~)
    d.run(() => {
      @sim.check_conn(left, right, coordination~, suspend=() => d.sleep(1), shutdown_left=() => {
        left.shutdown_write()
      })
    })
    assert_eq(left.closes(), 1)
    assert_eq(right.closes(), 1)
    assert_eq(d.live_tasks(), 0)
  }
}

///|
/// How a Faulty connection breaks the contract.
priv enum Fault {
  /// Reads ignore `max_len`.
  Oversize
  /// The first read returns an empty chunk.
  EmptyChunk
  /// A read after a cancelled one returns a stale byte.
  StaleAfterCancel
  /// A write after close is silently dropped.
  WriteAfterClose
  /// Close does not wake a pending read.
  DeafClose
  /// Large reads add a byte nobody wrote.
  ExtraByte
  /// Large reads return the right number of wrong bytes.
  Corrupt
  /// A one-byte read raises instead of waiting.
  Impatient
  /// The first one-byte read returns a byte nobody wrote.
  Phantom
  /// A read after EOF returns a byte.
  NonStickyEof
  /// A read woken by close returns a byte.
  LiesAfterClose
  /// After a large read, a small read returns wrong bytes.
  GarbledReply
  /// After a large read, a small read returns an empty chunk.
  EmptyReply
}

///|
/// A SimConn end with one fault.
priv struct Faulty {
  inner : @sim.SimConn
  fault : Fault
  mut reads : Int32
  mut interrupted : Bool
  mut closed : Bool
  mut eof : Bool
  mut large : Bool
}

///|
fn Faulty::new(inner : @sim.SimConn, fault : Fault) -> Faulty {
  {
    inner,
    fault,
    reads: 0,
    interrupted: false,
    closed: false,
    eof: false,
    large: false,
  }
}

///|
impl @rt.Conn for Faulty with fn read(self, max_len~) {
  self.reads += 1
  match self.fault {
    Oversize => self.inner.read(max_len=max_len * 2)
    EmptyChunk if self.reads == 1 => Some(b"")
    StaleAfterCancel if self.interrupted => {
      self.interrupted = false
      Some(b"?")
    }
    StaleAfterCancel => {
      self.interrupted = true
      let got = self.inner.read(max_len~)
      self.interrupted = false
      got
    }
    GarbledReply | EmptyReply if max_len > 2 => {
      self.large = true
      self.inner.read(max_len~)
    }
    GarbledReply if self.large =>
      self.inner.read(max_len~).map(chunk => Bytes::make(chunk.length(), b'#'))
    EmptyReply if self.large => Some(b"")
    ExtraByte if max_len > 2 =>
      self.inner
      .read(max_len=max_len - 1)
      .map(chunk => {
        let out = Buffer()
        out.write_bytes(chunk)
        out.write_byte(b'!')
        out.to_bytes()
      })
    Corrupt if max_len > 2 =>
      self.inner.read(max_len~).map(chunk => Bytes::make(chunk.length(), b'#'))
    Impatient if max_len == 1 =>
      raise @mttp.TransportError(kind=Network, phase=Unknown, detail="idle")
    Phantom if max_len == 1 && !self.interrupted => {
      self.interrupted = true
      Some(b"?")
    }
    NonStickyEof =>
      match self.inner.read(max_len~) {
        None if self.eof => Some(b"?")
        None => {
          self.eof = true
          None
        }
        got => got
      }
    LiesAfterClose => {
      let got = self.inner.read(max_len~)
      if self.closed {
        Some(b"?")
      } else {
        got
      }
    }
    _ => self.inner.read(max_len~)
  }
}

///|
impl @rt.Conn for Faulty with fn write(self, bytes) {
  if self.fault is WriteAfterClose && self.closed {
    return
  }
  self.inner.write(bytes)
}

///|
impl @rt.Conn for Faulty with fn close(self) {
  self.closed = true
  if !(self.fault is DeafClose) {
    self.inner.close()
  }
}

///|
test "connection check refuses each broken rule" {
  let rules = []
  for
    fault in [
      Oversize,
      EmptyChunk,
      StaleAfterCancel,
      WriteAfterClose,
      DeafClose,
      ExtraByte,
      Corrupt,
      Impatient,
      Phantom,
      NonStickyEof,
      LiesAfterClose,
      GarbledReply,
      EmptyReply,
    ] {
    let d = @driver.Driver::new()
    let coordination = @sim.SimCoordination::new(d)
    let (left, right) = @sim.pair(coordination)
    // Close and write-after-close faults are checked on the left end, read
    // faults on the right one.
    let (l, r) : (&@rt.Conn, &@rt.Conn) = match fault {
      WriteAfterClose | DeafClose | LiesAfterClose =>
        (Faulty::new(left, fault), right)
      _ => (left, Faulty::new(right, fault))
    }
    let rule = d.run(() => {
      outcome(() => {
        @sim.check_conn(l, r, coordination~, suspend=() => d.pause())
      })
    }) catch {
      @driver.DriverError(kind=Deadlock(..), ..) => "deadlock"
      error => "driver: \{error}"
    }
    rules.push(rule)
  }
  let unconnected = @driver.run_sync(() => {
    outcome(() => {
      @sim.check_conn(
        @sim.ScriptedConn::new([Eof]),
        @sim.ScriptedConn::new([Chunk(b"abcdef"), Eof]),
        coordination=@sim.SimCoordination::new(@driver.current()),
        suspend=() => @driver.pause() catch { _ => () },
      )
    })
  })
  rules.push(unconnected)
  // After a half close, too, EOF must stay.
  let d = @driver.Driver::new()
  let coordination = @sim.SimCoordination::new(d)
  let (left, right) = @sim.pair(coordination)
  rules.push(
    d.run(() => {
      outcome(() => {
        @sim.check_conn(
          left,
          Faulty::new(right, NonStickyEof),
          coordination~,
          suspend=() => d.pause(),
          shutdown_left=() => left.shutdown_write(),
        )
      })
    }),
  )
  debug_inspect(
    rules,
    content=(
      #|[
      #|  "check_conn: a read returned more than max_len bytes",
      #|  "check_conn: a read returned an empty chunk",
      #|  "check_conn: the bytes read differ from the bytes written",
      #|  "check_conn: a write after close must raise",
      #|  "deadlock",
      #|  "check_conn: a read returned bytes nobody wrote",
      #|  "check_conn: concurrent read and write corrupted the bytes",
      #|  "check_conn: a pending read raised instead of waiting",
      #|  "check_conn: a read returned although the peer wrote nothing",
      #|  "check_conn: the peer of a closed end must read a sticky EOF",
      #|  "check_conn: a read woken by close returned bytes",
      #|  "check_conn: concurrent read and write corrupted the bytes",
      #|  "check_conn: a read returned an empty chunk",
      #|  "check_conn: EOF before all written bytes arrived",
      #|  "check_conn: EOF after the peer's shutdown is not sticky",
      #|]
    ),
  )
}

// ------------------------------------------------------------ body streams

///|
test "feeds satisfy the body stream contract" {
  let d = @driver.Driver::new()
  d.run(() => {
    @sim.check_body_stream_contract(
      () => @sim.Feed::bytes(d, [b"a", b"", b"bc"]),
      b"abc",
    )
    @sim.check_body_stream_contract(() => @sim.Feed::bytes(d, []), b"")
    @sim.check_body_stream_contract(
      () => @sim.Feed::new(d, [Wait(5), Chunk(b"late"), End, Chunk(b"never")]),
      b"late",
    )
  })
  assert_eq(d.now(), 5L)
}

///|
/// A stream breaking one BodyStream rule, chosen by `mode`.
priv struct BrokenStream {
  mode : Int32
  mut calls : Int32
  mut closed : Bool
}

///|
impl @mttp.BodyStream for BrokenStream with fn read_some(self) {
  self.calls += 1
  match self.mode {
    0 => Some(b"")
    1 => Some(b"too much")
    2 => Some(b"a")
    3 => if self.calls == 1 { Some(b"ba") } else { None }
    4 => if self.calls == 2 { Some(b"after EOF") } else { None }
    _ =>
      if self.closed {
        Some(b"after close")
      } else if self.calls == 1 {
        Some(b"ab")
      } else {
        None
      }
  }
}

///|
impl @mttp.BodyStream for BrokenStream with fn close(self) {
  self.closed = true
}

///|
test "body stream check refuses each broken rule" {
  let rules = []
  for mode in 0..<6 {
    rules.push(
      @driver.run_sync(() => {
        outcome(() => {
          @sim.check_body_stream_contract(
            () => BrokenStream::{ mode, calls: 0, closed: false, },
            match mode {
              2 => b"aaaaaaaa"
              4 => b""
              _ => b"ab"
            },
            max_reads=4,
          )
        })
      }),
    )
  }
  debug_inspect(
    rules,
    content=(
      #|[
      #|  "check_body_stream_contract: a read returned an empty chunk",
      #|  "check_body_stream_contract: the stream returned more than the expected bytes",
      #|  "check_body_stream_contract: the stream did not end within 4 reads",
      #|  "check_body_stream_contract: the bytes read differ from the expected bytes",
      #|  "check_body_stream_contract: EOF is not sticky",
      #|  "check_body_stream_contract: a read after close must return EOF",
      #|]
    ),
  )
}

// ----------------------------------------------------------------- backends

///|
/// A backend that keeps the rules: it validates first and refuses sends
/// after close.
priv struct Validating {
  mut closed : Bool
}

///|
impl @mttp.Backend for Validating with fn send(self, request, options) {
  if self.closed {
    raise @mttp.TransportError(kind=Closed, phase=Pool, detail="closed")
  }
  request.validate()
  options.validate()
  if request.body is Stream(body) {
    body.take().close()
  }
  @mttp.Response::new(200)
}

///|
impl @mttp.Backend for Validating with fn close(self) {
  self.closed = true
}

///|
/// A backend breaking one Backend rule, chosen by `mode`.
priv struct BrokenBackend {
  mode : Int32
  mut closed : Bool
}

///|
impl @mttp.Backend for BrokenBackend with fn send(self, request, options) {
  match self.mode {
    0 => ()
    1 =>
      raise @mttp.TransportError(kind=Network, phase=Head, detail="wrong kind")
    2 =>
      raise @mttp.TransportError(
        kind=Invalid,
        phase=Write,
        detail="wrong phase",
      )
    // Validates everything except the body, so a negative stream length passes.
    3 => { ..request, body: Empty, }.validate()
    4 => {
      request.validate()
      if request.body is Stream(body) {
        body.take().close()
      }
    }
    _ => {
      request.validate()
      options.validate()
      if request.body is Stream(body) {
        body.take().close()
      }
      if self.closed {
        raise @mttp.TransportError(kind=Closed, phase=Write, detail="late")
      }
    }
  }
  @mttp.Response::new(200)
}

///|
impl @mttp.Backend for BrokenBackend with fn close(self) {
  self.closed = true
}

///|
test "backend check passes a validating backend and refuses each broken rule" {
  @driver.run_sync(() => {
    @sim.check_backend_contract(() => Validating::{ closed: false, })
  })
  let rules = []
  for mode in 0..<6 {
    rules.push(
      @driver.run_sync(() => {
        outcome(() => {
          @sim.check_backend_contract(() => BrokenBackend::{
            mode,
            closed: false,
          })
        })
      }),
    )
  }
  debug_inspect(
    rules,
    content=(
      #|[
      #|  "check_backend_contract: an invalid method was accepted",
      #|  "check_backend_contract: an invalid method raised Network in Head; want Invalid in Pool",
      #|  "check_backend_contract: an invalid method raised Invalid in Write; want Invalid in Pool",
      #|  "check_backend_contract: a stream declaring a negative length was accepted",
      #|  "check_backend_contract: a zero attempt deadline was accepted",
      #|  "check_backend_contract: a send after close raised Closed in Write; want Closed in Pool",
      #|]
    ),
  )
}

// ------------------------------------------------------------------- splits

///|
test "split check accepts a split-invariant parser and refuses one that is not" {
  for bytes in [b"", b"a", b"\xe6\x97\xa5\r\n"] {
    @sim.check_splits(bytes, chunks => {
      let out = Buffer()
      for chunk in chunks {
        out.write_bytes(chunk)
      }
      out.to_bytes()
    })
  }
  let rejected = try {
    @sim.check_splits(b"abc", chunks => chunks.length())
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
}

///|
test "body stream check stops a stream after max_reads reads" {
  let d = @driver.Driver::new()
  let chunks = n => Array::makei(n, _ => b"x")
  let expected = n => Bytes::make(n, b'x')
  let rules = d.run(() => {
    // The read that returns EOF is the max_reads-th read.
    @sim.check_body_stream_contract(
      () => @sim.Feed::bytes(d, chunks(2)),
      expected(2),
      max_reads=3,
    )
    @sim.check_body_stream_contract(
      () => @sim.Feed::bytes(d, chunks(1023)),
      expected(1023),
    )
    [
      outcome(() => {
        @sim.check_body_stream_contract(
          () => @sim.Feed::bytes(d, chunks(3)),
          expected(3),
          max_reads=3,
        )
      }),
      outcome(() => {
        @sim.check_body_stream_contract(
          () => @sim.Feed::bytes(d, chunks(1024)),
          expected(1024),
        )
      }),
    ]
  })
  debug_inspect(
    rules,
    content=(
      #|[
      #|  "check_body_stream_contract: the stream did not end within 3 reads",
      #|  "check_body_stream_contract: the stream did not end within 1024 reads",
      #|]
    ),
  )
}

///|
/// A SimConn end that runs one operation at a time: a read in progress
/// holds the lock a write needs.
priv struct Serialized {
  inner : @sim.SimConn
  coordination : &@rt.Coordination
  mut busy : Bool
  mut freed : &@rt.Signal
}

///|
fn Serialized::new(
  inner : @sim.SimConn,
  coordination : &@rt.Coordination,
) -> Serialized {
  { inner, coordination, busy: false, freed: coordination.signal(), }
}

///|
async fn Serialized::lock(self : Serialized) -> Unit noraise {
  while self.busy {
    self.freed.wait()
  }
  self.busy = true
}

///|
fn Serialized::unlock(self : Serialized) -> Unit {
  self.busy = false
  let freed = self.freed
  self.freed = self.coordination.signal()
  freed.notify()
}

///|
impl @rt.Conn for Serialized with fn read(self, max_len~) {
  self.lock()
  defer self.unlock()
  self.inner.read(max_len~)
}

///|
impl @rt.Conn for Serialized with fn write(self, bytes) {
  self.lock()
  defer self.unlock()
  self.inner.write(bytes)
}

///|
impl @rt.Conn for Serialized with fn close(self) {
  self.inner.close()
}

///|
test "connection check hangs on an end that serializes its reads and writes" {
  // No port can tell a stuck end from a slow one, so the hang is the
  // signal: under the Driver it is a Deadlock, on either end.
  let outcomes = []
  for serialized_left in [true, false] {
    let d = @driver.Driver::new()
    let coordination = @sim.SimCoordination::new(d)
    let (left, right) = @sim.pair(coordination)
    let (l, r) : (&@rt.Conn, &@rt.Conn) = if serialized_left {
      (Serialized::new(left, coordination), right)
    } else {
      (left, Serialized::new(right, coordination))
    }
    let outcome = d.run(() => {
      outcome(() => {
        @sim.check_conn(l, r, coordination~, suspend=() => d.pause())
      })
    }) catch {
      @driver.DriverError(kind=Deadlock(..), ..) => "deadlock"
      error => "driver: \{error}"
    }
    outcomes.push(outcome)
  }
  assert_eq(outcomes, ["deadlock", "deadlock"])
  // The same ends pass when only one operation is outstanding at a time.
  let d = @driver.Driver::new()
  let coordination = @sim.SimCoordination::new(d)
  let (left, right) = @sim.pair(coordination)
  let l : &@rt.Conn = Serialized::new(left, coordination)
  d.run(() => {
    l.write(b"one at a time")
    assert_eq(right.read(max_len=64), Some(b"one at a time"))
    right.write(b"ok")
    assert_eq(l.read(max_len=64), Some(b"ok"))
  })
}
