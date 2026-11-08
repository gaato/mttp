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

///|
test "fields at their empty default are omitted and decode back to it" {
  let operation = @apispec.Operation::new({
    "204": @apispec.ResponseObject::new("No content"),
  })
  assert_eq(Json(operation), {
    "responses": { "204": { "description": "No content" } },
  })
  let decoded : @apispec.Operation = @json.from_json(Json(operation))
  assert_eq(decoded, operation)
  assert_eq(decoded.security, None)
  // `security: []` removes inherited requirements, so it is kept.
  let public = @apispec.Operation::new(
    { "204": @apispec.ResponseObject::new("No content") },
    security=[],
  )
  assert_eq(Json(public), {
    "responses": { "204": { "description": "No content" } },
    "security": [],
  })
  let decoded : @apispec.Operation = @json.from_json(Json(public))
  assert_eq(decoded.security, Some([]))
  let spec = @apispec.OpenApi::new(@apispec.Info::new("T", "1"), {})
  assert_eq(Json(spec), {
    "info": { "title": "T", "version": "1" },
    "paths": {},
    "openapi": "3.1.0",
  })
  // Defaults that carry meaning are always written.
  assert_eq(Json(@apispec.MediaTypeObject::new()), { "schema": {} })
  assert_eq(Json(@apispec.Parameter::new("id", "path", required=true)), {
    "name": "id",
    "in": "path",
    "required": true,
    "schema": {},
  })
}

///|
test "info carries summary terms contact and license" {
  let info = @apispec.Info::new(
    "Example",
    "1",
    summary="An example",
    terms_of_service="https://example.test/terms",
    contact=@apispec.Contact::new(
      name="Team",
      url="https://example.test",
      email="team@example.test",
    ),
    license=@apispec.License::new(
      "Apache 2.0",
      identifier="Apache-2.0",
      url="https://www.apache.org/licenses/LICENSE-2.0",
    ),
  )
  assert_eq(Json(info), {
    "title": "Example",
    "version": "1",
    "summary": "An example",
    "termsOfService": "https://example.test/terms",
    "contact": {
      "name": "Team",
      "url": "https://example.test",
      "email": "team@example.test",
    },
    "license": {
      "name": "Apache 2.0",
      "identifier": "Apache-2.0",
      "url": "https://www.apache.org/licenses/LICENSE-2.0",
    },
  })
  let decoded : @apispec.Info = @json.from_json(Json(info))
  assert_eq(decoded, info)
  assert_eq(Json(@apispec.Contact::new()), {})
}

///|
test "extensions follow the fixed fields and cannot replace them" {
  let tag = @apispec.Tag::new("t", extensions={
    "name": "other",
    "x-a": 1,
    "description": "dropped",
  })
  assert_eq(Json(tag).stringify(), "{\"name\":\"t\",\"x-a\":1}")
  let item = @apispec.PathItem::new(summary="s", extensions={
    "get": "not an operation",
    "x-b": true,
  })
  assert_eq(Json(item), { "summary": "s", "x-b": true })
  let decoded : @apispec.PathItem = @json.from_json({
    "summary": "s",
    "x-b": true,
    "parameters": [],
  })
  assert_eq(
    decoded,
    @apispec.PathItem::new(summary="s", extensions={ "x-b": true }),
  )
}

///|
test "decoding errors name the JSON pointer of the bad member" {
  let cases : Array[(Json, String)] = [
    ({ "info": { "title": "T" }, "paths": {} }, "/info/version"),
    (
      {
        "info": { "title": "T", "version": "1" },
        "paths": { "/a": { "get": { "responses": { "200": {} } } } },
      },
      "/paths/~1a/get/responses/200/description",
    ),
    (
      {
        "info": { "title": "T", "version": "1" },
        "paths": {},
        "servers": [{ "url": "u" }, { "url": 1 }],
      },
      "/servers/1/url",
    ),
  ]
  for case_ in cases {
    let (json, pointer) = case_
    try {
      let _ : @apispec.OpenApi = @json.from_json(json)
      fail("invalid document accepted")
    } catch {
      @json.JsonDecodeError((path, _)) =>
        assert_eq(path.to_string(), pointer, msg=json.stringify())
      error => raise error
    }
  }
}
