///|
test "typed client round trips repeated queries cookies basic auth and headers" {
  let input = @endpoint.Input::map3(
    @endpoint.query_list("q", @schema.int),
    @endpoint.cookie("session", @schema.string),
    @endpoint.header("x-value", @schema.int),
    (queries, cookie, header) => (queries, cookie, header),
    value => value,
  )
  let ep = @endpoint.endpoint
    .get("/roundtrip")
    .security(@endpoint.basic())
    .input(input)
    .output(@endpoint.text_out().and_header("x-count", @schema.int))
  let server = ep.serve(
    credentials => Ok(assert_eq(credentials, ("user", "pass:word"))),
    (_, input) => {
      Ok(
        {
          assert_eq(input, ([1, 2], "cookie", 7))
          ("ok", 2)
        },
      )
    },
  )
  let router = @router.Router::new([server])
  let client = @client.Client::new(router, @sim.FakeClock::new())
  @driver.run_sync(() => {
    assert_eq(
      ep
      .call(client, ("user", "pass:word"), ([1, 2], "cookie", 7))
      .unwrap()
      .unwrap(),
      ("ok", 2),
    )
  })
  client.close()
}

///|
test "rest captures preserve encoded slashes empty segments and empty tails" {
  let ep = @endpoint.endpoint
    .get("/files/{tail...}")
    .input(@endpoint.paths("tail"))
    .output(@endpoint.json_out(@schema.array(@schema.jstring).body()))
  let exact = @endpoint.endpoint
    .get("/files/special")
    .output(@endpoint.text_out())
    .serve_public(_ => Ok("specific"))
  let router = @router.Router::new([ep.serve_public(parts => Ok(parts)), exact])
  let client = @client.Client::new(router, @sim.FakeClock::new())
  @driver.run_sync(() => {
    for parts in [[], [""], ["a/b", "", "x y"]] {
      assert_eq(ep.call(client, (), parts).unwrap().unwrap(), parts)
    }
    assert_eq(
      router.dispatch(@mttp.Request::get("/files/special")).body,
      @mttp.Bytes(b"specific"),
    )
  })
  client.close()
}

///|
test "SSE callback consumes events and closes exactly once" {
  let closed = Ref(0)
  let index = Ref(0)
  let ep = @endpoint.endpoint
    .get("/events")
    .output(@endpoint.sse_out(@schema.jint))
  let source = @endpoint.EventStream::from_pull(
    () => {
      index.val += 1
      if index.val <= 3 {
        Some(index.val)
      } else {
        None
      }
    },
    () => closed.val += 1,
  )
  let router = @router.Router::new([ep.serve_public(_ => Ok(source))])
  let client = @client.Client::new(router, @sim.FakeClock::new())
  let values = []
  @driver.run_sync(() => {
    ep
    .call_with(client, (), (), events => {
      events.each(value => values.push(value))
    })
    .unwrap()
    .unwrap()
  })
  assert_eq(values, [1, 2, 3])
  source.close()
  assert_eq(closed.val, 1)
  client.close()
}

///|
test "SSE items carry each event's id and name, and next stops before the end" {
  let pulls = Ref(0)
  let closes = Ref(0)
  let ep = @endpoint.endpoint
    .get("/events")
    .output(
      @endpoint.sse_out(@schema.jint, meta=value => {
        @endpoint.SseMeta::new(
          id="\{value}",
          event=if value % 2 == 0 { "even" } else { "" },
          retry?=if value == 1 { Some(500) } else { None },
        )
      }),
    )
  // An endless producer: only an early stop ends this response.
  let router = @router.Router::new([
    ep.serve_public(_ => {
      Ok(
        @endpoint.EventStream::from_pull(
          () => {
            pulls.val += 1
            Some(pulls.val)
          },
          () => closes.val += 1,
        ),
      )
    }),
  ])
  let client = @client.Client::new(router, @sim.FakeClock::new())
  @driver.run_sync(() => {
    ep
    .call_with(client, (), (), events => {
      assert_eq(
        events.next_item(),
        Some(@endpoint.SseItem::new(1, id="1", retry=500)),
      )
      assert_eq(
        events.next_item(),
        Some(@endpoint.SseItem::new(2, id="2", event="even")),
      )
      assert_eq(events.next(), Some(3))
      events.close()
      assert_eq(events.next(), None)
      assert_eq(events.next_item(), None)
    })
    .unwrap()
    .unwrap()
  })
  assert_eq(pulls.val, 3)
  assert_eq(closes.val, 1)
  client.close()
}

///|
test "a client resumes an SSE stream from the last event id it read" {
  let closes = Ref(0)
  let requested = []
  let ep = @endpoint.endpoint
    .get("/events")
    .input(@endpoint.last_event_id())
    .output(
      @endpoint.sse_out(@schema.jint, meta=value => {
        @endpoint.SseMeta::new(id="\{value}", event="tick")
      }),
    )
  let router = @router.Router::new([
    ep.serve_public(last => {
      requested.push(last)
      let next = Ref(
        match last {
          Some(id) => @schema.int.decode(id)
          None => 0
        },
      )
      Ok(
        @endpoint.EventStream::from_pull(
          () => {
            if next.val < 4 {
              next.val += 1
              Some(next.val)
            } else {
              None
            }
          },
          () => closes.val += 1,
        ),
      )
    }),
  ])
  let client = @client.Client::new(router, @sim.FakeClock::new())
  let items = []
  @driver.run_sync(() => {
    // The first connection reads two events and stops.
    let last = ep
      .call_with(client, (), None, events => {
        ignore(events.next_item())
        events.next_item().unwrap().id
      })
      .unwrap()
      .unwrap()
    assert_eq(last, Some("2"))
    ep
    .call_with(client, (), last, events => {
      events.each_item(item => items.push(item))
    })
    .unwrap()
    .unwrap()
  })
  assert_eq(requested, [None, Some("2")])
  assert_eq(items, [
    @endpoint.SseItem::new(3, id="3", event="tick"),
    @endpoint.SseItem::new(4, id="4", event="tick"),
  ])
  assert_eq(closes.val, 2)
  client.close()
}

///|
test "custom inputs work from outside the endpoint package" {
  let input = @endpoint.Input::new(
    [@endpoint.Atom::new(Header, "x-custom", @schema.string.schema())],
    head => {
      @endpoint.Staged::ready(
        head.request.headers.get("x-custom").unwrap_or("missing"),
      )
    },
    (value, sink) => sink.set_header("x-custom", value),
  )
  let ep = @endpoint.endpoint
    .get("/custom")
    .input(input)
    .output(@endpoint.text_out())
  let router = @router.Router::new([ep.serve_public(value => Ok(value))])
  let client = @client.Client::new(router, @sim.FakeClock::new())
  @driver.run_sync(() => {
    assert_eq(ep.call(client, (), "custom").unwrap().unwrap(), "custom")
  })
  client.close()
}

///|
test "dynamic response status media type and separate cookies round trip" {
  let ep = @endpoint.endpoint
    .get("/dynamic")
    .output(@endpoint.body_out().and_status().set_cookie("a").set_cookie("b"))
  let value = (
    ((("multipart/mixed; boundary=test", b"payload"), 202), "one; Secure"),
    "two; HttpOnly",
  )
  let router = @router.Router::new([ep.serve_public(_ => Ok(value))])
  let client = @client.Client::new(router, @sim.FakeClock::new())
  @driver.run_sync(() => {
    assert_eq(ep.call(client, (), ()).unwrap().unwrap(), value)
  })
  let doc = ep.doc().outputs[0]
  assert_true(doc.dynamic_status)
  assert_true(doc.dynamic_media)
  assert_eq(doc.header_schemas["set-cookie"].json, { "type": "string" })
  client.close()
}
