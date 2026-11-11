///|
// Bound tokens, not buckets: every in-flight request needs an identity so
// duplicate or out-of-order releases cannot consume another request's slot.
fn WindowLimiter::admission_room(
  self : WindowLimiter,
) -> Unit raise @mttp.TransportError {
  if self.admissions.length() >= max_entries {
    raise @mttp.TransportError(
      kind=TooLarge(limit=max_entries),
      phase=Pool,
      detail="rate-limit outstanding admission capacity exceeded",
    )
  }
  if self.sequence == 9223372036854775807L {
    raise @mttp.TransportError(
      kind=Invalid,
      phase=Pool,
      detail="admission sequence exhausted",
    )
  }
}

///|
fn WindowLimiter::issue(
  self : WindowLimiter,
  bucket : String,
  group : String,
  holding~ : Bool,
) -> @client.Admission raise @mttp.TransportError {
  self.admission_room()
  self.sequence += 1L
  let admission = @client.Admission::new(bucket, sequence=self.sequence)
  self.admissions[self.sequence] = { admission, group, holding, }
  admission
}
