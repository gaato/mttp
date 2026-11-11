///|
test "listen errors interpolate their stage and cause" {
  assert_eq(
    "\{@server.Config(InvalidMaxConnections(value=0))}",
    "server configuration: invalid server limit max_connections: 0",
  )
  assert_eq(
    "\{@server.Bind(detail="address in use")}",
    "cannot listen: address in use",
  )
  assert_eq(
    "\{@server.Accept(detail="too many files")}",
    "accept failed: too many files",
  )
}
