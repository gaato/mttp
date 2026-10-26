///|
priv struct Feed {
  chunks : Array[Bytes]
  mut reads : Int32
  mut closes : Int32
}

///|
impl @model.BodyStream for Feed with fn read_some(self) {
  let index = self.reads
  self.reads += 1
  self.chunks.get(index)
}

///|
impl @model.BodyStream for Feed with fn close(self) {
  self.closes += 1
}

///|
fn feed(chunks : Array[Bytes]) -> Feed {
  { chunks, reads: 0, closes: 0, }
}

///|
test "stream body take-once length and identity" {
  let source = feed([b"ab", b"c"])
  let body = @model.StreamBody::new(source, length=3)
  assert_eq(body.length(), Some(3))
  assert_eq(@model.Body::Stream(body).length(), Some(3))
  assert_eq(@model.Body::Stream(body).as_bytes(), None)
  assert_eq(
    body.to_repr().to_string(),
    "StreamBody(length=Some(3), taken=false)",
  )
  let request = @model.Request::post("/").body_stream(source, length=3)
  assert_eq(request.header("x", "1").body, request.body)
  assert_true(@model.Body::Stream(body).is_replayable())
  let stream = body.take()
  assert_false(@model.Body::Stream(body).is_replayable())
  @driver.run_sync(() => {
    assert_eq(stream.read_some(), Some(b"ab"))
    assert_eq(stream.read_some(), Some(b"c"))
    assert_eq(stream.read_some(), None)
    assert_eq(stream.read_some(), None)
    stream.close()
  })
  assert_eq(source.reads, 3)
  assert_eq(source.closes, 1)
  let refused = try {
    let _ = body.take()
    false
  } catch {
    @model.TransportError(kind=Unreplayable, ..) => true
    _ => false
  }
  assert_true(refused)
}

///|
test "discarding a response closes only a stream it still owns" {
  let unused = feed([b"data"])
  let unused_body = @model.StreamBody::new(unused)
  @model.Response::new(200, body=Stream(unused_body)).close_if_unclaimed()
  assert_eq(unused.closes, 1)
  assert_false(@model.Body::Stream(unused_body).is_replayable())

  let transferred = feed([b"data"])
  let body = @model.StreamBody::new(transferred)
  let reader = body.take()
  @model.Response::new(200, body=Stream(body)).close_if_unclaimed()
  assert_eq(transferred.closes, 0)
  @driver.run_sync(() => {
    assert_eq(reader.read_some(), Some(b"data"))
    reader.close()
  })
  assert_eq(transferred.closes, 1)
}

///|
test "closing a response before acquisition consumes its stream" {
  let source = feed([b"x"])
  let stream = @model.StreamBody::new(source)
  @model.Response::new(200, body=Stream(stream)).close()
  assert_eq(source.closes, 1)
  let refused = try {
    let _ = stream.take()
    false
  } catch {
    _ => true
  }
  assert_true(refused)
}

///|
test "stream body rejects negative short long and empty chunks" {
  let negative = feed([])
  let refused = try {
    let _ = @model.StreamBody::new(negative, length=-1).take()
    false
  } catch {
    @model.TransportError(kind=Invalid, ..) => true
    _ => false
  }
  assert_true(refused)
  assert_eq(negative.reads, 0)
  assert_eq(negative.closes, 1)
  for chunks in [[b"a"], [b"abc"], [b""]] {
    let source = feed(chunks)
    let stream = @model.StreamBody::new(source, length=2).take()
    let refused = try {
      @driver.run_sync(() => {
        while stream.read_some() is Some(_) {
          ()
        }
      })
      false
    } catch {
      @model.TransportError(kind=Protocol, ..) => true
      _ => false
    }
    assert_true(refused)
    assert_eq(source.closes, 1)
    assert_eq(@driver.run_sync(() => stream.read_some()), None)
  }
}

///|
test "read bounded accepts exact limit and closes at crossing chunk" {
  for limit in [0, 1, 2] {
    let source = feed([b"a", b"b"])
    let result = Some(
      @driver.run_sync(() => @model.read_bounded(source, limit)),
    ) catch {
      @model.TransportError(kind=TooLarge(..), ..) => None
      e => raise e
    }
    assert_eq(result, if limit == 2 { Some(b"ab") } else { None })
    assert_eq(source.reads, limit + 1)
    assert_eq(source.closes, 1)
  }
  let source = feed([])
  assert_eq(@driver.run_sync(() => @model.read_bounded(source, 0)), b"")
  assert_eq(source.closes, 1)
}

///|
test "read bounded closes on invalid limits and empty chunks" {
  for limit in [-1, 1] {
    let source = feed([b""])
    let refused = try {
      let _ = @driver.run_sync(() => @model.read_bounded(source, limit))
      false
    } catch {
      _ => true
    }
    assert_true(refused)
    assert_eq(source.reads, if limit < 0 { 0 } else { 1 })
    assert_eq(source.closes, 1)
  }
}
