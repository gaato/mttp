///|
fn main {
  // Define it: GET /hello/{name} takes a String from the path, answers text.
  let hello = @endpoint.endpoint
    .get("/hello/{name}")
    .input(@endpoint.path("name", @schema.string))
    .output(@endpoint.text_out())
    .operation_id("hello")
  // Implement it. The clock and timer let the Router keep the client's
  // deadlines when it answers in-process, as below.
  let app = @router.Router::must(
    [hello.serve_public(name => Ok("hello, \{name}"))],
    clock=@mttp_async.clock(),
    timer=@mttp_async.timer(),
  )
  @mttp_async.run(async fn() {
    // Serve it on a port: `moon run examples/tour -- 127.0.0.1:8080`.
    if @env.args() is [_, addr] {
      @server.serve(app.handler(), addr~)
      return
    }
    // Call it with the typed client: a String goes in, a String comes back.
    // The Router is a Backend too, so here it answers without a port.
    let client = @mttp_async.client(backend=app)
    defer client.close()
    match hello.request((), "moon").send(client).body {
      Ok(Ok(greeting)) => println(greeting)
      _ => println("the call failed")
    }
    // Document it: the OpenAPI 3.1 document of the same definition.
    let spec = @openapi.to_openapi(
      [hello.doc()],
      @apispec.Info::new("Hello", "1.0.0"),
    )
    println(spec.to_json().stringify(indent=2))
  })
}
