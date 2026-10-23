///|
let problem_schema : Json = {
  "type": "object",
  "properties": {
    "type": { "type": "string" },
    "title": { "type": "string" },
    "status": { "type": "integer" },
    "errors": { "type": "array" },
  },
}

///|
/// One response per status; content keyed by media type; two variants with
/// the same (status, media type) become a oneOf (SC-04, I-15).
fn add_response(
  responses : Map[String, @apispec.ResponseObject],
  status : Int,
  description : String,
  media : String?,
  schema : Json?,
  headers : Array[String],
) -> Unit {
  let key = status.to_string()
  let existing = responses.get(key).unwrap_or({
    description: if description == "" { @model.reason_phrase(status) } else { description },
    headers: Map::new(),
    content: Map::new(),
  })
  let content = existing.content.copy()
  if media is Some(m) {
    let s = schema.unwrap_or({})
    content[m] = match content.get(m) {
      None => { schema: s }
      Some({ schema: { "oneOf": Array(xs), .. } }) => { schema: { "oneOf": Json::array([..xs, s]) } }
      Some({ schema: prev }) => { schema: { "oneOf": [prev, s] } }
    }
  }
  let hs = existing.headers.copy()
  for h in headers {
    hs[h] = { required: true, schema: { "type": "string" } }
  }
  responses[key] = { ..existing, headers: hs, content }
}

///|
/// Statuses the framework itself can send for this endpoint.
fn framework_statuses(d : @endpoint.EndpointDoc) -> Array[Int] {
  let atoms = [..d.security, ..d.inputs]
  let out = [404, 405, 500]
  if atoms.iter().any(a => !(a.location is Auth(..))) {
    out.push(400)
  }
  if atoms.iter().any(a => a.location is Auth(..)) {
    out.push(401)
  }
  if atoms.iter().any(a => a.location is (Body(..) | RawBody)) {
    out.push(413)
    out.push(415)
  }
  out
}

///|
pub fn to_openapi(
  docs : Array[@endpoint.EndpointDoc],
  info : @apispec.Info,
  servers? : Array[@apispec.Server] = [],
) -> @apispec.OpenApi raise @endpoint.DefinitionError {
  let problems = @endpoint.check_definitions(docs).filter(p => p.fatal)
  if !problems.is_empty() {
    raise DefinitionError(problems)
  }
  let schemas : Map[String, Json] = Map::new()
  let schemes : Map[String, @apispec.SecurityScheme] = Map::new()
  let paths : Map[String, Map[String, @apispec.Operation]] = Map::new()
  schemas["Problem"] = problem_schema
  for d in docs {
    let params : Array[@apispec.Parameter] = []
    let mut request_body : @apispec.RequestBody? = None
    // all Auth atoms of one security input form ONE requirement (AND)
    let requirement : Map[String, Array[String]] = Map::new()
    for a in [..d.security, ..d.inputs] {
      match a.location {
        Path | Query | Header | Cookie => {
          let in_ = match a.location {
            Path => "path"
            Query => "query"
            Header => "header"
            _ => "cookie"
          }
          params.push({ name: a.name, in_, required: a.required, schema: a.schema.reference(schemas) })
        }
        // no OpenAPI scheme type for request signatures: a required header
        Auth(scheme=Signature(_), ..) =>
          params.push({ name: a.name, in_: "header", required: a.required, schema: { "type": "string" } })
        Auth(scheme~, scheme_name~) => {
          schemes[scheme_name] = match scheme {
            Bearer(..) => { type_: "http", scheme: Some("bearer"), name: None, in_: None }
            Basic => { type_: "http", scheme: Some("basic"), name: None, in_: None }
            _ => { type_: "apiKey", scheme: None, name: Some(a.name), in_: Some("header") }
          }
          requirement[scheme_name] = []
        }
        Body(media_type~, ..) =>
          request_body = Some({
            required: a.required,
            content: Map::from_array([(media_type, { schema: a.schema.reference(schemas) })]),
          })
        RawBody | Derived => ()
      }
    }
    let security : Array[Map[String, Array[String]]] = []
    if !requirement.is_empty() {
      security.push(requirement)
      if d.security.iter().all(a => !a.required) {
        security.push(Map::new()) // optional auth: {}
      }
    }
    let responses : Map[String, @apispec.ResponseObject] = Map::new()
    for v in [..d.outputs, ..d.errors] {
      add_response(responses, v.status, v.description, v.media_type, v.schema.map(s => s.reference(schemas)), v.headers)
    }
    for s in framework_statuses(d) {
      add_response(responses, s, "", Some("application/problem+json"), Some({ "$ref": "#/components/schemas/Problem" }), [])
    }
    let op : @apispec.Operation = {
      operationId: d.info.operation_id,
      summary: d.info.summary,
      parameters: params,
      requestBody: request_body,
      responses,
      security,
    }
    let item = paths.get(d.template).unwrap_or(Map::new())
    item[d.meth.unwrap_or(Get).to_string().to_lower()] = op
    paths[d.template] = item
  }
  { openapi: "3.1.0", info, servers, paths, components: { schemas, securitySchemes: schemes } }
}

///|
pub fn docs_endpoint(spec : @apispec.OpenApi, path? : String = "/openapi.json") -> @endpoint.ServerEndpoint {
  let json = spec.to_json()
  @endpoint.endpoint.get(path).output(@endpoint.json_out(@schema.jvalue.body())).serve_public(async fn(_) { json })
}

///|
/// Every status a server answered must be documented for that operation.
pub fn check_documented(spec : @apispec.OpenApi, template : String, meth : @model.Method, status : Int) -> String? {
  guard spec.paths.get(template) is Some(item) else { return Some("no path \{template}") }
  guard item.get(meth.to_string().to_lower()) is Some(op) else { return Some("no \{meth} on \{template}") }
  if op.responses.get(status.to_string()) is None {
    Some("\{meth} \{template}: \{status} undocumented")
  } else {
    None
  }
}
