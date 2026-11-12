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
/// The members of `obj` that are neither `known` fields nor `x-*`
/// extensions: what decoding keeps verbatim as `unmodeled`.
fn unmodeled_fields(
  obj : Map[String, Json],
  known : (String) -> Bool,
) -> Map[String, Json] {
  let out : Map[String, Json] = Map([])
  for key, value in obj {
    if !key.has_prefix("x-") && !known(key) {
      out[key] = value
    }
  }
  out
}

///|
/// Adds the unmodeled members to an encoded object, after its fixed fields.
/// A key that names a `known` field or an extension is dropped, so an
/// unmodeled member cannot replace either.
fn add_unmodeled(
  obj : Map[String, Json],
  unmodeled : Map[String, Json],
  known : (String) -> Bool,
) -> Unit {
  for key, value in unmodeled {
    if !key.has_prefix("x-") && !known(key) {
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
/// Whether `key` names a field PathItem types, operations included.
fn is_path_item_field(key : String) -> Bool {
  key
  is ("summary"
  | "description"
  | "servers"
  | "parameters"
  | "additionalOperations") ||
  is_method(key)
}

///|
/// The operations and metadata for one path; operation keys are lowercase
/// HTTP methods, and an operation under any other key is not encoded.
/// `query` (the QUERY method) and `additional_operations` (other methods,
/// keyed as sent, such as `COPY`) are OpenAPI 3.2 fields, left empty in a
/// 3.1 document.
/// Members it does not type (a `$ref`) are kept in `unmodeled`, and `x-*`
/// members in `extensions`.
#derive(Eq, Debug)
pub(all) struct PathItem {
  operations : Map[String, Operation]
  summary : String?
  description : String?
  servers : Array[Server]
  parameters : Array[Parameter]
  additional_operations : Map[String, Operation]
  unmodeled : Map[String, Json]
  extensions : Map[String, Json]
}

///|
/// Creates a path item with optional descriptive metadata.
pub fn PathItem::new(
  operations~ : Map[String, Operation] = {},
  summary? : String,
  description? : String,
  servers~ : Array[Server] = [],
  parameters~ : Array[Parameter] = [],
  additional_operations~ : Map[String, Operation] = {},
  unmodeled~ : Map[String, Json] = {},
  extensions~ : Map[String, Json] = {},
) -> PathItem {
  {
    operations: operations.copy(),
    summary,
    description,
    servers,
    parameters,
    additional_operations: additional_operations.copy(),
    unmodeled: unmodeled.copy(),
    extensions: extensions.copy(),
  }
}

///|
/// Encodes the metadata, the operations, the unmodeled members and the
/// extensions of a path item.
pub impl ToJson for PathItem with fn to_json(self) {
  let obj : Map[String, Json] = Map([])
  if self.summary is Some(value) {
    obj["summary"] = Json(value)
  }
  if self.description is Some(value) {
    obj["description"] = Json(value)
  }
  if !self.servers.is_empty() {
    obj["servers"] = Json(self.servers)
  }
  if !self.parameters.is_empty() {
    obj["parameters"] = Json(self.parameters)
  }
  for key, value in self.operations {
    if is_method(key) {
      obj[key] = Json(value)
    }
  }
  if !self.additional_operations.is_empty() {
    obj["additionalOperations"] = Json(self.additional_operations)
  }
  add_unmodeled(obj, self.unmodeled, is_path_item_field)
  add_extensions(obj, self.extensions)
  Json::object(obj)
}

///|
/// Decodes the operations by method, keeping unmodeled members and
/// extensions apart from them.
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
    servers: field(obj, "servers", path, default=[]),
    parameters: field(obj, "parameters", path, default=[]),
    additional_operations: field(
      obj,
      "additionalOperations",
      path,
      default=Map([]),
    ),
    unmodeled: unmodeled_fields(obj, is_path_item_field),
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
    | "trace"
    | "query" => true
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
