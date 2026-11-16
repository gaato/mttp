///|
test "same SSE definitions project to 3.1 extension or 3.2 typed itemSchema" {
  let ep = @endpoint.endpoint
    .get("/events")
    .output(@endpoint.sse_out(@schema.jint))
  let docs = [ep.doc()]
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
  assert_eq(b.schema, a.schema)
  assert_true(!b.extensions.contains("x-oai-itemSchema"))
  let document = Json(spec)
  let decoded : @apispec.OpenApi = @json.from_json(document)
  assert_eq(decoded, spec)
  assert_eq(Json(decoded), document)
  assert_eq(@openapi.check_references(spec), [])
}
