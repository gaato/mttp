///|
fn empty_members(count : Int32) -> Bytes {
  Bytes::makei(count * 2 + 1, i => {
    if i < count * 2 && i % 2 == 0 {
      3
    } else {
      0
    }
  })
}

///|
test "DEFLATE final member work bound accepts eight rejects nine and stops a MiB train" {
  let extension : &@core_ws.Extension = PerMessageDeflate::new(
    encode_reset=true,
    decode_reset=true,
  )
  assert_eq(
    extension.decode(empty_members(8), rsv1=true, max_bytes=2097152),
    b"",
  )
  // Check the crossing first: the unfixed decoder must fail the test before
  // the full-size attack could make it allocate tens of GiB.
  for count in [9, 524288] {
    try
      extension.decode(empty_members(count), rsv1=true, max_bytes=2097152)
    catch {
      @core_ws.WsError(kind=TooLarge(limit=8), ..) => ()
      _ => fail("wrong member bound failure")
    } noraise {
      _ => fail("unbounded final member train")
    }
  }
}
