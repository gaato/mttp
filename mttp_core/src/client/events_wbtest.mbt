///|
test "a retry's reason is the status, or the failure kind's low-cardinality name" {
  let kinds : Array[(@mttp_core.Kind, String)] = [
    (Invalid, "invalid"),
    (Connect, "connect"),
    (Timeout(ms=5), "timeout"),
    (Network, "network"),
    (Protocol, "protocol"),
    (Proxy(status=407), "proxy"),
    (TooLarge(limit=1), "too_large"),
    (TooManyRedirects(max=2), "too_many_redirects"),
    (RedirectRefused, "redirect_refused"),
    (Unreplayable, "unreplayable"),
    (Closed, "closed"),
    (IncompleteClose, "incomplete_close"),
    (Refused, "refused"),
  ]
  for row in kinds {
    let (kind, name) = row
    let result : AttemptResult[Unit] = TransportFailure(
      @mttp_core.TransportError(kind~, phase=Unknown, detail=""),
    )
    assert_eq(retry_reason(result), name)
  }
  let head = @mttp_core.Response::new(429).head()
  let streamed : AttemptResult[Unit] = StreamReady(head)
  assert_eq(retry_reason(streamed), "429")
}
