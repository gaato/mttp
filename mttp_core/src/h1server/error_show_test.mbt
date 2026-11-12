///|
test "every server limit error names its limit" {
  let cases : Array[(@h1server.ServerConfigError, String)] = [
    (InvalidMaxBodyBytes(value=-1), "max_body_bytes: -1"),
    (InvalidBodyTimeoutMs(value=0), "body_timeout_ms: 0"),
    (InvalidHeaderTimeoutMs(value=0), "header_timeout_ms: 0"),
    (InvalidMaxConnections(value=0), "max_connections: 0"),
    (InvalidMaxHeaderBytes(value=0), "max_header_bytes: 0"),
    (InvalidDrainMaxBytes(value=-1), "drain_max_bytes: -1"),
    (InvalidHandlerTimeoutMs(value=0), "handler_timeout_ms: 0"),
    (InvalidDrainMs(value=-1), "drain_ms: -1"),
  ]
  for case_ in cases {
    let (error, text) = case_
    assert_eq("\{error}", "invalid server limit " + text)
  }
}
