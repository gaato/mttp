///|
test "shared backend contract checks wrappers and canned stub" {
  let wrappers = @testing.run_sync(() => {
    @testing.check_backend_contract(() => {
      @client.from_handler(_ => @model.Response::new(200))
    })
  })
  assert_eq(wrappers, [])
  let stubs = @testing.run_sync(() => {
    @testing.check_backend_contract(() => @testing.BackendStub::new())
  })
  assert_eq(stubs, [])
}

///|
test "shared body contract checks deterministic feeds" {
  let d = @driver.Driver::new()
  assert_eq(
    d.run(() => {
      @testing.check_body_stream_contract(
        () => @feed.Feed::bytes(d, [b"a", b"bc"]),
        b"abc",
      )
    }),
    [],
  )
  assert_eq(
    d.run(() => {
      @testing.check_body_stream_contract(() => @feed.Feed::bytes(d, []), b"")
    }),
    [],
  )
}

///|
test "split checking covers empty and UTF-8 byte boundaries" {
  for bytes in [b"", b"a", b"\xe6\x97\xa5\r\n"] {
    @testing.check_splits(bytes, chunks => {
      let out = Buffer()
      for chunk in chunks {
        out.write_bytes(chunk)
      }
      out.to_bytes()
    })
  }
}

///|
priv struct BrokenBackend {
  errors : Bool
}

///|
impl @client.Backend for BrokenBackend with fn send(self, _, _) {
  if self.errors {
    raise @model.TransportError(kind=Network, phase=Head, detail="wrong kind")
  }
  @model.Response::new(200)
}

///|
test "backend contract rejects both acceptance and wrong failure kinds" {
  for errors in [false, true] {
    let failures = @testing.run_sync(() => {
      @testing.check_backend_contract(() => BrokenBackend::{ errors, })
    })
    assert_eq(failures.length(), 4)
    assert_eq(
      failures[0],
      if errors {
        "invalid request has wrong error kind"
      } else {
        "invalid request accepted"
      },
    )
  }
}

///|
priv struct BrokenStream {
  mode : Int32
  mut calls : Int32
}

///|
impl @model.BodyStream for BrokenStream with fn read_some(self) {
  self.calls += 1
  match self.mode {
    0 => Some(b"")
    1 => Some(b"too much")
    2 => if self.calls == 1 { None } else { Some(b"after EOF") }
    _ => Some(b"a")
  }
}

///|
impl @model.BodyStream for BrokenStream with fn close(_) {
  ()
}

///|
test "body contract rejects empty chunks overflow nonsticky EOF and ignored close" {
  for mode in [0, 1, 2, 3] {
    let failures = @testing.run_sync(() => {
      @testing.check_body_stream_contract(
        () => BrokenStream::{ mode, calls: 0, },
        b"ab",
        max_reads=2,
      )
    })
    assert_true(!failures.is_empty())
    assert_true(failures.contains("read after close is not EOF"))
    if mode == 0 {
      assert_true(failures.contains("empty body chunk"))
    }
    if mode == 1 {
      assert_true(failures.contains("body exceeds expected bytes"))
    }
    if mode == 2 {
      assert_true(failures.contains("EOF is not sticky"))
    }
    if mode == 3 {
      assert_true(
        failures.contains("stream did not reach EOF within read budget"),
      )
    }
  }
}

///|
test "split checker refuses a parser whose result depends on chunk count" {
  let rejected = try {
    @testing.check_splits(b"abc", chunks => chunks.length())
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
}
