///|
async test "typed client calls the same definitions without sockets" {
  let app = @api.application("test-token")
  defer app.close()
  let client = @mttp.client(backend=app)
  defer client.close()
  assert_eq(
    @api.hello.call(client, (), "Moon").unwrap().unwrap(),
    "Hello, Moon",
  )
  assert_eq(@api.echo.call(client, (), "hello").unwrap().unwrap(), "hello")
  assert_eq(
    @api.account.call(client, "test-token", ()).unwrap().unwrap(),
    "example account",
  )
  assert_eq(
    @api.account.call(client, "wrong", ()).unwrap(),
    Err("Invalid bearer token"),
  )
}

///|
async test "validation authentication docs and secure headers" {
  let app = @api.application("test-token")
  defer app.close()
  for body in [b"\"\"", b"not json"] {
    let response = app.dispatch(
      @mttp.Request::post("/echo")
      .set_header("content-type", "application/json")
      .body_bytes(body),
    )
    assert_eq(response.status, 400)
    assert_eq(
      response.headers.get("content-type"),
      Some("application/problem+json"),
    )
  }
  assert_eq(app.dispatch(@mttp.Request::get("/account")).status, 401)
  assert_eq(
    app.dispatch(
      @mttp.Request::post("/echo").body_bytes(
        Bytes::make(4097, b'x'),
        content_type="application/json",
      ),
    ).status,
    413,
  )
  let spec = app.dispatch(@mttp.Request::get("/openapi.json"))
  assert_eq(spec.status, 200)
  assert_eq(
    spec.body,
    Bytes(@utf8.encode(@api.specification().to_json().stringify())),
  )
  let docs = app.dispatch(@mttp.Request::get("/docs"))
  assert_eq(docs.status, 200)
  assert_eq(docs.headers.get("x-content-type-options"), Some("nosniff"))
  assert_true(docs.headers.get("content-security-policy") is Some(_))
}

///|
async test "service budget refuses the next request" {
  let app = @api.application("test-token")
  defer app.close()
  for _ in 0..<60 {
    assert_eq(app.dispatch(@mttp.Request::get("/hello/Moon")).status, 200)
  }
  let response = app.dispatch(@mttp.Request::get("/hello/Moon"))
  assert_eq(response.status, 429)
  assert_true(response.headers.get("retry-after") is Some(_))
  assert_eq(response.headers.get("x-content-type-options"), Some("nosniff"))
}

///|
test "OpenAPI golden" {
  inspect(
    @api.specification().to_json().stringify(indent=2),
    content=(
      #|{
      #|  "info": {
      #|    "title": "Example API",
      #|    "version": "1.0.0"
      #|  },
      #|  "paths": {
      #|    "/hello/{name}": {
      #|      "get": {
      #|        "responses": {
      #|          "200": {
      #|            "description": "OK",
      #|            "content": {
      #|              "application/json": {
      #|                "schema": {
      #|                  "type": "string"
      #|                }
      #|              }
      #|            }
      #|          },
      #|          "400": {
      #|            "description": "Bad Request",
      #|            "content": {
      #|              "application/problem+json": {
      #|                "schema": {
      #|                  "$ref": "#/components/schemas/Problem"
      #|                }
      #|              }
      #|            }
      #|          },
      #|          "404": {
      #|            "description": "Not Found",
      #|            "content": {
      #|              "application/problem+json": {
      #|                "schema": {
      #|                  "$ref": "#/components/schemas/Problem"
      #|                }
      #|              }
      #|            }
      #|          },
      #|          "405": {
      #|            "description": "Method Not Allowed",
      #|            "content": {
      #|              "application/problem+json": {
      #|                "schema": {
      #|                  "$ref": "#/components/schemas/Problem"
      #|                }
      #|              }
      #|            }
      #|          },
      #|          "500": {
      #|            "description": "Internal Server Error",
      #|            "content": {
      #|              "application/problem+json": {
      #|                "schema": {
      #|                  "$ref": "#/components/schemas/Problem"
      #|                }
      #|              }
      #|            }
      #|          }
      #|        },
      #|        "operationId": "hello",
      #|        "parameters": [
      #|          {
      #|            "name": "name",
      #|            "in": "path",
      #|            "required": true,
      #|            "schema": {
      #|              "type": "string"
      #|            }
      #|          }
      #|        ],
      #|        "security": []
      #|      }
      #|    },
      #|    "/echo": {
      #|      "post": {
      #|        "responses": {
      #|          "200": {
      #|            "description": "OK",
      #|            "content": {
      #|              "application/json": {
      #|                "schema": {
      #|                  "type": "string"
      #|                }
      #|              }
      #|            }
      #|          },
      #|          "400": {
      #|            "description": "Bad Request",
      #|            "content": {
      #|              "application/problem+json": {
      #|                "schema": {
      #|                  "$ref": "#/components/schemas/Problem"
      #|                }
      #|              }
      #|            }
      #|          },
      #|          "404": {
      #|            "description": "Not Found",
      #|            "content": {
      #|              "application/problem+json": {
      #|                "schema": {
      #|                  "$ref": "#/components/schemas/Problem"
      #|                }
      #|              }
      #|            }
      #|          },
      #|          "405": {
      #|            "description": "Method Not Allowed",
      #|            "content": {
      #|              "application/problem+json": {
      #|                "schema": {
      #|                  "$ref": "#/components/schemas/Problem"
      #|                }
      #|              }
      #|            }
      #|          },
      #|          "500": {
      #|            "description": "Internal Server Error",
      #|            "content": {
      #|              "application/problem+json": {
      #|                "schema": {
      #|                  "$ref": "#/components/schemas/Problem"
      #|                }
      #|              }
      #|            }
      #|          },
      #|          "413": {
      #|            "description": "Content Too Large",
      #|            "content": {
      #|              "application/problem+json": {
      #|                "schema": {
      #|                  "$ref": "#/components/schemas/Problem"
      #|                }
      #|              }
      #|            }
      #|          },
      #|          "415": {
      #|            "description": "Unsupported Media Type",
      #|            "content": {
      #|              "application/problem+json": {
      #|                "schema": {
      #|                  "$ref": "#/components/schemas/Problem"
      #|                }
      #|              }
      #|            }
      #|          }
      #|        },
      #|        "operationId": "echo",
      #|        "requestBody": {
      #|          "content": {
      #|            "application/json": {
      #|              "schema": {
      #|                "type": "string",
      #|                "minLength": 1,
      #|                "maxLength": 80
      #|              }
      #|            }
      #|          },
      #|          "required": true
      #|        },
      #|        "security": []
      #|      }
      #|    },
      #|    "/account": {
      #|      "get": {
      #|        "responses": {
      #|          "200": {
      #|            "description": "OK",
      #|            "content": {
      #|              "application/json": {
      #|                "schema": {
      #|                  "type": "string"
      #|                }
      #|              }
      #|            }
      #|          },
      #|          "401": {
      #|            "description": "Unauthorized",
      #|            "content": {
      #|              "text/plain": {
      #|                "schema": {
      #|                  "type": "string"
      #|                }
      #|              },
      #|              "application/problem+json": {
      #|                "schema": {
      #|                  "$ref": "#/components/schemas/Problem"
      #|                }
      #|              }
      #|            }
      #|          },
      #|          "400": {
      #|            "description": "Bad Request",
      #|            "content": {
      #|              "application/problem+json": {
      #|                "schema": {
      #|                  "$ref": "#/components/schemas/Problem"
      #|                }
      #|              }
      #|            }
      #|          },
      #|          "404": {
      #|            "description": "Not Found",
      #|            "content": {
      #|              "application/problem+json": {
      #|                "schema": {
      #|                  "$ref": "#/components/schemas/Problem"
      #|                }
      #|              }
      #|            }
      #|          },
      #|          "405": {
      #|            "description": "Method Not Allowed",
      #|            "content": {
      #|              "application/problem+json": {
      #|                "schema": {
      #|                  "$ref": "#/components/schemas/Problem"
      #|                }
      #|              }
      #|            }
      #|          },
      #|          "500": {
      #|            "description": "Internal Server Error",
      #|            "content": {
      #|              "application/problem+json": {
      #|                "schema": {
      #|                  "$ref": "#/components/schemas/Problem"
      #|                }
      #|              }
      #|            }
      #|          }
      #|        },
      #|        "operationId": "account",
      #|        "security": [
      #|          {
      #|            "bearer": []
      #|          }
      #|        ]
      #|      }
      #|    }
      #|  },
      #|  "openapi": "3.1.0",
      #|  "components": {
      #|    "schemas": {
      #|      "Problem": {
      #|        "type": "object",
      #|        "properties": {
      #|          "type": {
      #|            "type": "string"
      #|          },
      #|          "title": {
      #|            "type": "string"
      #|          },
      #|          "status": {
      #|            "type": "integer"
      #|          },
      #|          "errors": {
      #|            "type": "array",
      #|            "items": {}
      #|          }
      #|        }
      #|      }
      #|    },
      #|    "securitySchemes": {
      #|      "bearer": {
      #|        "type": "http",
      #|        "scheme": "bearer"
      #|      }
      #|    }
      #|  }
      #|}
    ),
  )
}
