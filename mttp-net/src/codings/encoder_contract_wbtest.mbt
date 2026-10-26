///|
priv struct QuietEncoder {
  fail : Bool
}

///|
impl @codec_bytes.Encode for QuietEncoder with fn step(self, _, _, action~) {
  if self.fail {
    raise @codec_bytes.CodecError::CodecError(
      @codec_bytes.ErrorKind::Corrupt,
      "injected codec failure",
    )
  }
  if action is Finish {
    Done
  } else {
    NeedMoreInput
  }
}

///|
impl @codec_bytes.Encode for QuietEncoder with fn last_consumed(_) {
  0
}

///|
impl @codec_bytes.Encode for QuietEncoder with fn last_produced(_) {
  0
}

///|
impl @codec_bytes.Encode for QuietEncoder with fn reset(_) {

}

///|
impl @codec_bytes.Encode for QuietEncoder with fn memory_usage(_) {
  0
}

///|
test "encoded body direct close is idempotent and makes EOF sticky" {
  let closes = Ref(0)
  let body = EncodedBody::{
    read: () => None,
    close_: () => closes.val += 1,
    encoder: ContentEncoder::new(Gzip),
    closed: false,
  }
  @model.BodyStream::close(body)
  @model.BodyStream::close(body)
  @driver.run_sync(() => assert_eq(@model.BodyStream::read_some(body), None))
  assert_eq(closes.val, 1)
}

///|
test "encoder adapter accepts silent progress and retains a codec failure" {
  for failing in [false, true] {
    let encoder = ContentEncoder::{
      ..ContentEncoder::new(Gzip),
      encoder: QuietEncoder::{ fail: failing, },
    }
    encoder.feed(b"")
    if failing {
      for
        action in [
          () => ignore(encoder.pull()),
          () => encoder.feed(b""),
          () => encoder.end(),
          () => ignore(encoder.pull()),
        ] {
        let failed = try {
          action()
          false
        } catch {
          @model.TransportError(kind=Protocol, ..) => true
          _ => false
        }
        assert_true(failed)
      }
    } else {
      assert_true(encoder.pull() is NeedInput)
      encoder.end()
      assert_true(encoder.pull() is Done)
    }
  }
}
