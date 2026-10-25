///|
async test "concurrent background jobs report failures and remain owned after the response" {
  let started = Ref(0)
  let release = Ref(false)
  let errors : Array[@server.ServeError] = []
  let cleaned = Ref(0)
  let wake = @cond_var.Cond()
  with_server(
    req => {
      if req.attributes.get(@model.background) is Some(schedule) {
        for _ in 0..<2 {
          schedule(() => {
            defer {
              cleaned.val += 1
            }
            started.val += 1
            wake.broadcast()
            while !release.val {
              wake.wait()
            }
            raise Failure("application detail")
          })
        }
      }
      @model.Response::new(204)
    },
    address => {
      assert_true(
        raw(address, b"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n").has_prefix(
          "HTTP/1.1 204",
        ),
      )
      while started.val < 2 {
        wake.wait()
      }
      assert_eq(cleaned.val, 0)
      release.val = true
      wake.broadcast()
      while errors.length() < 2 {
        wake.wait()
      }
      assert_eq(cleaned.val, 2)
      assert_eq(errors[0].phase, @model.Unknown)
      assert_false(errors[0].detail.contains("application detail"))
    },
    on_error=error => {
      errors.push(error)
      wake.broadcast()
    },
  )
}

///|
async test "read-ahead preserves a pipelined request arriving during a suspended handler" {
  let entered = Ref(false)
  let release = Ref(false)
  let calls = Ref(0)
  let wake = @cond_var.Cond()
  with_server(
    _ => {
      calls.val += 1
      entered.val = true
      wake.broadcast()
      while !release.val {
        wake.wait()
      }
      @model.Response::new(204)
    },
    address => {
      let tcp = @socket.Tcp::connect(@socket.Addr::parse(address))
      defer tcp.close()
      tcp.write(b"GET /one HTTP/1.1\r\nHost: x\r\n\r\n")
      while !entered.val {
        wake.wait()
      }
      tcp.write(b"GET /two HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
      @async.sleep(5)
      release.val = true
      wake.broadcast()
      let out = Buffer()
      while tcp.read_some(max_len=4096) is Some(bytes) {
        out.write_bytes(bytes)
      }
      assert_eq(@utf8.decode(out.to_bytes()).split("HTTP/1.1 204").count(), 3)
      assert_eq(calls.val, 2)
    },
  )
}
