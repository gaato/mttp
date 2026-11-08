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
fn add_response(
  responses : Map[String, @apispec.ResponseObject],
  key : String,
  description : String,
  media : String?,
  schema : Json?,
  headers : Map[String, @apispec.HeaderObject],
) -> Unit {
  let existing = responses.get(key)
  let previous = existing.unwrap_or(@apispec.ResponseObject::new(description))
  let content = previous.content.copy()
  if media is Some(media) {
    let schema = schema.unwrap_or({})
    content[media] = match content.get(media) {
      None => @apispec.MediaTypeObject::new(schema~)
      Some(old) if old.schema == Some(schema) => old
      Some(old) =>
        @apispec.MediaTypeObject::new(schema={
          "anyOf": [old.schema.unwrap_or({}), schema],
        })
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
        if media != "*/*" && content.schema != wildcard.schema {
          response.content[media] = {
            ..content,
            schema: Some({
              "anyOf": [
                content.schema.unwrap_or({}),
                wildcard.schema.unwrap_or({}),
              ],
            }),
          }
        }
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
