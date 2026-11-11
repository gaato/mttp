// An event stream from the endpoint layer through the engine: the engine
// pulls a stream's first piece before it writes the head, so the stream's
// opening comment is what lets the head out before any event exists.

///|
/// Reads one response head into `head`, leaving what follows it pending.
async fn Client::head_into(
  self : Client,
  head : Ref[@h1.ParsedResponse?],
) -> Unit {
  let decoder = @h1.HeadDecoder::new()
  for ;; {
    if self.pending.is_empty() && !self.fill() {
      fail("EOF before the response head")
    }
    let result = decoder.feed(self.pending)
    self.pending = self.pending[result.consumed:].to_owned()
    if result.head is Some(raw) {
      head.val = Some(@h1.parse_response_head(raw))
      return
    }
  }
}

///|
test "the head of an event stream is sent before its producer gives an event" {
  let h = Harness::new()
  let release = h.coordination.signal()
  let pulls = Ref(0)
  let events = @endpoint.endpoint
    .get("/events")
    .output(@endpoint.sse_out(@schema.jint))
    .serve_public(_ => {
      Ok(
        @endpoint.EventStream::from_pull(
          () => {
            pulls.val += 1
            if pulls.val == 1 {
              release.wait()
              Some(1)
            } else {
              None
            }
          },
          () => (),
        ),
      )
    })
  let head : Ref[@h1.ParsedResponse?] = Ref(None)
  let head_before_event = Ref(false)
  let rest = Ref("")
  h.run(() => {
    let (client, task) = h.serve(request => {
      events.dispatch(request, Map([]), @endpoint.DispatchContext::new())
    })
    client.send(get("/events"))
    let reader = h.driver.spawn(() => client.head_into(head))
    h.driver.sleep(10)
    // The producer is waiting for its first event.
    assert_eq(pulls.val, 1)
    head_before_event.val = head.val is Some(_)
    release.notify()
    ignore(reader.wait())
    client.conn.shutdown_write()
    rest.val = client.rest()
    ignore(task.wait())
    client.conn.close()
  })
  assert_true(head_before_event.val)
  // The opening comment and then the event, each in its own chunk.
  assert_eq(rest.val, "3\r\n:\n\n\r\n9\r\ndata: 1\n\n\r\n0\r\n\r\n")
  guard head.val is Some(head) else { fail("no head") }
  assert_eq(head.status, 200)
  assert_eq(head.headers.get("content-type"), Some("text/event-stream"))
  assert_eq(h.errors.length(), 0)
}
