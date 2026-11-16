///|
test "connection_scheme_of keeps http and https, case aside, and nothing else" {
  assert_eq(@mttp_core.connection_scheme_of("https"), Some("https"))
  assert_eq(@mttp_core.connection_scheme_of("HTTP"), Some("http"))
  assert_eq(@mttp_core.connection_scheme_of("ftp"), None)
  assert_eq(@mttp_core.connection_scheme_of(""), None)
}
