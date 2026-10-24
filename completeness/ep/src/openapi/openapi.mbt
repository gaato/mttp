///|
/// Hoists named schemas into components and refers to them.
priv struct Components {
  schemas : Map[String, Json]
}

///|
fn Components::refer(self : Components, s : @schema.Schema) -> Json {
  match s.name {
    None => s.json
    Some(n) => {
      self.schemas[n] = s.json
      { "$ref": "#/components/schemas/\{n}".to_json() }
    }
  }
}

///|
fn parameter(c : Components, a : @endpoint.Atom) -> Json? {
  let where_ = match a.location {
    Path => "path"
    Query => "query"
    Header => "header"
    Cookie => "cookie"
    _ => return None
  }
  Some({
    "name": a.name.to_json(),
    "in": where_.to_json(),
    "required": a.required.to_json(),
    "schema": c.refer(a.schema),
  })
}

///|
fn response(c : Components, v : @endpoint.VariantDoc) -> Json {
  let m : Map[String, Json] = { "description": v.description.to_json() }
  if v.media_type is Some(mt) {
    let content : Map[String, Json] = Map::new()
    let schema = match v.schema {
      Some(s) => c.refer(s)
      None => {}
    }
    content[mt] = { "schema": schema }
    m["content"] = Json::object(content)
  }
  Json::object(m)
}

///|
fn method_key(m : @model.Method) -> String {
  m.as_str().to_lower()
}

///|
/// OpenAPI 3.1 from endpoint descriptions. Every response the server can
/// send is listed: outputs, declared errors, and the implied ones.
pub fn document(
  docs : Array[@endpoint.EndpointDoc],
  title~ : String,
  version~ : String,
) -> Json {
  let c = Components::{ schemas: {} }
  let paths : Map[String, Map[String, Json]] = {}
  let schemes : Map[String, Json] = {}
  for d in docs {
    let op : Map[String, Json] = {}
    if d.info.operation_id is Some(id) {
      op["operationId"] = id.to_json()
    }
    if d.info.summary is Some(s) {
      op["summary"] = s.to_json()
    }
    if !d.info.tags.is_empty() {
      op["tags"] = d.info.tags.to_json()
    }
    let params = [..d.security, ..d.inputs].filter_map(a => parameter(c, a))
    if !params.is_empty() {
      op["parameters"] = Json::array(params)
    }
    for a in d.inputs {
      if a.location is Body(media_type~, secondary=false, ..) {
        let content : Map[String, Json] = Map::new()
        content[media_type] = { "schema": c.refer(a.schema) }
        op["requestBody"] = {
          "required": true,
          "content": Json::object(content),
        }
      }
    }
    let security = []
    for a in d.security {
      if a.location is Auth(scheme~, scheme_name~) {
        schemes[scheme_name] = match scheme {
          Bearer(..) => { "type": "http", "scheme": "bearer" }
          Basic => { "type": "http", "scheme": "basic" }
          ApiKeyHeader(n) => { "type": "apiKey", "in": "header", "name": n.to_json() }
          ApiKeyQuery(n) => { "type": "apiKey", "in": "query", "name": n.to_json() }
        }
        let req = Map::new()
        req[scheme_name] = Json::array([])
        security.push(Json::object(req))
      }
    }
    if !security.is_empty() {
      op["security"] = Json::array(security)
    }
    let responses : Map[String, Json] = {}
    for v in [..d.outputs, ..d.errors] {
      responses[v.status.to_string()] = response(c, v)
    }
    for i in d.implied {
      if responses.get(i.0.to_string()) is None {
        responses[i.0.to_string()] = {
          "description": i.1.to_json(),
          "content": {
            "application/problem+json": { "schema": { "type": "object" } },
          },
        }
      }
    }
    op["responses"] = Json::object(responses)
    let key = "/" + d.segments.map(s => match s {
      Lit(l) => l
      Cap(n) => "{\{n}}"
    }).join("/")
    let item = match paths.get(key) {
      Some(m) => m
      None => {
        let m = {}
        paths[key] = m
        m
      }
    }
    item[method_key(d.meth)] = Json::object(op)
  }
  let path_json = Map::new()
  for k, v in paths {
    path_json[k] = Json::object(v)
  }
  {
    "openapi": "3.1.0",
    "info": { "title": title.to_json(), "version": version.to_json() },
    "paths": Json::object(path_json),
    "components": {
      "schemas": Json::object(c.schemas),
      "securitySchemes": Json::object(schemes),
    },
  }
}
