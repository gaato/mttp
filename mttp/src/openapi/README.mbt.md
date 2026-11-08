# OpenAPI from endpoints (experimental)

`to_openapi` projects checked endpoint definitions onto
[OpenAPI 3.1](https://spec.openapis.org/oas/v3.1.1.html). It merges response
representations by status and media type, includes framework problem responses,
retains typed response-header schemas and combines security inputs with AND.
An all-optional authentication input also permits anonymous requests.
Optional credentials are grouped with AND; mixed required and optional inputs
also have an alternative containing just the required credentials. Every
projected operation has explicit security, including `[]` for public routes,
so adding document-level security later cannot accidentally protect a public
endpoint. The projection itself leaves root security absent.

Path literals use the endpoint client's shared encoding, so the source
template `/files/a%2Fb/{id}` is documented as `/files/a%252Fb/{id}`. Capture
placeholders stay intact. `check_documented` takes the source template and
uses the same renderer. Dot-only literal segments are refused because HTTP
transports normalize them away.

Raw-only bodies use wildcard `*/*` content and the atom's requiredness. Raw
security plus a typed body keeps the typed media/schema; either required
consumer makes the shared body required. As for typed bodies, absent raw
bodies differ from present empty bytes. Content keys use the server's shared
case-insensitive media token without parameters.

Differing schemas sharing a status and media type merge with `anyOf`, as do
differing header schemas. Their accepted values may overlap; an exclusive
`oneOf` would reject those values. A response header is required only if every
merged representation of that status supplies it, including framework problem
responses. Once any representation omits a header, it stays optional even if
later representations supply it again.
Fixed headers carry their `const` value. An SSE response describes the framed
wire body as a string and its JSON event data under `x-mttp-sse-data-schema`;
named payload schemas are hoisted and their references checked normally.
Form schemas admit scalar strings and repeated string arrays for each name.

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
The walk includes schemas in component responses, parameters, request bodies,
headers, path items and webhooks, as well as normal operations. It visits one
child at a time, so a wide schema cannot first allocate an unbounded worklist.

Dynamic output statuses use the default response and dynamic content types use
`*/*`. Rest-path captures use a normal path parameter plus `x-mttp-rest`; generic
OpenAPI clients do not know its slash-separated array encoding. Routes which
would collapse to the same documented operation are refused.
The shared definition checker also refuses equivalent hierarchies with
different capture names across methods, because separate `/pets/{id}` and
`/pets/{name}` Path Items would make the document invalid. Consistent names
let the methods share one Path Item. This applies to rest captures too.

Projection refuses duplicate `(name, in)` parameters (header names are compared
case-insensitively). It also refuses ordinary or signature header parameters
named Accept, Content-Type or Authorization: OpenAPI ignores those entries,
which would lose server-enforced constraints. Use typed body metadata or an
explicit authentication input where applicable. Response Content-Type must
come from a body representation rather than a Header Object for the same
reason. These failures are structured `DefinitionError` findings.

`headers()` and `query_params()` impose no fixed named-field requirements, so
they add no invented parameters. Derived inputs add no wire requirements.
Multipart is supported as an opaque body codec or stream; the endpoint layer
does not parse multipart fields. Custom input atoms and codecs must describe
their own decoding/encoding contracts, including any custom event mapping.

`docs_endpoint` serves the generated JSON as a normal buffered endpoint.
`check_documented` compares observed statuses against an operation, including
its default response and HEAD fallback to GET.
