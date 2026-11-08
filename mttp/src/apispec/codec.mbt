///|
/// The members of an object, or a decoding error at `path`.
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
/// Decodes a member, substituting `default` when it is absent.
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
/// The `x-*` members of `values`: what decoding keeps as extensions.
fn extension_fields(values : Map[String, Json]) -> Map[String, Json] {
  let out : Map[String, Json] = Map([])
  add_extensions(out, values)
  out
}

///|
/// Adds the `x-*` members of `extensions` to an encoded object, after its
/// fixed fields. Other keys are dropped, so an extension cannot replace a
/// fixed field.
fn add_extensions(
  obj : Map[String, Json],
  extensions : Map[String, Json],
) -> Unit {
  for key, value in extensions {
    if key.has_prefix("x-") {
      obj[key] = value
    }
  }
}

///|
/// Decodes an optional member; absent and `null` are `None`.
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
#derive(Eq, Debug)
pub(all) struct PathItem {
  operations : Map[String, Operation]
  summary : String?
  description : String?
  extensions : Map[String, Json]
}

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
  let obj : Map[String, Json] = Map([])
  if self.summary is Some(value) {
    obj["summary"] = Json(value)
  }
  if self.description is Some(value) {
    obj["description"] = Json(value)
  }
  for key, value in self.operations {
    if is_method(key) {
      obj[key] = Json(value)
    }
  }
  add_extensions(obj, self.extensions)
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
/// The operation keys of a path item.
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
