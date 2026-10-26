///|
test "encoded SSE survives every byte split including UTF-8" {
  let event : @sse.SseEvent = {
    event: "delta",
    data: "日本\n🙂\n",
    id: Some("id"),
    retry: Some(100),
  }
  let bytes = @sse.encode(event)
  for split in 0..<=bytes.length() {
    let parser = @sse.SseParser::new()
    let events = parser.feed(bytes[:split].to_owned())
    events.append(parser.feed(bytes[split:].to_owned()))
    events.append(parser.finish())
    assert_eq(events, [event])
  }
}

///|
test "SSE encoder normalizes data line endings and defaults event type" {
  let event : @sse.SseEvent = {
    event: "",
    data: "a\rb\r\nc",
    id: None,
    retry: None,
  }
  assert_eq(@sse.SseParser::new().feed(@sse.encode(event)), [
    { ..event, event: "message", data: "a\nb\nc", },
  ])
  let empty = { ..event, data: "", id: Some(""), }
  assert_eq(@sse.SseParser::new().feed(@sse.encode(empty)), [
    { ..empty, event: "message", },
  ])
}

///|
test "SSE encoder refuses fields that could inject lines" {
  let base : @sse.SseEvent = {
    event: "message",
    data: "data",
    id: None,
    retry: None,
  }
  for
    event in [
      { ..base, event: "bad\rname", },
      { ..base, event: "bad\nname", },
      { ..base, id: Some("bad\nvalue"), },
      { ..base, id: Some("bad\rvalue"), },
      { ..base, id: Some("bad\u0000value"), },
      { ..base, retry: Some(-1), },
    ] {
    let refused = try {
      let _ = @sse.encode(event)
      false
    } catch {
      @model.TransportError(kind=Invalid, ..) => true
      _ => false
    }
    assert_true(refused)
  }
}
