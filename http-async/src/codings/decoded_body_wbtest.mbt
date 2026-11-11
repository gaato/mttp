///|
async test "decoded body direct close is idempotent and makes EOF sticky" {
  let closes = Ref(0)
  let body = DecodedBody::{
    read: () => None,
    close_: () => closes.val += 1,
    decoder: ContentDecoder::new([Gzip]),
    closed: false,
  }
  @mttp.BodyStream::close(body)
  @mttp.BodyStream::close(body)
  assert_eq(@mttp.BodyStream::read_some(body), None)
  assert_eq(closes.val, 1)
}
