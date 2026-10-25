# Script-level client

`send` uses one lazy shared client; `close` releases its idle resources. A later
send creates a new client. Use an explicitly owned `Client` for applications
that need custom backends, clocks, retry policy or independent lifetimes.

```mbt check
///|
test {
  // Constructing a request does no I/O. Pass it to @quick.send to send it.
  let request = @client.quick_request(
    @model.Request::get("https://example.test/"),
  )
  assert_true(request.to_curl().contains("example.test"))
  @quick.close()
}
```

`client.quick_request` returns a string body for any HTTP status. Other
`ClientRequest[T]` readers keep their result type through `send`. Redirects are
enabled by default; retries and cookies are not. The JS backend's fetch
restrictions also apply here; see the backend package's platform notes.
