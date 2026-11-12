///|
priv struct ProbeIo {
  reader : @io.BinaryReaderController
  writer : @io.BinaryWriterController
  bytes : Bytes
  mut offset : Int32
  limits : Array[Int32]
  writes : Array[Bytes]
  fail_read : Bool
  fail_write : Bool
  /// Writes raise `Closed`, as a connection beneath TLS may.
  closed_write : Bool
  wait_write : Bool
  mut writing : Bool
  mut cleaned : Bool
  after_read : (() -> Unit)?
  yield_before_read : Bool
}

///|
fn probe(
  bytes~ : Bytes = b"",
  fail_read~ : Bool = false,
  fail_write~ : Bool = false,
  closed_write~ : Bool = false,
  wait_write~ : Bool = false,
  after_read? : () -> Unit,
  yield_before_read~ : Bool = false,
) -> ProbeIo {
  {
    reader: @io.BinaryReaderController(),
    writer: @io.BinaryWriterController(),
    bytes,
    offset: 0,
    limits: [],
    writes: [],
    fail_read,
    fail_write,
    closed_write,
    wait_write,
    writing: false,
    cleaned: false,
    after_read,
    yield_before_read,
  }
}

///|
impl @io.BinaryReaderImpl for ProbeIo with fn get_controller(self) {
  self.reader
}

///|
impl @io.BinaryWriterImpl for ProbeIo with fn get_controller(self) {
  self.writer
}

///|
suberror Injected {
  Injected
}

///|
impl @io.BinaryReaderImpl for ProbeIo with fn raw_read_impl(
  self,
  out,
  offset~,
  max_len~,
) {
  if self.yield_before_read {
    @async.pause()
  }
  self.limits.push(max_len)
  if self.fail_read {
    raise Injected
  }
  let count = (self.bytes.length() - self.offset).min(max_len)
  for i in 0..<count {
    out[offset + i] = self.bytes[self.offset + i]
  }
  self.offset += count
  if self.after_read is Some(after) {
    after()
  }
  count
}

///|
async test "cancelled read waiter retains bytes committed by its completed child" {
  let cancel : Ref[(() -> Unit)?] = Ref(None)
  let io = probe(bytes=b"abc", yield_before_read=true, after_read=() => {
    cancel.val.unwrap()()
  })
  let conn : &@rt.Conn = wrap(io, Ref(0))
  defer conn.close()
  @async.with_task_group(group => {
    let task = group.spawn(allow_failure=true, () => {
      ignore(conn.read(max_len=3))
      fail("cancelled read returned")
    })
    cancel.val = Some(() => task.cancel())
    task.wait() catch {
      @async.WaitedTaskAlreadyCancelled => ()
      error => raise error
    }
  })
  assert_eq(io.offset, 3)
  assert_eq(conn.read(max_len=1), Some(b"a"))
  assert_eq(conn.read(max_len=1), Some(b"b"))
  assert_eq(conn.read(max_len=1), Some(b"c"))
}

///|
impl @io.BinaryWriterImpl for ProbeIo with fn raw_write_impl(
  self,
  bytes,
  offset~,
  len~,
) {
  self.writing = true
  defer {
    self.cleaned = true
  }
  if self.wait_write {
    @async.Cond().wait()
  }
  if self.fail_write {
    raise Injected
  }
  if self.closed_write {
    raise @mttp_core.TransportError(
      kind=Closed,
      phase=Unknown,
      detail="closed beneath",
    )
  }
  self.writes.push(bytes[offset:offset + len].to_owned())
  len
}

///|
impl @io.BinaryReader for ProbeIo

///|
impl @io.BinaryWriter for ProbeIo

///|
fn wrap(
  io : ProbeIo,
  closes : Ref[Int32],
  lower_sends? : () -> Int64,
  lower_failure? : () -> @mttp_core.TransportError?,
) -> SocketConn[ProbeIo, ProbeIo] {
  {
    reader: io,
    writer: io,
    close_: () => closes.val += 1,
    closed: false,
    eof: false,
    pending: b"",
    cancel_read: None,
    cancel_write: None,
    lower_sends,
    lower_failure,
  }
}

///|
async test "socket read and write bounds EOF halves and close errors" {
  let io = probe(bytes=Bytes::make(65537, b'x'))
  let closes = Ref(0)
  let conn : &@rt.Conn = wrap(io, closes)
  for invalid in [0, -1] {
    try conn.read(max_len=invalid) catch {
      @mttp_core.TransportError(kind=Invalid, phase=Unknown, ..) => ()
      error => raise error
    } noraise {
      _ => fail("invalid read size accepted")
    }
  }
  assert_eq(conn.read(max_len=2147483647).map(Bytes::length), Some(65536))
  assert_eq(conn.read(max_len=1).map(Bytes::length), Some(1))
  assert_eq(conn.read(max_len=100), None)
  assert_eq(conn.read(max_len=100), None)
  assert_eq(io.limits, [65536, 1, 100])
  conn.write(Bytes::make(131073, b'y'))
  conn.write(b"")
  assert_eq(io.writes.map(Bytes::length), [65536, 65536, 1])
  conn.close()
  conn.close()
  assert_eq(closes.val, 1)
  assert_eq(conn.read(max_len=1), None)
  try conn.write(b"x") catch {
    @mttp_core.TransportError(kind=Closed, phase=Unknown, ..) => ()
    error => raise error
  } noraise {
    _ => fail("closed write accepted")
  }
}

///|
async test "socket adapter translates runtime I O failures and preserves transport errors" {
  let conn : &@rt.Conn = wrap(probe(fail_read=true, fail_write=true), Ref(0))
  for
    action in [
      () => {
        let _ = conn.read(max_len=1)
      },
      () => conn.write(b"x"),
    ] {
    try action() catch {
      @mttp_core.TransportError(kind=Network, phase=Unknown, ..) => ()
      error => raise error
    } noraise {
      _ => fail("runtime error lost")
    }
  }
  let original = @mttp_core.TransportError(
    kind=Timeout(ms=7),
    phase=Write,
    detail="original",
  )
  assert_true(
    transport_error(original)
    is @mttp_core.TransportError(
      kind=Timeout(ms=7),
      phase=Write,
      detail="original"
    ),
  )
}

///|
/// A TLS session fails with an error of its own, or wraps the error of
/// the connection beneath on toolchains after MoonBit 0.10.20. The adapter
/// reports the last failure beneath for an error that is not a
/// `TransportError`, and keeps a `TransportError` as it is.
async test "a TLS failure reports the last failure beneath instead of a wrapped one" {
  let beneath = @mttp_core.TransportError(
    kind=Timeout(ms=7),
    phase=Body,
    detail="beneath",
  )
  let none : () -> @mttp_core.TransportError? = () => None
  let failed : () -> @mttp_core.TransportError? = () => Some(beneath)
  for row in [(none, @mttp_core.Kind::Network), (failed, Timeout(ms=7))] {
    let (lower_failure, expected) = row
    let conn : &@rt.Conn = wrap(
      probe(fail_read=true, fail_write=true),
      Ref(0),
      lower_failure~,
    )
    for
      action in [
        () => {
          let _ = conn.read(max_len=1)
        },
        () => conn.write(b"x"),
      ] {
      try action() catch {
        @mttp_core.TransportError(kind~, ..) => assert_eq(kind, expected)
      } noraise {
        _ => fail("the failing operation succeeded")
      }
    }
  }
  let own = @mttp_core.TransportError(kind=Closed, phase=Write, detail="own")
  let conn = wrap(probe(), Ref(0), lower_failure=failed)
  assert_true(conn.cause(own) is @mttp_core.TransportError(kind=Closed, ..))
}

///|
async test "closing socket cancels a pending write and joins cleanup" {
  let io = probe(wait_write=true)
  let closes = Ref(0)
  let conn : &@rt.Conn = wrap(io, closes)
  let failed = Ref(false)
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      // Part of the bytes may have left, so not `Closed`.
      conn.write(b"pending") catch {
        @mttp_core.TransportError(kind=Network, phase=Unknown, ..) =>
          failed.val = true
        error => raise error
      }
    })
    while !io.writing {
      @async.pause()
    }
    conn.close()
  })
  assert_true(io.cleaned)
  assert_true(failed.val)
  assert_eq(closes.val, 1)
}

///|
async test "caller cancellation of write is a signal and joins direction cleanup" {
  let io = probe(wait_write=true)
  let conn : &@rt.Conn = wrap(io, Ref(0))
  let caught = Ref(false)
  @async.with_task_group(group => {
    let task = group.spawn(() => {
      conn.write(b"pending") catch {
        _ => caught.val = true
      }
    })
    while !io.writing {
      @async.pause()
    }
    task.cancel()
    task.wait() catch {
      @async.WaitedTaskAlreadyCancelled => ()
      error => raise error
    }
  })
  assert_false(caught.val)
  assert_true(io.cleaned)
  conn.close()
}

///|
/// `Closed` promises that nothing of the write was sent. Over TLS the
/// adapter is told how many writes beneath may have sent bytes; a write
/// beneath that raised `Closed` does not count. If none did during the
/// write, any failure is `Closed`; if one did, a `Closed` from beneath, or
/// a read's `Closed` that the session raises again, is `Network`. Over TCP,
/// which cannot tell, it is `Network` too.
async test "a TLS write failed before sending anything beneath is Closed" {
  let idle : () -> Int64 = () => 0L
  // Each look finds one more write beneath that may have sent bytes.
  let sending = () => {
    let sent = Ref(0L)
    () => {
      sent.val += 1L
      sent.val
    }
  }
  for
    row in [
      (false, Some(idle), @mttp_core.Kind::Closed),
      (false, Some(sending()), Network),
      (false, None, Network),
      (true, Some(idle), Closed),
      (true, Some(sending()), Network),
      (true, None, Network),
    ] {
    let (closed, lower_sends, expected) = row
    let io = if closed {
      probe(closed_write=true)
    } else {
      probe(fail_write=true)
    }
    let conn : &@rt.Conn = wrap(io, Ref(0), lower_sends?)
    try conn.write(b"request") catch {
      @mttp_core.TransportError(kind~, phase=Unknown, ..) =>
        assert_eq(kind, expected)
      error => raise error
    } noraise {
      _ => fail("the failing write succeeded")
    }
  }
}
