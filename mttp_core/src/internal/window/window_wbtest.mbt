///|
test "fixed windows preserve client boundaries and saturating delays" {
  assert_eq(
    fixed_step(0, limit=2, window_ms=10, start=None, count=0),
    Admit(start=0, count=1),
  )
  assert_eq(
    fixed_step(9, limit=2, window_ms=10, start=Some(0), count=2),
    Wait(1),
  )
  assert_eq(
    fixed_step(10, limit=2, window_ms=10, start=Some(0), count=2),
    Admit(start=10, count=1),
  )
  assert_eq(delay_until(0, 0), 0)
  assert_eq(delay_until(0, 1), 0)
  assert_eq(
    delay_until(9223372036854775807L, -9223372036854775808L),
    2147483647,
  )
  assert_eq(delay_until(2147483648L, 0), 2147483647)
  assert_eq(saturating_add_ms(9223372036854775800L, 10), 9223372036854775807L)
  assert_eq(saturating_add_i64(1, 2), 3)
}

///|
test "sliding log never exceeds limit and expires each admission exactly" {
  guard sliding_step(0, limit=2, window_ms=1000, None)
    is Admit(a, remaining=1, reset_ms=1000) else {
    fail("first")
  }
  guard sliding_step(500, limit=2, window_ms=1000, Some(a))
    is Admit(b, remaining=0, reset_ms=500) else {
    fail("second")
  }
  guard sliding_step(999, limit=2, window_ms=1000, Some(b)) is Wait(c, 1) else {
    fail("full")
  }
  assert_eq(c.admitted.length(), 2)
  guard sliding_step(1000, limit=2, window_ms=1000, Some(c))
    is Admit(d, remaining=0, reset_ms=500) else {
    fail("exclusive boundary")
  }
  guard sliding_step(1499, limit=2, window_ms=1000, Some(d)) is Wait(_, 1) else {
    fail("second expiry")
  }
  guard sliding_step(1500, limit=2, window_ms=1000, Some(d))
    is Admit(e, remaining=0, reset_ms=500) else {
    fail("second boundary")
  }
  guard sliding_step(9999, limit=2, window_ms=1000, Some(e))
    is Admit(f, remaining=1, ..) else {
    fail("idle")
  }
  assert_eq(f.admitted.length(), 1)
}

///|
test "sliding windows handle clock rollback and largest instants" {
  guard sliding_step(10, limit=1, window_ms=10, None) is Admit(a, ..) else {
    fail("first")
  }
  guard sliding_step(0, limit=1, window_ms=10, Some(a)) is Wait(_, 20) else {
    fail("rollback")
  }
  guard sliding_step(9223372036854775807L, limit=1, window_ms=10, None)
    is Admit(b, ..) else {
    fail("largest")
  }
  guard sliding_step(9223372036854775807L, limit=1, window_ms=10, Some(b))
    is Wait(_, 1) else {
    fail("no wrap")
  }
}
