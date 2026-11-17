///|
// String operations stay outside the proved package. The complete UTF-16
// code-unit domain of this mapping is checked in numbers_wbtest.mbt.
fn digit_value(code : Int32, hex~ : Bool) -> Int64 {
  if code >= 48 && code <= 57 {
    (code - 48).to_int64()
  } else if hex && code >= 65 && code <= 70 {
    (code - 65 + 10).to_int64()
  } else if hex && code >= 97 && code <= 102 {
    (code - 97 + 10).to_int64()
  } else {
    -1L
  }
}

///|
// Map only the initial digit run. Folding it before handling the remainder
// preserves the existing error order: overflow before a later bad character
// or chunk extension. The scratch array is never retained by a decoder.
fn number_prefix(value : StringView, hex~ : Bool) -> (FixedArray[Int64], Int32) {
  let digits = FixedArray::make(value.length(), 0L)
  let n = for i = 0; i < value.length(); {
    let digit = digit_value(value[i].to_int(), hex~)
    if digit < 0L {
      break i
    }
    digits[i] = digit
    continue i + 1
  } nobreak {
    value.length()
  }
  (digits, n)
}
