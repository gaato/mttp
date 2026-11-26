///|
async test "decoded body direct close is idempotent and makes EOF sticky" {
  let closes = Ref(0)
  let body = DecodedBody::{
    origin: @mttp_core.Body::Empty,
    read: () => None,
    close_: () => closes.val += 1,
    decoder: ContentDecoder::new([Gzip]),
    closed: false,
    ended: false,
  }
  @mttp_core.BodyStream::close(body)
  @mttp_core.BodyStream::close(body)
  assert_eq(@mttp_core.BodyStream::read_some(body), None)
  assert_eq(closes.val, 1)
}
