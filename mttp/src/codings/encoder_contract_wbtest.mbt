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
async test "encoded body direct close is idempotent and makes EOF sticky" {
  let closes = Ref(0)
  let body = EncodedBody::{
    origin: @mttp_core.Body::Empty,
    read: () => None,
    close_: () => closes.val += 1,
    encoder: ContentEncoder::new(Gzip),
    closed: false,
    ended: false,
  }
  @mttp_core.BodyStream::close(body)
  @mttp_core.BodyStream::close(body)
  assert_eq(@mttp_core.BodyStream::read_some(body), None)
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
          @mttp_core.TransportError(kind=Protocol, ..) => true
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

///|
/// The encoder has bytes to hand out after its source ended (gzip's
/// footer, at the least): the source's trailers are the encoded body's
/// only once it returned EOF itself (Codex's review of #60).
async test "an encoded body shows its source's trailers only at its own end" {
  let origin = @mttp_core.Body::with_trailers(
    b"hello",
    trailers=@mttp_core.Headers::of([("x-checksum", "9")]),
  )
  let (read, close_) = body_source(origin)
  let body = EncodedBody::{
    origin,
    read,
    close_,
    encoder: ContentEncoder::new(Gzip),
    closed: false,
    ended: false,
  }
  while @mttp_core.BodyStream::read_some(body) is Some(_) {
    assert_eq(@mttp_core.BodyStream::trailers(body).length(), 0)
  }
  assert_eq(@mttp_core.BodyStream::trailers(body).get("x-checksum"), Some("9"))
}
