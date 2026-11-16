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
    (CircuitOpen, "circuit_open"),
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

///|
test "send identity exhaustion refuses before admission instead of reusing an id" {
  let sent = Ref(0)
  let events = []
  let client = Client::new(
    from_fn((_, _) => {
      sent.val += 1
      @mttp_core.Response::new(200)
    }),
    ExhaustionClock::{ },
    events=event => events.push(event),
  )
  client.send_sequence = 9223372036854775806L
  assert_eq(client.next_send_id(), 9223372036854775807L)
  @driver.run_sync(() => {
    try client.send(get("http://example.test/")) catch {
      @mttp_core.TransportError(kind=Invalid, phase=Pool, ..) => ()
      error => raise error
    } noraise {
      _ => fail("send identity wrapped")
    }
  })
  assert_eq(sent.val, 0)
  assert_eq(events.length(), 0)
  assert_eq(client.send_sequence, 9223372036854775807L)
}

///|
priv struct ExhaustionClock {}

///|
impl @rt.Clock for ExhaustionClock with fn now_unix_ms(_) {
  0L
}

///|
impl @rt.Clock for ExhaustionClock with fn sleep(_, _) {
  ()
}
