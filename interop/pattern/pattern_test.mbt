///|
/// The other interop clients hard-code these values in their own copies of
/// the pattern and digest, so a change here must change them too.
test "pattern and digest agree with the other languages" {
  assert_eq(@pattern.binary(8), b"\x00\x07\x0e\x15\x1c\x23\x2a\x31")
  assert_eq(@pattern.byte_at(256), b'\x01')
  assert_eq(@pattern.digest(b""), "0:811c9dc5")
  assert_eq(@pattern.digest(b"a"), "1:e40c292c")
  assert_eq(@pattern.digest(@pattern.binary(1 << 20)), "1048576:38d79dc5")
}

///|
test "digest is the same in one piece and in many" {
  let body = @pattern.binary(100000)
  let d = @pattern.Digest::new()
  let mut at = 0
  while at < body.length() {
    let end = (at + 4093).min(body.length())
    d.update(body[at:end])
    at = end
  }
  assert_eq(d.summary(), @pattern.digest(body))
}

///|
test "text is numbered lines of the requested length" {
  let t = @pattern.text(100)
  assert_eq(t.length(), 100)
  assert_true(@utf8.decode(t).has_prefix("000001 the quick brown fox"))
}
