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
    description="Success",
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
    responses={ "200": response },
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
    paths={ "/example": item },
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
  let operation = @apispec.Operation::new(responses={
    "204": @apispec.ResponseObject::new(description="No content"),
  })
  assert_eq(Json(operation), {
    "responses": { "204": { "description": "No content" } },
  })
  let decoded : @apispec.Operation = @json.from_json(Json(operation))
  assert_eq(decoded, operation)
  assert_eq(decoded.security, None)
  // `security: []` removes inherited requirements, so it is kept.
  let public = @apispec.Operation::new(
    responses={ "204": @apispec.ResponseObject::new(description="No content") },
    security=[],
  )
  assert_eq(Json(public), {
    "responses": { "204": { "description": "No content" } },
    "security": [],
  })
  let decoded : @apispec.Operation = @json.from_json(Json(public))
  assert_eq(decoded.security, Some([]))
  let spec = @apispec.OpenApi::new(@apispec.Info::new("T", "1"))
  assert_eq(Json(spec), {
    "info": { "title": "T", "version": "1" },
    "paths": {},
    "openapi": "3.1.0",
  })
  // A schema is optional: a parameter may describe itself by content.
  assert_eq(Json(@apispec.MediaTypeObject::new()), {})
  assert_eq(Json(@apispec.Parameter::new("id", "path", required=true)), {
    "name": "id",
    "in": "path",
    "required": true,
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
        "paths": {
          "/a": { "get": { "responses": { "200": { "description": 1 } } } },
        },
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

///|
/// Decodes `json` as a document and encodes it again.
fn round_trip(json : Json) -> Json raise {
  let spec : @apispec.OpenApi = @json.from_json(json)
  Json(spec)
}

///|
test "document security applies to operations that do not override it" {
  let json : Json = {
    "openapi": "3.1.0",
    "info": { "title": "T", "version": "1" },
    "security": [{ "bearer": [] }],
    "paths": {
      "/private": { "get": { "responses": { "200": { "description": "ok" } } } },
      "/public": {
        "get": {
          "security": [],
          "responses": { "200": { "description": "ok" } },
        },
      },
    },
    "components": {
      "securitySchemes": { "bearer": { "type": "http", "scheme": "bearer" } },
    },
  }
  assert_eq(round_trip(json), json)
  let spec : @apispec.OpenApi = @json.from_json(json)
  assert_eq(spec.security, Some([{ "bearer": [] }]))
  assert_eq(spec.paths["/private"].operations["get"].security, None)
  assert_eq(spec.paths["/public"].operations["get"].security, Some([]))
  // An empty document requirement list is kept too.
  let open : Json = {
    "openapi": "3.1.0",
    "info": { "title": "T", "version": "1" },
    "paths": {},
    "security": [],
  }
  assert_eq(round_trip(open), open)
}

///|
test "every OpenAPI 3.1 fixed field survives decoding and encoding" {
  // Modeled fields and members the records do not type (examples, links,
  // callbacks, OAuth flows, a path item $ref, encodings) alike.
  let json : Json = {
    "openapi": "3.1.0",
    "jsonSchemaDialect": "https://spec.openapis.org/oas/3.1/dialect/base",
    "info": {
      "title": "T",
      "version": "1",
      "summary": "s",
      "license": { "name": "MIT", "url": "https://opensource.org/license/mit" },
    },
    "servers": [
      {
        "url": "https://{env}.example.test",
        "variables": {
          "env": {
            "default": "api",
            "enum": ["api", "staging"],
            "description": "d",
          },
        },
      },
    ],
    "paths": {
      "/a": {
        "summary": "a",
        "servers": [{ "url": "https://a.example.test" }],
        "parameters": [
          {
            "name": "q",
            "in": "query",
            "deprecated": true,
            "allowEmptyValue": true,
            "allowReserved": true,
            "content": {
              "application/json": {
                "schema": { "type": "object" },
                "example": { "k": 1 },
                "encoding": { "k": { "contentType": "text/plain" } },
              },
            },
            "examples": { "one": { "value": "1" } },
          },
        ],
        "get": {
          "responses": {
            "200": {
              "description": "ok",
              "links": { "self": { "operationId": "get" } },
              "headers": {
                "X-Rate": {
                  "deprecated": true,
                  "style": "simple",
                  "explode": false,
                  "schema": { "type": "integer" },
                  "example": 1,
                },
              },
            },
          },
          "callbacks": { "hook": { "{$request.body#/url}": { "post": {} } } },
          "servers": [{ "url": "https://get.example.test" }],
          "externalDocs": { "url": "https://docs.example.test/get" },
        },
      },
      "/b": { "$ref": "#/components/pathItems/B" },
    },
    "webhooks": {
      "created": { "post": { "responses": { "200": { "description": "ok" } } } },
    },
    "components": {
      "schemas": { "S": { "type": "string" } },
      "responses": { "NotFound": { "description": "missing" } },
      "parameters": { "Id": { "name": "id", "in": "path", "required": true } },
      "requestBodies": {
        "Body": {
          "content": { "text/plain": { "schema": { "type": "string" } } },
        },
      },
      "headers": { "H": { "schema": { "type": "string" } } },
      "pathItems": { "B": { "summary": "b" } },
      "examples": { "E": { "value": 1 } },
      "links": { "L": { "operationId": "get" } },
      "callbacks": { "C": {} },
      "securitySchemes": {
        "oauth": {
          "type": "oauth2",
          "flows": {
            "clientCredentials": {
              "tokenUrl": "https://t.example.test",
              "scopes": {},
            },
          },
        },
        "oidc": {
          "type": "openIdConnect",
          "openIdConnectUrl": "https://id.example.test/.well-known/openid-configuration",
        },
      },
    },
    "security": [{ "oauth": [] }],
    "tags": [
      { "name": "t", "externalDocs": { "url": "https://docs.example.test/t" } },
    ],
    "externalDocs": { "url": "https://docs.example.test", "description": "d" },
    "x-top": true,
  }
  assert_eq(round_trip(json), json)
  let spec : @apispec.OpenApi = @json.from_json(json)
  assert_eq(spec.paths["/b"].unmodeled, { "$ref": "#/components/pathItems/B" })
  assert_eq(spec.components.unmodeled.length(), 3)
  assert_eq(spec.servers[0].variables["env"].enum_, ["api", "staging"])
  assert_eq(spec.extensions, { "x-top": true })
}

///|
test "unmodeled members cannot replace fields or extensions" {
  let tag = @apispec.Tag::new("t", unmodeled={
    "name": "other",
    "description": "absent but typed",
    "x-a": 1,
    "kept": "yes",
  })
  assert_eq(Json(tag), { "name": "t", "kept": "yes" })
  let item = @apispec.PathItem::new(unmodeled={ "get": {}, "$ref": "#/r" })
  assert_eq(Json(item), { "$ref": "#/r" })
}

///|
/// Encodes `value`, decodes it again and compares.
fn[T : ToJson + @json.FromJson + Eq] same_after_json(value : T) -> Unit raise {
  let decoded : T = @json.from_json(Json(value))
  if decoded != value {
    fail("changed by a round trip: " + Json(value).stringify())
  }
}

///|
test "every record keeps an unmodeled member through encoding and decoding" {
  let other : Map[String, Json] = { "zz": [1, "two"] }
  let media = @apispec.MediaTypeObject::new(unmodeled=other)
  let header = @apispec.HeaderObject::new(
    content={ "text/plain": media },
    unmodeled=other,
  )
  let docs = @apispec.ExternalDocs::new(
    "https://docs.example.test",
    description="d",
    unmodeled=other,
  )
  let server = @apispec.Server::new(
    "https://example.test",
    variables={
      "v": @apispec.ServerVariable::new("a", enum_=["a"], unmodeled=other),
    },
    unmodeled=other,
  )
  let parameter = @apispec.Parameter::new("q", "query", unmodeled=other)
  let response = @apispec.ResponseObject::new(
    description="ok",
    headers={ "h": header },
    unmodeled=other,
  )
  let body = @apispec.RequestBody::new({ "text/plain": media }, unmodeled=other)
  let operation = @apispec.Operation::new(
    responses={ "200": response },
    request_body=body,
    external_docs=docs,
    unmodeled=other,
  )
  let item = @apispec.PathItem::new(
    operations={ "get": operation },
    parameters=[parameter],
    unmodeled=other,
  )
  let scheme = @apispec.SecurityScheme::new("http", unmodeled=other)
  let components = @apispec.Components::new(
    security_schemes={ "s": scheme },
    unmodeled=other,
  )
  let info = @apispec.Info::new(
    "T",
    "1",
    contact=@apispec.Contact::new(unmodeled=other),
    license=@apispec.License::new("MIT", unmodeled=other),
    unmodeled=other,
  )
  let spec = @apispec.OpenApi::new(
    info,
    paths={ "/": item },
    servers=[server],
    components~,
    tags=[@apispec.Tag::new("t", external_docs=docs, unmodeled=other)],
    unmodeled=other,
  )
  same_after_json(media)
  same_after_json(header)
  same_after_json(docs)
  same_after_json(server)
  same_after_json(parameter)
  same_after_json(response)
  same_after_json(body)
  same_after_json(operation)
  same_after_json(item)
  same_after_json(scheme)
  same_after_json(components)
  same_after_json(info)
  same_after_json(spec)
  assert_eq(Json(media), { "zz": [1, "two"] })
}

///|
test "OpenAPI 3.2 fields are typed and round-trip" {
  let doc : Json = {
    "openapi": "3.2.0",
    "$self": "https://example.com/openapi.json",
    "info": { "title": "T", "version": "1" },
    "servers": [{ "url": "https://example.com", "name": "production" }],
    "tags": [
      { "name": "users", "summary": "Users", "parent": "admin", "kind": "nav" },
      { "name": "admin" },
    ],
    "paths": {
      "/search": {
        "query": { "responses": { "200": { "description": "found" } } },
        // 3.1 and 3.2 allow an operation without responses.
        "trace": {},
        "additionalOperations": {
          "COPY": {
            "responses": {
              // 3.2 makes a response's description optional.
              "201": { "summary": "Copy" },
            },
          },
        },
      },
      "/events": {
        "get": {
          "responses": {
            "200": {
              "description": "events",
              "content": {
                "text/event-stream": {
                  "itemSchema": { "type": "object", "required": ["data"] },
                },
              },
            },
          },
        },
      },
    },
    "components": {
      "mediaTypes": { "Events": { "itemSchema": { "type": "string" } } },
      "securitySchemes": {
        "old": {
          "type": "oauth2",
          "deprecated": true,
          "oauth2MetadataUrl": "https://example.com/.well-known/oauth-authorization-server",
        },
      },
    },
  }
  let spec : @apispec.OpenApi = @json.from_json(doc)
  assert_eq(spec.self_, Some("https://example.com/openapi.json"))
  assert_eq(spec.servers[0].name, Some("production"))
  assert_eq(spec.tags[0].parent, Some("admin"))
  assert_eq(spec.tags[0].kind, Some("nav"))
  let search = spec.paths["/search"]
  assert_true(search.operations.contains("query"))
  assert_eq(
    search.additional_operations["COPY"].responses["201"].summary,
    Some("Copy"),
  )
  assert_eq(
    spec.paths["/events"].operations["get"].responses["200"].content["text/event-stream"].item_schema,
    Some({ "type": "object", "required": ["data"] }),
  )
  assert_true(spec.components.media_types.contains("Events"))
  let old = spec.components.security_schemes["old"]
  assert_true(old.deprecated)
  assert_true(old.oauth2_metadata_url is Some(_))
  // Nothing typed lands in unmodeled, and encoding gives the document back.
  assert_eq(
    search.additional_operations["COPY"].responses["201"].description,
    None,
  )
  assert_eq(search.operations["trace"].responses, {})
  assert_eq(search.unmodeled, {})
  assert_eq(spec.to_json(), doc)
}
