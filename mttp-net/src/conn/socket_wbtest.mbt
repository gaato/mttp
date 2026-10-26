///|
suberror Injected {
  Injected
}

///|
async test "dialer refuses a closed listener and socket close is idempotent" {
  let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  let port = listener.addr.port()
  let tcp = @socket.Tcp::connect(listener.addr)
  let (accepted, _) = listener.accept()
  defer accepted.close()
  let conn = @socket_conn.from_tcp(tcp)
  conn.close()
  conn.close()
  assert_eq(conn.read(max_len=1), None)
  let closed_write = try {
    conn.write(b"x")
    false
  } catch {
    @model.TransportError(kind=Network, phase=Unknown, ..) => true
    _ => false
  }
  assert_true(closed_write)
  listener.close()
  let refused = try {
    ignore(TcpDialer::new().connect(host="127.0.0.1", port~))
    false
  } catch {
    @model.TransportError(kind=Connect, phase=Dial, ..) => true
    _ => false
  }
  assert_true(refused)
}

///|
test "TLS boundary preserves transport errors and translates runtime errors" {
  let original = @model.TransportError(
    kind=Timeout(ms=7),
    phase=Write,
    detail="transport",
  )
  assert_true(
    transport_error(original)
    is @model.TransportError(
      kind=Timeout(ms=7),
      phase=Write,
      detail="transport"
    ),
  )
  assert_true(
    transport_error(Injected)
    is @model.TransportError(kind=Network, phase=Unknown, ..),
  )
}
