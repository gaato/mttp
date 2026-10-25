///|
priv struct EncoderSource {
  driver : @driver.Driver
  closes : Ref[Int32]
  wait : Bool
  fail : Bool
  mut sent : Bool
}

///|
impl @model.BodyStream for EncoderSource with fn read_some(self) {
  if self.wait {
    self.driver.sleep(1000)
  }
  if self.fail {
    raise @model.TransportError(
      kind=Network,
      phase=Body,
      detail="upstream failed",
    )
  }
  if self.sent {
    None
  } else {
    self.sent = true
    Some(b"hello")
  }
}

///|
impl @model.BodyStream for EncoderSource with fn close(self) {
  self.closes.val += 1
}

///|
test "encoded bodies close upstream on EOF failure and cancellation" {
  let driver = @driver.Driver::new(auto_advance=false)
  for (wait, should_fail) in [(false, false), (false, true), (true, false)] {
    let closes = Ref(0)
    let source = @model.Stream(
      @model.StreamBody::new(EncoderSource::{
        driver,
        closes,
        wait,
        fail: should_fail,
        sent: false,
      }),
    )
    let body = @codings.encode_body(source, Gzip)
    assert_eq(closes.val, 0)
    guard body is Stream(stream) else { fail("expected stream") }
    let reader = stream.take()
    driver.run(() => {
      let task = driver.spawn(() => {
        let failed = try {
          while reader.read_some() is Some(_) {

          }
          false
        } catch {
          @model.TransportError(kind=Network, ..) => true
          error => raise error
        }
        assert_eq(failed, should_fail)
      })
      driver.pause()
      if wait {
        task.cancel()
      }
      assert_eq(task.wait(), !wait)
    })
    reader.close()
    stream.close()
    assert_eq(closes.val, 1)
  }
}

///|
test "encoded buffered bodies decode incrementally and explicit close is lazy" {
  let driver = @driver.Driver::new()
  driver.run(() => {
    for body in [@model.Empty, @model.Bytes(b"hello")] {
      guard @codings.encode_body(body, Gzip) is Stream(stream) else {
        fail("expected stream")
      }
      let reader = stream.take()
      let decoder = @codings.ContentDecoder::new([Gzip])
      let out = Buffer()
      while @codings.read_decoded(() => reader.read_some(), Some(decoder))
            is Some(bytes) {
        out.write_bytes(bytes)
      }
      assert_eq(out.to_bytes(), body.as_bytes().unwrap_or(b""))
    }
    let closes = Ref(0)
    let source = @model.Stream(
      @model.StreamBody::new(EncoderSource::{
        driver,
        closes,
        wait: true,
        fail: false,
        sent: false,
      }),
    )
    guard @codings.encode_body(source, Deflate) is Stream(stream) else {
      fail("expected stream")
    }
    stream.close()
    assert_eq(closes.val, 1)
  })
}

///|
test "content encoders roundtrip split input and finish empty streams" {
  @driver.run_sync(() => {
    for coding in [@codings.Gzip, @codings.Deflate, @codings.Brotli] {
      for chunks in [[], [b""], [b"a", b"bc", b"def"], [b"abcdef"]] {
        let encoder = @codings.ContentEncoder::new(coding)
        let offset = Ref(0)
        let wire = Buffer()
        while @codings.read_encoded(
                () => {
                  let next = chunks.get(offset.val)
                  offset.val += 1
                  next
                },
                encoder,
              )
              is Some(bytes) {
          assert_true(bytes.length() > 0 && bytes.length() <= 65536)
          wire.write_bytes(bytes)
        }
        let encoded = wire.to_bytes()
        assert_true(encoded.length() > 0)
        let decoder = @codings.ContentDecoder::new([coding])
        let supplied = Ref(false)
        let decoded = Buffer()
        while @codings.read_decoded(
                () => {
                  if supplied.val {
                    None
                  } else {
                    supplied.val = true
                    Some(encoded)
                  }
                },
                Some(decoder),
              )
              is Some(bytes) {
          decoded.write_bytes(bytes)
        }
        let expected = Buffer()
        for chunk in chunks {
          expected.write_bytes(chunk)
        }
        assert_eq(decoded.to_bytes(), expected.to_bytes())
        assert_true(encoder.pull() is Done)
        encoder.end()
      }
    }
  })
}

///|
test "encoder refuses overwrite premature end unsupported coding and input after EOF" {
  let encoder = @codings.ContentEncoder::new(Gzip)
  encoder.feed(b"pending")
  for
    action in [
      () => encoder.feed(b"lost"),
      () => encoder.end(),
      () => ignore(@codings.ContentEncoder::new(Zstd)),
    ] {
    let refused = try {
      action()
      false
    } catch {
      @model.TransportError(kind=Invalid, ..) => true
      _ => false
    }
    assert_true(refused)
  }
  while encoder.pull() is Slice(_) {

  }
  encoder.end()
  let refused = try {
    encoder.feed(b"late")
    false
  } catch {
    @model.TransportError(kind=Invalid, ..) => true
    _ => false
  }
  assert_true(refused)
}

///|
test "sync flushed chunks can be decoded before upstream EOF" {
  for coding in [@codings.Gzip, @codings.Deflate, @codings.Brotli] {
    let encoder = @codings.ContentEncoder::new(coding)
    encoder.feed(b"data: hello\n\n")
    let wire = Buffer()
    while encoder.pull() is Slice(bytes) {
      wire.write_bytes(bytes)
    }
    let decoder = @codings.ContentDecoder::new([coding])
    decoder.feed(wire.to_bytes())
    let out = Buffer()
    while decoder.pull() is Slice(bytes) {
      out.write_bytes(bytes)
    }
    assert_eq(out.to_bytes(), b"data: hello\n\n")
  }
}
