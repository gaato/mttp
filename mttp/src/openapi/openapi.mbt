///|
/// Projects checked endpoint metadata into OpenAPI 3.1. Optional fields are
/// omitted by apispec's serializer and all local schema references are checked.
pub fn to_openapi(
  docs : Array[@endpoint.EndpointDoc],
  info : @apispec.Info,
  servers~ : Array[@apispec.Server] = [],
) -> @apispec.OpenApi raise @endpoint.DefinitionError {
  let problems = @endpoint.check_definitions(docs).filter(p => p.fatal)
  if !problems.is_empty() {
    raise @endpoint.DefinitionError(problems)
  }
  let schemas : Map[String, Json] = Map([])
  let schemes : Map[String, @apispec.SecurityScheme] = Map([])
  let paths : Map[String, @apispec.PathItem] = Map([])
  for doc in docs {
    let parameters = []
    let mut request_body : @apispec.RequestBody? = None
    let requirement : Map[String, Array[String]] = Map([])
    let mut required_auth = false
    for atom in [..doc.security, ..doc.inputs] {
      match atom.location {
        Path | Query | Header | Cookie => {
          let location = match atom.location {
            Path => "path"
            Query => "query"
            Header => "header"
            _ => "cookie"
          }
          let extensions : Map[String, Json] = if atom.rest {
            { "x-mttp-rest": true }
          } else {
            {}
          }
          parameters.push(
            @apispec.Parameter::new(
              atom.name,
              location,
              required=atom.required,
              schema=atom.schema.reference(schemas),
              description?=atom.description,
              extensions~,
            ),
          )
        }
        Auth(scheme=Signature(_), ..) =>
          parameters.push(
            @apispec.Parameter::new(
              atom.name,
              "header",
              required=atom.required,
              schema=atom.schema.reference(schemas),
              description?=atom.description,
            ),
          )
        Auth(scheme~, scheme_name~) => {
          let scheme = match scheme {
            Bearer(format~) =>
              @apispec.SecurityScheme::new(
                "http",
                scheme="bearer",
                bearer_format?=format,
              )
            Basic => @apispec.SecurityScheme::new("http", scheme="basic")
            ApiKeyHeader(name) =>
              @apispec.SecurityScheme::new("apiKey", name~, in_="header")
            ApiKeyQuery(name) =>
              @apispec.SecurityScheme::new("apiKey", name~, in_="query")
            ApiKeyCookie(name) =>
              @apispec.SecurityScheme::new("apiKey", name~, in_="cookie")
            _ => {
              problems.push(
                @endpoint.DefinitionProblem::new(
                  doc.template,
                  "unsupported security scheme",
                ),
              )
              continue
            }
          }
          if schemes.get(scheme_name) is Some(previous) && previous != scheme {
            problems.push(
              @endpoint.DefinitionProblem::new(
                doc.template,
                "conflicting security scheme " + scheme_name,
              ),
            )
          } else {
            schemes[scheme_name] = scheme
          }
          requirement[scheme_name] = []
          required_auth = required_auth || atom.required
        }
        Body(media_type~, ..) =>
          request_body = Some(
            @apispec.RequestBody::new(
              Map([
                (
                  media_type,
                  @apispec.MediaTypeObject::new(
                    schema=atom.schema.reference(schemas),
                  ),
                ),
              ]),
              required=atom.required,
            ),
          )
        RawBody | Derived | @endpoint.Location::.. => ()
      }
    }
    let security : Array[Map[String, Array[String]]] = []
    if !requirement.is_empty() {
      security.push(requirement)
      if !required_auth {
        security.push({})
      }
    }
    let responses : Map[String, @apispec.ResponseObject] = Map([])
    for variant in [..doc.outputs, ..doc.errors] {
      let headers : Map[String, @apispec.HeaderObject] = Map([])
      for name in variant.headers {
        let schema = variant.header_schemas
          .get(name.to_lower())
          .unwrap_or(@schema.string.schema())
        headers[name.to_lower()] = @apispec.HeaderObject::new(
          required=true,
          schema=schema.reference(schemas),
        )
      }
      let key = if variant.dynamic_status {
        "default"
      } else {
        variant.status.to_string()
      }
      let media = if variant.dynamic_media {
        Some("*/*")
      } else {
        variant.media_type
      }
      let description = if variant.description.is_empty() {
        @model.reason_phrase(variant.status)
      } else {
        variant.description
      }
      add_response(
        responses,
        key,
        description,
        media,
        variant.schema.map(s => s.reference(schemas)),
        headers,
      )
    }
    for status in framework_statuses(doc) {
      add_response(
        responses,
        status.to_string(),
        @model.reason_phrase(status),
        Some("application/problem+json"),
        Some({ "$ref": "#/components/schemas/Problem" }),
        {},
      )
    }
    let operation = @apispec.Operation::new(
      responses,
      operation_id?=doc.info.operation_id,
      summary?=doc.info.summary,
      description?=doc.info.description,
      tags=doc.info.tags.copy(),
      deprecated=doc.info.deprecated,
      parameters~,
      request_body?,
      security~,
    )
    let meth = doc.meth.unwrap_or(Get).to_string().to_lower()
    if !["get", "put", "post", "delete", "options", "head", "patch", "trace"].contains(
        meth,
      ) {
      problems.push(
        @endpoint.DefinitionProblem::new(
          doc.template,
          "method not supported by OpenAPI 3.1: " + meth,
        ),
      )
    }
    let template = api_template(doc)
    let item = paths.get(template).unwrap_or(@apispec.PathItem::new())
    if item.operations.contains(meth) {
      problems.push(
        @endpoint.DefinitionProblem::new(
          doc.template,
          "routes collapse to the same OpenAPI path and method",
        ),
      )
    }
    item.operations[meth] = operation
    paths[template] = item
  }
  if schemas.get("Problem") is Some(existing) && existing != problem_schema {
    problems.push(
      @endpoint.DefinitionProblem::new(
        "", "schema name Problem is reserved for framework errors",
      ),
    )
  }
  schemas["Problem"] = problem_schema
  let spec = @apispec.OpenApi::new(
    info,
    paths,
    servers=servers.copy(),
    components=@apispec.Components::new(schemas~, security_schemes=schemes),
  )
  for message in check_references(spec) {
    problems.push(@endpoint.DefinitionProblem::new("", message))
  }
  if !problems.is_empty() {
    raise @endpoint.DefinitionError(problems)
  }
  spec
}

///|
fn api_template(doc : @endpoint.EndpointDoc) -> String {
  let builder = StringBuilder()
  for segment in doc.segments {
    builder.write_char('/')
    match segment {
      Lit(value) => builder.write_string(value)
      Cap(name) | Rest(name) => builder.write_string("{" + name + "}")
      @endpoint.Seg::.. => ()
    }
  }
  let result = builder.to_string()
  if result.is_empty() {
    "/"
  } else {
    result
  }
}

///|
/// Creates a buffered endpoint serving this document as application/json.
pub fn docs_endpoint(
  spec : @apispec.OpenApi,
  path~ : String = "/openapi.json",
) -> @endpoint.ServerEndpoint {
  let document = Json(spec)
  @endpoint.endpoint
  .get(path)
  .output(@endpoint.json_out(@schema.jvalue.body()))
  .serve_public(_ => document)
}

///|
/// Reports an observed response missing from the operation's documentation.
/// A default response covers dynamic statuses; HEAD may use the GET operation.
pub fn check_documented(
  spec : @apispec.OpenApi,
  template : String,
  meth : @model.Method,
  status : Int32,
) -> String? {
  let path = template.split("...}").join("}")
  guard spec.paths.get(path) is Some(item) else {
    return Some("no path " + template)
  }
  let key = meth.to_string().to_lower()
  let operation = match item.operations.get(key) {
    Some(operation) => Some(operation)
    None => if meth is Head { item.operations.get("get") } else { None }
  }
  guard operation is Some(operation) else {
    return Some("no " + key + " on " + template)
  }
  if operation.responses.contains(status.to_string()) ||
    operation.responses.contains("default") {
    None
  } else {
    Some("undocumented status " + status.to_string() + " on " + template)
  }
}
