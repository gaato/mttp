///|
test "TLS trust is cross target data with equality and diagnostics" {
  assert_eq(@trust.Trust::System, @trust.Trust::System)
  assert_not_eq(@trust.Trust::Insecure, @trust.Trust::System)
  debug_inspect(
    @trust.Trust::PemFile("roots.pem"),
    content="PemFile(\"roots.pem\")",
  )
}
