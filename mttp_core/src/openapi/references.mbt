///|
/// Checks schema references without following them recursively. Local JSON
/// pointers are supported; external documents and anchors require a resolver
/// outside this package. Traversal is limited to 100,000 schema nodes and 128
/// levels, and data annotations such as examples are never treated as schemas.
pub fn check_references(spec : @apispec.OpenApi) -> Array[String] {
  let walker = ReferenceWalker::{ root: Json(spec), problems: [], count: 0, }
  for _, schema in spec.components.schemas {
    if !walker.visit(schema, 0) {
      return walker.problems
    }
  }
  for _, response in spec.components.responses {
    if !walker.response(response) {
      return walker.problems
    }
  }
  for _, parameter in spec.components.parameters {
    if !walker.parameter(parameter) {
      return walker.problems
    }
  }
  for _, body in spec.components.request_bodies {
    if !walker.content(body.content) {
      return walker.problems
    }
  }
  for _, header in spec.components.headers {
    if !walker.header(header) {
      return walker.problems
    }
  }
  if !walker.content(spec.components.media_types) {
    return walker.problems
  }
  for items in [spec.paths, spec.webhooks, spec.components.path_items] {
    for _, item in items {
      if !walker.path_item(item) {
        return walker.problems
      }
    }
  }
  walker.problems
}

///|
// Walk one child at a time: a wide schema must not fill an unbounded pending
// stack before the node budget is checked. Recursion is capped at 128 edges.
priv struct ReferenceWalker {
  root : Json
  problems : Array[String]
  mut count : Int32
}

///|
fn ReferenceWalker::visit(
  self : ReferenceWalker,
  schema : Json,
  depth : Int32,
) -> Bool {
  self.count += 1
  if self.count > 100000 || depth > 128 {
    self.problems.push("schema traversal limit exceeded")
    return false
  }
  if schema is Object(obj) {
    for keyword in ["$ref", "$dynamicRef"] {
      if obj.get(keyword) is Some(String(reference)) {
        if resolve_pointer(self.root, reference) is None {
          self.problems.push("unresolved schema reference " + reference)
        }
      }
    }
    for key, value in obj {
      match key {
        "properties"
        | "patternProperties"
        | "$defs"
        | "definitions"
        | "dependentSchemas" =>
          if value is Object(children) {
            for _, child in children {
              if !self.visit(child, depth + 1) {
                return false
              }
            }
          }
        "allOf" | "anyOf" | "oneOf" | "prefixItems" =>
          if value is Array(children) {
            for child in children {
              if !self.visit(child, depth + 1) {
                return false
              }
            }
          }
        "items"
        | "contains"
        | "additionalProperties"
        | "unevaluatedProperties"
        | "unevaluatedItems"
        | "propertyNames"
        | "not"
        | "if"
        | "then"
        | "else"
        | "contentSchema" => if !self.visit(value, depth + 1) { return false }
        _ => ()
      }
    }
  }
  true
}

///|
fn ReferenceWalker::optional(self : ReferenceWalker, schema : Json?) -> Bool {
  match schema {
    Some(schema) => self.visit(schema, 0)
    None => true
  }
}

///|
fn ReferenceWalker::content(
  self : ReferenceWalker,
  content : Map[String, @apispec.MediaTypeObject],
) -> Bool {
  for _, media in content {
    if !self.optional(media.schema) ||
      !self.optional(media.item_schema) ||
      !self.optional(media.extensions.get(item_schema_extension)) {
      return false
    }
  }
  true
}

///|
fn ReferenceWalker::parameter(
  self : ReferenceWalker,
  parameter : @apispec.Parameter,
) -> Bool {
  self.optional(parameter.schema) &&
  parameter.content.map(content => self.content(content)).unwrap_or(true)
}

///|
fn ReferenceWalker::header(
  self : ReferenceWalker,
  header : @apispec.HeaderObject,
) -> Bool {
  self.optional(header.schema) &&
  header.content.map(content => self.content(content)).unwrap_or(true)
}

///|
fn ReferenceWalker::response(
  self : ReferenceWalker,
  response : @apispec.ResponseObject,
) -> Bool {
  if !self.content(response.content) {
    return false
  }
  for _, header in response.headers {
    if !self.header(header) {
      return false
    }
  }
  true
}

///|
fn ReferenceWalker::path_item(
  self : ReferenceWalker,
  item : @apispec.PathItem,
) -> Bool {
  for parameter in item.parameters {
    if !self.parameter(parameter) {
      return false
    }
  }
  for
    operation in [
      ..item.operations.values(),
      ..item.additional_operations.values(),
    ] {
    for parameter in operation.parameters {
      if !self.parameter(parameter) {
        return false
      }
    }
    if operation.request_body is Some(body) && !self.content(body.content) {
      return false
    }
    for _, response in operation.responses {
      if !self.response(response) {
        return false
      }
    }
  }
  true
}

///|
fn resolve_pointer(root : Json, reference : String) -> Json? {
  if reference == "#" {
    return Some(root)
  }
  if !reference.has_prefix("#") {
    return None
  }
  let decoded = @mttp_core.percent_decode(reference[1:].to_owned()) catch {
    _ => return None
  }
  if !decoded.has_prefix("/") {
    return None
  }
  let mut value = root
  for raw in decoded[1:].split("/") {
    let key = pointer_key(raw.to_owned())
    guard key is Some(key) else { return None }
    value = match value {
      Object(obj) =>
        match obj.get(key) {
          Some(value) => value
          None => return None
        }
      Array(items) => {
        if key.is_empty() ||
          (key.length() > 1 && key.has_prefix("0")) ||
          !key.iter().all(c => c >= '0' && c <= '9') {
          return None
        }
        let index = @string.parse_int(key) catch { _ => return None }
        if index < 0 || index >= items.length() {
          return None
        }
        items[index]
      }
      _ => return None
    }
  }
  Some(value)
}

///|
fn pointer_key(raw : String) -> String? {
  let builder = StringBuilder()
  let mut escaped = false
  for char in raw {
    if escaped {
      match char {
        '0' => builder.write_char('~')
        '1' => builder.write_char('/')
        _ => return None
      }
      escaped = false
    } else if char == '~' {
      escaped = true
    } else {
      builder.write_char(char)
    }
  }
  if escaped {
    None
  } else {
    Some(builder.to_string())
  }
}
