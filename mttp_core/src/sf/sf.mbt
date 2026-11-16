// Structured Field Values (RFC 9651): the values, and their bounds.

///|
/// The largest Integer, and the largest Decimal in thousandths: 15 digits.
const MAX_DIGITS_VALUE : Int64 = 999_999_999_999_999L

///|
/// A Structured Field's bare value (RFC 9651 section 3.3).
#derive(Eq, @debug.Debug)
#non_exhaustive
pub(all) enum BareItem {
  /// At most 15 digits, signed.
  Integer(Int64)
  /// In thousandths: at most 12 digits before the point and 3 after, so
  /// `Decimal(1500)` is 1.5. `decimal_from_string` rounds longer ones as
  /// the RFC does.
  Decimal(Int64)
  /// Printable ASCII, 0x20 to 0x7E.
  String(String)
  /// An ALPHA or `*`, then token characters, `:` and `/`.
  Token(String)
  /// A byte sequence, written as base64 between colons.
  Bytes(Bytes)
  /// `?1` or `?0`.
  Boolean(Bool)
  /// Seconds since 1970-01-01T00:00:00Z, an Integer's range.
  Date(Int64)
  /// Unicode text, written as `%"..."` with its UTF-8 percent-encoded.
  DisplayString(String)
}

///|
/// Compares two bare items.
pub extend BareItem with Eq::{equal, not_equal}

///|
/// Shows a bare item.
pub extend BareItem with @debug.Debug::{to_repr}

///|
/// Parameters: keys and values in their order; a repeated key keeps its
/// first place and its last value, as RFC 9651 parses them.
pub type Parameters = Array[(String, BareItem)]

///|
/// An Item: a bare item and its parameters.
#derive(Eq, @debug.Debug)
pub(all) struct Item {
  value : BareItem
  params : Parameters
}

///|
/// Compares two items.
pub extend Item with Eq::{equal, not_equal}

///|
/// Shows an item.
pub extend Item with @debug.Debug::{to_repr}

///|
/// A member of a List or a Dictionary: an Item, or an Inner List of Items
/// with parameters of its own.
#derive(Eq, @debug.Debug)
pub(all) enum Member {
  Item(Item)
  InnerList(Array[Item], Parameters)
}

///|
/// Compares two members.
pub extend Member with Eq::{equal, not_equal}

///|
/// Shows a member.
pub extend Member with @debug.Debug::{to_repr}

///|
/// A Dictionary: keys and members in their order; a repeated key keeps its
/// first place and its last member.
pub type Dictionary = Array[(String, Member)]

///|
/// An Item of `value` without parameters.
pub fn Item::of(value : BareItem) -> Item {
  { value, params: [], }
}

///|
/// Sets `key` to `value` in `pairs`, in place when the key is there;
/// `places` maps each key in `pairs` to its index, so a field of many keys
/// costs one lookup per key, not a scan.
fn[V] set_pair(
  pairs : Array[(String, V)],
  places : Map[String, Int32],
  key : String,
  value : V,
) -> Unit {
  match places.get(key) {
    Some(i) => pairs[i] = (key, value)
    None => {
      places[key] = pairs.length()
      pairs.push((key, value))
    }
  }
}

///|
/// The value of a Decimal written as `text`, in thousandths, rounded to
/// three fractional digits with ties to even, as RFC 9651 section 4.1.5
/// serializes a decimal with more: "0.0025" is 2, "9.9995" is 10000. None
/// when `text` is not a decimal number (an optional `-`, digits, and an
/// optional `.` and digits) or has more than 12 digits before the point
/// once rounded.
pub fn decimal_from_string(text : StringView) -> Int64? {
  let n = text.length()
  let mut i = 0
  let negative = n > 0 && text[0] == '-'
  if negative {
    i = 1
  }
  let mut whole = 0L
  let mut whole_digits = 0
  // Digits after the leading zeros; past 13 the value is out of range
  // however it rounds, and counting stops before Int64 could overflow.
  let mut significant = 0
  while i < n && text[i] >= '0' && text[i] <= '9' {
    whole_digits += 1
    if whole > 0L || text[i] != '0' {
      significant += 1
    }
    if significant > 13 {
      return None
    }
    whole = whole * 10L + (text[i].to_int() - 48).to_int64()
    i += 1
  }
  guard whole_digits > 0 else { return None }
  let mut milli = 0L
  let mut tail_digits = 0
  // The fourth digit, and whether any digit after it is not zero.
  let mut fourth = 0
  let mut beyond = false
  if i < n {
    guard text[i] == '.' && i + 1 < n else { return None }
    i += 1
    while i < n {
      let c = text[i]
      guard c >= '0' && c <= '9' else { return None }
      let d = c.to_int() - 48
      if tail_digits < 3 {
        milli = milli * 10L + d.to_int64()
      } else if tail_digits == 3 {
        fourth = d
      } else if d != 0 {
        beyond = true
      }
      tail_digits += 1
      i += 1
    }
  }
  for _ in tail_digits.min(3)..<3 {
    milli = milli * 10L
  }
  let mut value = whole * 1000L + milli
  // Ties to even: round up past half, and at half when the kept digit is odd.
  if fourth > 5 || (fourth == 5 && (beyond || value % 2L == 1L)) {
    value += 1L
  }
  guard value <= MAX_DIGITS_VALUE else { return None }
  Some(if negative { -value } else { value })
}
