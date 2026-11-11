///|
test "item schemas of one media type merge as an inclusive union" {
  let responses : Map[String, @apispec.ResponseObject] = Map([])
  let media = Some("text/event-stream")
  let wire : Json = { "type": "string" }
  add_response(
    responses,
    "200",
    "events",
    media,
    Some(wire),
    Some({ "type": "integer" }),
    {},
  )
  add_response(
    responses,
    "200",
    "events",
    media,
    Some(wire),
    Some({ "type": "integer" }),
    {},
  )
  assert_eq(
    responses["200"].content["text/event-stream"].extensions.get(
      item_schema_extension,
    ),
    Some({ "type": "integer" }),
  )
  add_response(
    responses,
    "200",
    "events",
    media,
    Some(wire),
    Some({ "type": "string" }),
    {},
  )
  let merged = responses["200"].content["text/event-stream"]
  assert_eq(merged.schema, Some(wire))
  assert_eq(
    merged.extensions.get(item_schema_extension),
    Some({ "anyOf": [{ "type": "integer" }, { "type": "string" }] }),
  )
}

///|
test "a representation without an item schema drops the merged item schema" {
  let responses : Map[String, @apispec.ResponseObject] = Map([])
  let media = Some("text/event-stream")
  let wire : Json = { "type": "string" }
  add_response(
    responses,
    "200",
    "events",
    media,
    Some(wire),
    Some({ "type": "integer" }),
    {},
  )
  add_response(responses, "200", "events", media, Some(wire), None, {})
  assert_eq(
    responses["200"].content["text/event-stream"].extensions.get(
      item_schema_extension,
    ),
    None,
  )
}
