// sse_body_out: event data from any body codec, such as HTML fragments for
// htmx.

///|
/// A client that reaches `server` in memory.
fn sse_client(server : @endpoint.ServerEndpoint) -> @client.Client {
  @client.Client::new(
    @client.from_handler(request => {
      server.dispatch(request, Map([]), @endpoint.DispatchContext::new())
    }),
    @sim.FakeClock::new(),
  )
}

///|
test "sse_body_out sends HTML as data lines and a client reads it back" {
  let fragments = [
    "<tr id=\"row-1\">\n  <td>one</td>\n</tr>", "<p>trailing newline</p>\n", "\n<p>leading newline and blank line</p>\n\n",
    "  <b>leading spaces</b>", "<p>日本語 🙂</p>", "",
  ]
  let rows = @endpoint.endpoint
    .get("/rows")
    .output(
      @endpoint.sse_body_out(@schema.html_body, meta=html => {
        @endpoint.SseMeta::new(id="\{html.length()}", event="row")
      }),
    )
  let server = rows.serve_public(_ => {
    Ok(@endpoint.EventStream::from_array(fragments))
  })
  @driver.run_sync(() => {
    let response = server.dispatch(
      @mttp.Request::get("/rows"),
      Map([]),
      @endpoint.DispatchContext::new(),
    )
    assert_eq(response.headers.get("content-type"), Some("text/event-stream"))
    // The HTML itself, not a JSON string literal, one data line per line.
    let wire = @utf8.decode(response.body.read_all(max=4096))
    assert_true(
      wire.has_prefix(
        (
          #|event: row
          #|id: 36
          #|data: <tr id="row-1">
          #|data:   <td>one</td>
          #|data: </tr>
          #|
          #|
        ),
      ),
    )
  })
  let client = sse_client(server)
  @driver.run_sync(() => {
    let read = []
    rows
    .call_with(client, (), (), stream => {
      stream.each_item(item => {
        assert_eq(item.event, "row")
        read.push(item.data)
      })
    })
    .unwrap()
    .unwrap()
    assert_eq(read, fragments)
  })
  client.close()
}

///|
test "sse_body_out turns CR and CRLF in data into LF, as every SSE parser does" {
  let rows = @endpoint.endpoint
    .get("/rows")
    .output(@endpoint.sse_body_out(@schema.html_body))
  let server = rows.serve_public(_ => {
    Ok(@endpoint.EventStream::from_array(["<p>\r\n  a\r</p>\r\n"]))
  })
  @driver.run_sync(() => {
    let response = server.dispatch(
      @mttp.Request::get("/rows"),
      Map([]),
      @endpoint.DispatchContext::new(),
    )
    assert_eq(
      response.body.read_all(max=1024),
      b"data: <p>\ndata:   a\ndata: </p>\ndata: \n\n",
    )
  })
  let client = sse_client(server)
  @driver.run_sync(() => {
    let read = []
    rows
    .call_with(client, (), (), stream => stream.each(html => read.push(html)))
    .unwrap()
    .unwrap()
    assert_eq(read, ["<p>\n  a\n</p>\n"])
  })
  client.close()
}

///|
test "sse_body_out fails the stream when an encoding is not UTF-8" {
  let closes = Ref(0)
  let pulls = Ref(0)
  let chunks : Array[Bytes] = [b"ok", b"\xff\xfe"]
  let blobs = @endpoint.endpoint
    .get("/blobs")
    .output(@endpoint.sse_body_out(@schema.raw_bytes))
    .serve_public(_ => {
      Ok(
        @endpoint.EventStream::from_pull(
          () => {
            pulls.val += 1
            chunks.get(pulls.val - 1)
          },
          () => closes.val += 1,
        ),
      )
    })
  @driver.run_sync(() => {
    let response = blobs.dispatch(
      @mttp.Request::get("/blobs"),
      Map([]),
      @endpoint.DispatchContext::new(),
    )
    let body = match response.body {
      Stream(stream) => stream.take()
      _ => fail("expected a stream")
    }
    assert_eq(body.read_some(), Some(b"data: ok\n\n"))
    let error = try {
      let _ = body.read_some()
      "read"
    } catch {
      error => error.to_string()
    }
    inspect(
      error,
      content=(
        #|Invalid during Write: SSE data is not UTF-8
      ),
    )
    assert_eq(closes.val, 1)
    assert_eq(body.read_some(), None)
    body.close()
    assert_eq(closes.val, 1)
  })
}

///|
test "sse_body_out describes data with the codec's media type and schema" {
  let html = @endpoint.endpoint
    .get("/rows")
    .output(@endpoint.sse_body_out(@schema.html_body))
    .doc()
  let item = html.outputs[0].item_schema.unwrap().json
  guard item is { "properties": { "data": data, .. }, .. } else {
    fail("no data property")
  }
  json_inspect(data, content={
    "type": "string",
    "contentMediaType": "text/html; charset=utf-8",
    "contentSchema": { "type": "string" },
  })
  let json = @endpoint.endpoint
    .get("/numbers")
    .output(@endpoint.sse_out(@schema.jint))
    .doc()
  let item = json.outputs[0].item_schema.unwrap().json
  guard item is { "properties": { "data": data, .. }, .. } else {
    fail("no data property")
  }
  json_inspect(data, content={
    "type": "string",
    "contentMediaType": "application/json",
    "contentSchema": { "type": "integer", "format": "int32" },
  })
}
