# OpenAPI document data (experimental)

These core-only records describe the OpenAPI 3.1 subset emitted by the endpoint
interpreter. They are plain data, independent of HTTP handlers and runtime I/O.
Constructors supply optional defaults. JSON encoding omits absent optional
fields and flattens `extensions` entries whose names start with `x-`.

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

`scripts/gen_apispec.mbtx` generates the repetitive record codecs from a field
table. Explicit codecs keep wire field names such as `operationId`, `requestBody`
and `securitySchemes` separate from MoonBit names and retain extension values
when a document is decoded and encoded again.
