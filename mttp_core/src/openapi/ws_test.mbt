///|
test "WebSocket OpenAPI snapshot is handshake only while docs retain message schemas" {
  let message = @schema.JsonCodec::new(
    j => @schema.jstring.from_json(j),
    value => @schema.jstring.to_json(value),
    @schema.jstring.schema().named("ChatMessage"),
  )
  let endpoint = @endpoint.ws_endpoint()
    .get("/chat/{room}")
    .input(@endpoint.path("room", @schema.string))
    .security(@endpoint.bearer())
    .messages(
      incoming=@endpoint.ws_json(message),
      outgoing=@endpoint.ws_json(message),
    )
    .subprotocols(["chat.v1"])
    .operation_id("chat")
    .summary("Join chat")
    .tag("chat")
  let router = @router.Router::new([
    endpoint.serve(_ => Ok(()), (_, _, _) => ()),
  ])
  let docs = router.docs()
  assert_eq(
    docs[0].websocket.unwrap().incoming.unwrap().name,
    Some("ChatMessage"),
  )
  let spec = @openapi.to_openapi(docs, @apispec.Info::new("Chat", "1"))
  assert_false(spec.components.schemas.contains("ChatMessage"))
  json_inspect(Json(spec.paths), content={
    "/chat/{room}": {
      "get": {
        "responses": {
          "101": { "description": "Switching Protocols" },
          "400": {
            "description": "Bad Request",
            "content": {
              "application/problem+json": {
                "schema": { "$ref": "#/components/schemas/Problem" },
              },
            },
          },
          "404": {
            "description": "Not Found",
            "content": {
              "application/problem+json": {
                "schema": { "$ref": "#/components/schemas/Problem" },
              },
            },
          },
          "405": {
            "description": "Method Not Allowed",
            "content": {
              "application/problem+json": {
                "schema": { "$ref": "#/components/schemas/Problem" },
              },
            },
          },
          "500": {
            "description": "Internal Server Error",
            "content": {
              "application/problem+json": {
                "schema": { "$ref": "#/components/schemas/Problem" },
              },
            },
          },
          "403": {
            "description": "Forbidden",
            "content": {
              "application/problem+json": {
                "schema": { "$ref": "#/components/schemas/Problem" },
              },
            },
          },
          "426": {
            "description": "Upgrade Required",
            "content": {
              "application/problem+json": {
                "schema": { "$ref": "#/components/schemas/Problem" },
              },
            },
          },
          "401": {
            "description": "Unauthorized",
            "content": {
              "application/problem+json": {
                "schema": { "$ref": "#/components/schemas/Problem" },
              },
            },
          },
        },
        "operationId": "chat",
        "summary": "Join chat",
        "tags": ["chat"],
        "parameters": [
          {
            "name": "room",
            "in": "path",
            "required": true,
            "schema": { "type": "string" },
          },
        ],
        "security": [{ "bearer": [] }],
        "x-websocket": { "subprotocols": ["chat.v1"] },
      },
    },
  })
  assert_eq(@openapi.check_documented(spec, "/chat/{room}", Get, 101), None)
  assert_eq(@openapi.check_references(spec), [])
}
