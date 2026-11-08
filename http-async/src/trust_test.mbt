///|
test "TLS trust is cross target data with equality and diagnostics" {
  assert_eq(@http-async.Trust::System, @http-async.Trust::System)
  assert_not_eq(@http-async.Trust::Insecure, @http-async.Trust::System)
  debug_inspect(
    @http-async.Trust::PemFile("roots.pem"),
    content="PemFile(\"roots.pem\")",
  )
}
