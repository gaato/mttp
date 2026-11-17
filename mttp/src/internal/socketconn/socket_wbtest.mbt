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
  wait_read : Bool
  cleanup_error : Bool
  mut reading : Bool
  mut read_cleaned : Bool
  mut writing : Bool
  mut cleaned : Bool
  after_read : (() -> Unit)?
  after_write : (() -> Unit)?
  yield_before_read : Bool
}

///|
fn probe(
  bytes~ : Bytes = b"",
  fail_read~ : Bool = false,
  fail_write~ : Bool = false,
  closed_write~ : Bool = false,
  wait_write~ : Bool = false,
  wait_read~ : Bool = false,
  cleanup_error~ : Bool = false,
  after_read? : () -> Unit,
  after_write? : () -> Unit,
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
    wait_read,
    cleanup_error,
    reading: false,
    read_cleaned: false,
    writing: false,
    cleaned: false,
    after_read,
    after_write,
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
  self.reading = true
  defer {
    self.read_cleaned = true
    if self.cleanup_error {
      raise Injected
    }
  }
  if self.wait_read {
    @async.Cond().wait()
  }
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
  let io = probe(bytes=b"abcdef", yield_before_read=true, after_read=() => {
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
  assert_eq(conn.read(max_len=3), Some(b"def"))
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
    if self.cleanup_error {
      raise Injected
    }
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
  if self.after_write is Some(after) {
    after()
  }
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
    incomplete: false,
    pending: b"",
    read_buffer: [],
    read_size: 4096,
    cancel_read: None,
    cancel_write: None,
    lower_sends,
    lower_failure,
  }
}

///|
async test "socket read and write bounds EOF halves and close errors" {
  let io = probe(bytes=Bytes::make(4097, b'x'))
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
  assert_eq(conn.read(max_len=2147483647).map(Bytes::length), Some(4096))
  assert_eq(conn.read(max_len=1).map(Bytes::length), Some(1))
  assert_eq(conn.read(max_len=100), None)
  assert_eq(conn.read(max_len=100), None)
  assert_eq(io.limits, [4096, 1, 100])
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
async test "receive storage grows to 64 KiB and reuses it past the bound" {
  let bytes = Bytes::make(4096 + 8192 + 16384 + 32768 + 2 * 65536 + 1, b'x')
  let io = probe(bytes~)
  let socket = wrap(io, Ref(0))
  let conn : &@rt.Conn = socket
  defer conn.close()
  assert_eq(socket.read_buffer.length(), 0)
  let out = Buffer()
  for size in [4096, 8192, 16384, 32768, 65536] {
    let piece = conn.read(max_len=2147483647).unwrap()
    assert_eq(piece.length(), size)
    assert_eq(socket.read_buffer.length(), size)
    out.write_bytes(piece)
  }
  let full = socket.read_buffer
  out.write_bytes(conn.read(max_len=65537).unwrap())
  assert_true(physical_equal(full, socket.read_buffer))
  assert_eq(socket.read_buffer.length(), 65536)
  out.write_bytes(conn.read(max_len=65537).unwrap())
  assert_eq(conn.read(max_len=65537), None)
  assert_eq(io.limits, [4096, 8192, 16384, 32768, 65536, 65536, 65536, 65536])
  assert_eq(out.to_bytes(), bytes)
  conn.close()
  assert_eq(socket.read_buffer.length(), 0)
}

///|
async test "reused receive storage respects small reads and never aliases returned bytes" {
  let io = probe(bytes=b"abcdef")
  let socket = wrap(io, Ref(0))
  let conn : &@rt.Conn = socket
  defer conn.close()
  let first = conn.read(max_len=2).unwrap()
  let buffer = socket.read_buffer
  assert_eq(buffer.length(), 2)
  assert_eq(conn.read(max_len=2), Some(b"cd"))
  assert_true(physical_equal(buffer, socket.read_buffer))
  assert_eq(conn.read(max_len=2147483647), Some(b"ef"))
  assert_eq(first, b"ab")
  assert_eq(io.limits, [2, 2, 4096])
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
  match transport_error(original) {
    @mttp_core.TransportError(kind~, phase~, detail~) =>
      assert_eq((kind, phase, detail), (Timeout(ms=7), Write, "original"))
  }
}

///|
/// A TLS session fails with an error of its own, or wraps the error of
/// the connection beneath. The adapter
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
/// Over TLS, a read failure that the toolchain does not report as a close
/// without close_notify keeps its kind. Once a read found such a close
/// (`incomplete`, tested in incomplete_close_wbtest.mbt), later reads raise
/// `IncompleteClose` again without reading beneath, until close.
async test "an unclean TLS close stays IncompleteClose until close" {
  let sending : () -> Int64 = () => 0L
  let failing : &@rt.Conn = wrap(
    probe(fail_read=true),
    Ref(0),
    lower_sends=sending,
  )
  try failing.read(max_len=1) catch {
    @mttp_core.TransportError(kind~, ..) => assert_eq(kind, Network)
  } noraise {
    _ => fail("the failing read succeeded")
  }
  let io = probe(bytes=b"abc")
  let conn : &@rt.Conn = {
    ..wrap(io, Ref(0), lower_sends=sending),
    incomplete: true,
  }
  for _ in 0..<2 {
    try conn.read(max_len=1) catch {
      @mttp_core.TransportError(kind~, ..) => assert_eq(kind, IncompleteClose)
    } noraise {
      _ => fail("a read after an unclean close succeeded")
    }
  }
  assert_eq(io.limits, [])
  conn.close()
  assert_eq(conn.read(max_len=1), None)
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
async test "close wakes and joins both detached I O owners" {
  let io = probe(wait_read=true, wait_write=true)
  let socket = wrap(io, Ref(0))
  let conn : &@rt.Conn = socket
  let read_done = Ref(false)
  let write_done = Ref(false)
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      assert_eq(conn.read(max_len=1), None)
      assert_true(io.read_cleaned)
      read_done.val = true
    })
    group.spawn_bg(() => {
      try conn.write(b"pending") catch {
        @mttp_core.TransportError(kind=Network, ..) => ()
        error => raise error
      } noraise {
        _ => fail("closed pending write succeeded")
      }
      assert_true(io.cleaned)
      write_done.val = true
    })
    while !io.reading || !io.writing {
      @async.pause()
    }
    conn.close()
    conn.close()
  })
  assert_true(read_done.val && write_done.val)
  assert_true(socket.cancel_read is None && socket.cancel_write is None)
}

///|
async test "close during a completed write slice prevents the next slice" {
  let close : Ref[(() -> Unit)?] = Ref(None)
  let io = probe(after_write=() => close.val.unwrap()())
  let conn : &@rt.Conn = wrap(io, Ref(0))
  close.val = Some(() => conn.close())
  try conn.write(Bytes::make(131073, b'x')) catch {
    @mttp_core.TransportError(kind=Network, ..) => ()
    error => raise error
  } noraise {
    _ => fail("partial write succeeded")
  }
  assert_eq(io.writes.map(Bytes::length), [65536])
  assert_true(io.cleaned)
}

///|
async test "caller cancellation racing the final write remains a signal" {
  let cancel : Ref[(() -> Unit)?] = Ref(None)
  let io = probe(after_write=() => cancel.val.unwrap()())
  let conn : &@rt.Conn = wrap(io, Ref(0))
  defer conn.close()
  let returned = Ref(false)
  let caught = Ref(false)
  @async.with_task_group(group => {
    let task = group.spawn(() => {
      conn.write(b"written") catch {
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
  assert_eq(io.writes, [b"written"])
  assert_true(io.cleaned)
  assert_false(returned.val || caught.val)
}

///|
async test "caller cancellation still wins when an I O owner raises during cleanup" {
  for reading in [true, false] {
    let io = probe(wait_read=true, wait_write=true, cleanup_error=true)
    let conn : &@rt.Conn = wrap(io, Ref(0))
    defer conn.close()
    let caught = Ref(false)
    let returned = Ref(false)
    @async.with_task_group(group => {
      let task = group.spawn(() => {
        try {
          if reading {
            ignore(conn.read(max_len=1))
          } else {
            conn.write(b"pending")
          }
        } catch {
          _ => caught.val = true
        }
        returned.val = true
      })
      while !(if reading { io.reading } else { io.writing }) {
        @async.pause()
      }
      task.cancel()
      task.wait() catch {
        @async.WaitedTaskAlreadyCancelled => ()
        error => raise error
      }
    })
    assert_true(if reading { io.read_cleaned } else { io.cleaned })
    assert_false(returned.val || caught.val)
  }
}

///|
async test "close before the directional owner starts never calls I O" {
  for reading in [true, false] {
    let io = probe(bytes=b"unread")
    let socket = wrap(io, Ref(0))
    let conn : &@rt.Conn = socket
    let entered = Ref(false)
    @async.with_task_group(group => {
      let task = group.spawn(() => {
        entered.val = true
        if reading {
          assert_eq(conn.read(max_len=1), None)
        } else {
          try conn.write(b"unsent") catch {
            @mttp_core.TransportError(kind=Network, ..) => ()
            error => raise error
          } noraise {
            _ => fail("write on a closed connection succeeded")
          }
        }
      })
      while !entered.val {
        @async.pause()
      }
      // The operation has entered its group but its owner is still queued.
      assert_true(socket.cancel_read is None && socket.cancel_write is None)
      conn.close()
      task.wait()
    })
    assert_eq(io.limits, [])
    assert_eq(io.writes, [])
  }
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
