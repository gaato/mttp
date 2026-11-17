///|
test "negotiation rejection closes static SSE sources without pulling" {
  for
    (accept, status) in [
      ("text/plain", 406),
      ("text/event-stream;q=2", 400),
      ("text/event-stream", 200),
    ] {
    let closes = Ref(0)
    let pulls = Ref(0)
    let server = @endpoint.endpoint
      .get("/")
      .output(@endpoint.sse_out(@schema.jint).negotiated())
      .serve_public(_ => {
        Ok(
          @endpoint.EventStream::from_pull(
            () => {
              pulls.val += 1
              Some(1)
            },
            () => closes.val += 1,
          ),
        )
      })
    @driver.run_sync(() => {
      let response = server.dispatch(
        @mttp_core.Request::get("/").header("accept", accept),
        Map([]),
        @endpoint.DispatchContext::new(),
      )
      assert_eq(response.status, status)
      assert_eq(pulls.val, 0)
      if status == 200 {
        assert_eq(closes.val, 0)
        guard response.body is Stream(body) else { fail("missing SSE body") }
        body.close()
        body.close()
      }
      assert_eq(closes.val, 1)
    })
  }
}

///|
test "runtime 204 and 304 bypass Accept negotiation and close their bodies" {
  for status in [204, 304] {
    for accept in ["text/plain", "text/plain;q=2"] {
      let server = @endpoint.endpoint
        .get("/")
        .output(@endpoint.stream_body_out().and_status().negotiated())
        .serve_public(_ => Ok(((None, @mttp_core.Empty), status)))
      @driver.run_sync(() => {
        let response = server.dispatch(
          @mttp_core.Request::get("/").header("accept", accept),
          Map([]),
          @endpoint.DispatchContext::new(),
        )
        assert_eq(response.status, status)
        assert_eq(response.body, @mttp_core.Empty)
        let closes = Ref(0)
        let reads = Ref(0)
        let body : &@mttp_core.BodyStream = CountedBody::{
          chunks: [b"ignored"],
          index: 0,
          closed: false,
          closes,
          reads,
        }
        let source : @mttp_core.Body = Stream(@mttp_core.StreamBody::new(body))
        let streamed = @endpoint.endpoint
          .get("/")
          .output(@endpoint.stream_body_out().and_status().negotiated())
          .serve_public(_ => Ok(((None, source), status)))
        let response = streamed.dispatch(
          @mttp_core.Request::get("/").header("accept", accept),
          Map([]),
          @endpoint.DispatchContext::new(),
        )
        assert_eq(response.status, status)
        assert_eq(response.body, @mttp_core.Empty)
        assert_eq(closes.val, 1)
        assert_eq(reads.val, 0)
      })
    }
  }
}
