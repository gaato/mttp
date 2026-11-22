///|
test "the linked library reports its version" {
  assert_true(@h3.ngtcp2_version() >= 0x010c00)
  assert_true(@h3.nghttp3_version() > 0)
  assert_eq(@h3.crypto_init(), 0)
}
