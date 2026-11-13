// What MoonBit 0.10.20's TLS client does with a body the close delimits,
// cut by a close without close_notify. Later toolchains report that close,
// and compat/core_async_next keeps their test in a file of this name, which
// the canary copies over this one (.github/workflows/canary.yml); both
// files hold as many tests, so scripts/test_manifest.tsv fits either.

///|
/// 0.10.20's TLS client returns EOF for a close without close_notify, so
/// the body reads as complete: RFC 9112, section 9.8, cannot be applied.
#cfg(all(not(target="js"), not(platform="windows")))
async test "socket TLS close-delimited body fails at a close without close_notify" {
  with_closing_tls_server(
    b"HTTP/1.1 200 OK\r\nconnection: close\r\n\r\nperhaps all of it",
    close_notify=false,
    (url, _) => {
      let backend = closing_backend()
      defer backend.close()
      assert_eq(
        body(
          backend.send(
            @mttp_core.Request::get(url),
            @mttp_core.SendOptions::default(),
          ),
        ),
        b"perhaps all of it",
      )
      assert_eq(backend.idle_connections(), 0)
    },
  )
}
