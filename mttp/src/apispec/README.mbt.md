# OpenAPI document data (experimental)

These core-only records describe the OpenAPI 3.1 subset emitted by the endpoint
interpreter. They are plain data, independent of HTTP handlers and runtime I/O.
Constructors supply optional defaults. JSON encoding flattens `extensions`
entries whose names start with `x-` after the fixed fields.

```mbt check
///|
test "document metadata JSON" {
  let info = @apispec.Info::new("Example", "1", extensions={ "x-owner": "team" })
  assert_eq(Json(info), {
    "title": "Example",
    "version": "1",
    "x-owner": "team",
  })
  let decoded : @apispec.Info = @json.from_json(Json(info))
  assert_eq(decoded, info)
}
```

Encoding leaves out an optional field that is absent and a field at its empty
default (`false`, `[]`, `{}`), and decoding restores the default, so a
document decodes to the value that encoded it. `Operation.security` is
optional rather than defaulted: an absent list inherits the document's
requirements and an empty one removes them.

The package is experimental, as is the endpoint layer it documents: a package
that imports it lists `gaato/mttp/apispec` in its
`allow-experimental-packages`.

The repository's `scripts/gen_apispec.mbtx` generates the record codecs from
a field table. Explicit codecs keep wire field names such as `operationId`,
`requestBody` and `securitySchemes` separate from MoonBit names and retain
extension values when a document is decoded and encoded again.
