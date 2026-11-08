// Fixtures for clock, gate and retention tests. admit exercises real admission.
// respond selects the most recently admitted outstanding request in a bucket;
// without one it issues a synthetic head fixture without consuming quota or
// time. Sequence-order contract tests use the public token API directly.

///|
async fn WindowLimiter::admit(
  self : WindowLimiter,
  bucket : String,
  global_exempt~ : Bool,
) -> Unit {
  ignore(self.acquire(bucket, global_exempt~))
}

///|
async fn WindowLimiter::respond(
  self : WindowLimiter,
  bucket : String,
  status~ : Int32,
  headers~ : @http.Headers,
) -> Unit {
  let mut admission : @client.Admission? = None
  for sequence, active in self.admissions {
    if active.admission.bucket() == bucket &&
      sequence > admission.map(a => a.sequence()).unwrap_or(-1L) {
      admission = Some(active.admission)
    }
  }
  let admission = admission.unwrap_or_else(() => {
    self.issue(bucket, (self.pace)(bucket).group, holding=false)
  })
  self.release(admission, status~, headers~)
}
