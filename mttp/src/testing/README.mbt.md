# gaato/mttp/testing

Test doubles for code built on `gaato/mttp/client`. They import only
`gaato/http` and the client, so an SDK's tests do not compile the endpoint
layer.

- `BackendStub` is a strict `@mttp.Backend`: `expect` queues one-shot answers
  in FIFO order, `when` adds reusable rules after them, `sent` returns a
  `Recorded` request head, options and byte body per send, and `verify`
  fails while expectations remain. An unmatched send raises `Protocol`,
  never a retryable connection error. A `Canned` answer is a byte response,
  a `TransportError`, or a `Factory` function that receives the request and
  options.
- `fail_sends` fails the first sends of a backend with a given error, so the
  error's phase decides whether a retry may resend; `fail_after` fails a
  body stream after a byte offset.

The contract checks of `gaato/http/sim` (`check_backend_contract` and the
rest) apply to these doubles as to any backend, and the deterministic
scheduler of `gaato/http/driver` runs the async code on every target.

```mbt check
///|
test "an unsent failure is retried even for a POST" {
  let stub = @testing.BackendStub::new().when(
    request => request.meth == Post,
    @testing.Canned::bytes(201, body=b"created"),
  )
  let backend = @testing.fail_sends(
    stub,
    @mttp.TransportError(kind=Connect, phase=Dial, detail="refused"),
  )
  let client = @client.Client::new(
    backend,
    @sim.FakeClock::new(),
    retry=@client.RetryPolicy::conservative(),
  )
  let reply = @driver.run_sync(() => {
    client.send(@client.post("https://api.example/items"))
  })
  assert_eq(reply.status, 201)
  assert_eq(reply.body, Ok("created"))
  assert_eq(stub.sent().length(), 1)
}
```
