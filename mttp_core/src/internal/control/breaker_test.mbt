// Circuit-breaker accounting: fixed transitions, then random sequences of
// admissions, outcomes and clock steps checked against its invariants.

///|
fn breaker_config(
  min_requests~ : Int32 = 4,
  probes~ : Int32 = 2,
) -> @control.BreakerConfig {
  @control.BreakerConfig::new(
    failure_ratio=0.5,
    min_requests~,
    window_ms=1000,
    open_ms=500,
    half_open_probes=probes,
  )
}

///|
test "breaker opens on the failure ratio once the window has its minimum" {
  let config = breaker_config()
  let mut state = @control.BreakerState::new(now=0L)
  // Three failures stay below min_requests = 4.
  for _ in 0..<3 {
    let (next, ticket) = state.admit(config, now=10L)
    state = next.record(config, ticket, Failure, now=10L)
  }
  assert_true(state.phase is Closed(requests=3, failures=3, ..))
  let (next, ticket) = state.admit(config, now=20L)
  state = next.record(config, ticket, Success, now=20L)
  assert_eq(state.phase, Open(opened_at_ms=20L))
  assert_eq(state.generation, 1L)
  // Refused for open_ms; the request after it is the first probe.
  assert_eq(state.admit(config, now=519L).1, Reject)
  let (half, probe) = state.admit(config, now=520L)
  assert_eq(probe, Probe(generation=2L))
  assert_eq(half.phase, HalfOpen(probes=1))
  let (half, second) = half.admit(config, now=520L)
  assert_eq(second, Probe(generation=2L))
  assert_eq(half.admit(config, now=520L).1, Reject)
  // A neutral probe frees its slot, a successful one closes the circuit.
  let half = half.record(config, second, Neutral, now=521L)
  assert_eq(half.phase, HalfOpen(probes=1))
  let closed = half.record(config, probe, Success, now=600L)
  assert_eq(closed.phase, Closed(window_start_ms=600L, requests=0, failures=0))
  // The outcome of the probe from the earlier generation is ignored.
  assert_eq(closed.record(config, second, Failure, now=601L), closed)
}

///|
test "breaker windows roll over and a failed probe reopens the circuit" {
  let config = breaker_config(min_requests=2, probes=1)
  let mut state = @control.BreakerState::new(now=0L)
  let (next, ticket) = state.admit(config, now=0L)
  state = next.record(config, ticket, Failure, now=0L)
  // The next outcome lands in a new window, so one failure in each never
  // reaches min_requests.
  let (next, ticket) = state.admit(config, now=1000L)
  state = next.record(config, ticket, Failure, now=1000L)
  assert_eq(state.phase, Closed(window_start_ms=1000L, requests=1, failures=1))
  // A neutral outcome is not counted; a clock that went back starts a new
  // window.
  let (next, ticket) = state.admit(config, now=1001L)
  state = next.record(config, ticket, Neutral, now=1001L)
  assert_eq(state.phase, Closed(window_start_ms=1000L, requests=1, failures=1))
  let (next, ticket) = state.admit(config, now=999L)
  state = next.record(config, ticket, Failure, now=999L)
  assert_eq(state.phase, Closed(window_start_ms=999L, requests=1, failures=1))
  let (next, ticket) = state.admit(config, now=1000L)
  state = next.record(config, ticket, Failure, now=1000L)
  assert_eq(state.phase, Open(opened_at_ms=1000L))
  let (half, probe) = state.admit(config, now=1500L)
  let reopened = half.record(config, probe, Failure, now=1600L)
  assert_eq(reopened.phase, Open(opened_at_ms=1600L))
  // A clock that went back before the opening restarts the open time.
  let (back, ticket) = reopened.admit(config, now=100L)
  assert_eq(ticket, Reject)
  assert_eq(back.phase, Open(opened_at_ms=100L))
  assert_eq(back.admit(config, now=599L).1, Reject)
  assert_true(back.admit(config, now=600L).1 is Probe(..))
}

///|
test "breaker ratio thresholds count failures among at least min_requests" {
  // A ratio of 0 or less opens on the first failure once the minimum is
  // met, never on successes alone; NaN never opens.
  for ratio in [0.0, -1.0, 0.25, 0.0 / 0.0] {
    let config = @control.BreakerConfig::new(
      failure_ratio=ratio,
      min_requests=0,
      window_ms=0,
      open_ms=-5,
      half_open_probes=0,
    )
    assert_eq(
      (
        config.min_requests,
        config.window_ms,
        config.open_ms,
        config.half_open_probes,
      ),
      (1, 1, 0, 1),
    )
    let mut state = @control.BreakerState::new(now=0L)
    let (next, ticket) = state.admit(config, now=0L)
    state = next.record(config, ticket, Success, now=0L)
    assert_true(state.phase is Closed(..))
    let (next, ticket) = state.admit(config, now=0L)
    state = next.record(config, ticket, Failure, now=0L)
    assert_eq(state.phase is Open(..), !ratio.is_nan(), msg="ratio \{ratio}")
  }
}

///|
#derive(Debug)
priv enum BreakerOp {
  Admit
  Complete(Int32, Int32)
  Advance(Int32)
}

///|
fn gen_breaker_ops() -> @qc.Generator[Array[BreakerOp]] {
  @qc.frequency([
    (6, @qc.pure(BreakerOp::Admit)),
    (6, @qc.int_range(0, 16 * 6).map(n => BreakerOp::Complete(n / 6, n % 6))),
    (3, @qc.int_range(0, 400).map(ms => BreakerOp::Advance(ms))),
  ]).array_with_size(200)
}

///|
fn outcome_of(n : Int32) -> @control.BreakerOutcome {
  match n {
    0 | 1 | 2 => Failure
    3 | 4 => Success
    _ => Neutral
  }
}

///|
test "breaker invariants hold on random sequences" {
  let configs = [
    breaker_config(min_requests=1, probes=1),
    breaker_config(min_requests=3, probes=2),
    breaker_config(min_requests=5, probes=3),
  ]
  for seed in 0UL..<60UL {
    let config = configs[(seed % 3UL).to_int()]
    let mut state = @control.BreakerState::new(now=0L)
    let mut now = 0L
    let outstanding : Array[@control.BreakerTicket] = []
    for op in gen_breaker_ops().sample(seed~) {
      let before = state
      match op {
        Admit => {
          let (next, ticket) = state.admit(config, now~)
          // Open lasts at least open_ms: nothing passes before it ends.
          if before.phase is Open(opened_at_ms~) &&
            now >= opened_at_ms &&
            now - opened_at_ms < config.open_ms.to_int64() {
            assert_eq(ticket, Reject, msg="seed \{seed}")
          }
          // Only a probe moves an open circuit, and only once open_ms passed.
          if before.phase is Open(opened_at_ms~) && ticket is Probe(..) {
            assert_true(now - opened_at_ms >= config.open_ms.to_int64())
          }
          if before.phase is Closed(..) {
            assert_true(ticket is Pass(..), msg="seed \{seed}")
          }
          if ticket is (Pass(..) | Probe(..)) {
            outstanding.push(ticket)
          }
          state = next
        }
        Complete(pick, outcome) =>
          if !outstanding.is_empty() {
            let index = pick % outstanding.length()
            let ticket = outstanding.remove(index)
            state = state.record(config, ticket, outcome_of(outcome), now~)
            if state.phase is Open(opened_at_ms~) && !(before.phase is Open(..)) {
              // A circuit opens at the time of the outcome that opened it.
              assert_eq(opened_at_ms, now)
            }
            if before.phase is Closed(requests~, ..) && state.phase is Open(..) {
              assert_true(
                requests + 1 >= config.min_requests,
                msg="seed \{seed}",
              )
            }
          }
        Advance(ms) => now += ms.to_int64()
      }
      if state.phase != before.phase {
        // Every change of phase starts a new generation, except the
        // in-phase updates of a window or of the probe count.
        let same_kind = (state.phase, before.phase)
          is ((Closed(..), Closed(..))
          | (HalfOpen(..), HalfOpen(..))
          | (Open(..), Open(..)))
        assert_eq(
          state.generation != before.generation,
          !same_kind,
          msg="seed \{seed}",
        )
      }
      // Never more probes in flight than allowed, and exactly the probes of
      // the current generation still outstanding.
      let live_probes = outstanding
        .iter()
        .filter(t => t is Probe(generation~) && generation == state.generation)
        .count()
      match state.phase {
        HalfOpen(probes~) => {
          assert_true(probes <= config.half_open_probes, msg="seed \{seed}")
          assert_eq(probes, live_probes, msg="\{Repr(op)} seed \{seed}")
        }
        _ => assert_eq(live_probes, 0, msg="seed \{seed}")
      }
    }
  }
}
