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
/// The Media Type Object member that holds the schema of each item of a
/// sequential media type. OpenAPI 3.2 names it `itemSchema`; the OpenAPI
/// Initiative registers this extension for documents of earlier versions.
/// Moving the documents to 3.2 renames this member.
let item_schema_extension = "x-oai-itemSchema"

///|
/// Items of a representation without an item schema are unconstrained, so
/// the union keeps an item schema only when both sides have one.
fn union_item_schemas(old : Json?, new : Json?) -> Json? {
  match (old, new) {
    (Some(old), Some(new)) if old == new => Some(old)
    (Some(old), Some(new)) => Some({ "anyOf": [old, new] })
    _ => None
  }
}

///|
fn with_item_schema(
  media : @apispec.MediaTypeObject,
  item_schema : Json?,
) -> @apispec.MediaTypeObject {
  let extensions = media.extensions.copy()
  match item_schema {
    Some(item_schema) => extensions[item_schema_extension] = item_schema
    None => extensions.remove(item_schema_extension)
  }
  { ..media, extensions, }
}

///|
fn add_response(
  responses : Map[String, @apispec.ResponseObject],
  key : String,
  description : String,
  media : String?,
  schema : Json?,
  item_schema : Json?,
  headers : Map[String, @apispec.HeaderObject],
) -> Unit {
  let existing = responses.get(key)
  let previous = existing.unwrap_or(@apispec.ResponseObject::new(description))
  let content = previous.content.copy()
  if media is Some(media) {
    let schema = schema.unwrap_or({})
    content[media] = match content.get(media) {
      None =>
        with_item_schema(@apispec.MediaTypeObject::new(schema~), item_schema)
      Some(old) =>
        with_item_schema(
          {
            ..old,
            schema: if old.schema == Some(schema) {
              old.schema
            } else {
              Some({ "anyOf": [old.schema.unwrap_or({}), schema] })
            },
          },
          union_item_schemas(
            old.extensions.get(item_schema_extension),
            item_schema,
          ),
        )
    }
  }
  let merged = previous.headers.copy()
  // A Response Object describes every representation of this status, so a
  // header omitted by even one representation cannot remain required.
  for name, header in previous.headers {
    if !headers.contains(name) {
      merged[name] = { ..header, required: false, }
    }
  }
  for name, header in headers {
    merged[name] = match merged.get(name) {
      Some(old) =>
        {
          ..old,
          required: old.required && header.required,
          schema: if old.schema == header.schema {
            old.schema
          } else {
            Some({
              "anyOf": [old.schema.unwrap_or({}), header.schema.unwrap_or({})],
            })
          },
        }
      None => { ..header, required: existing is None && header.required, }
    }
  }
  responses[key] = { ..previous, content, headers: merged, }
}

///|
fn merge_wildcard_content(
  responses : Map[String, @apispec.ResponseObject],
) -> Unit {
  for _, response in responses {
    if response.content.get("*/*") is Some(wildcard) {
      // Exact media entries take precedence over */*. A dynamic media
      // encoder can also produce those media types, so retain its schema in
      // each specific entry instead of losing it to OpenAPI's selection.
      for media, content in response.content.copy() {
        if media == "*/*" {
          continue
        }
        let schema = if content.schema == wildcard.schema {
          content.schema
        } else {
          Some({
            "anyOf": [
              content.schema.unwrap_or({}),
              wildcard.schema.unwrap_or({}),
            ],
          })
        }
        response.content[media] = with_item_schema(
          { ..content, schema, },
          union_item_schemas(
            content.extensions.get(item_schema_extension),
            wildcard.extensions.get(item_schema_extension),
          ),
        )
      }
    }
  }
}

///|
fn framework_statuses(doc : @endpoint.EndpointDoc) -> Array[Int32] {
  // URL/query validation can fail even on an endpoint without explicit inputs.
  let statuses = [400, 404, 405, 500]
  let atoms = [..doc.security, ..doc.inputs]
  // Only security-stage authentication failures use 401. The same atom in
  // ordinary inputs fails in the head stage and uses the normal 400 policy.
  if doc.security.iter().any(a => a.location is Auth(..)) {
    statuses.push(401)
  }
  if atoms.iter().any(a => a.location is (Body(..) | RawBody)) {
    statuses.push(413)
  }
  if atoms.iter().any(a => a.location is Body(..)) {
    statuses.push(415)
  }
  statuses
}
