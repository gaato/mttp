///|
// This workload owns one accepted socket. Splitting server writes preserves
// the old benchmark's two chunk sizes without exposing a runtime handle in
// a library API. TCP may coalesce writes; these are not packet sizes.
priv struct LoopbackConn {
  tcp : @socket.Tcp
  chunk_bytes : Int32
  mut closed : Bool
  mut eof : Bool
}

///|
impl @rt.Conn for LoopbackConn with fn read(self, max_len~) {
  if max_len <= 0 {
    raise @http.TransportError(
      kind=Invalid,
      phase=Body,
      detail="max_len must be positive",
    )
  }
  if self.closed || self.eof {
    return None
  }
  let buffer = FixedArray::make(max_len.min(65536), b'\x00')
  let n = self.tcp.read_into(buffer) catch {
    error =>
      raise @http.TransportError(
        kind=Network,
        phase=Body,
        detail=error.to_string(),
      )
  }
  self.eof = n == 0
  if self.eof {
    None
  } else {
    Some(Bytes::from_array(buffer[:n]))
  }
}

///|
impl @rt.Conn for LoopbackConn with fn write(self, bytes) {
  if self.closed {
    raise @http.TransportError(
      kind=Closed,
      phase=Body,
      detail="connection closed",
    )
  }
  for offset = 0; offset < bytes.length(); {
    let end = offset + (bytes.length() - offset).min(self.chunk_bytes)
    self.tcp.write(bytes[offset:end]) catch {
      error =>
        raise @http.TransportError(
          kind=Network,
          phase=Body,
          detail=error.to_string(),
        )
    }
    continue end
  }
}

///|
impl @rt.Conn for LoopbackConn with fn close(self) {
  if !self.closed {
    self.closed = true
    self.tcp.close()
  }
}

///|
async fn sample(chunk_bytes : Int32) -> Double {
  let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  defer listener.close()
  let result = Ref(0.0)
  @async.with_task_group(group => {
    let served = Ref(0)
    let remote = group.spawn(() => {
      let (tcp, _) = listener.accept()
      @h1server.serve_conn(
        LoopbackConn::{ tcp, chunk_bytes, closed: false, eof: false, },
        _ => {
          served.val += 1
          @http.Response::new(200, body=Bytes(b"pong"))
        },
        clock=@runtime.AsyncClock::new(),
        timer=@runtime.ClockTimer::new(),
        coordination=@runtime.RuntimeCoordination::new(),
        scheme="http",
        on_error=error => abort("\{Repr(error)}"),
      )
    })
    let backend = @backend.AsyncBackend::new(
      config=@h1client.ClientConfig::default(),
    )
    defer backend.close()
    let request = @http.Request::get(
      "http://127.0.0.1:\{listener.addr.port()}/",
    )
    let exchange : async () -> Unit = () => {
      let response = backend.send(request, @http.SendOptions::default())
      defer response.close()
      assert_eq(response.status, 200)
      let bytes = match response.body {
        Empty => b""
        Bytes(bytes) => bytes
        Stream(cell) => @http.read_bounded(cell.take(), 10)
        @http.Body::.. => abort("unsupported body kind")
      }
      assert_eq(bytes, b"pong")
    }
    for _ in 0..<32 {
      exchange()
    }
    let start = @bench.monotonic_clock_start()
    for _ in 0..<500 {
      exchange()
    }
    let us = @bench.monotonic_clock_end(start) / 500.0
    assert_eq(backend.idle_connections(), 1)
    backend.close()
    remote.wait()
    assert_eq(served.val, 532)
    result.val = us
  })
  result.val
}

///|
async fn main {
  for chunk_bytes in [65536, 1] {
    let samples = []
    for _ in 0..<3 {
      samples.push(sample(chunk_bytes))
    }
    samples.sort()
    println("loopback chunk=\{chunk_bytes} median_us_per_request=\{samples[1]}")
  }
}
