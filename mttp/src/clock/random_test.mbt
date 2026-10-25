///|
test "default random samples remain in the half-open unit interval" {
  for _ in 0..<64 {
    let sample = @clock.default_random()
    assert_true(sample >= 0.0 && sample < 1.0)
  }
}
