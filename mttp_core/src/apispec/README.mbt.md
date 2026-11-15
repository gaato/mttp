# gaato/mttp_core/apispec

OpenAPI document records with their JSON codecs.

The records describe the OpenAPI documents the endpoint interpreter emits.
They type the 3.1 fixed fields and those 3.2 adds (`$self`, `itemSchema`, the
`query` operation and `additionalOperations`, tag `parent` and `kind`, and
others); the 3.2 fields stay unset in a 3.1 document, so moving to 3.2 adds no
field. They are plain data, independent of HTTP handlers and runtime I/O.
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

Encoding a value built with a constructor leaves out an optional field that is
absent and a field at its empty default (`false`, `[]`, `{}`). Decoding restores
the default and remembers when the provider wrote it explicitly, so encoding a
decoded document does not erase that member. `security` is optional rather than
defaulted, on the document and on each operation: the document's list applies
to every operation without its own, and an operation's empty list removes it.

The records type the OpenAPI 3.1 fixed fields except these, which they keep
verbatim in `unmodeled` instead, so decoding and encoding a document loses
nothing:

- `example`, `examples` and `encoding` (parameters, headers, media types);
- `links` (responses, components) and `callbacks` (operations, components);
- `components.examples`;
- OAuth `flows` of a security scheme;
- Reference Objects in path items, parameters, request bodies and security
  schemes.

An unmodeled member never replaces a typed field or an extension when
encoding.

The codecs keep wire field names such as `operationId`, `requestBody` and
`securitySchemes` apart from the MoonBit field names, and keep extension
values when a document is decoded and encoded again.
