///|
/// Decodes application/x-www-form-urlencoded pairs in order, preserving
/// duplicates. Empty pieces are skipped, a missing equals means empty value,
/// plus becomes space, malformed escapes stay literal and invalid UTF-8 is
/// replaced. At most max_pairs (default 256) nonempty pairs are accepted.
/// Byte limits belong to the caller that reads the input body.
pub fn form_urldecode(
  input : String,
  max_pairs~ : Int32 = 256,
) -> Array[(String, String)] raise TransportError {
  if max_pairs < 0 {
    raise TransportError(
      kind=Invalid,
      phase=Body,
      detail="negative form pair limit",
    )
  }
  let pairs = []
  for piece in input.split("&") {
    if !piece.is_empty() {
      if pairs.length() >= max_pairs {
        raise TransportError(
          kind=TooLarge(limit=max_pairs),
          phase=Body,
          detail="too many form pairs",
        )
      }
      pairs.push(query_pair(piece))
    }
  }
  pairs
}
