///|
async fn controllable(
  handler : @mttp.Handler,
  limits : @h1server.ServerLimits,
  run : async (String, @async.Task[Unit]) -> Unit,
  on_error~ : (@mttp.TransportError) -> Unit = _ => (),
) -> Unit {
  @async.with_timeout(3000, () => {
    @async.with_task_group(group => {
      let ready : Ref[String?] = Ref(None)
      let wake = @cond_var.Cond()
      let server = group.spawn(no_wait=true, allow_failure=true, () => {
        @server.serve(handler, addr="127.0.0.1:0", limits~, on_error~, on_listen=address => {
          ready.val = Some(address)
          wake.signal()
        })
      })
      while ready.val is None {
        wake.wait()
      }
      run(ready.val.unwrap(), server)
    })
  })
}

///|
async fn stopped(task : @async.Task[Unit]) -> Unit {
  task.wait() catch {
    @async.WaitedTaskAlreadyCancelled => ()
    error => raise error
  }
}

///|
async test "graceful shutdown lets an active handler finish and cancels idle accepts" {
  let entered = Ref(false)
  let released = Ref(false)
  let completed = Ref(false)
  let wake = @cond_var.Cond()
  controllable(
    _ => {
      entered.val = true
      wake.broadcast()
      while !released.val {
        wake.wait()
      }
      completed.val = true
      @mttp.Response::new(200, body=Bytes(b"finished"))
    },
    { ..@h1server.ServerLimits::default(), drain_ms: 1000, },
    (address, server) => {
      let tcp = @socket.Tcp::connect(@socket.Addr::parse(address))
      defer tcp.close()
      tcp.write(b"GET / HTTP/1.1\r\nHost: x\r\n\r\n")
      while !entered.val {
        wake.wait()
      }
      server.cancel()
      @async.pause()
      assert_false(completed.val)
      released.val = true
      wake.broadcast()
      let out = Buffer()
      while tcp.read() is Some(bytes) {
        out.write_bytes(bytes)
      }
      assert_true(@utf8.decode(out.to_bytes()).has_suffix("finished"))
      stopped(server)
      assert_true(completed.val)
    },
  )
  // Protocol refusals are active responses too, before a handler can run.
  let stop : Ref[(() -> Unit)?] = Ref(None)
  controllable(
    _ => @mttp.Response::new(200),
    { ..@h1server.ServerLimits::default(), drain_ms: 1000, },
    (address, server) => {
      stop.val = Some(() => server.cancel())
      let response = raw(
        address, b"GET / HTTP/1.1\r\nHost: x\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\n",
      )
      assert_true(response.has_prefix("HTTP/1.1 400"))
      stopped(server)
    },
    on_error=_ => stop.val.unwrap()(),
  )
}

///|
async test "grace expiry cancels handler and response-independent background tasks" {
  for background in [false, true] {
    let started = Ref(false)
    let cleaned = Ref(false)
    let wake = @cond_var.Cond()
    controllable(
      request => {
        if background {
          if request.attributes.get(@mttp.background) is Some(schedule) {
            schedule(() => {
              defer {
                cleaned.val = true
              }
              started.val = true
              wake.signal()
              @async.sleep(10000)
            })
          }
        } else {
          defer {
            cleaned.val = true
          }
          started.val = true
          wake.signal()
          @async.sleep(10000)
        }
        @mttp.Response::new(200)
      },
      { ..@h1server.ServerLimits::default(), drain_ms: 20, },
      (address, server) => {
        let tcp = @socket.Tcp::connect(@socket.Addr::parse(address))
        defer tcp.close()
        tcp.write(b"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
        while !started.val {
          wake.wait()
        }
        if background {
          assert_true(
            tcp.read_until(b"\r\n\r\n").unwrap().has_prefix(b"HTTP/1.1 200"),
          )
        }
        assert_false(cleaned.val)
        server.cancel()
        stopped(server)
        assert_true(cleaned.val)
      },
    )
  }
}

///|
async test "connection cap holds later requests until the active exchange finishes" {
  let calls = Ref(0)
  let release = Ref(false)
  let wake = @cond_var.Cond()
  controllable(
    _ => {
      calls.val += 1
      wake.broadcast()
      while !release.val {
        wake.wait()
      }
      @mttp.Response::new(204)
    },
    { ..@h1server.ServerLimits::default(), max_connections: 1, },
    (address, server) => {
      let first = @socket.Tcp::connect(@socket.Addr::parse(address))
      defer first.close()
      first.write(b"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
      while calls.val == 0 {
        wake.wait()
      }
      let second = @socket.Tcp::connect(@socket.Addr::parse(address))
      defer second.close()
      second.write(b"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
      @async.sleep(10)
      assert_eq(calls.val, 1)
      release.val = true
      wake.broadcast()
      assert_true(
        first.read_until(b"\r\n\r\n").unwrap().has_prefix(b"HTTP/1.1 204"),
      )
      assert_true(
        second.read_until(b"\r\n\r\n").unwrap().has_prefix(b"HTTP/1.1 204"),
      )
      assert_eq(calls.val, 2)
      server.cancel()
      stopped(server)
    },
  )
}
