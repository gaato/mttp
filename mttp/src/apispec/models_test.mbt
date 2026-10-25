///|
test "OpenAPI data codecs preserve optional fields and extensions at every level" {
  let extension : Map[String, Json] = { "x-note": "retained" }
  let media = @apispec.MediaTypeObject::new(
    schema={ "type": "string" },
    extensions=extension,
  )
  let header = @apispec.HeaderObject::new(
    required=true,
    schema={ "type": "integer" },
    description="count",
    extensions=extension,
  )
  let response = @apispec.ResponseObject::new(
    "Success",
    headers={ "x-count": header },
    content={ "text/plain": media },
    extensions=extension,
  )
  let parameter = @apispec.Parameter::new(
    "q",
    "query",
    required=true,
    schema={ "type": "array" },
    description="search",
    style="form",
    explode=true,
    extensions=extension,
  )
  let request_body = @apispec.RequestBody::new(
    { "text/plain": media },
    required=true,
    description="payload",
    extensions=extension,
  )
  let operation = @apispec.Operation::new(
    { "200": response },
    operation_id="example",
    summary="summary",
    description="description",
    tags=["examples"],
    deprecated=true,
    parameters=[parameter],
    request_body~,
    security=[{ "bearer": [] }],
    extensions=extension,
  )
  let item = @apispec.PathItem::new(
    operations={ "post": operation },
    summary="path",
    description="path description",
    extensions=extension,
  )
  let security = @apispec.SecurityScheme::new(
    "http",
    scheme="bearer",
    name="token",
    in_="header",
    bearer_format="JWT",
    description="authentication",
    extensions=extension,
  )
  let components = @apispec.Components::new(
    schemas={ "String": { "type": "string" } },
    security_schemes={ "bearer": security },
    extensions=extension,
  )
  let info = @apispec.Info::new(
    "Example",
    "1",
    description="API",
    extensions=extension,
  )
  let server = @apispec.Server::new(
    "https://example.test",
    description="server",
    extensions=extension,
  )
  let tag = @apispec.Tag::new(
    "examples",
    description="tag",
    extensions=extension,
  )
  let spec = @apispec.OpenApi::new(
    info,
    { "/example": item },
    servers=[server],
    components~,
    tags=[tag],
    extensions=extension,
  )
  let json = Json(spec)
  let decoded : @apispec.OpenApi = @json.from_json(json)
  assert_eq(decoded, spec)
  assert_eq(Json(parameter), {
    "name": "q",
    "in": "query",
    "required": true,
    "schema": { "type": "array" },
    "description": "search",
    "style": "form",
    "explode": true,
    "x-note": "retained",
  })
  assert_eq(Json(security), {
    "type": "http",
    "scheme": "bearer",
    "name": "token",
    "in": "header",
    "bearerFormat": "JWT",
    "description": "authentication",
    "x-note": "retained",
  })
  assert_eq(decoded.tags[0].description, Some("tag"))
  assert_eq(decoded.paths["/example"].extensions, extension)
}

///|
test "minimal documents receive defaults and malformed required fields fail" {
  let minimal : Json = {
    "info": { "title": "Test", "version": "1" },
    "paths": {
      "/": {
        "get": { "responses": { "204": { "description": "No content" } } },
      },
    },
  }
  let decoded : @apispec.OpenApi = @json.from_json(minimal)
  assert_eq(decoded.openapi, "3.1.0")
  assert_eq(decoded.servers, [])
  assert_eq(decoded.paths["/"].operations["get"].parameters, [])
  let invalid : Array[Json] = [null, {}, { "title": 1, "version": "1" }]
  for value in invalid {
    let failed = try {
      let _ : @apispec.Info = @json.from_json(value)
      false
    } catch {
      _ => true
    }
    assert_true(failed)
  }
  let info : @apispec.Info = @json.from_json({
    "title": "Test",
    "version": "1",
    "description": null,
  })
  assert_eq(Json(info), { "title": "Test", "version": "1" })
}
