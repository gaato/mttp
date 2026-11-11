///|
/// A shared definition with wire inputs only, as a definition package would
/// declare it for both the server and the client.
let chat : @endpoint.Endpoint[
  Unit,
  String,
  @endpoint.NoError,
  String,
  @client.Buffered,
] = @endpoint.endpoint
  .post("/chat")
  .input(@endpoint.body(@schema.text_body))
  .output(@endpoint.text_out())

///|
test "serve_public_with hands the handler the request's server-only attributes" {
  let scheduled = []
  let server = chat.serve_public_with((prompt, attributes) => {
    let peer = attributes.get(@mttp.remote_addr).unwrap_or("none")
    guard attributes.get(@mttp.background) is Some(schedule) else {
      return Ok("no scheduler")
    }
    schedule(() => scheduled.push("logged \{prompt}"))
    Ok("\{prompt} from \{peer}")
  })
  @driver.run_sync(() => {
    let driver = @driver.current()
    // A test adapter: it sets what a server adapter sets before dispatch.
    let backend = @client.from_handler(request => {
      let request = request
        .attribute(@mttp.remote_addr, "203.0.113.7")
        .attribute(@mttp.background, work => ignore(driver.spawn(work)))
      server.dispatch(request, Map([]), @endpoint.DispatchContext::new())
    })
    let client = @client.Client::new(backend, @sim.FakeClock::new())
    // The client passes only the wire input: the definition has no attribute
    // input, so its input type stays `String`.
    let reply = chat.call(client, (), "hello")
    assert_eq(reply, Ok(Ok("hello from 203.0.113.7")))
    @driver.pause()
    assert_eq(scheduled, ["logged hello"])
    client.close()
    // Without the adapter, the handler sees no attributes.
    let bare = server.dispatch(
      chat.request((), "hi").raw(),
      Map([]),
      @endpoint.DispatchContext::new(),
    )
    assert_eq(bare.body.read_all(max=100), b"no scheduler")
  })
}

///|
test "serve_with authenticates before the handler and passes attributes" {
  let secured = @endpoint.endpoint
    .post("/chat")
    .security(@endpoint.bearer())
    .input(@endpoint.body(@schema.text_body))
    .output(@endpoint.text_out())
    .errors(@endpoint.one_of([@endpoint.empty_variant(403)]))
  let order = []
  let server = secured.serve_with(
    token => {
      order.push("authenticate \{token}")
      if token == "secret" {
        Ok("admin")
      } else {
        Err(())
      }
    },
    (who, prompt, attributes) => {
      let peer = attributes.get(@mttp.remote_addr).unwrap_or("none")
      order.push("handle \{who} \{prompt} \{peer}")
      Ok(prompt)
    },
  )
  @driver.run_sync(() => {
    let ctx = @endpoint.DispatchContext::new()
    let request = secured
      .request("secret", "hi")
      .raw()
      .attribute(@mttp.remote_addr, "peer")
    assert_eq(server.dispatch(request, Map([]), ctx).status, 200)
    let refused = secured
      .request("wrong", "hi")
      .raw()
      .attribute(@mttp.remote_addr, "peer")
    assert_eq(server.dispatch(refused, Map([]), ctx).status, 403)
  })
  assert_eq(order, [
    "authenticate secret", "handle admin hi peer", "authenticate wrong",
  ])
}
