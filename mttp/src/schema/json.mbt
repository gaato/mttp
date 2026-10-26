///|
/// Json <-> T, collecting every issue instead of stopping at the first.
pub struct JsonCodec[T] {
  priv from_ : (Json, String) -> T raise DecodeFailure
  priv to_ : (T) -> Json
  priv schema_ : Schema
  priv missing_ : (() -> T raise DecodeFailure)?
  priv omit_ : (T) -> Bool
}

///|
fn[T] never_omit(_ : T) -> Bool {
  false
}

///|
/// Creates a custom codec. Custom issue paths are relative JSON pointers;
/// enclosing fields and collections prepend their own paths.
pub fn[T] JsonCodec::new(
  decode : (Json) -> T raise DecodeFailure,
  encode : (T) -> Json,
  schema : Schema,
) -> JsonCodec[T] {
  {
    from_: (j, path) => decode(j) catch { error => raise at_path(error, path) },
    to_: encode,
    schema_: schema,
    missing_: None,
    omit_: never_omit,
  }
}

///|
/// Returns the schema and reachable named definitions.
pub fn[T] JsonCodec::schema(self : JsonCodec[T]) -> Schema {
  self.schema_
}

///|
/// Decodes a JSON value, reporting issues as JSON-pointer paths.
pub fn[T] JsonCodec::from_json(
  self : JsonCodec[T],
  j : Json,
) -> T raise DecodeFailure {
  (self.from_)(j, "")
}

///|
/// Encodes a typed value; union projections must cover the value supplied.
pub fn[T] JsonCodec::to_json(self : JsonCodec[T], v : T) -> Json {
  (self.to_)(v)
}

///|
/// For types that already `derive(FromJson, ToJson)`; the schema is supplied
/// (the OpenAPI generator knows it) and must describe what derive does.
pub fn[T : FromJson + ToJson] JsonCodec::derived(
  schema : Schema,
) -> JsonCodec[T] {
  {
    missing_: None,
    omit_: never_omit,
    from_: (j, path) => {
      @json.from_json(j) catch {
        e => raise invalid([{ path, code: "json", message: e.to_string(), }])
      }
    },
    to_: v => ToJson::to_json(v),
    schema_: schema,
  }
}

///|
/// Implemented by generated code (or by hand); the `Self?` proxy lets a
/// generic function reach it: `JsonSchema::json_schema((None : T?))`.
pub(open) trait JsonSchema {
  fn json_schema(Self?) -> Schema
}

///|
/// Builds a derived codec using the type's declared JsonSchema implementation.
pub fn[T : FromJson + ToJson + JsonSchema] json() -> JsonCodec[T] {
  JsonCodec::derived(JsonSchema::json_schema((None : T?)))
}

///|
/// Integral JSON numbers in the signed 32-bit range.
pub let jint : JsonCodec[Int32] = {
  missing_: None,
  omit_: never_omit,
  from_: (j, path) => {
    match j {
      Number(n, ..) if n == n.floor() && n >= -2147483648.0 && n <= 2147483647.0 =>
        n.to_int()
      _ => raise invalid([{ path, code: "type", message: "expected integer", }])
    }
  },
  to_: i => Json(i),
  schema_: Schema::of({ "type": "integer", "format": "int32" }),
}

///|
/// JSON strings without coercion from other JSON types.
pub let jstring : JsonCodec[String] = {
  missing_: None,
  omit_: never_omit,
  from_: (j, path) => {
    match j {
      String(s) => s
      _ => raise invalid([{ path, code: "type", message: "expected string", }])
    }
  },
  to_: s => Json(s),
  schema_: Schema::of({ "type": "string" }),
}

///|
/// Not in the architecture: a schema-carrying JsonCodec for an arbitrary
/// Json value (problem+json, passthrough).
pub let jvalue : JsonCodec[Json] = {
  missing_: None,
  omit_: never_omit,
  from_: (j, _) => j,
  to_: j => j,
  schema_: Schema::of({}),
}
