// ReconnectPolicy::decide over a grid of policies and inputs, checked
// against the properties its documentation states.

///|
fn reconnect_policies() -> Array[@client.ReconnectPolicy] {
  let policies = []
  let backoffs : Array[@client.Backoff] = [
    { base_ms: 100, max_ms: 10_000, jitter: NoJitter, },
    { base_ms: 1000, max_ms: 30_000, jitter: Proportional(lo=500, hi=1000), },
    { base_ms: 250, max_ms: 4000, jitter: Full, },
    { base_ms: 500, max_ms: 0, jitter: NoJitter, },
    { base_ms: 500, max_ms: -10, jitter: Proportional(lo=800, hi=1200), },
  ]
  for backoff in backoffs {
    for max_attempts in [None, Some(0), Some(1), Some(5)] {
      for reset_after_ms in [60_000, 0, -1] {
        for honour_server_retry in [true, false] {
          policies.push(@client.ReconnectPolicy::{
            backoff,
            max_attempts,
            reset_after_ms,
            honour_server_retry,
          })
        }
      }
    }
  }
  policies
}

///|
test "reconnect waits are never negative, respect the cap and honour the server" {
  let attempts_grid = [-3, 0, 1, 2, 4, 5, 12, 31, 40]
  let lived_grid = [-5L, 0L, 59_999L, 60_000L, 1_000_000_000L]
  let hints : Array[Int32?] = [
    None,
    Some(-5),
    Some(0),
    Some(700),
    Some(1_000_000),
  ]
  let randoms = [-1.0, 0.0, 0.3, 0.999, 1.5, 0.0 / 0.0]
  let mut checked = 0
  for policy in reconnect_policies() {
    let cap = policy.backoff.max_ms.max(0)
    for attempts in attempts_grid {
      for lived_ms in lived_grid {
        let reset = policy.reset_after_ms > 0 &&
          lived_ms >= policy.reset_after_ms.to_int64()
        let counted = if reset { 0 } else { attempts.max(0) }
        assert_eq(policy.next_attempts(attempts~, lived_ms~), counted + 1)
        for hint in hints {
          for random in randoms {
            let decision = policy.decide(
              attempts~,
              lived_ms~,
              server_hint_ms?=hint,
              random~,
            )
            checked += 1
            let context = "\{Repr(policy)} \{attempts} \{lived_ms} \{Repr(hint)} \{random}"
            // A long enough connection resets the count.
            if reset {
              assert_eq(
                decision,
                policy.decide(
                  attempts=0,
                  lived_ms=0L,
                  server_hint_ms?=hint,
                  random~,
                ),
                msg=context,
              )
            }
            match (decision, policy.max_attempts) {
              (GiveUp, Some(max)) => assert_true(counted >= max, msg=context)
              (GiveUp, None) => fail("gave up without a limit: \{context}")
              (Wait(ms), _) => {
                assert_true(
                  policy.max_attempts is None ||
                  counted < policy.max_attempts.unwrap(),
                  msg=context,
                )
                assert_true(ms >= 0 && ms <= cap, msg=context)
                let backoff = policy.backoff.delay_ms(counted, random)
                match hint {
                  Some(hint) if policy.honour_server_retry => {
                    let wanted = hint.max(0).min(cap)
                    if counted == 0 {
                      assert_eq(ms, wanted, msg=context)
                    } else {
                      assert_eq(ms, wanted.max(backoff), msg=context)
                    }
                  }
                  _ => assert_eq(ms, backoff, msg=context)
                }
              }
              _ => fail("unknown decision: \{context}")
            }
          }
        }
      }
    }
  }
  assert_true(checked > 100_000)
}

///|
test "the default reconnect policy backs off from one to thirty seconds for ever" {
  let policy = @client.ReconnectPolicy::default()
  assert_eq(policy.backoff, {
    base_ms: 1000,
    max_ms: 30_000,
    jitter: Proportional(lo=500, hi=1000),
  })
  assert_eq(
    (policy.max_attempts, policy.reset_after_ms, policy.honour_server_retry),
    (None, 60_000, true),
  )
  let waits = [0, 1, 4, 5, 1000].map(attempts => {
    policy.decide(attempts~, lived_ms=0L, random=0.999)
  })
  assert_eq(waits, [
    Wait(999),
    Wait(1998),
    Wait(15984),
    Wait(29970),
    Wait(29970),
  ])
  // A retry: field of 3 s sets the first wait exactly.
  assert_eq(
    policy.decide(attempts=0, lived_ms=0L, server_hint_ms=3000, random=0.0),
    Wait(3000),
  )
}
