///|
fn expect_object(
  value : Json,
  path : @json.JsonPath,
) -> Map[String, Json] raise @json.JsonDecodeError {
  match value {
    Object(obj) => obj
    _ => raise @json.JsonDecodeError((path, "expected object"))
  }
}

///|
fn[T : @json.FromJson] field(
  obj : Map[String, Json],
  name : String,
  path : @json.JsonPath,
  default? : T,
) -> T raise @json.JsonDecodeError {
  match obj.get(name) {
    Some(value) => @json.from_json(value, path=path.add_key(name))
    None =>
      match default {
        Some(value) => value
        None =>
          raise @json.JsonDecodeError(
            (path.add_key(name), "missing required field"),
          )
      }
  }
}

///|
fn extension_fields(values : Map[String, Json]) -> Map[String, Json] {
  let out : Map[String, Json] = Map([])
  for key, value in values {
    if key.has_prefix("x-") {
      out[key] = value
    }
  }
  out
}

///|
fn[T : @json.FromJson] optional_field(
  obj : Map[String, Json],
  name : String,
  path : @json.JsonPath,
) -> T? raise @json.JsonDecodeError {
  match obj.get(name) {
    None | Some(Null) => None
    Some(value) => Some(@json.from_json(value, path=path.add_key(name)))
  }
}

///|
/// The operations and metadata for one path; operation keys are lowercase
/// HTTP methods. Extensions are serialized alongside those operations.
pub(all) struct PathItem {
  operations : Map[String, Operation]
  summary : String?
  description : String?
  extensions : Map[String, Json]
} derive(Eq, Debug)

///|
/// Creates a path item with optional descriptive metadata.
pub fn PathItem::new(
  operations~ : Map[String, Operation] = {},
  summary? : String,
  description? : String,
  extensions~ : Map[String, Json] = {},
) -> PathItem {
  {
    operations: operations.copy(),
    summary,
    description,
    extensions: extensions.copy(),
  }
}

///|
/// Encodes operation fields and x-* extensions at the path-item level.
pub impl ToJson for PathItem with fn to_json(self) {
  let obj = extension_fields(self.extensions)
  for key, value in self.operations {
    if is_method(key) {
      obj[key] = Json(value)
    }
  }
  if self.summary is Some(value) {
    obj["summary"] = Json(value)
  }
  if self.description is Some(value) {
    obj["description"] = Json(value)
  }
  Json::object(obj)
}

///|
/// Decodes standard operation fields without mistaking extensions for methods.
pub impl @json.FromJson for PathItem with fn from_json(value, path) {
  let obj = expect_object(value, path)
  let operations : Map[String, Operation] = Map([])
  for key, value in obj {
    if is_method(key) {
      operations[key] = @json.from_json(value, path=path.add_key(key))
    }
  }
  {
    operations,
    summary: optional_field(obj, "summary", path),
    description: optional_field(obj, "description", path),
    extensions: extension_fields(obj),
  }
}

///|
fn is_method(key : String) -> Bool {
  match key {
    "get"
    | "put"
    | "post"
    | "delete"
    | "options"
    | "head"
    | "patch"
    | "trace" => true
    _ => false
  }
}

///|
/// Compares path items.
pub extend PathItem with Eq::{equal, not_equal}

///|
/// Formats a path item.
pub extend PathItem with @debug.Debug::{to_repr}

///|
/// Serializes a path item.
pub extend PathItem with ToJson::{to_json}

///|
/// Deserializes a path item at a JSON path.
pub extend PathItem with @json.FromJson::{from_json}
