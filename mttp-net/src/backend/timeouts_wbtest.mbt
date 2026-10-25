///|

///|
test "phase_budget takes the phase's limit unless the exchange ends first" {
  let rows : Array[(Int32, Int64?, (Int32, Int32))] = [
    // A stream's body read has no exchange deadline.
    (400, None, (400, 400)),
    (400, Some(5000L), (400, 400)),
    // On a tie the phase's own limit is the one reported.
    (400, Some(400L), (400, 400)),
    (400, Some(399L), (399, 5000)),
    (400, Some(0L), (0, 5000)),
    (400, Some(-20L), (0, 5000)),
    // A nonpositive limit has run out before the phase starts.
    (0, Some(5000L), (0, 0)),
    (-1, None, (-1, -1)),
  ]
  for row in rows {
    let (limit, remaining, expected) = row
    assert_eq(phase_budget(limit, total=5000, remaining~), expected)
  }
}

///|
test "Timeouts gives the head and body the read limit" {
  let limits = { total: 1, pool: 2, connect: 3, write: 4, read: 5, }
  let phases : Array[@model.Phase] = [Pool, Dial, Write, Head, Body, Unknown]
  assert_eq(phases.map(phase => limits.of(phase)), [2, 3, 4, 5, 5, 5])
}
