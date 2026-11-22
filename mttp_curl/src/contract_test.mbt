///|
async test "gaato/mttp_core's Backend contract" {
  // Port 1 refuses connections, so a send that broke a rule would fail
  // there rather than reach a server.
  @sim.check_backend_contract(
    () => @mttp_curl.CurlBackend::new(),
    url="http://127.0.0.1:1/",
  )
}
