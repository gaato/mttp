# Endpoint test helpers

`when_endpoint` adds a typed route to BackendStub. It uses a one-endpoint Router
to perform actual input decoding and output encoding. Security inputs are
decoded, but authentication itself is intentionally bypassed. A callback
returns `Result[O, E]`; the typed client retains a declared application error
as the same ordinary value type.
For a Client with attempt or idle deadlines, pass `clock` and `timer` ports to
`when_endpoint`; they are supplied to its in-process Router Backend.

```mbt check
///|
test "verify an endpoint definition" {
  let endpoint = @endpoint.endpoint
    .get("/health")
    .output(@endpoint.no_content())
  assert_eq(@testkit.verify([endpoint.doc()]), [])
}
```

Use BackendStub's Canned response factories directly for malformed wire
responses or transport failures. `verify` returns both fatal definition
problems and advisories using the same checker as Router and OpenAPI.
Pass `adapter_max_body_bytes` to `verify` when the adapter ceiling is known;
an endpoint override above it is advisory, while schema composition problems
(including duplicate union tags) are fatal.
