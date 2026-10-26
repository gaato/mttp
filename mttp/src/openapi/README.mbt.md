# OpenAPI from endpoints (experimental)

`to_openapi` projects checked endpoint definitions onto
[OpenAPI 3.1](https://spec.openapis.org/oas/v3.1.1.html). It merges response
representations by status and media type, includes framework problem responses,
retains typed response-header schemas and combines security inputs with AND.
An all-optional authentication input also permits anonymous requests.

```mbt check
///|
test "OpenAPI endpoint projection" {
  let endpoint = @endpoint.endpoint.get("/hello").output(@endpoint.text_out())
  let spec = @openapi.to_openapi(
    [endpoint.doc()],
    @apispec.Info::new("Example", "1"),
  )
  assert_eq(@openapi.check_documented(spec, "/hello", Get, 200), None)
  assert_eq(@openapi.check_references(spec), [])
}
```

Conflicting schema names, dangling local references and conflicting security
scheme names are errors. `Problem` is reserved for the framework error schema.
Schema and security component names must be nonempty and use only ASCII
letters, digits, `.`, `_` and `-`, as required by OpenAPI's Components Object.
Reference checking supports local JSON pointers, with a 100,000-node visit
budget and 128 levels; external documents and named anchors need an external
resolver and are refused here. Example/default/const values are data and are
not interpreted as schema references.

Dynamic output statuses use the default response and dynamic content types use
`*/*`. Rest-path captures use a normal path parameter plus `x-mttp-rest`; generic
OpenAPI clients do not know its slash-separated array encoding. Routes which
would collapse to the same documented operation are refused.

`docs_endpoint` serves the generated JSON as a normal buffered endpoint.
`check_documented` compares observed statuses against an operation, including
its default response and HEAD fallback to GET.
