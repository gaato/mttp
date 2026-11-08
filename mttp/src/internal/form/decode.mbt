///|
/// Form decoding limits, independent of HTTP transport and endpoint errors.
pub(all) suberror FormError {
  InvalidLimit
  TooMany(Int32)
}

///|
/// Decodes one pair, retaining forgiving percent/UTF-8 replacement behavior.
pub fn decode_pair(piece : StringView) -> (String, String) {
  let (name, value) = match piece.find("=") {
    Some(i) => (piece[:i], piece[i + 1:])
    None => (piece, "")
  }
  let decode = (s : StringView) => {
    @percent.decode_lossy(s.to_owned().replace_all(old="+", new=" "))
  }
  (decode(name), decode(value))
}

///|
/// Decodes at most max_pairs nonempty pieces, in order with duplicates kept.
pub fn decode(
  input : String,
  max_pairs : Int32,
) -> Array[(String, String)] raise FormError {
  if max_pairs < 0 {
    raise InvalidLimit
  }
  let pairs = []
  for piece in input.split("&") {
    if !piece.is_empty() {
      if pairs.length() >= max_pairs {
        raise TooMany(max_pairs)
      }
      pairs.push(decode_pair(piece))
    }
  }
  pairs
}
