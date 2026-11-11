///|
test "reference traversal admits 100000 nodes and refuses the next without wide pending storage" {
  let children = Array::make(99999, Json::boolean(true))
  let spec = @apispec.OpenApi::new(
    @apispec.Info::new("Test", "1"),
    components=@apispec.Components::new(schemas={
      "Wide": { "anyOf": Json::array(children) },
    }),
  )
  assert_eq(@openapi.check_references(spec), [])
  children.push(Json::boolean(true))
  assert_eq(@openapi.check_references(spec), ["schema traversal limit exceeded"])
}

///|
test "traversal exhaustion propagates from every modeled schema position" {
  let mut deep : Json = true
  for _ in 0..<129 {
    deep = { "properties": { "child": deep } }
  }
  let content = {
    "application/json": @apispec.MediaTypeObject::new(schema=deep),
  }
  let parameter = @apispec.Parameter::new("p", "query", schema=deep)
  let header = @apispec.HeaderObject::new(schema=deep)
  let response = @apispec.ResponseObject::new(description="reply", content~)
  let body = @apispec.RequestBody::new(content)
  let info = @apispec.Info::new("Test", "1")
  for
    components in [
      @apispec.Components::new(responses={ "R": response }),
      @apispec.Components::new(responses={
        "R": @apispec.ResponseObject::new(description="reply", headers={
          "x": header,
        }),
      }),
      @apispec.Components::new(parameters={ "P": parameter }),
      @apispec.Components::new(request_bodies={ "B": body }),
      @apispec.Components::new(headers={ "H": header }),
    ] {
    assert_eq(
      @openapi.check_references(@apispec.OpenApi::new(info, components~)),
      ["schema traversal limit exceeded"],
    )
  }
  for
    item in [
      @apispec.PathItem::new(parameters=[parameter]),
      @apispec.PathItem::new(operations={
        "get": @apispec.Operation::new(responses={}, parameters=[parameter]),
      }),
      @apispec.PathItem::new(operations={
        "post": @apispec.Operation::new(responses={}, request_body=body),
      }),
      @apispec.PathItem::new(operations={
        "get": @apispec.Operation::new(responses={ "200": response }),
      }),
    ] {
    assert_eq(
      @openapi.check_references(
        @apispec.OpenApi::new(info, paths={ "/": item }),
      ),
      ["schema traversal limit exceeded"],
    )
  }
}

///|
test "reference traversal covers every schema keyword and ignores annotation values" {
  let bad : Json = { "$dynamicRef": "#/missing" }
  let schemas : Map[String, Json] = Map([])
  for
    keyword in [
      "properties", "patternProperties", "$defs", "definitions", "dependentSchemas",
    ] {
    schemas[keyword] = Json::object(Map([(keyword, { "child": bad })]))
  }
  for keyword in ["allOf", "anyOf", "oneOf", "prefixItems"] {
    schemas[keyword] = Json::object(Map([(keyword, [bad])]))
  }
  for
    keyword in [
      "items", "contains", "additionalProperties", "unevaluatedProperties", "unevaluatedItems",
      "propertyNames", "not", "if", "then", "else", "contentSchema",
    ] {
    schemas[keyword] = Json::object(Map([(keyword, bad)]))
  }
  schemas["Annotations"] = {
    "examples": [bad],
    "default": bad,
    "const": bad,
    "enum": [bad],
  }
  let spec = @apispec.OpenApi::new(
    @apispec.Info::new("Test", "1"),
    components=@apispec.Components::new(schemas~),
  )
  assert_eq(@openapi.check_references(spec).length(), 20)
}

///|
test "references in component media parameters headers webhooks and path items are checked" {
  let bad : Json = { "$ref": "#/missing" }
  let content = {
    "application/json": @apispec.MediaTypeObject::new(schema=bad),
  }
  let parameter = @apispec.Parameter::new("p", "query", schema=bad, content~)
  let header = @apispec.HeaderObject::new(schema=bad, content~)
  let response = @apispec.ResponseObject::new(description="reply", content~, headers={
    "x": header,
  })
  let body = @apispec.RequestBody::new(content)
  let operation = @apispec.Operation::new(
    responses={ "200": response },
    parameters=[parameter],
    request_body=body,
  )
  let item = @apispec.PathItem::new(parameters=[parameter], operations={
    "post": operation,
  })
  let spec = @apispec.OpenApi::new(
    @apispec.Info::new("Test", "1"),
    paths={ "/": item },
    webhooks={ "hook": item },
    components=@apispec.Components::new(
      responses={ "Reply": response },
      parameters={ "P": parameter },
      headers={ "H": header },
      request_bodies={ "B": body },
      path_items={ "Item": item },
    ),
  )
  assert_eq(@openapi.check_references(spec).length(), 32)
  let empty = @apispec.OpenApi::new(@apispec.Info::new("Test", "1"), paths={
    "/": @apispec.PathItem::new(
      parameters=[@apispec.Parameter::new("p", "query")],
      operations={
        "get": @apispec.Operation::new(responses={
          "200": @apispec.ResponseObject::new(
            description="ok",
            headers={ "x": @apispec.HeaderObject::new() },
            content={ "text/plain": @apispec.MediaTypeObject::new() },
          ),
        }),
      },
    ),
  })
  assert_eq(@openapi.check_references(empty), [])
}
