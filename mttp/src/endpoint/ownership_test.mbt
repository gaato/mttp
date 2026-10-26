///|
priv struct CountedBody {
  chunks : Array[Bytes]
  mut index : Int32
  mut closed : Bool
  closes : Ref[Int32]
  reads : Ref[Int32]
}

///|
impl @model.BodyStream for CountedBody with fn read_some(self) {
  self.reads.val += 1
  if self.closed || self.index == self.chunks.length() {
    return None
  }
  let bytes = self.chunks[self.index]
  self.index += 1
  Some(bytes)
}

///|
impl @model.BodyStream for CountedBody with fn close(self) {
  if !self.closed {
    self.closed = true
    self.closes.val += 1
  }
}

///|
test "rejected heads close unread bodies and limits survive caught read errors" {
  let closes = Ref(0)
  let reads = Ref(0)
  let source : &@model.BodyStream = CountedBody::{
    chunks: [b"abcd"],
    index: 0,
    closed: false,
    closes,
    reads,
  }
  let endpoint = @endpoint.endpoint
    .post("/upload")
    .input(@endpoint.stream_body())
    .max_body_bytes(3)
  let server = endpoint.serve_public(reader => {
    Ok(ignore(reader.read_some() catch { _ => None }))
  })
  let failures = []
  let ctx = @endpoint.DispatchContext::new(decode_failure=f => {
    failures.push(f)
    @model.Response::new(413)
  })
  @driver.run_sync(() => {
    let req = @model.Request::post("/upload").header(
      "content-type", "application/octet-stream",
    )
    let req = { ..req, body: @model.Stream(@model.StreamBody::new(source)), }
    let response = server.dispatch(req, Map([]), ctx)
    assert_eq(response.status, 413)
    assert_eq(response.headers.get("connection"), Some("close"))
  })
  assert_eq(closes.val, 1)
  assert_eq(reads.val, 1)
  assert_eq(failures.length(), 1)
  assert_eq(failures[0].stage, @endpoint.Body)
  assert_true(
    failures[0].failures[0].failure
    is @schema.DecodeFailure(kind=TooLarge(limit=3), ..),
  )
  let source : &@model.BodyStream = CountedBody::{
    chunks: [b"abcd"],
    index: 0,
    closed: false,
    closes,
    reads,
  }
  @driver.run_sync(() => {
    let req = {
      ..@model.Request::post("/upload"),
      body: @model.Stream(@model.StreamBody::new(source)),
    }
    assert_eq(
      server.dispatch(req, Map([]), @endpoint.DispatchContext::new()).status,
      400,
    )
  })
  assert_eq(closes.val, 2)
  assert_eq(reads.val, 1)
}

///|
test "request ownership lasts until the streamed response closes" {
  let closes = Ref(0)
  let reads = Ref(0)
  let source : &@model.BodyStream = CountedBody::{
    chunks: [b"abc"],
    index: 0,
    closed: false,
    closes,
    reads,
  }
  let endpoint = @endpoint.endpoint
    .post("/events")
    .input(@endpoint.stream_body())
    .output(@endpoint.sse_out(@schema.jint))
  let server = endpoint.serve_public(reader => {
    Ok(
      @endpoint.EventStream::from_pull(
        () => {
          match reader.read_some() {
            Some(bytes) => Some(bytes.length())
            None => None
          }
        },
        () => reader.close(),
      ),
    )
  })
  @driver.run_sync(() => {
    let req = @model.Request::post("/events").header(
      "content-type", "application/octet-stream",
    )
    let req = { ..req, body: @model.Stream(@model.StreamBody::new(source)), }
    let response = server.dispatch(
      req,
      Map([]),
      @endpoint.DispatchContext::new(),
    )
    assert_eq(closes.val, 0)
    assert_eq(reads.val, 0)
    assert_eq(@client.read_body(response.body, 1024), b"data: 3\n\n")
    assert_eq(closes.val, 1)
    response.close()
    assert_eq(closes.val, 1)
  })
}
