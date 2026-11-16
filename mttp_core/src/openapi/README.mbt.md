# gaato/mttp_core/openapi

WebSocket endpoint docs project only the handshake GET: 101, declared
parameters and security, plus `x-websocket: { "subprotocols": [...] }`.
Message schemas remain in `EndpointDoc.websocket`, including in Router.docs(),
and are not added to OpenAPI components or responses. This leaves the same
definition ready for a separate AsyncAPI projection later.

OpenAPI documents projected from endpoint definitions.

`to_openapi(..., version=V3_2)` opts into OpenAPI 3.2.0 and its typed
`itemSchema` member for SSE, omitting the complete-body `schema`: OpenAPI 3.2
maps complete SSE content to an array, while `itemSchema` validates each event
independently without requiring a finite stream. The default remains 3.1.0 with
`x-oai-itemSchema` for client-generator compatibility.

`docs_ui_endpoint(spec_url="/openapi.json")` serves Scalar at `/docs`;
`ui=SwaggerUi` selects Swagger UI, and `path` changes the route. Serve the
specification on the same origin: CSP blocks other connection origins. Assets
are pinned to Scalar 1.78.1 and Swagger UI 5.33.0 on jsDelivr, with SHA-384
SRI, anonymous CORS and no referrer. Initialization uses a fixed script hash;
the URL is HTML attribute data, never executable JavaScript. Inline styles
are allowed because both renderers generate styles. Fonts, external validators
and proxies are disabled; external specification references are blocked.

```mbt check
///|
test "serve documentation and opt into OpenAPI 3.2" {
  let spec = @openapi.to_openapi(
    [@endpoint.endpoint.get("/hello").output(@endpoint.text_out()).doc()],
    @apispec.Info::new("Example", "1"),
    version=V3_2,
  )
  let _ : Array[@endpoint.ServerEndpoint] = [
    @openapi.docs_endpoint(spec),
    @openapi.docs_ui_endpoint(spec_url="/openapi.json"),
    @openapi.docs_ui_endpoint(
      spec_url="/openapi.json",
      path="/swagger",
      ui=SwaggerUi,
    ),
  ]
  assert_eq(spec.openapi, "3.2.0")
}
```

`to_openapi` projects checked endpoint definitions onto
[OpenAPI 3.1](https://spec.openapis.org/oas/v3.1.1.html). It merges response
representations by status and media type, includes framework problem responses,
retains typed response-header schemas and combines security inputs with AND.
An all-optional authentication input also permits anonymous requests.
Optional credentials are grouped with AND; mixed required and optional inputs
also have an alternative containing just the required credentials. Every
projected operation has explicit security, including `[]` for public routes,
so adding document-level security later cannot accidentally protect a public
endpoint. Root security is absent by default; `security=` supplies a document
requirement. Each named scheme must be defined by an endpoint authentication
atom (including webhook endpoints); signatures are header parameters, not schemes.

`tags=` supplies tag descriptions. Used tags missing from that list are appended
without descriptions, and unused listed tags are retained. `webhooks=` accepts
named endpoint docs: the request is what this server sends, and the responses
are what the receiving server returns. Webhooks share schema and security
components with paths. Duplicate webhook names, conflicting component definitions
and duplicate operation IDs across paths and webhooks are definition errors.

```mbt check
///|
test "examples tags security and webhooks" {
  let codec = @schema.jint.with_examples([1, 2]).with_default(1)
  let ep = @endpoint.endpoint
    .post("/counts")
    .security(@endpoint.bearer())
    .input(@endpoint.body(codec.body()))
    .output(@endpoint.json_out(codec.body()))
    .request_example("one", 1, summary="One count")
    .response_example(200, "two", 2)
    .tag("counts")
  let spec = @openapi.to_openapi(
    [ep.doc()],
    @apispec.Info::new("Counts", "1"),
    tags=[@apispec.Tag::new("counts", description="Count operations")],
    security=[{ "bearer": [] }],
    webhooks=[("countChanged", ep.doc())],
  )
  assert_eq(spec.tags[0].description, Some("Count operations"))
  assert_true(spec.webhooks.contains("countChanged"))
  assert_eq(@openapi.check_references(spec), [])
}
```

Schema `with_examples` and `with_default` add JSON Schema annotations via
`Schema::patch`; they do not supply missing input or alter decoding. JSON
defaults use the codec's JSON encoder. Text defaults use its text encoder and
are JSON strings, even for numeric text codecs. Existing keywords retain the
conjunctive `patch` behavior when annotations are composed repeatedly.

Endpoint examples become Example Objects (`summary`, `value`) in each media
type's `examples` map, after response media merging. They are held in the
released apispec model's `unmodeled` field. Request names are unique per endpoint;
response names are unique per status. Requests require a body, and response
statuses must be declared (a dynamic-status variant covers 200–599). Examples
at dynamic statuses create explicit responses; bodyless statuses have no media
object in which to place an example. Examples apply to every representation
at the selected status, so use values appropriate for those representations.

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
Fixed headers carry their `const` value. In 3.1, an SSE response describes the
framed wire body as a string and each event under the media type's `x-oai-itemSchema`,
the OpenAPI Initiative's extension for OpenAPI 3.2's `itemSchema`: an object
with string `event`, `data` and `id`, an integer `retry`, and the JSON payload
as the `contentSchema` of `data`. Named payload schemas are hoisted and their
references checked normally.
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

Dynamic output and declared-error statuses are merged into every explicit
response, including fixed variants and framework responses. OpenAPI uses an
explicit response in preference to `default`, so default alone would lose those
representations. `default` covers the remaining final status codes. Explicit
204 and 304 responses have no content because the server discards their bodies,
including streamed bodies. Dynamic content types use `*/*`; their schemas
also join any specific media entry at that status, since OpenAPI selects the
specific entry ahead of the wildcard.
Framework problem responses follow the default router policy: 400, 404, 405
and 500, plus 401 for authentication atoms in security inputs, 413 for body
consumers and 415 for typed bodies. Authentication atoms in ordinary inputs
fail as 400. Applications replacing the router's response policies must also
describe any representations their policies introduce.
Rest-path captures use a normal path parameter plus `x-mttp-rest`; generic
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
