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
  wait_write : Bool
  mut writing : Bool
  mut cleaned : Bool
}

///|
fn probe(
  bytes~ : Bytes = b"",
  fail_read~ : Bool = false,
  fail_write~ : Bool = false,
  wait_write~ : Bool = false,
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
    wait_write,
    writing: false,
    cleaned: false,
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
  self.limits.push(max_len)
  if self.fail_read {
    raise Injected
  }
  let count = (self.bytes.length() - self.offset).min(max_len)
  for i in 0..<count {
    out[offset + i] = self.bytes[self.offset + i]
  }
  self.offset += count
  count
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
  self.writes.push(bytes[offset:offset + len].to_owned())
  len
}

///|
impl @io.BinaryReader for ProbeIo

///|
impl @io.BinaryWriter for ProbeIo

///|
fn wrap(io : ProbeIo, closes : Ref[Int32]) -> SocketConn[ProbeIo, ProbeIo] {
  {
    reader: io,
    writer: io,
    close_: () => closes.val += 1,
    closed: false,
    eof: false,
    cancel_read: None,
    cancel_write: None,
  }
}

///|
async test "socket read and write bounds EOF halves and close errors" {
  let io = probe(bytes=Bytes::make(65537, b'x'))
  let closes = Ref(0)
  let conn : &@rt.Conn = wrap(io, closes)
  for invalid in [0, -1] {
    try conn.read(max_len=invalid) catch {
      @http.TransportError(kind=Invalid, phase=Unknown, ..) => ()
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
    @http.TransportError(kind=Closed, phase=Unknown, ..) => ()
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
      @http.TransportError(kind=Network, phase=Unknown, ..) => ()
      error => raise error
    } noraise {
      _ => fail("runtime error lost")
    }
  }
  let original = @http.TransportError(
    kind=Timeout(ms=7),
    phase=Write,
    detail="original",
  )
  assert_true(
    transport_error(original)
    is @http.TransportError(kind=Timeout(ms=7), phase=Write, detail="original"),
  )
}

///|
async test "closing socket cancels a pending write and joins cleanup" {
  let io = probe(wait_write=true)
  let closes = Ref(0)
  let conn : &@rt.Conn = wrap(io, closes)
  let failed = Ref(false)
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      conn.write(b"pending") catch {
        @http.TransportError(kind=Closed, phase=Unknown, ..) =>
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
