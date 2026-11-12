///|
test "host randomness maps both six-byte extremes without reaching one" {
  let state = Ref(1UL)
  assert_eq(random_sample(Some(b"\x00\x00\x00\x00\x00\x00"), state), 0.0)
  let sample = random_sample(Some(b"\xff\xff\xff\xff\xff\xff"), state)
  assert_true(sample > 0.999999 && sample < 1.0)
  assert_eq(state.val, 1UL)
}

///|
test "fallback randomness advances deterministically without leaving its interval" {
  let first = Ref(0x9E3779B97F4A7C15UL)
  let second = Ref(first.val)
  let samples = Array::makei(64, _ => random_sample(None, first))
  assert_eq(samples, Array::makei(64, _ => random_sample(None, second)))
  assert_true(samples[0] != samples[1])
  for sample in samples {
    assert_true(sample >= 0.0 && sample < 1.0)
  }
}
