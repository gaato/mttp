///|
test "RFC 3174 and FIPS 180 SHA-1 vectors including one million a" {
  for
    (input, expected) in [
      (
        b"", b"\xda\x39\xa3\xee\x5e\x6b\x4b\x0d\x32\x55\xbf\xef\x95\x60\x18\x90\xaf\xd8\x07\x09",
      ),
      (
        b"abc", b"\xa9\x99\x3e\x36\x47\x06\x81\x6a\xba\x3e\x25\x71\x78\x50\xc2\x6c\x9c\xd0\xd8\x9d",
      ),
      (
        b"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq", b"\x84\x98\x3e\x44\x1c\x3b\xd2\x6e\xba\xae\x4a\xa1\xf9\x51\x29\xe5\xe5\x46\x70\xf1",
      ),
    ] {
    assert_eq(@sha1.digest(input), expected)
    for cut in 0..<=input.length() {
      let incremental = @sha1.Sha1::new()
      incremental.update(input[:cut])
      incremental.update(input[cut:])
      assert_eq(incremental.finish(), expected)
    }
  }
  let state = @sha1.Sha1::new()
  let block = Bytes::make(1000, b'a')
  for _ in 0..<1000 {
    state.update(block)
  }
  assert_eq(
    state.finish(),
    b"\x34\xaa\x97\x3c\xd4\xc4\xda\xa4\xf6\x1e\xeb\x2b\xdb\xad\x27\x31\x65\x34\x01\x6f",
  )
  assert_eq(@sha1.digest(Bytes::make(1000000, b'a')), state.finish())
}

///|
test "incremental SHA-1 equals one shot at every split and finish is a snapshot" {
  for size in 0..<=130 {
    let input = Bytes::makei(size, i => i.to_byte())
    let expected = @sha1.digest(input)
    for cut in 0..<=size {
      let state = @sha1.Sha1::new()
      state.update(input[:cut])
      assert_eq(state.finish(), @sha1.digest(input[:cut]))
      assert_eq(state.finish(), state.finish())
      state.update(input[cut:])
      assert_eq(state.finish(), expected)
    }
    let state = @sha1.Sha1::new()
    for i in 0..<size {
      state.update(input[i:i + 1])
    }
    assert_eq(state.finish(), expected)
  }
}
