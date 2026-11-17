///|
test "step accepts the exact signed bound and refuses one more in both bases" {
  assert_eq(@number.step(922337203685477580L, 7L, 10L), 9223372036854775807L)
  assert_eq(@number.step(922337203685477580L, 8L, 10L), -1L)
  assert_eq(@number.step(576460752303423487L, 15L, 16L), 9223372036854775807L)
  assert_eq(@number.step(576460752303423488L, 0L, 16L), -1L)
  assert_eq(@number.step(0L, 0L, 10L), 0L)
}

///|
test "fold accepts the bound and leading zeros and refuses overflow invalid and empty digits" {
  let decimal : FixedArray[Int64] = [
    9L, 2L, 2L, 3L, 3L, 7L, 2L, 0L, 3L, 6L, 8L, 5L, 4L, 7L, 7L, 5L, 8L, 0L, 7L,
  ]
  assert_eq(@number.fold(decimal, 19, 10L), 9223372036854775807L)
  decimal[18] = 8L
  assert_eq(@number.fold(decimal, 19, 10L), -1L)
  let hex = FixedArray::make(16, 15L)
  hex[0] = 7L
  assert_eq(@number.fold(hex, 16, 16L), 9223372036854775807L)
  hex[0] = 8L
  for i in 1..<16 {
    hex[i] = 0L
  }
  assert_eq(@number.fold(hex, 16, 16L), -1L)
  let zeros = FixedArray::make(1024, 0L)
  zeros[1023] = 1L
  assert_eq(@number.fold(zeros, 1024, 10L), 1L)
  assert_eq(@number.fold(zeros, 1024, 16L), 1L)
  for bad in [-1L, 10L, 16L, 9223372036854775807L, -9223372036854775808L] {
    assert_eq(@number.fold([0L, bad], 2, 10L), -1L)
  }
  assert_eq(@number.fold([16L], 1, 16L), -1L)
  assert_eq(@number.fold([], 0, 10L), -1L)
  assert_eq(@number.fold([1L, 2L, 3L, 99L], 3, 10L), 123L)
  assert_eq(@number.fold(FixedArray::make(64, 15L), 64, 16L), -1L)
}

///|
test "fold agrees with independent small positional arithmetic for every digit pair" {
  for base in [10L, 16L] {
    for a = 0L; a < base; a = a + 1L {
      for b = 0L; b < base; b = b + 1L {
        assert_eq(@number.fold([a, b], 2, base), a * base + b)
      }
    }
  }
}
