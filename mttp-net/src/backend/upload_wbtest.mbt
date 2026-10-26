///|
priv struct FailedUpload {}

///|
impl @model.BodyStream for FailedUpload with fn read_some(_) {
  raise @model.TransportError(
    kind=Network,
    phase=Write,
    detail="upstream input failed",
  )
}

///|
impl @model.BodyStream for FailedUpload with fn close(_) {
  ()
}

///|
async test "a head deadline after an upload network failure retains the original write failure" {
  for malformed_head in [false, true] {
    let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer listener.close()
    let tcp = @socket.Tcp::connect(listener.addr)
    let (peer, _) = listener.accept()
    defer peer.close()
    let wire = Wire::new(@accepted.from_tcp(tcp))
    defer wire.close()
    let clock = ManualClock::new()
    let backend = H1Backend::new(trust_env=false, clock~)
    defer backend.close()
    let source = FailedUpload::{ }
    @async.with_task_group(group => {
      group.spawn_bg(() => {
        // A head timer is registered only after the upload has failed. Wait
        // for that observable phase instead of racing a 5 ms wall-clock sleep.
        while clock.started.get() != 20 {
          ()
        }
        if malformed_head {
          peer.write(b"not a response\r\n\r\n")
        } else {
          clock.wake.signal()
        }
      })
      try
        duplex(
          wire,
          Stream(@model.StreamBody::new(source)),
          Some(source),
          Some(b"x"),
          Chunked,
          phase_exchange(backend.clock, { ..backend.limits, read: 20, }),
          backend.head_limits,
        )
      catch {
        @model.TransportError(
          kind=Network,
          phase=Write,
          detail="upstream input failed"
        ) => ()
        error => raise error
      } noraise {
        _ => fail("network failure lost")
      }
    })
  }
}

///|
async test "a closed socket preserves a buffered final response and otherwise reports a network failure" {
  for response in [b"", b"HTTP/1.1 413 Too Large\r\nContent-Length: 0\r\n\r\n"] {
    let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer listener.close()
    let tcp = @socket.Tcp::connect(listener.addr)
    let (peer, _) = listener.accept()
    defer peer.close()
    tcp.close()
    let wire = Wire::{
      conn: @accepted.from_tcp(tcp),
      pending: response,
      closed: false,
    }
    defer wire.close()
    let backend = H1Backend::new(trust_env=false)
    defer backend.close()
    let result = Some(
      duplex(
        wire,
        Bytes(b"x"),
        None,
        None,
        Length(1L),
        phase_exchange(backend.clock, backend.limits),
        backend.head_limits,
      ),
    ) catch {
      @model.TransportError(kind=Network, phase=Write | Head, ..) => None
      error => raise Failure(error.message())
    }
    if response.is_empty() {
      assert_eq(result.map(x => x.1.status), None)
    } else {
      let (_, head, reusable) = result.unwrap()
      assert_eq(head.status, 413)
      assert_false(reusable)
    }
  }
}
