///|
/// Appends one digit in base 10 or 16 to a nonnegative Int64. Returns -1
/// exactly on overflow. Requires value in 0..MAX and digit in 0..<base.
pub fn step(
  value : Int64,
  digit : Int64,
  base : Int64,
) -> Int64 where {
  proof_require: step_pre(value, digit, base),
  proof_ensure: result => step_post(value, digit, base, result),
} {
  if value > (9223372036854775807L - digit) / base {
    -1L
  } else {
    proof_assert 0L <= value * base && value * base <= 9223372036854775807L
    value * base + digit
  }
}

///|
fn model_zero(
  a : FixedArray[Int64],
  base : Int64,
) -> Unit where {
  proof_ensure: model(a, 0, base) == 0L,
} {

}

///|
fn model_step(
  a : FixedArray[Int64],
  n : Int32,
  base : Int64,
) -> Unit where {
  proof_require: 0 <= n && n < a.length(),
  proof_ensure: model(a, n + 1, base) == model(a, n, base) * base + a[n],
} {

}

///|
/// Folds a nonempty sequence of digit values in base 10 or 16. Returns -1
/// for empty input, an invalid digit, or a value exceeding signed 63 bits.
/// Requires 0 <= n <= a.length() and base 10 or 16.
pub fn fold(
  a : FixedArray[Int64],
  n : Int32,
  base : Int64,
) -> Int64 where {
  proof_require: fold_pre(a, n, base),
  proof_ensure: result => fold_post(a, n, base, result),
} {
  if n == 0 {
    -1L
  } else if !valid_digits(a, n, base) {
    -1L
  } else {
    model_zero(a, base)
    for i = 0, acc = 0L, overflow = false; i < n; {
      model_step(a, i, base)
      if overflow {
        proof_assert model(a, i + 1, base) > 9223372036854775807L
        continue i + 1, acc, true
      } else {
        let next = step(acc, a[i], base)
        if next < 0L {
          continue i + 1, acc, true
        } else {
          continue i + 1, next, false
        }
      }
    } nobreak {
      if overflow {
        -1L
      } else {
        acc
      }
    } where {
      proof_invariant: 0 <= i && i <= n,
      proof_invariant: fold_inv(a, i, base, acc, overflow),
      proof_yield: result => fold_post(a, n, base, result),
    }
  }
}

///|
fn valid_digits(
  a : FixedArray[Int64],
  n : Int32,
  base : Int64,
) -> Bool where {
  proof_require: fold_pre(a, n, base),
  proof_ensure: result => result == digits(a, n, base),
} {
  for i = 0, good = true; i < n; {
    continue i + 1, good && 0L <= a[i] && a[i] < base
  } nobreak {
    good
  } where {
    proof_invariant: 0 <= i && i <= n,
    proof_invariant: good == digits(a, i, base),
    proof_yield: result => result == digits(a, n, base),
  }
}
