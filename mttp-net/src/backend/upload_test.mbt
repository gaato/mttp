///|
priv struct SlowUpload {
  mut reads : Int32
  mut closes : Int32
  fail : Bool
}

///|
impl @model.BodyStream for SlowUpload with fn read_some(self) {
  self.reads += 1
  if self.reads == 1 {
    return Some(b"x")
  }
  if self.fail {
    raise @model.TransportError(
      kind=Unreplayable,
      phase=Write,
      detail="producer refused",
    )
  }
  @async.sleep(80)
  None
}

///|
impl @model.BodyStream for SlowUpload with fn close(self) {
  self.closes += 1
}

///|
async test "early final responses stop uploads and exclude their sockets from reuse" {
  for streamed in [true, false] {
    let source = SlowUpload::{ reads: 0, closes: 0, fail: false, }
    with_server(
      conn => {
        ignore(conn.read_until("\r\n\r\n"))
        conn.write(
          b"HTTP/1.1 413 Content Too Large\r\nContent-Length: 3\r\n\r\nno!",
        )
        // Retain the peer until the client has consumed the final response.
        // This also proves that nonreuse does not depend on Connection: close.
        while conn.read_some() is Some(_) {
          ()
        }
      },
      url => {
        let backend = @backend.H1Backend::new(trust_env=false)
        defer backend.close()
        let request = if streamed {
          @model.Request::post(url).body_stream(source)
        } else {
          @model.Request::post(url).body_bytes(
            Bytes::make(16 * 1024 * 1024, b'x'),
          )
        }
        let response = backend.send(request, @client.RequestOptions::default())
        assert_eq(response.status, 413)
        assert_eq(body(response), b"no!")
        assert_eq(backend.idle_connections(), 0)
        if streamed {
          assert_eq(source.closes, 1)
        }
      },
    )
  }
}

///|
async test "informational heads do not end uploads or start the response idle timeout" {
  let source = SlowUpload::{ reads: 0, closes: 0, fail: false, }
  with_server(
    conn => {
      ignore(conn.read_until("\r\n\r\n"))
      conn.write(
        b"HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 103 Early Hints\r\n\r\n",
      )
      assert_eq(conn.read_exactly(11), b"1\r\nx\r\n0\r\n\r\n")
      conn.write(b"HTTP/1.1 204 No Content\r\n\r\n")
    },
    url => {
      let backend = @backend.H1Backend::new(trust_env=false)
      defer backend.close()
      let response = backend.send(
        @model.Request::post(url).body_stream(source),
        { ..@client.RequestOptions::default(), read_idle_ms: Some(20), },
      )
      assert_eq(response.status, 204)
      response.close()
      assert_eq(source.reads, 2)
      assert_eq(source.closes, 1)
      assert_eq(backend.idle_connections(), 1)
    },
  )
}

///|
async test "upload producer errors retain their kind and release ownership" {
  let source = SlowUpload::{ reads: 0, closes: 0, fail: true, }
  with_server(
    conn => {
      while conn.read_some() is Some(_) {
        ()
      }
    },
    url => {
      let backend = @backend.H1Backend::new(trust_env=false)
      defer backend.close()
      try
        backend.send(
          @model.Request::post(url).body_stream(source),
          @client.RequestOptions::default(),
        )
      catch {
        @model.TransportError(kind=Unreplayable, phase=Write, ..) => ()
        error => raise error
      } noraise {
        _ => fail("producer error lost")
      }
      assert_eq(source.closes, 1)
      assert_eq(backend.idle_connections(), 0)
    },
  )
}

///|
async test "response head idle deadline applies after a successful upload" {
  with_server(
    conn => {
      ignore(conn.read_until("\r\n\r\n"))
      while conn.read_some() is Some(_) {
        ()
      }
    },
    url => {
      let backend = @backend.H1Backend::new(trust_env=false)
      defer backend.close()
      try
        backend.send(@model.Request::get(url), {
          ..@client.RequestOptions::default(),
          read_idle_ms: Some(20),
        })
      catch {
        @model.TransportError(kind=Timeout(ms=20), phase=Head, ..) => ()
        error => raise error
      } noraise {
        _ => fail("head deadline ignored")
      }
      assert_eq(backend.idle_connections(), 0)
    },
  )
}

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
