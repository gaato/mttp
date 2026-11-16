///|
test "decoder admits five stages and refuses six before allocation" {
  let mut wire : Bytes = b"x"
  for _ in 0..<5 {
    wire = @gzip.compress(wire)
  }
  assert_eq(decode_chunks(Array::make(5, Gzip), [wire]), Ok(b"x"))
  try ContentDecoder::new(Array::make(6, Gzip)) catch {
    @mttp_core.TransportError(kind=Invalid, phase=Body, ..) => ()
    error => raise error
  } noraise {
    _ => fail("accepted six stages")
  }
}

///|
test "codec window declarations admit HTTP limits and refuse the next size" {
  assert_eq(decode_chunks([Brotli], [hello_br_16m]), Ok(b"hello, hello, hello"))
  assert_true(decode_chunks([Brotli], [b"\x11"]) is Err(_))
  assert_eq(decode_chunks([Zstd], [hello_zstd_8m]), Ok(b"hello, hello, hello"))
  // Zstd's window descriptor 0x69 is 9 MiB, the first encoded size above 8 MiB.
  let larger = hello_zstd_8m.to_array()
  larger[5] = b'\x69'
  assert_true(decode_chunks([Zstd], [Bytes::from_array(larger)]) is Err(_))
  assert_eq(decode_chunks([Deflate], [hello_zlib]), Ok(b"hello, hello, hello"))
  // CINFO=8 declares 64 KiB instead of zlib's maximum 32 KiB.
  assert_true(
    decode_chunks([Deflate], [b"\x88\x98" + hello_zlib[2:].to_owned()])
    is Err(_),
  )
}

///|
test "the dcz window is 8 MiB, or 1.25 times a larger dictionary, up to 128 MiB" {
  assert_eq(dcz_window_bits(0), 23)
  assert_eq(dcz_window_bits(4 * 1024 * 1024), 23)
  // 1.25 times 8 MiB needs 10 MiB: a 16 MiB window.
  assert_eq(dcz_window_bits(8 * 1024 * 1024), 24)
  assert_eq(dcz_window_bits(100 * 1024 * 1024), 27)
  assert_eq(dcz_window_bits(2147483647), 27)
}
