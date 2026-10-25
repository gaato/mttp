# Endpoint test helpers (experimental)

`when_endpoint` adds a typed route to BackendStub. It uses a one-endpoint Router
to perform actual input decoding and output encoding. Security inputs are
decoded, but authentication itself is intentionally bypassed. A callback can
raise a declared application error, which the typed client decodes as that
same error type.

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
