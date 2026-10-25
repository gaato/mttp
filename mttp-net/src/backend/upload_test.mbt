///|
priv struct FirstRead {
  failing : Bool
  mut reads : Int32
  mut closed : Bool
}

///|
impl @model.BodyStream for FirstRead with fn read_some(self) {
  self.reads += 1
  if self.failing {
    raise @model.TransportError(
      kind=Unreplayable,
      phase=Write,
      detail="nested body already taken",
    )
  }
  None
}

///|
impl @model.BodyStream for FirstRead with fn close(self) {
  self.closed = true
}

///|
async test "stream ownership and first-read validation happen before any request bytes" {
  for mode in 0..<3 {
    let finished : @aqueue.Queue[Unit] = @aqueue.Queue(kind=Unbounded)
    with_server(
      conn => {
        assert_eq(conn.read_some(max_len=1), None)
        finished.put(())
      },
      url => {
        let backend = @backend.H1Backend::new(trust_env=false)
        defer backend.close()
        let stream = FirstRead::{ failing: true, reads: 0, closed: false, }
        let request = if mode == 0 {
          @model.Request::post(url).body_stream(
            Upload::{ bytes: Some(b"x"), closed: false, },
            length=0L,
          )
        } else if mode == 1 {
          @model.Request::post(url).body_stream(stream)
        } else {
          let cell = @model.StreamBody::new(stream)
          cell.take().close()
          { ..@model.Request::post(url), body: Stream(cell), }
        }
        try backend.send(request, @client.RequestOptions::default()) catch {
          @model.TransportError(kind=Protocol | Unreplayable, ..) => ()
          error => raise error
        } noraise {
          _ => fail("invalid stream was sent")
        }
        finished.get()
        assert_eq(backend.idle_connections(), 0)
        if mode != 0 {
          assert_true(stream.closed)
        }
      },
    )
  }
}

///|
async test "empty known and unknown length streams are read exactly once" {
  for length in [Some(0L), None] {
    let stream = FirstRead::{ failing: false, reads: 0, closed: false, }
    with_server(
      conn => {
        let head = conn.read_until("\r\n\r\n").unwrap()
        if length is None {
          assert_true(head.contains("transfer-encoding: chunked"))
          assert_eq(conn.read_exactly(5), b"0\r\n\r\n")
        } else {
          assert_true(head.contains("content-length: 0"))
        }
        conn.write(b"HTTP/1.1 204 No Content\r\n\r\n")
      },
      url => {
        let backend = @backend.H1Backend::new(trust_env=false)
        defer backend.close()
        backend
        .send(
          @model.Request::post(url).body_stream(stream, length?),
          @client.RequestOptions::default(),
        )
        .close()
        assert_eq(stream.reads, 1)
        assert_true(stream.closed)
      },
    )
  }
}
