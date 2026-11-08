///|
async test "AsyncBackend satisfies the shared Backend contract" {
  @sim.check_backend_contract(() => @backend.AsyncBackend::new())
}
