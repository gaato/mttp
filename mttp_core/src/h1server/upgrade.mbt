///|
/// A 101 has no HTTP body or framing fields. Its write still has the HTTP
/// write deadline; only the callback runs without HTTP deadlines.
async fn Session::write_upgrade(
  self : Session,
  response : @mttp_core.Response,
  sent : Ref[Bool],
) -> Unit raise @mttp_core.TransportError {
  let headers = if self.auto_date && !response.headers.contains("date") {
    response.headers.add("date", self.date())
  } else {
    response.headers
  }
  let head = @h1.write_response_head(101, headers, NoBody, Http11) catch {
    @h1.ParseError(detail~, ..) => raise invalid_response(detail)
  }
  sent.val = true
  self.wire.write(head, self.limits.body_timeout_ms)
}
