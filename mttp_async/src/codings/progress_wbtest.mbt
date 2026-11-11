///|
test "zero-output stored blocks skippable frames and metadata consume every input byte" {
  let deflate = Buffer()
  let zstd = Buffer()
  let brotli = Buffer()
  // WBITS=16, ISLAST=0, MNIBBLES=3, reserved=0, MSKIPBYTES=0.
  brotli.write_bytes(b"\x0c")
  for _ in 0..<1024 {
    // Nonfinal empty stored block: BFINAL=0, BTYPE=00, LEN=0, NLEN=ffff.
    deflate.write_bytes(b"\x00\x00\x00\xff\xff")
    // A skippable frame containing three bytes that produce no output.
    zstd.write_bytes(b"\x50\x2a\x4d\x18\x03\x00\x00\x00abc")
    // An empty metadata block after byte alignment, without another WBITS.
    brotli.write_bytes(b"\x06")
  }
  deflate.write_bytes(b"\x01\x00\x00\xff\xff")
  // Last empty Brotli meta-block: ISLAST=1, ISLASTEMPTY=1.
  brotli.write_bytes(b"\x03")
  for
    (coding, wire) in [
      (Coding::Deflate, deflate.to_bytes()),
      (Zstd, zstd.to_bytes()),
      (Brotli, brotli.to_bytes()),
    ] {
    for
      chunks in [
        [wire],
        wire.iter().map(byte => Bytes::from_array([byte])).collect(),
      ] {
      let decoder = ContentDecoder::new([coding])
      for chunk in chunks {
        assert_true(decoder.pull() is NeedInput)
        decoder.feed(chunk)
        assert_true(decoder.pull() is NeedInput)
        // A NeedInput must have consumed the entire chunk, even when it
        // yielded no bytes. Thus the wrapper's loop is bounded by wire bytes.
        assert_eq(decoder.stages[0].input.length(), 0)
      }
      decoder.end()
      assert_true(decoder.pull() is Done)
      assert_true(decoder.pull() is Done)
    }
  }
}
