///|
test "NoLimiter sequence exhaustion refuses instead of reusing an identity" {
  @driver.run_sync(() => {
    let limiter = NoLimiter::new()
    limiter.sequence = 9223372036854775807L
    try limiter.acquire("a", global_exempt=false) catch {
      @mttp_core.TransportError(kind=Invalid, phase=Pool, ..) => ()
      _ => fail("wrong exhaustion error")
    } noraise {
      _ => fail("sequence wrapped")
    }
  })
}
