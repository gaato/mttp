///|
test "the stub, the function wrappers and the fault wrapper keep the backend contract" {
  @driver.run_sync(() => {
    @sim.check_backend_contract(() => @testing.BackendStub::new())
    @sim.check_backend_contract(() => {
      @client.from_handler(_ => @http.Response::new(200))
    })
    @sim.check_backend_contract(() => {
      @client.from_fn((_, _) => @http.Response::new(200))
    })
    @sim.check_backend_contract(() => {
      @testing.fail_sends(
        @testing.BackendStub::new(),
        @http.TransportError(kind=Network, phase=Dial, detail="fixture"),
        times=0,
      )
    })
    @sim.check_backend_contract(() => {
      @client.FollowRedirects::new(
        @client.from_handler(_ => @http.Response::new(200)),
      )
    })
  })
}
