# Bounded positional numbers

Internal arithmetic for HTTP/1's Content-Length and chunk-size. This package
has no imports: its executable step and digit-array fold are checked by
`moon prove`. See [the proof record](../../h1/PROOFS.md) for the model,
toolchain, trust boundary and commands.

Digits are integer values, not ASCII codes. `fold` accepts bases 10 and 16
and a prefix length in `0..=digits.length()`. It returns -1 for an empty
prefix, an out-of-base digit or a value over 2^63 - 1. Leading zeros are
allowed. The caller owns the fixed array; the fold allocates nothing and
does not mutate it.

```mbt check
///|
test {
  let digits : FixedArray[Int64] = [1L, 2L, 3L]
  assert_eq(@number.fold(digits, 3, 10L), 123L)
  assert_eq(@number.fold(digits, 3, 16L), 291L)
  assert_eq(@number.fold(digits, 0, 10L), -1L)
}
```
