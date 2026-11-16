///|
fn parameter_doc(parameter : Json) -> @apispec.OpenApi raise {
  doc({ "/x": { "get": { "parameters": [parameter], "responses": {} } } })
}

///|
test "review path normalization preserves suffixes and literal prefixes" {
  let a = doc({
    "/files/{id}.json": {
      "get": {
        "parameters": [{ "name": "id", "in": "path", "required": true }],
        "responses": {},
      },
    },
  })
  let b = doc({
    "/files/{id}.csv": {
      "get": {
        "parameters": [{ "name": "id", "in": "path", "required": true }],
        "responses": {},
      },
    },
  })
  has(@diff.compare(a, b), ["path-removed", "path-added"])
  let c = doc({
    "/files/prefix-{id}.json": {
      "get": {
        "parameters": [{ "name": "id", "in": "path", "required": true }],
        "responses": {},
      },
    },
  })
  let d = doc({
    "/files/prefix-{key}.json": {
      "get": {
        "parameters": [{ "name": "key", "in": "path", "required": true }],
        "responses": {},
      },
    },
  })
  assert_eq(kinds(@diff.compare(c, d)), [])
}

///|
test "review negated enum changes are never reported harmless" {
  let a = schema_doc({ "not": { "properties": { "p": { "enum": ["a"] } } } })
  let b = schema_doc({
    "not": { "properties": { "p": { "enum": ["a", "b"] } } },
  })
  let r = @diff.compare(a, b)
  assert_true(r.request.any(c => c.kind is EnumValueAdded(..)))
  assert_true(r.request.all(c => c.client != Info && c.server != Info))
  assert_true(r.response.all(c => c.client != Info && c.server != Info))
  let ar = doc(
    {
      "/x": {
        "get": {
          "responses": {
            "200": {
              "description": "ok",
              "content": {
                "application/json": {
                  "schema": {
                    "properties": {
                      "plain": { "$ref": "#/components/schemas/S" },
                      "negated": { "not": { "$ref": "#/components/schemas/S" } },
                    },
                  },
                },
              },
            },
          },
        },
      },
    },
    components={ "schemas": { "S": { "enum": ["a"] } } },
  )
  let br = doc(
    {
      "/x": {
        "get": {
          "responses": {
            "200": {
              "description": "ok",
              "content": {
                "application/json": {
                  "schema": {
                    "properties": {
                      "plain": { "$ref": "#/components/schemas/S" },
                      "negated": { "not": { "$ref": "#/components/schemas/S" } },
                    },
                  },
                },
              },
            },
          },
        },
      },
    },
    components={ "schemas": { "S": { "enum": ["a", "b"] } } },
  )
  let rr = @diff.compare(ar, br)
  assert_true(
    rr.response.any(c => c.kind is EnumValueAdded(..) && c.client == Breaking),
  )
  assert_true(
    rr.response.any(c => {
      c.kind is EnumValueAdded(..) && c.client == Warning && c.server == Warning
    }),
  )
}

///|
test "review parameter serialization compares effective style and explode" {
  let a = parameter_doc({
    "name": "q",
    "in": "query",
    "schema": { "type": "array", "items": { "type": "string" } },
    "explode": true,
  })
  let b = parameter_doc({
    "name": "q",
    "in": "query",
    "schema": { "type": "array", "items": { "type": "string" } },
    "explode": false,
  })
  assert_true(@diff.compare(a, b).breaking(Client).length() > 0)
  assert_true(@diff.compare(a, b).breaking(Server).length() > 0)
  let implicit = parameter_doc({
    "name": "q",
    "in": "query",
    "schema": { "type": "array", "items": { "type": "string" } },
  })
  let explicit = parameter_doc({
    "name": "q",
    "in": "query",
    "style": "form",
    "explode": true,
    "allowReserved": false,
    "schema": { "type": "array", "items": { "type": "string" } },
  })
  assert_eq(kinds(@diff.compare(implicit, explicit)), [])
  let styled = parameter_doc({
    "name": "q",
    "in": "query",
    "style": "spaceDelimited",
    "schema": { "type": "array", "items": { "type": "string" } },
  })
  assert_true(@diff.compare(implicit, styled).breaking(Client).length() > 0)
  for location in ["path", "header", "cookie"] {
    let style = if location == "cookie" { "form" } else { "simple" }
    let aa = parameter_doc({
      "name": "q",
      "in": Json::string(location),
      "schema": { "type": "array" },
    })
    let bb = parameter_doc({
      "name": "q",
      "in": Json::string(location),
      "style": Json::string(style),
      "explode": Json::boolean(location == "cookie"),
      "schema": { "type": "array" },
    })
    assert_eq(kinds(@diff.compare(aa, bb)), [])
  }
  let cookie_implicit = parameter_doc({
    "name": "q",
    "in": "cookie",
    "style": "cookie",
    "schema": { "type": "array" },
  })
  let cookie_explicit = parameter_doc({
    "name": "q",
    "in": "cookie",
    "style": "cookie",
    "explode": true,
    "schema": { "type": "array" },
  })
  assert_eq(kinds(@diff.compare(cookie_implicit, cookie_explicit)), [])
}

///|
test "review additionalOperations additions removals and schema changes" {
  let a = doc(
    {
      "/x": {
        "additionalOperations": {
          "COPY": {
            "requestBody": {
              "content": {
                "application/json": { "schema": { "enum": ["a", "b"] } },
              },
            },
            "responses": {},
          },
        },
      },
    },
    openapi="3.2.0",
  )
  let b = doc(
    {
      "/x": {
        "additionalOperations": {
          "COPY": {
            "requestBody": {
              "content": { "application/json": { "schema": { "enum": ["a"] } } },
            },
            "responses": {},
          },
        },
      },
    },
    openapi="3.2.0",
  )
  let empty = doc({ "/x": {} }, openapi="3.2.0")
  has(@diff.compare(a, empty), ["operation-removed"])
  has(@diff.compare(empty, a), ["operation-added"])
  let r = @diff.compare(a, b)
  assert_true(
    r
    .breaking(Client)
    .any(c => {
      c.path ==
      "/paths/~1x/additionalOperations/COPY/requestBody/content/application~1json/schema/enum"
    }),
  )
}

///|
test "review equivalent ref and inline schemas have no phantom type change" {
  let paths : Json = {
    "/x": {
      "get": {
        "responses": {
          "200": {
            "description": "ok",
            "content": {
              "application/json": {
                "schema": { "$ref": "#/components/schemas/S" },
              },
            },
          },
        },
      },
    },
  }
  let a = doc(paths, components={ "schemas": { "S": { "type": "string" } } })
  let b = doc({
    "/x": {
      "get": {
        "responses": {
          "200": {
            "description": "ok",
            "content": {
              "application/json": { "schema": { "type": "string" } },
            },
          },
        },
      },
    },
  })
  assert_eq(@diff.compare(a, b).breaking(Client).length(), 0)
  assert_eq(@diff.compare(b, a).breaking(Client).length(), 0)
  let c = doc(
    {
      "/x": {
        "get": {
          "responses": {
            "200": {
              "description": "ok",
              "content": {
                "application/json": {
                  "schema": { "$ref": "#/components/schemas/S", "maxLength": 3 },
                },
              },
            },
          },
        },
      },
    },
    components={ "schemas": { "S": { "type": "string" } } },
  )
  has(@diff.compare(a, c), ["bound-changed"])
  let inline_sibling = doc({
    "/x": {
      "get": {
        "responses": {
          "200": {
            "description": "ok",
            "content": {
              "application/json": {
                "schema": { "type": "string", "maxLength": 3 },
              },
            },
          },
        },
      },
    },
  })
  assert_eq(@diff.compare(c, inline_sibling).breaking(Client).length(), 0)
  assert_eq(@diff.compare(inline_sibling, c).breaking(Client).length(), 0)
  let overlapping = doc(
    {
      "/x": {
        "get": {
          "responses": {
            "200": {
              "description": "ok",
              "content": {
                "application/json": {
                  "schema": { "$ref": "#/components/schemas/S", "maxLength": 3 },
                },
              },
            },
          },
        },
      },
    },
    components={ "schemas": { "S": { "type": "string", "maxLength": 5 } } },
  )
  let conservative = @diff.compare(overlapping, inline_sibling)
  assert_true(conservative.complete())
  assert_true(
    conservative.response.all(c => c.client == Warning && c.server == Warning),
  )
}

///|
test "review security alternatives match scope sets" {
  let a = doc({
    "/x": {
      "get": { "security": [{ "oauth": ["read", "write"] }], "responses": {} },
    },
  })
  let b = doc({
    "/x": {
      "get": {
        "security": [{ "oauth": ["write", "read", "read"] }],
        "responses": {},
      },
    },
  })
  assert_eq(kinds(@diff.compare(a, b)), [])
  let c = doc({
    "/x": { "get": { "security": [{ "oauth": ["read"] }], "responses": {} } },
  })
  has(@diff.compare(a, c), [
    "security-requirement-added", "security-requirement-removed",
  ])
}

///|
test "review local JSON Pointers resolve array elements" {
  let paths : Json = {
    "/x": {
      "get": {
        "responses": {
          "200": {
            "description": "ok",
            "content": {
              "application/json": {
                "schema": { "$ref": "#/components/schemas/S/anyOf/0" },
              },
            },
          },
        },
      },
    },
  }
  let a = doc(paths, components={
    "schemas": { "S": { "anyOf": [{ "enum": ["a"] }] } },
  })
  let b = doc(paths, components={
    "schemas": { "S": { "anyOf": [{ "enum": ["a", "b"] }] } },
  })
  let r = @diff.compare(a, b)
  assert_true(
    r.response.any(c => {
      c.kind is EnumValueAdded(..) &&
      c.client == Breaking &&
      c.path == "/components/schemas/S/anyOf/0/enum"
    }),
  )
  for token in ["", "1", "01", "-", "-1", "+0", "999999999999999999999999"] {
    let malformed = doc(
      {
        "/x": {
          "get": {
            "responses": {
              "200": {
                "description": "ok",
                "content": {
                  "application/json": {
                    "schema": {
                      "$ref": Json::string(
                        "#/components/schemas/S/anyOf/" + token,
                      ),
                    },
                  },
                },
              },
            },
          },
        },
      },
      components={ "schemas": { "S": { "anyOf": [{ "enum": ["a"] }] } } },
    )
    let rr = @diff.compare(malformed, malformed)
    assert_true(
      rr.response.any(c => {
        c.kind is KeywordChanged(keyword="unresolved-ref", ..)
      }),
    )
  }
}

///|
test "review unresolved path item references produce warnings" {
  let a = doc({ "/x": { "$ref": "other.yaml#/Item" } })
  let b = doc({ "/x": { "$ref": "changed.yaml#/Item" } })
  let r = @diff.compare(a, b)
  assert_true(
    r.request.any(c => {
      c.path == "/paths/~1x" &&
      c.kind is KeywordChanged(keyword="unresolved-ref", ..) &&
      c.client == Warning &&
      c.server == Warning
    }),
  )
  let missing = doc({ "/x": { "$ref": "#/components/pathItems/Absent" } })
  assert_true(
    @diff.compare(missing, missing).request.any(c => {
      c.kind is KeywordChanged(keyword="unresolved-ref", ..)
    }),
  )
}
