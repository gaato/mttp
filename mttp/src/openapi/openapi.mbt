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
    let parameters : Array[@apispec.Parameter] = []
    let seen_parameters : Map[String, Bool] = Map([])
    let mut request_body : @apispec.RequestBody? = None
    let mut raw_body : @schema.Schema? = None
    let mut raw_required = false
    let requirement : Map[String, Array[String]] = Map([])
    let all_schemes : Map[String, Array[String]] = Map([])
    for atom in [..doc.security, ..doc.inputs] {
      match atom.location {
        Path | Query | Header | Cookie => {
          let location = match atom.location {
            Path => "path"
            Query => "query"
            Header => "header"
            _ => "cookie"
          }
          add_parameter(
            parameters,
            seen_parameters,
            atom,
            location,
            schemas,
            problems,
            doc.template,
          )
        }
        Auth(scheme=Signature(_), ..) =>
          add_parameter(
            parameters,
            seen_parameters,
            atom,
            "header",
            schemas,
            problems,
            doc.template,
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
          if atom.required {
            requirement[scheme_name] = []
          }
          all_schemes[scheme_name] = []
        }
        Body(media_type~, ..) =>
          request_body = Some(
            @apispec.RequestBody::new(
              Map([
                (
                  @endpoint.media_type_token(media_type),
                  @apispec.MediaTypeObject::new(
                    schema=atom.schema.reference(schemas),
                  ),
                ),
              ]),
              required=atom.required,
            ),
          )
        RawBody => {
          raw_body = Some(atom.schema)
          raw_required = raw_required || atom.required
        }
        Derived | @endpoint.Location::.. => ()
      }
    }
    if raw_body is Some(schema) {
      request_body = Some(
        match request_body {
          Some(typed) => { ..typed, required: typed.required || raw_required, }
          None =>
            @apispec.RequestBody::new(
              {
                "*/*": @apispec.MediaTypeObject::new(
                  schema=schema.reference(schemas),
                ),
              },
              required=raw_required,
            )
        },
      )
    }
    let security : Array[Map[String, Array[String]]] = []
    if !requirement.is_empty() {
      security.push(requirement.copy())
    } else if !all_schemes.is_empty() {
      security.push({})
    }
    if all_schemes != requirement {
      security.push(all_schemes)
    }
    let responses : Map[String, @apispec.ResponseObject] = Map([])
    let variants = [..doc.outputs, ..doc.errors]
    let framework = framework_statuses(doc)
    let explicit_statuses = framework.copy()
    for variant in variants {
      if !variant.dynamic_status && !explicit_statuses.contains(variant.status) {
        explicit_statuses.push(variant.status)
      }
    }
    if variants.iter().any(v => v.dynamic_status) {
      // The encoder strips bodies at these statuses. They need explicit
      // responses so the body-bearing default cannot describe them.
      for status in [204, 304] {
        if !explicit_statuses.contains(status) {
          explicit_statuses.push(status)
        }
      }
    }
    for variant in variants {
      let headers : Map[String, @apispec.HeaderObject] = Map([])
      for name in variant.headers {
        if name.to_lower() == "content-type" {
          problems.push(
            @endpoint.DefinitionProblem::new(
              doc.template,
              "OpenAPI ignores response Content-Type headers; use a body representation",
            ),
          )
          continue
        }
        let schema = variant.header_schemas
          .get(name.to_lower())
          .unwrap_or(@schema.string.schema())
        headers[name.to_lower()] = @apispec.HeaderObject::new(
          required=true,
          schema=schema.reference(schemas),
        )
      }
      // An explicit Response Object shadows default in OpenAPI. Project each
      // dynamic variant at every explicit status as well, regardless of the
      // order of fixed variants, declared errors and framework responses.
      let keys = if variant.dynamic_status {
        ["default", ..explicit_statuses.map(s => s.to_string())]
      } else {
        [variant.status.to_string()]
      }
      let media = if variant.dynamic_media {
        Some("*/*")
      } else {
        variant.media_type.map(@endpoint.media_type_token)
      }
      let description = if variant.description.is_empty() {
        @http.reason_phrase(variant.status)
      } else {
        variant.description
      }
      let schema = variant.schema.map(s => s.reference(schemas))
      for key in keys {
        let bodyless = key == "204" || key == "304"
        add_response(
          responses,
          key,
          description,
          if bodyless {
            None
          } else {
            media
          },
          if bodyless {
            None
          } else {
            schema
          },
          headers,
        )
      }
    }
    for status in framework {
      add_response(
        responses,
        status.to_string(),
        @http.reason_phrase(status),
        Some("application/problem+json"),
        Some({ "$ref": "#/components/schemas/Problem" }),
        {},
      )
    }
    merge_wildcard_content(responses)
    let operation = @apispec.Operation::new(
      responses,
      operation_id?=doc.info.operation_id,
      summary?=doc.info.summary,
      description?=doc.info.description,
      tags=doc.info.tags.copy(),
      deprecated=doc.info.deprecated,
      parameters~,
      request_body?,
      // Explicit [] on public operations overrides any document-level
      // security subsequently added by the application. None would inherit.
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
    let template = @endpoint.encoded_path_template(doc.template)
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
  // OAS 3.1 Components keys are narrower than JSON Schema property names.
  // Enforce this only at projection, retaining general schema composition.
  for
    (kind, names) in [
      ("schema", schemas.keys()),
      ("security scheme", schemes.keys()),
    ] {
    for name in names {
      if name.is_empty() ||
        !name
        .iter()
        .all(c => {
          (c >= 'a' && c <= 'z') ||
          (c >= 'A' && c <= 'Z') ||
          (c >= '0' && c <= '9') ||
          c == '.' ||
          c == '_' ||
          c == '-'
        }) {
        problems.push(
          @endpoint.DefinitionProblem::new(
            "",
            "invalid OpenAPI " + kind + " component name: " + name,
          ),
        )
      }
    }
  }
  let spec = @apispec.OpenApi::new(
    info,
    paths~,
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
/// Creates a buffered endpoint serving this document as application/json.
pub fn docs_endpoint(
  spec : @apispec.OpenApi,
  path~ : String = "/openapi.json",
) -> @endpoint.ServerEndpoint {
  let document = Json(spec)
  @endpoint.endpoint
  .get(path)
  .output(@endpoint.json_out(@schema.jvalue.body()))
  .serve_public(_ => Ok(document))
}

///|
/// Reports an observed response missing from the operation's documentation.
/// A default response covers dynamic statuses; HEAD may use the GET operation.
pub fn check_documented(
  spec : @apispec.OpenApi,
  template : String,
  meth : @http.Method,
  status : Int32,
) -> String? {
  let path = @endpoint.encoded_path_template(template)
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
