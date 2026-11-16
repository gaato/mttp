///|
fn doc(
  paths : Json,
  components~ : Json = Json::object(Map([])),
  openapi~ : String = "3.1.0",
) -> @apispec.OpenApi raise {
  @json.from_json({
    "openapi": Json::string(openapi),
    "info": { "title": "test", "version": "1" },
    "paths": paths,
    "components": components,
  })
}

///|
fn schema_doc(schema : Json) -> @apispec.OpenApi raise {
  doc({
    "/x": {
      "post": {
        "requestBody": {
          "content": { "application/json": { "schema": schema } },
        },
        "responses": {
          "200": {
            "description": "ok",
            "content": { "application/json": { "schema": schema } },
          },
        },
      },
    },
  })
}

///|
fn kinds(r : @diff.Report) -> Array[String] {
  r.request.iter().concat(r.response.iter()).map(c => c.kind.name()).collect()
}

///|
fn has(r : @diff.Report, names : Array[String]) -> Unit raise {
  guard r.to_json() is Object(fields) &&
    fields.get("request") is Some(Array(_)) &&
    fields.get("response") is Some(Array(_)) else {
    fail("invalid report JSON")
  }
  for name in names {
    assert_true(kinds(r).contains(name), msg=name)
  }
}

///|
test "paths operations and identifiers" {
  let a = doc({
    "/gone": { "get": { "responses": {} } },
    "/x": {
      "get": { "operationId": "a", "responses": {} },
      "delete": { "responses": {} },
    },
  })
  let b = doc({
    "/new": { "get": { "responses": {} } },
    "/x": {
      "get": { "operationId": "b", "responses": {} },
      "post": { "responses": {} },
    },
  })
  has(@diff.compare(a, b), [
    "path-added", "path-removed", "operation-added", "operation-removed", "operation-id-changed",
  ])
}

///|
test "parameter additions removals requiredness and location" {
  let a = doc({
    "/x": {
      "get": {
        "parameters": [
          { "name": "gone", "in": "query" },
          { "name": "required", "in": "query" },
          { "name": "move", "in": "query" },
        ],
        "responses": {},
      },
    },
  })
  let b = doc({
    "/x": {
      "get": {
        "parameters": [
          { "name": "added", "in": "query", "required": true },
          { "name": "optional", "in": "query" },
          { "name": "required", "in": "query", "required": true },
          { "name": "move", "in": "header" },
        ],
        "responses": {},
      },
    },
  })
  let r = @diff.compare(a, b)
  has(r, [
    "parameter-added", "parameter-removed", "parameter-required-changed", "parameter-location-changed",
  ])
  has(@diff.compare(b, a), ["parameter-required-changed"])
  assert_true(
    r.request.any(c => {
      c.kind is ParameterAdded(required=false, ..) && c.client == Info
    }),
  )
  assert_true(
    r.request.any(c => {
      c.kind is ParameterAdded(required=true, ..) && c.client == Breaking
    }),
  )
}

///|
test "path parameters match position and operation overrides inherited parameter" {
  let a = doc({
    "/x/{id}": {
      "parameters": [{ "name": "id", "in": "path", "required": true }],
      "get": { "responses": {} },
    },
  })
  let b = doc({
    "/x/{key}": {
      "parameters": [{ "name": "key", "in": "path" }],
      "get": {
        "parameters": [{ "name": "key", "in": "path", "required": true }],
        "responses": {},
      },
    },
  })
  assert_eq(kinds(@diff.compare(a, b)), [])
}

///|
test "request bodies media and response status" {
  let a = doc({
    "/x": {
      "post": {
        "requestBody": {
          "content": { "text/plain": { "schema": { "type": "string" } } },
        },
        "responses": { "200": { "description": "ok" } },
      },
    },
  })
  let b = doc({
    "/x": {
      "post": {
        "requestBody": {
          "required": true,
          "content": { "application/json": { "schema": { "type": "integer" } } },
        },
        "responses": { "201": { "description": "ok" } },
      },
    },
  })
  has(@diff.compare(a, b), [
    "request-body-required-changed", "media-type-added", "media-type-removed", "response-added",
    "response-removed",
  ])
  let empty = doc({ "/x": { "post": { "responses": {} } } })
  has(@diff.compare(empty, a), ["request-body-added"])
  has(@diff.compare(empty, b), ["request-body-added"])
  has(@diff.compare(b, a), ["request-body-required-changed"])
  has(@diff.compare(a, empty), ["request-body-removed"])
}

///|
test "schema type nullability format properties and enum variances" {
  let a = schema_doc({
    "type": "object",
    "properties": {
      "gone": { "type": "string" },
      "p": { "type": "string", "enum": ["a", "b"], "format": "uuid" },
    },
    "required": ["gone"],
  })
  let b = schema_doc({
    "type": ["object", "null"],
    "properties": {
      "new": { "type": "string" },
      "p": { "type": "integer", "enum": ["b", "c"], "format": "int32" },
    },
    "required": ["new"],
  })
  let r = @diff.compare(a, b)
  has(r, [
    "type-changed", "nullable-added", "format-changed", "property-added", "property-removed",
    "required-property-added", "required-property-removed", "enum-value-added", "enum-value-removed",
  ])
  has(@diff.compare(b, a), ["nullable-removed"])
  assert_true(
    r.response.any(c => {
      c.kind is EnumValueAdded(..) && c.client == Breaking && c.server == Info
    }),
  )
  assert_true(
    r.request.any(c => c.kind is EnumValueRemoved(..) && c.client == Breaking),
  )
  has(@diff.compare(schema_doc({}), schema_doc({ "enum": [1] })), ["enum-added"])
  has(@diff.compare(schema_doc({ "enum": [1] }), schema_doc({})), [
    "enum-removed",
  ])
}

///|
test "schema bounds additionalProperties combinators and raw 3.0 keywords" {
  let null_removed = @diff.compare(
    schema_doc({ "nullable": Json::null() }),
    schema_doc({}),
  )
  assert_true(
    null_removed.request.any(c => {
      c.kind is KeywordChanged(keyword="nullable", old=Some(Null), new=None)
    }),
  )
  let a = schema_doc({
    "minimum": 0,
    "maximum": 20,
    "additionalProperties": true,
    "nullable": false,
    "exclusiveMinimum": false,
    "oneOf": [{ "type": "string" }],
    "allOf": [{ "type": "object" }],
  })
  let b = schema_doc({
    "minimum": 1,
    "maximum": 10,
    "additionalProperties": false,
    "nullable": true,
    "exclusiveMinimum": true,
    "oneOf": [{ "type": "integer" }, { "type": "string" }],
  })
  has(@diff.compare(a, b), [
    "bound-changed", "additional-properties-changed", "keyword-changed", "subschema-added",
    "subschema-removed",
  ])
  assert_false(kinds(@diff.compare(a, b)).contains("nullable-added"))
  assert_true(@diff.compare(a, b).complete())
  assert_true(@diff.compare(a, b).breaking(Client).length() > 0)
  assert_true(@diff.compare(a, b).to_json() is Object(_))
}

///|
test "local references are followed even when use sites are unchanged and cycles terminate" {
  let reference : Json = { "$ref": "#/components/schemas/A" }
  let paths : Json = {
    "/x": {
      "get": {
        "responses": {
          "200": {
            "description": "ok",
            "content": { "application/json": { "schema": reference } },
          },
        },
      },
    },
  }
  let a = doc(paths, components={
    "schemas": {
      "A": {
        "type": "object",
        "properties": { "next": reference, "v": { "enum": ["a"] } },
      },
    },
  })
  let b = doc(paths, components={
    "schemas": {
      "A": {
        "type": "object",
        "properties": { "next": reference, "v": { "enum": ["a", "b"] } },
      },
    },
  })
  let r = @diff.compare(a, b)
  has(r, ["enum-value-added"])
  assert_true(r.complete())
  assert_true(
    r.response.any(c => c.path == "/components/schemas/A/properties/v/enum"),
  )
  let c = schema_doc({ "$ref": "#/missing" })
  has(@diff.compare(schema_doc({}), c), [
    "ref-target-changed", "keyword-changed",
  ])
}

///|
test "security and servers use effective operation inheritance" {
  let a = doc({
    "/x": {
      "servers": [{ "url": "https://old" }],
      "get": { "security": [{ "key": [] }], "responses": {} },
    },
  })
  let b = doc({
    "/x": {
      "servers": [{ "url": "https://new" }],
      "get": { "security": [{ "oauth": ["write"] }], "responses": {} },
    },
  })
  has(@diff.compare(a, b), [
    "security-requirement-added", "security-requirement-removed", "server-added",
    "server-removed",
  ])
}

///|
test "comparison budget accepts exact work and marks one past incomplete" {
  let a = doc({})
  let b = doc({ "/x": {} })
  assert_true(@diff.compare(a, b, max_nodes=1).complete())
  let r = @diff.compare(a, b, max_nodes=0)
  assert_false(r.complete())
  assert_eq(kinds(r), ["limit-reached"])
  assert_true(r.to_json() is Object(_))
  assert_false(@diff.compare(a, b, max_nodes=-1).complete())
}

///|
test "reference metadata requiredness and changed targets" {
  let paths : Json = {
    "/x": {
      "post": {
        "parameters": [{ "$ref": "#/components/parameters/P" }],
        "requestBody": { "$ref": "#/components/requestBodies/B" },
        "responses": {},
      },
    },
  }
  let a = doc(paths, components={
    "parameters": { "P": { "name": "q", "in": "query" } },
    "requestBodies": { "B": { "content": {} } },
  })
  let b = doc(paths, components={
    "parameters": { "P": { "name": "q", "in": "query", "required": true } },
    "requestBodies": { "B": { "required": true, "content": {} } },
  })
  has(@diff.compare(a, b), [
    "parameter-required-changed", "request-body-required-changed",
  ])
  let c = schema_doc({ "$ref": "#/missing-a" })
  let d = schema_doc({ "$ref": "#/missing-b" })
  has(@diff.compare(c, d), ["ref-target-changed"])
}

///|
test "empty security means anonymous and adding authentication breaks" {
  let a = doc({ "/x": { "get": { "security": [], "responses": {} } } })
  let b = doc({
    "/x": { "get": { "security": [{ "key": [] }], "responses": {} } },
  })
  assert_true(
    @diff.compare(a, b).request.any(c => {
      c.kind is SecurityRequirementRemoved(..) && c.client == Breaking
    }),
  )
}

///|
test "budget also bounds unchanged schemas and repeated references" {
  let a = schema_doc({
    "properties": { "a": { "items": { "type": "string" } } },
  })
  let r = @diff.compare(a, a, max_nodes=1)
  assert_false(r.complete())
  assert_eq(kinds(r), ["limit-reached"])
  let full = @diff.compare(a, a)
  assert_true(full.complete())
  assert_eq(kinds(full), [])
}

///|
test "numeric bound directions and nested additionalProperties schemas" {
  assert_eq(
    kinds(
      @diff.compare(
        schema_doc({}),
        schema_doc({ "additionalProperties": true }),
      ),
    ),
    [],
  )
  let restricted = @diff.compare(
    schema_doc({}),
    schema_doc({ "additionalProperties": { "type": "string" } }),
  )
  assert_true(
    restricted.request.any(c => {
      c.kind is AdditionalPropertiesChanged(..) && c.client == Breaking
    }),
  )
  assert_eq(
    kinds(
      @diff.compare(
        schema_doc({ "type": ["string", "null", "integer"] }),
        schema_doc({ "type": ["integer", "string", "null"] }),
      ),
    ),
    [],
  )
  let a = schema_doc({
    "minLength": 3,
    "maxLength": 10,
    "additionalProperties": { "type": "string", "enum": ["a"] },
    "anyOf": [{ "items": { "type": "string" } }],
  })
  let b = schema_doc({
    "minLength": 2,
    "additionalProperties": { "type": "string", "enum": ["a", "b"] },
    "anyOf": [{ "items": { "type": "integer" } }],
  })
  let r = @diff.compare(a, b)
  has(r, ["bound-changed", "enum-value-added", "type-changed"])
  assert_true(
    r.request.any(c => c.kind is BoundChanged(..) && c.client == Info),
  )
  for c in r.request.iter().concat(r.response.iter()) {
    guard c.kind.to_json() is Object(fields) else {
      fail("expected change object")
    }
    assert_eq(fields.get("kind"), Some(Json::string(c.kind.name())))
    assert_eq(c.severity(Client), c.client)
    assert_eq(c.severity(Server), c.server)
  }
}

///|
test "exact paths win over a sibling with the same parameter shape" {
  let a = doc({ "/x/{digest}": { "get": { "responses": {} } } })
  let b = doc({
    "/x/{id}": { "delete": { "responses": {} } },
    "/x/{digest}": { "get": { "responses": {} } },
  })
  let r = @diff.compare(a, b)
  assert_eq(kinds(r), ["path-added"])
  assert_eq(r.breaking(Client).length(), 0)
}
