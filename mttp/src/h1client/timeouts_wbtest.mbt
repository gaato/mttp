///|
test "phase_budget takes the phase's limit unless the attempt ends first" {
  let rows : Array[(Int32?, Int64?, (Int32, Int32)?)] = [
    // No attempt deadline: the phase's own limit.
    (Some(400), None, Some((400, 400))),
    (Some(400), Some(5000L), Some((400, 400))),
    // On a tie the phase's own limit is the one reported.
    (Some(400), Some(400L), Some((400, 400))),
    (Some(400), Some(399L), Some((399, 5000))),
    (Some(400), Some(0L), Some((0, 5000))),
    (Some(400), Some(-20L), Some((0, 5000))),
    // A nonpositive limit has run out before the phase starts.
    (Some(0), Some(5000L), Some((0, 0))),
    (Some(-1), None, Some((-1, -1))),
    // Only the attempt deadline, or nothing at all.
    (None, Some(7L), Some((7, 5000))),
    (None, Some(-3L), Some((0, 5000))),
    (None, Some(9223372036854775807L), Some((2147483647, 5000))),
    (None, None, None),
  ]
  for row in rows {
    let (limit, remaining, expected) = row
    assert_eq(phase_budget(limit, total=5000, remaining~), expected)
  }
}

///|
test "Timeouts gives the head and the body the read limit" {
  let limits : Timeouts = {
    pool: Some(2),
    connect: Some(3),
    write: Some(4),
    read: Some(5),
  }
  let phases : Array[@mttp.Phase] = [Pool, Dial, Write, Head, Body, Unknown]
  assert_eq(phases.map(phase => limits.of(phase)), [
    Some(2),
    Some(3),
    Some(4),
    Some(5),
    Some(5),
    Some(5),
  ])
}
