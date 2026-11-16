///|
priv struct LiveOutput {
  changed : @cond_var.Cond
  release : Ref[Bool]
  mut pulls : Int32
  mut closes : Int32
}

///|
impl @mttp_core.BodyStream for LiveOutput with fn read_some(self) {
  self.pulls += 1
  match self.pulls {
    1 => Some(b"first")
    2 => {
      self.changed.broadcast()
      while !self.release.val {
        self.changed.wait()
      }
      Some(b"last")
    }
    _ => None
  }
}

///|
impl @mttp_core.BodyStream for LiveOutput with fn close(self) {
  self.closes += 1
}

///|
async test "shutdown preserves streamed response through its final chunk and closes it once" {
  let changed = @cond_var.Cond()
  let output = LiveOutput::{
    changed,
    release: Ref(false),
    pulls: 0,
    closes: 0,
  }
  let calls = Ref(0)
  controllable(
    _ => {
      calls.val += 1
      @mttp_core.Response::new(
        200,
        body=Stream(@mttp_core.StreamBody::new(output)),
      )
    },
    { ..@h1server.ServerLimits::default(), drain_ms: 1000, },
    (address, server) => {
      let tcp = @socket.Tcp::connect(@socket.Addr::parse(address))
      defer tcp.close()
      tcp.write(
        b"GET / HTTP/1.1\r\nHost: x\r\n\r\nGET /later HTTP/1.1\r\nHost: x\r\n\r\n",
      )
      assert_true(
        tcp.read_until(b"\r\n\r\n").unwrap().has_prefix(b"HTTP/1.1 200"),
      )
      while output.pulls < 2 {
        changed.wait()
      }
      server.cancel()
      @async.pause()
      assert_eq(output.closes, 0)
      output.release.val = true
      changed.broadcast()
      let body = tcp.read_all()
      assert_eq(body, b"5\r\nfirst\r\n4\r\nlast\r\n0\r\n\r\n")
      stopped(server)
      assert_eq(output.closes, 1)
      assert_eq(calls.val, 1)
    },
  )
}

///|
async test "shutdown ends a close_on_shutdown stream well before the drain time" {
  let output = LiveOutput::{
    changed: @cond_var.Cond(),
    release: Ref(false),
    pulls: 0,
    closes: 0,
  }
  controllable(
    _ => {
      let response = @mttp_core.Response::new(
        200,
        body=Stream(@mttp_core.StreamBody::new(output)),
      )
      {
        ..response,
        attributes: response.attributes.put(@mttp_core.close_on_shutdown, true),
      }
    },
    // Neither the drain time nor the body deadline can end the stream within
    // the test's three seconds; only the shutdown cut can.
    {
      ..@h1server.ServerLimits::default(),
      drain_ms: 10000,
      body_timeout_ms: 60000,
    },
    (address, server) => {
      let tcp = @socket.Tcp::connect(@socket.Addr::parse(address))
      defer tcp.close()
      tcp.write(b"GET / HTTP/1.1\r\nHost: x\r\n\r\n")
      assert_true(
        tcp.read_until(b"\r\n\r\n").unwrap().has_prefix(b"HTTP/1.1 200"),
      )
      while output.pulls < 2 {
        output.changed.wait()
      }
      server.cancel()
      @async.with_timeout(1000, () => {
        assert_eq(tcp.read_all(), b"5\r\nfirst\r\n0\r\n\r\n")
        stopped(server)
      })
      assert_eq(output.pulls, 2)
      assert_eq(output.closes, 1)
    },
  )
}

///|
async test "zero grace cancels streamed output and joins producer cleanup" {
  let output = LiveOutput::{
    changed: @cond_var.Cond(),
    release: Ref(false),
    pulls: 0,
    closes: 0,
  }
  controllable(
    _ => {
      @mttp_core.Response::new(
        200,
        body=Stream(@mttp_core.StreamBody::new(output)),
      )
    },
    { ..@h1server.ServerLimits::default(), drain_ms: 0, },
    (address, server) => {
      let tcp = @socket.Tcp::connect(@socket.Addr::parse(address))
      defer tcp.close()
      tcp.write(b"GET / HTTP/1.1\r\nHost: x\r\n\r\n")
      while output.pulls < 2 {
        output.changed.wait()
      }
      server.cancel()
      stopped(server)
      assert_eq(output.closes, 1)
    },
  )
}

///|
async test "HEAD empty and zero length streams release leases and preserve pipelining" {
  let output = LiveOutput::{
    changed: @cond_var.Cond(),
    release: Ref(true),
    pulls: 2,
    closes: 0,
  }
  let calls = Ref(0)
  with_server(
    _ => {
      calls.val += 1
      @mttp_core.Response::new(
        if calls.val == 5 {
          304
        } else {
          200
        },
        body=match calls.val {
          1 | 4 | 5 => Empty
          2 => Bytes(b"")
          _ => Stream(@mttp_core.StreamBody::new(output, length=0L))
        },
      )
    },
    address => {
      let result = raw(
        address, b"GET / HTTP/1.1\r\nHost: x\r\n\r\nGET / HTTP/1.1\r\nHost: x\r\n\r\nHEAD / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
      )
      assert_eq(result.split("HTTP/1.1 200").count(), 4)
      assert_eq(output.pulls, 2)
      assert_eq(output.closes, 1)
      let head = raw(
        address, b"HEAD / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
      )
      assert_true(head.has_prefix("HTTP/1.1 200"))
      assert_false(head.to_lower().contains("content-length"))
      let cached = raw(
        address, b"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
      )
      assert_true(cached.has_prefix("HTTP/1.1 304"))
      assert_false(cached.to_lower().contains("content-length"))
    },
  )
}

///|
async test "shutdown keeps a large Bytes response active through its final write" {
  for marked in [false, true] {
    let body = Bytes::make(8 * 1024 * 1024, b'x')
    let calls = Ref(0)
    controllable(
      _ => {
        calls.val += 1
        let response = @mttp_core.Response::new(200, body=Bytes(body))
        {
          ..response,
          attributes: response.attributes.put(
            @mttp_core.close_on_shutdown, marked,
          ),
        }
      },
      { ..@h1server.ServerLimits::default(), drain_ms: 1000, },
      (address, server) => {
        let tcp = @socket.Tcp::connect(@socket.Addr::parse(address))
        defer tcp.close()
        tcp.write(
          b"GET / HTTP/1.1\r\nHost: x\r\n\r\nGET /later HTTP/1.1\r\nHost: x\r\n\r\n",
        )
        assert_true(
          tcp.read_until(b"\r\n\r\n").unwrap().has_prefix(b"HTTP/1.1 200"),
        )
        server.cancel()
        assert_eq(tcp.read_all(), body)
        stopped(server)
        assert_eq(calls.val, 1)
      },
    )
  }
}

///|
async test "a Bytes response to a peer that stops reading expires in phase Write" {
  let body = Bytes::make(8 * 1024 * 1024, b'x')
  let errors : Array[@mttp_core.TransportError] = []
  let changed = @cond_var.Cond()
  controllable(
    _ => @mttp_core.Response::new(200, body=Bytes(body)),
    { ..@h1server.ServerLimits::default(), body_timeout_ms: 50, },
    (address, server) => {
      let tcp = @socket.Tcp::connect(@socket.Addr::parse(address))
      defer tcp.close()
      tcp.write(b"GET / HTTP/1.1\r\nHost: x\r\n\r\n")
      assert_true(
        tcp.read_until(b"\r\n\r\n").unwrap().has_prefix(b"HTTP/1.1 200"),
      )
      while errors.is_empty() {
        changed.wait()
      }
      assert_true(
        errors[0]
        is @mttp_core.TransportError(kind=Timeout(ms=50), phase=Write, ..),
      )
      let partial = tcp.read_all()
      assert_true(partial.length() < body.length())
      assert_eq(partial, body[:partial.length()].to_owned())
      server.cancel()
      stopped(server)
      assert_eq(errors.length(), 1)
    },
    on_error=error => {
      errors.push(error)
      changed.broadcast()
    },
  )
}

///|
async test "close_on_shutdown still cuts Bytes before its first write when already stopping" {
  let entered = Ref(false)
  let released = Ref(false)
  let changed = @cond_var.Cond()
  controllable(
    request => {
      if request.url.has_suffix("/idle") {
        return @mttp_core.Response::new(204)
      }
      entered.val = true
      changed.broadcast()
      while !released.val {
        changed.wait()
      }
      let response = @mttp_core.Response::new(200, body=Bytes(b"cut"))
      {
        ..response,
        attributes: response.attributes.put(@mttp_core.close_on_shutdown, true),
      }
    },
    { ..@h1server.ServerLimits::default(), drain_ms: 1000, },
    (address, server) => {
      let idle = @socket.Tcp::connect(@socket.Addr::parse(address))
      defer idle.close()
      idle.write(b"GET /idle HTTP/1.1\r\nHost: x\r\n\r\n")
      assert_true(
        idle.read_until(b"\r\n\r\n").unwrap().has_prefix(b"HTTP/1.1 204"),
      )
      let tcp = @socket.Tcp::connect(@socket.Addr::parse(address))
      defer tcp.close()
      tcp.write(b"GET / HTTP/1.1\r\nHost: x\r\n\r\n")
      while !entered.val {
        changed.wait()
      }
      server.cancel()
      // Idle closure proves Stop has been applied, without a clock delay.
      assert_eq(idle.read(), None)
      released.val = true
      changed.broadcast()
      let head = @utf8.decode(tcp.read_until(b"\r\n\r\n").unwrap())
      assert_true(head.has_prefix("HTTP/1.1 200"))
      assert_true(head.contains("content-length: 3"))
      assert_true(head.contains("connection: close"))
      assert_eq(tcp.read_all(), b"")
      stopped(server)
    },
  )
}
