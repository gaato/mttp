# In-process router (experimental)

Router validates definitions at construction and dispatches through ordered
middleware. Literal segments beat captures, and a final rest capture is less
specific than an exact path. Once a path is selected, a method mismatch does
not fall through to a less specific route.

```mbt check
///|
test "in-process router example" {
  let endpoint = @endpoint.endpoint.get("/hello").output(@endpoint.text_out())
  let router = @router.Router::new([endpoint.serve_public(_ => "hello")])
  @driver.run_sync(() => {
    let response = router.dispatch(@model.Request::get("/hello"))
    assert_eq(response.body, @model.Bytes(b"hello"))
  })
  router.close()
}
```

An explicit HEAD endpoint wins; otherwise GET handles HEAD and its body is
closed and removed. OPTIONS is generated from the selected path's methods.
Default failures use application/problem+json; internal exception details and
authentication credentials are not included. Configure `ServerOptions` to
override error policies and add middleware such as `cors`.

As a Backend, Router strips local attributes in both directions and marks the
server-side remote address as `in-process`. Streaming bodies pass through
without buffering. Closing a router refuses new requests while already returned
response streams remain usable.

Middleware owns any resources it creates. Calling `next` transfers its forwarded
request to the inner handler. Router closes an inner response that middleware
replaces without taking its reader, and retains the original request until a
returned stream finishes. Taking an inner stream transfers its ownership to
middleware: a lazy wrapper must close that reader on completion, failure or
cancellation, and middleware must close any taken reader it discards.
