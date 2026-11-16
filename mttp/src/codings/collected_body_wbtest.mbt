///|
async test "a closed collected body reads as ended, as BodyStream requires" {
  let body = CollectedBody::{
    read: () => Some(b"x"),
    close_: () => (),
    collected: [],
    collected_bytes: 0,
    block: Buffer(size_hint=0),
    limit: 8,
    over: false,
    on_end: _ => abort("not ended"),
    closed: false,
  }
  @mttp_core.BodyStream::close(body)
  assert_eq(@mttp_core.BodyStream::read_some(body), None)
}

///|
async test "collection gathers small chunks into blocks and stops at the limit without wrapping" {
  let ended : Ref[Bytes?] = Ref(None)
  let chunks = [b"a", b"b", b"c"]
  let big = Bytes::make(70000, b'z')
  chunks.push(big)
  for _ in 0..<70000 {
    chunks.push(b"y")
  }
  let at = Ref(0)
  let body = CollectedBody::{
    read: () => {
      guard at.val < chunks.length() else { return None }
      at.val += 1
      Some(chunks[at.val - 1])
    },
    close_: () => (),
    collected: [],
    collected_bytes: 0,
    block: Buffer(size_hint=0),
    limit: 1 << 20,
    over: false,
    on_end: bytes => ended.val = Some(bytes),
    closed: false,
  }
  while @mttp_core.BodyStream::read_some(body) is Some(_) {
    // A few blocks, not one entry per one-byte chunk.
    assert_true(body.collected.length() < 8)
  }
  guard ended.val is Some(whole) else { fail("not offered") }
  assert_eq(whole.length(), 3 + 70000 + 70000)
  assert_eq(whole[3:70003].to_owned(), big)
  assert_eq(whole[70003], b'y')
  // Near Int's top the comparison does not wrap: the chunk is refused.
  let near = CollectedBody::{
    read: () => Some(b"0123456789"),
    close_: () => (),
    collected: [],
    collected_bytes: 2147483640,
    block: Buffer(size_hint=0),
    limit: 2147483647,
    over: false,
    on_end: _ => abort("not ended"),
    closed: false,
  }
  @mttp_core.BodyStream::read_some(near) |> ignore
  assert_true(near.over)
  assert_eq(near.collected_bytes, 0)
}
