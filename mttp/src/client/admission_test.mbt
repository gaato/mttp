///|
priv struct IdentityLimiter {
  mut next : Int64
  pending : Map[Int64, String]
  released : Array[(Int64, Int32)]
}

///|
fn IdentityLimiter::new() -> IdentityLimiter {
  { next: 0L, pending: Map([]), released: [], }
}

///|
impl @client.RateLimiter for IdentityLimiter with fn acquire(
  self,
  bucket,
  global_exempt~,
) {
  let _ = global_exempt
  self.next += 1L
  self.pending[self.next] = bucket
  @client.Admission::new(bucket, sequence=self.next)
}

///|
impl @client.RateLimiter for IdentityLimiter with fn release(
  self,
  admission,
  status~,
  headers~,
) {
  let _ = headers
  guard self.pending.get(admission.sequence()) is Some(bucket) else { return }
  assert_eq(bucket, admission.bucket())
  self.pending.remove(admission.sequence())
  self.released.push((admission.sequence(), status))
}

///|
test "concurrent Client attempts release their own admissions in delivery order" {
  let d = @driver.Driver::new()
  d.run(() => {
    let limiter = IdentityLimiter::new()
    let calls = Ref(0)
    let client = @client.Client::new(
      @client.from_handler(_ => {
        calls.val += 1
        if calls.val == 1 {
          d.sleep(10)
          @mttp.Response::new(201)
        } else {
          @mttp.Response::new(202)
        }
      }),
      @sim.SimClock::new(d),
      limiter~,
    )
    let slow = d.spawn(() => ignore(client.send(@client.get("/slow"))))
    d.pause()
    ignore(client.send(@client.get("/fast")))
    assert_true(slow.wait())
    assert_eq(limiter.released, [(2L, 202), (1L, 201)])
    assert_eq(limiter.pending.length(), 0)
  })
}

///|
test "each retry retains a distinct Admission through release" {
  @driver.run_sync(() => {
    let limiter = IdentityLimiter::new()
    let calls = Ref(0)
    let client = @client.Client::new(
      @client.from_handler(_ => {
        calls.val += 1
        @mttp.Response::new(if calls.val == 1 { 503 } else { 200 })
      }),
      @sim.FakeClock::new(),
      limiter~,
      retry=@client.RetryPolicy::conservative().with_max_retries(1),
    )
    ignore(client.send(@client.get("/")))
    assert_eq(limiter.released, [(1L, 503), (2L, 200)])
    assert_eq(limiter.pending.length(), 0)
  })
}

///|
test "a failed exchange releases its Admission with status zero" {
  @driver.run_sync(() => {
    let limiter = IdentityLimiter::new()
    let client = @client.Client::new(
      @client.from_fn((_, _) => {
        raise @mttp.TransportError(
          kind=Closed,
          phase=Pool,
          detail="test exchange failure",
        )
      }),
      @sim.FakeClock::new(),
      limiter~,
    )
    try client.send(@client.get("/")) catch {
      @mttp.TransportError(kind=Closed, ..) => ()
      _ => fail("wrong exchange error")
    } noraise {
      _ => fail("expected exchange failure")
    }
    assert_eq(limiter.released, [(1L, 0)])
    assert_eq(limiter.pending.length(), 0)
  })
}

///|
test "cancelled Client cleanup passes the acquired Admission to release" {
  let d = @driver.Driver::new()
  d.run(() => {
    let limiter = IdentityLimiter::new()
    let client = @client.Client::new(
      @client.from_handler(_ => {
        d.sleep(1000)
        @mttp.Response::new(200)
      }),
      @sim.SimClock::new(d),
      limiter~,
    )
    let task = d.spawn(() => ignore(client.send(@client.get("/"))))
    d.pause()
    task.cancel()
    assert_false(task.wait())
    assert_eq(limiter.released, [(1L, 0)])
    assert_eq(limiter.pending.length(), 0)
  })
}
