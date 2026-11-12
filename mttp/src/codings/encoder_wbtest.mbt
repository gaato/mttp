///|
test "encoder output stays within 64 KiB and resumes pending input without loss" {
  let random = @random.Rand::chacha8(seed=Bytes::make(32, b'\x07'))
  let source = Buffer()
  for _ in 0..<200000 {
    source.write_byte(random.int(limit=256).to_byte())
  }
  let input = source.to_bytes()
  for coding in [Gzip, Deflate, Brotli] {
    let encoder = ContentEncoder::new(coding)
    encoder.feed(input)
    let wire = Buffer()
    let mut full_slice = false
    for ;; {
      match encoder.pull() {
        Slice(bytes) => {
          assert_true(bytes.length() > 0 && bytes.length() <= 65536)
          full_slice = full_slice || bytes.length() == 65536
          wire.write_bytes(bytes)
        }
        NeedInput => encoder.end()
        Done => break
      }
    }
    assert_true(full_slice)
    assert_eq(decode_chunks([coding], [wire.to_bytes()]), Ok(input))
    assert_eq(encoder.input.length(), 0)
  }
}
