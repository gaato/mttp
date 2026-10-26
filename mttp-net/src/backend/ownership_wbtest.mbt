///|
async test "body close and framing error release the active slot exactly once" {
  for malformed in [false, true] {
    let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer server.close()
    @async.with_timeout(5000, () => {
      @async.with_task_group(group => {
        group.spawn_bg(no_wait=true, () => {
          let (conn, _) = server.accept()
          defer conn.close()
          ignore(conn.read_until("\r\n\r\n"))
          conn.write(b"HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nx")
        })
        let backend = H1Backend::new(trust_env=false, max_connections=1)
        defer backend.close()
        let response = backend.send(
          @model.Request::get("http://127.0.0.1:\{server.addr.port()}/"),
          @client.RequestOptions::default(),
        )
        assert_eq(backend.slots.control.in_use, 1)
        if malformed {
          guard response.body is Stream(stream) else { fail("expected stream") }
          try @model.read_bounded(stream.take(), 100) catch {
            @model.TransportError(kind=Protocol, ..) => ()
            error => raise error
          } noraise {
            _ => fail("expected premature EOF")
          }
        }
        response.close()
        response.close()
        assert_eq(backend.slots.control.in_use, 0)
        assert_eq(backend.slots.control.per_origin.length(), 0)
        assert_eq(backend.pool.count(), 0)
      })
    })
  }
}

///|
test "idle pool total bound also bounds the origin index" {
  assert_eq(H1Backend::new(trust_env=false).pool.control.max_total, 256)
  assert_eq(H1Backend::new(trust_env=false).pool.control.max_per_origin, 4)
  let pool : IdlePool[Int32] = IdlePool::new(
    max_total=2,
    max_per_origin=4,
    idle_max_ms=100,
  )
  assert_eq(pool.put("a", None, 1, now=0L), [])
  assert_eq(pool.put("b", None, 2, now=0L), [])
  assert_eq(pool.put("c", None, 3, now=0L), [3])
  assert_eq(pool.control.parked.length(), 2)
  let evicted = pool.put("c", None, 4, now=100L)
  // Both origins expire; their map traversal order is not a pool contract.
  evicted.sort()
  assert_eq(evicted, [1, 2])
  assert_eq(pool.count(), 1)
  assert_eq(pool.control.parked.length(), 1)
}
