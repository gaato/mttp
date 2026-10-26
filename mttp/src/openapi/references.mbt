///|
/// Checks schema references without following them recursively. Local JSON
/// pointers are supported; external documents and anchors require a resolver
/// outside this package. Traversal is limited to 100,000 schema nodes and 128
/// levels, and data annotations such as examples are never treated as schemas.
pub fn check_references(spec : @apispec.OpenApi) -> Array[String] {
  let root = Json(spec)
  let pending : Array[(Json, Int32)] = []
  for _, schema in spec.components.schemas {
    pending.push((schema, 0))
  }
  for _, item in spec.paths {
    for _, operation in item.operations {
      for parameter in operation.parameters {
        pending.push((parameter.schema, 0))
      }
      if operation.request_body is Some(body) {
        for _, media in body.content {
          pending.push((media.schema, 0))
        }
      }
      for _, response in operation.responses {
        for _, media in response.content {
          pending.push((media.schema, 0))
        }
        for _, header in response.headers {
          pending.push((header.schema, 0))
        }
      }
    }
  }
  let problems = []
  let mut count = 0
  while pending.pop() is Some((schema, depth)) {
    count += 1
    if count > 100000 || depth > 128 {
      problems.push("schema traversal limit exceeded")
      break
    }
    if schema is Object(obj) {
      for keyword in ["$ref", "$dynamicRef"] {
        if obj.get(keyword) is Some(String(reference)) {
          if resolve_pointer(root, reference) is None {
            problems.push("unresolved schema reference " + reference)
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
                pending.push((child, depth + 1))
              }
            }
          "allOf" | "anyOf" | "oneOf" | "prefixItems" =>
            if value is Array(children) {
              for child in children {
                pending.push((child, depth + 1))
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
          | "else" => pending.push((value, depth + 1))
          _ => ()
        }
      }
    }
  }
  problems
}

///|
fn resolve_pointer(root : Json, reference : String) -> Json? {
  if reference == "#" {
    return Some(root)
  }
  if !reference.has_prefix("#") {
    return None
  }
  let decoded = @model.percent_decode(reference[1:].to_owned()) catch {
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
