// What MoonBit 0.10.20's TLS client does when its peer closes without
// close_notify. Later toolchains report that close, and
// compat/core_async_next keeps their tests in a file of this name, which
// the canary copies over this one (.github/workflows/canary.yml); both
// files hold as many tests, so scripts/test_manifest.tsv fits either.

///|
test "MoonBit 0.10.20 has no report of a missing close_notify" {
  assert_false(incomplete_close(Failure("closed")))
}

///|
/// Without that report a close without close_notify is EOF, which the
/// client cannot tell from a clean end (RFC 9112, section 9.8, needs it).
#cfg(not(platform="windows"))
async test "a TLS session closed without close_notify reads as EOF on MoonBit 0.10.20" {
  let cert = "src/conn/testdata/localhost.pem"
  @async.with_timeout(5000, () => {
    let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer listener.close()
    @async.with_task_group(group => {
      group.spawn_bg(() => {
        let (tcp, _) = listener.accept()
        let server = @testtls.accept(
          from_tcp(tcp),
          key_file="src/conn/testdata/localhost.key",
          cert_file=cert,
        )
        server.write(b"bye")
        server.close()
      })
      let tcp = @socket.Tcp::connect(listener.addr)
      let tls = @tls.Tls::client(
        tcp,
        host="localhost",
        trust=CustomPemFile(cert),
      )
      let conn = from_tls(tls, from_tcp(tcp), lower_sends=() => 0L)
      defer conn.close()
      assert_eq(conn.read(max_len=16), Some(b"bye"))
      assert_eq(conn.read(max_len=16), None)
    })
  })
}
