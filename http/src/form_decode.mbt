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
  @form.decode(input, max_pairs) catch {
    @form.InvalidLimit =>
      raise TransportError(
        kind=Invalid,
        phase=Body,
        detail="negative form pair limit",
      )
    @form.TooMany(limit) =>
      raise TransportError(
        kind=TooLarge(limit~),
        phase=Body,
        detail="too many form pairs",
      )
  }
}
