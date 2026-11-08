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
fn framework_statuses(doc : @endpoint.EndpointDoc) -> Array[Int32] {
  // URL/query validation can fail even on an endpoint without explicit inputs.
  let statuses = [400, 404, 405, 500]
  let atoms = [..doc.security, ..doc.inputs]
  if atoms.iter().any(a => a.location is Auth(..)) {
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
