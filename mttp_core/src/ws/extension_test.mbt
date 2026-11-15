///|
priv struct TestExtension {
  encode_fn : (Bytes) -> (Bytes, Bool)
  decode_fn : (Bytes, Bool, Int32) -> Bytes raise @ws.WsError
}

///|
impl @ws.Extension for TestExtension with fn name(_) {
  "test-extension"
}

///|
impl @ws.Extension for TestExtension with fn encode(self, bytes) {
  (self.encode_fn)(bytes)
}

///|
impl @ws.Extension for TestExtension with fn decode(
  self,
  bytes,
  rsv1~,
  max_bytes~,
) {
  (self.decode_fn)(bytes, rsv1, max_bytes)
}

///|
test "extension runs per message with first frame RSV1 and enforces decoded bound plus one" {
  for n in [3, 4] {
    let d = @driver.Driver::new()
    let seen = []
    let ext = TestExtension::{
      encode_fn: b => (b, true),
      decode_fn: (b, r, limit) => {
        seen.push((b, r, limit))
        Bytes::make(n, 1)
      },
    }
    let conn = @sim.ScriptedConn::new([
      Chunk(
        packet(Binary, b"a", fin=false, rsv1=true) + packet(Continuation, b"b"),
      ),
    ])
    let s = session(d, conn, extension=ext, limits={
      ..limits(),
      max_message_bytes: 3,
    })
    if n == 3 {
      d.run(() => {
        assert_eq(s.recv(), @ws.Message::Binary(Bytes::make(n, 1)))
        s.abort()
      })
    } else {
      assert_true(recv_error(d, s) is @ws.WsError(kind=TooLarge(limit=3), ..))
      assert_eq(reply_code(conn.written()), 1009)
    }
    assert_eq(seen, [(b"ab", true, 3)])
    assert_eq((conn.closes(), d.live_tasks(), d.pending_timers()), (1, 0, 0))
  }
}

///|
test "encoded output obeys frame and wire message bounds and carries RSV1" {
  for size in [3, 4] {
    for frame_bound in [true, false] {
      let d = @driver.Driver::new()
      let seen = []
      let ext = TestExtension::{
        encode_fn: b => {
          seen.push(b)
          (Bytes::make(size, 9), true)
        },
        decode_fn: (b, _, _) => b,
      }
      let conn = @sim.ScriptedConn::new([])
      let l = if frame_bound {
        { ..limits(), max_frame_bytes: 3, }
      } else {
        { ..limits(), max_message_bytes: 3, }
      }
      let s = session(d, conn, extension=ext, limits=l)
      d.run(() => {
        let rejected = try {
          s.send(Binary(b"x"))
          false
        } catch {
          @ws.WsError(kind=TooLarge(limit=3), ..) => true
          e => raise e
        }
        assert_eq(rejected, size == 4)
        if size == 3 {
          let p = @frame.Parser::new(
            role=Server,
            max_frame_bytes=3,
            allow_rsv1=true,
          )
          p.feed(conn.written()[0])
          assert_true(
            p.next()
            is Some(
              Head({ fin: true, rsv1: true, opcode: Binary, length: 3L, .. })
            ),
          )
        } else {
          assert_eq(conn.written(), [])
        }
        s.abort()
      })
      assert_eq(seen, [b"x"])
      assert_eq((conn.closes(), d.live_tasks()), (1, 0))
    }
  }
}

///|
test "extension decoded text is UTF8 validated and extension errors close the session" {
  for failure in [false, true] {
    let d = @driver.Driver::new()
    let ext = TestExtension::{
      encode_fn: b => (b, true),
      decode_fn: (_, _, _) => {
        if failure {
          raise @ws.WsError(kind=TooLarge(limit=2), detail="extension limit")
        }
        b"\xff"
      },
    }
    let conn = @sim.ScriptedConn::new([Chunk(packet(Text, b"x", rsv1=true))])
    let s = session(d, conn, extension=ext)
    let _ = recv_error(d, s)
    assert_eq(reply_code(conn.written()), if failure { 1009 } else { 1007 })
    assert_eq(conn.closes(), 1)
  }
}

///|
test "a message committed before recv waiter cancellation is delivered on retry" {
  @sim.explore(schedule => {
    let d = @driver.Driver::new(schedule~)
    let task : Ref[@driver.Task?] = Ref(None)
    let ext = TestExtension::{
      encode_fn: b => (b, false),
      decode_fn: (b, _, _) => {
        if task.val is Some(t) {
          t.cancel()
        }
        b
      },
    }
    let conn = @sim.ScriptedConn::new([Chunk(packet(Text, b"saved"))])
    let s = session(d, conn, extension=ext)
    d.run(() => {
      let receiver = d.spawn(() => {
        let _ = s.recv()
      })
      task.val = Some(receiver)
      ignore(receiver.wait())
      assert_true(receiver.is_cancelled())
      assert_eq(conn.closes(), 0)
      task.val = None
      assert_eq(s.recv(), @ws.Message::Text("saved"))
      s.abort()
    })
    assert_eq((conn.closes(), d.live_tasks(), d.pending_timers()), (1, 0, 0))
  })
}
