///|
fn content_spec(version : @openapi.OpenApiVersion) -> @apispec.OpenApi raise {
  let codec = @schema.JsonCodec::new(
      j => @schema.jint.from_json(j),
      n => Json(n),
      @schema.jint.schema().named("Count"),
    )
    .with_examples([1, 2])
    .with_default(1)
  let ep = @endpoint.endpoint
    .post("/counts")
    .security(@endpoint.bearer())
    .input(@endpoint.body(codec.body()))
    .output(@endpoint.json_out(codec.body()))
    .request_example("one", 1, summary="One count")
    .response_example(200, "two", 2)
    .tag("counts")
  let hook = @endpoint.endpoint
    .post("/counts")
    .input(@endpoint.body(codec.body()))
    .output(@endpoint.json_out(codec.body()))
    .request_example("notice", 2)
    .response_example(200, "accepted", 1, summary="Accepted")
    .tag("hooks")
  @openapi.to_openapi(
    [ep.doc()],
    @apispec.Info::new("Counts", "1"),
    version~,
    tags=[
      @apispec.Tag::new("counts", description="Count operations"),
      @apispec.Tag::new("unused", description="Reserved"),
    ],
    security=[{ "bearer": [] }],
    webhooks=[("countChanged", hook.doc())],
  )
}

///|
fn content_golden(version : @openapi.OpenApiVersion) -> Json raise {
  let spec = content_spec(version)
  let decoded : @apispec.OpenApi = @json.from_json(Json(spec))
  assert_eq(decoded, spec)
  assert_eq(Json(decoded), Json(spec))
  assert_eq(@openapi.check_references(spec), [])
  let operation = spec.paths["/counts"].operations["post"]
  let hook = spec.webhooks["countChanged"].operations["post"]
  assert_eq(hook.security, Some([]))
  {
    "openapi": Json(spec.openapi),
    "tags": Json(spec.tags),
    "security": Json(spec.security.unwrap()),
    "requestBody": Json(operation.request_body.unwrap()),
    "response": Json(operation.responses["200"]),
    "webhooks": Json(spec.webhooks),
    "schema": spec.components.schemas["Count"],
  }
}

///|
test "OpenAPI 3.1 content annotations golden" {
  json_inspect(content_golden(V3_1), content={
    "openapi": "3.1.0",
    "tags": [
      { "name": "counts", "description": "Count operations" },
      { "name": "unused", "description": "Reserved" },
      { "name": "hooks" },
    ],
    "security": [{ "bearer": [] }],
    "requestBody": {
      "content": {
        "application/json": {
          "schema": { "$ref": "#/components/schemas/Count" },
          "examples": { "one": { "value": 1, "summary": "One count" } },
        },
      },
      "required": true,
    },
    "response": {
      "description": "OK",
      "content": {
        "application/json": {
          "schema": { "$ref": "#/components/schemas/Count" },
          "examples": { "two": { "value": 2 } },
        },
      },
    },
    "webhooks": {
      "countChanged": {
        "post": {
          "responses": {
            "200": {
              "description": "OK",
              "content": {
                "application/json": {
                  "schema": { "$ref": "#/components/schemas/Count" },
                  "examples": {
                    "accepted": { "value": 1, "summary": "Accepted" },
                  },
                },
              },
            },
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
            "413": {
              "description": "Content Too Large",
              "content": {
                "application/problem+json": {
                  "schema": { "$ref": "#/components/schemas/Problem" },
                },
              },
            },
            "415": {
              "description": "Unsupported Media Type",
              "content": {
                "application/problem+json": {
                  "schema": { "$ref": "#/components/schemas/Problem" },
                },
              },
            },
          },
          "tags": ["hooks"],
          "requestBody": {
            "content": {
              "application/json": {
                "schema": { "$ref": "#/components/schemas/Count" },
                "examples": { "notice": { "value": 2 } },
              },
            },
            "required": true,
          },
          "security": [],
        },
      },
    },
    "schema": {
      "type": "integer",
      "format": "int32",
      "examples": [1, 2],
      "default": 1,
    },
  })
}

///|
test "OpenAPI 3.2 content annotations golden" {
  json_inspect(content_golden(V3_2), content={
    "openapi": "3.2.0",
    "tags": [
      { "name": "counts", "description": "Count operations" },
      { "name": "unused", "description": "Reserved" },
      { "name": "hooks" },
    ],
    "security": [{ "bearer": [] }],
    "requestBody": {
      "content": {
        "application/json": {
          "schema": { "$ref": "#/components/schemas/Count" },
          "examples": { "one": { "value": 1, "summary": "One count" } },
        },
      },
      "required": true,
    },
    "response": {
      "description": "OK",
      "content": {
        "application/json": {
          "schema": { "$ref": "#/components/schemas/Count" },
          "examples": { "two": { "value": 2 } },
        },
      },
    },
    "webhooks": {
      "countChanged": {
        "post": {
          "responses": {
            "200": {
              "description": "OK",
              "content": {
                "application/json": {
                  "schema": { "$ref": "#/components/schemas/Count" },
                  "examples": {
                    "accepted": { "value": 1, "summary": "Accepted" },
                  },
                },
              },
            },
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
            "413": {
              "description": "Content Too Large",
              "content": {
                "application/problem+json": {
                  "schema": { "$ref": "#/components/schemas/Problem" },
                },
              },
            },
            "415": {
              "description": "Unsupported Media Type",
              "content": {
                "application/problem+json": {
                  "schema": { "$ref": "#/components/schemas/Problem" },
                },
              },
            },
          },
          "tags": ["hooks"],
          "requestBody": {
            "content": {
              "application/json": {
                "schema": { "$ref": "#/components/schemas/Count" },
                "examples": { "notice": { "value": 2 } },
              },
            },
            "required": true,
          },
          "security": [],
        },
      },
    },
    "schema": {
      "type": "integer",
      "format": "int32",
      "examples": [1, 2],
      "default": 1,
    },
  })
}

///|
fn refused(
  docs : Array[@endpoint.EndpointDoc],
  webhooks~ : Array[(String, @endpoint.EndpointDoc)] = [],
  security? : Array[Map[String, Array[String]]],
) -> Array[String] {
  try {
    ignore(
      @openapi.to_openapi(
        docs,
        @apispec.Info::new("Test", "1"),
        webhooks~,
        security?,
      ),
    )
    []
  } catch {
    @endpoint.DefinitionError(ps) => ps.filter(p => p.fatal).map(p => p.message)
  }
}

///|
test "document security validates names and preserves absent versus empty requirements" {
  let doc = @endpoint.endpoint.get("/").doc()
  assert_eq(refused([doc], security=[{ "missing": [] }]), [
    "undefined document security scheme missing",
  ])
  let info = @apispec.Info::new("Test", "1")
  assert_eq(@openapi.to_openapi([doc], info).security, None)
  assert_eq(@openapi.to_openapi([doc], info, security=[]).security, Some([]))
  let secured = @endpoint.endpoint
    .post("/hook")
    .security(@endpoint.bearer())
    .doc()
  assert_eq(
    refused([doc], webhooks=[("hook", secured)], security=[{ "bearer": [] }]),
    [],
  )
}

///|
test "webhook names schema definitions operation ids and references are checked across the document" {
  let doc = @endpoint.endpoint.post("/same").doc()
  assert_eq(refused([doc], webhooks=[("a", doc), ("b", doc)]), [])
  assert_true(
    refused([], webhooks=[("a", doc), ("a", doc)]).contains(
      "duplicate webhook name a",
    ),
  )
  let identified = @endpoint.endpoint.post("/same").operation_id("same").doc()
  assert_true(
    refused([identified], webhooks=[("a", identified)]).contains(
      "duplicate operation_id same",
    ),
  )
  let codec = @schema.JsonCodec::new(
    j => j,
    j => j,
    @schema.Schema::of({ "type": "integer" }).named("Shared"),
  )
  let other = @schema.JsonCodec::new(
    j => j,
    j => j,
    @schema.Schema::of({ "type": "string" }).named("Shared"),
  )
  let first = @endpoint.endpoint
    .post("/first")
    .output(@endpoint.json_out(codec.body()))
    .doc()
  let second = @endpoint.endpoint
    .post("/second")
    .output(@endpoint.json_out(other.body()))
    .doc()
  assert_true(
    refused([first], webhooks=[("a", second)]).contains(
      "conflicting schema definition Shared",
    ),
  )
  let broken = @schema.JsonCodec::new(
    j => j,
    j => j,
    @schema.Schema::of({ "$ref": "#/components/schemas/Absent" }),
  )
  let hook = @endpoint.endpoint
    .post("/hook")
    .input(@endpoint.body(broken.body()))
    .doc()
  assert_true(
    refused([], webhooks=[("a", hook)]).contains(
      "unresolved schema reference #/components/schemas/Absent",
    ),
  )
}

///|
test "raw bodies dynamic statuses and multiple response media keep examples after merging" {
  let ep = @endpoint.endpoint
    .post("/raw")
    .input(@endpoint.raw_body())
    .output(@endpoint.text_out().and_status())
    .errors(@endpoint.json_out(@schema.jint.body(), status=409))
    .request_example("raw", "data")
    .response_example(202, "later", "pending")
    .response_example(409, "conflict", 3)
    .response_example(
      409,
      "other",
      { "$ref": "#/example-data" },
      summary="Data, not a schema",
    )
    .response_example(204, "empty", null)
  let spec = @openapi.to_openapi([ep.doc()], @apispec.Info::new("Test", "1"))
  let op = spec.paths["/raw"].operations["post"]
  assert_eq(op.request_body.unwrap().content["*/*"].unmodeled["examples"], {
    "raw": { "value": "data" },
  })
  assert_eq(op.responses["202"].content["text/plain"].unmodeled["examples"], {
    "later": { "value": "pending" },
  })
  for _, media in op.responses["409"].content {
    assert_eq(media.unmodeled["examples"], {
      "conflict": { "value": 3 },
      "other": {
        "value": { "$ref": "#/example-data" },
        "summary": "Data, not a schema",
      },
    })
  }
  assert_true(op.responses["204"].content.is_empty())
  assert_false(
    op.responses["default"].content["text/plain"].unmodeled.contains("examples"),
  )
  assert_eq(@openapi.check_references(spec), [])
  let decoded : @apispec.OpenApi = @json.from_json(Json(spec))
  assert_eq(decoded, spec)
}
