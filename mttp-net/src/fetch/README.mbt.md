# Host-neutral fetch handlers

`fetch_handler` adapts the shared nonraising Handler to Web Request/Response.
The public externs do not expose async-runtime types. Export a function from
your application's JS package; exporting a top-level MoonBit `let` does not
create a JavaScript export.

```mbt check
///|
#cfg(target="js")
test "a fetch adapter can be assembled without a host runtime call" {
  let adapter = @fetch.fetch_handler(_ => @model.Response::new(204))
  ignore(adapter)
}
```

The host calls `fetch(request, background)`. `background` receives exactly one
Promise synchronously, before the adapter returns its response Promise. Work
registered through `model.background` before the handler returns is included
in that aggregate; it can outlive the response. Every registered task settles
before the aggregate resolves or rejects. Late scheduling is ignored. Request
abort cancels handling and response reads; already scheduled background work
has an independent lifetime owned by the host's waitUntil/shutdown policy.

The request ceiling defaults to 1 MiB. Declared overflow is rejected before
the handler (413); observed overflow remains a failure even if the handler
catches it. Invalid request framing/length is 400. Negative adapter limits or
invalid response headers/status are 500. A failure after the host response has
been returned errors its stream, because its status can no longer be changed.

Input/output chunks delivered to MoonBit or the host are at most 64 KiB. Input
retains at most one host-provided chunk within the configured ceiling; an
already allocated host chunk cannot be prevented by this adapter. An output
retains one application-provided chunk. Empty input chunks have a 1024-read
budget. The adapter prefetches one output chunk for validation, then uses a
zero-high-water-mark ReadableStream. EOF, failure, cancellation and HEAD/no-body
responses release owned streams. Input remains open for lazy response readers
(including echo) until output completes. Web Headers may combine ordinary
duplicate fields; response Set-Cookie entries remain separate on hosts with
the standard getSetCookie API.

Use `with_env(request, value)` in the Workers entry before calling the adapter;
the opaque environment is then available through the `env` attribute. Other
hosts leave it absent. The association uses a WeakMap and does not modify the
Request object.

See the [host adapters](https://github.com/gaato/mttp/tree/main/mttp-net/hosts)
for Workers, Fastly, Vercel, Deno, Bun and Lambda Function URLs. The behavior
uses the [Fetch](https://fetch.spec.whatwg.org/) and
[Streams](https://streams.spec.whatwg.org/) APIs.
