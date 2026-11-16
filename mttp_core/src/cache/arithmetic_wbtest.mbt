///|
test "time arithmetic saturates at the bound in both directions" {
  let max = 9223372036854775807L
  let min = -max - 1L
  assert_eq(clamp_ms(max), LIMIT_MS)
  assert_eq(clamp_ms(min), -LIMIT_MS)
  assert_eq(sub_ms(max, min), LIMIT_MS)
  assert_eq(sub_ms(min, max), -LIMIT_MS)
  assert_eq(sub_ms(5L, 7L), -2L)
  assert_eq(add_ms(max, max), LIMIT_MS)
  assert_eq(add_ms(min, min), -LIMIT_MS)
  assert_eq(add_ms(LIMIT_MS, LIMIT_MS), LIMIT_MS)
  assert_eq(add_ms(-3L, 1L), -2L)
}
