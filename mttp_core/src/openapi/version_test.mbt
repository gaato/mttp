///|
test "same SSE definitions project to 3.1 extension or 3.2 typed itemSchema" {
  let ep = @endpoint.endpoint
    .get("/events")
    .output(@endpoint.sse_out(@schema.jint))
  let mixed = @endpoint.endpoint
    .get("/mixed")
    .output(@endpoint.sse_out(@schema.jint))
    .errors(@endpoint.body_out().and_status())
  let docs = [
    ep.doc(),
    mixed.doc(),
    @endpoint.endpoint.get("/text").output(@endpoint.text_out()).doc(),
  ]
  let info = @apispec.Info::new("Events", "1")
  let old = @openapi.to_openapi(docs, info)
  let explicit_old = @openapi.to_openapi(docs, info, version=V3_1)
  assert_eq(old, explicit_old)
  let spec = @openapi.to_openapi(docs, info, version=V3_2)
  assert_eq(old.openapi, "3.1.0")
  assert_eq(spec.openapi, "3.2.0")
  let a = old.paths["/events"].operations["get"].responses["200"].content["text/event-stream"]
  let b = spec.paths["/events"].operations["get"].responses["200"].content["text/event-stream"]
  assert_eq(a.item_schema, None)
  assert_eq(b.item_schema, a.extensions.get("x-oai-itemSchema"))
  assert_true(b.item_schema is Some(_))
  assert_eq(a.schema, Some({ "type": "string" }))
  assert_eq(b.schema, None)
  assert_eq(
    spec.paths["/text"].operations["get"].responses["200"].content["text/plain"].schema,
    old.paths["/text"].operations["get"].responses["200"].content["text/plain"].schema,
  )
  assert_true(!b.extensions.contains("x-oai-itemSchema"))
  // A wildcard response can erase item constraints; SSE still must not
  // retain a wire-string schema as its complete-content array schema.
  let mixed_old = old.paths["/mixed"].operations["get"].responses["200"].content["text/event-stream"]
  let mixed_new = spec.paths["/mixed"].operations["get"].responses["200"].content["text/event-stream"]
  assert_true(mixed_old.schema is Some(_))
  assert_eq(mixed_new.schema, None)
  assert_eq(mixed_new.item_schema, None)
  let document = Json(spec)
  guard Json(b) is Object(media) else { fail("media object required") }
  assert_true(!media.contains("schema"))
  assert_true(media.contains("itemSchema"))
  let decoded : @apispec.OpenApi = @json.from_json(document)
  assert_eq(decoded, spec)
  assert_eq(Json(decoded), document)
  assert_eq(@openapi.check_references(spec), [])
}
