///|
/// RFC 9112, section 9.8: a body that the close delimits, cut by a close
/// without close_notify, may be truncated, so reading it fails.
#cfg(all(not(target="js"), not(platform="windows")))
async test "socket TLS close-delimited body fails at a close without close_notify" {
  with_closing_tls_server(
    b"HTTP/1.1 200 OK\r\nconnection: close\r\n\r\nperhaps all of it",
    close_notify=false,
    (url, _) => {
      let backend = closing_backend()
      defer backend.close()
      try
        body(
          backend.send(
            @mttp_core.Request::get(url),
            @mttp_core.SendOptions::default(),
          ),
        )
        |> ignore
      catch {
        @mttp_core.TransportError(kind=Protocol, phase=Body, ..) => ()
        error => raise error
      } noraise {
        _ => fail("a body cut without close_notify was read as complete")
      }
      assert_eq(backend.idle_connections(), 0)
    },
  )
}
