///|
/// A JSON Schema 2020-12 document (what OpenAPI 3.1 embeds), plus the name
/// it is hoisted under in `components/schemas` when it has one.
pub(all) struct Schema {
  name : String?
  json : Json                // for a named schema: its definition body
  defs : Map[String, Json]   // every named schema reachable from here (SC-01)
} derive(Eq, Debug)

///|
pub fn Schema::of(json : Json) -> Schema {
  { name: None, json, defs: {} }
}

///|
/// What a parent embeds for this child: a $ref for a named schema (its
/// definition and its own defs are merged into `into`), the body otherwise.
pub fn Schema::reference(self : Schema, into : Map[String, Json]) -> Json {
  for k, v in self.defs {
    into[k] = v
  }
  match self.name {
    Some(n) => {
      into[n] = self.json
      { "$ref": "#/components/schemas/\{n}".to_json() }
    }
    None => self.json
  }
}

///|
pub fn Schema::named(self : Schema, name : String) -> Schema {
  { ..self, name: Some(name) }
}

///|
/// Adds JSON Schema keywords; validators use it so the document states
/// every constraint the decoder enforces.
pub fn Schema::patch(self : Schema, keywords : Map[String, Json]) -> Schema {
  match self.json {
    Object(m) => {
      let out = Map::new()
      for k, v in m {
        out[k] = v
      }
      for k, v in keywords {
        out[k] = v
      }
      { ..self, json: Json::object(out) }
    }
    _ => self
  }
}

///|
/// One problem with an input, located by JSON pointer.
pub(all) struct Issue {
  path : String
  code : String
  message : String
} derive(Eq, Debug, ToJson)

///|
pub(all) suberror DecodeFailure {
  Missing
  Multiple(Int)
  Malformed(String)
  Invalid(Array[Issue])
  Mismatch(expected~ : String, actual~ : String)
  TooLarge(limit~ : Int)
  UnsupportedMediaType(String)
} derive(Debug)

///|
pub fn DecodeFailure::message(self : DecodeFailure) -> String {
  match self {
    Missing => "missing"
    Multiple(n) => "expected one value, got \{n}"
    Malformed(m) => m
    Invalid(issues) => issues.map(i => "\{i.path}: \{i.message}").join("; ")
    Mismatch(expected~, actual~) => "expected \{expected}, got \{actual}"
    TooLarge(limit~) => "larger than \{limit} bytes"
    UnsupportedMediaType(m) => "unsupported media type \{m}"
  }
}

///|
/// String <-> T for path, query, header and cookie values.
pub struct TextCodec[T] {
  priv decode_ : (String) -> T raise DecodeFailure
  priv encode_ : (T) -> String
  priv schema_ : Schema
}

///|
pub fn[T] TextCodec::new(
  decode : (String) -> T raise DecodeFailure,
  encode : (T) -> String,
  schema : Schema,
) -> TextCodec[T] {
  { decode_: decode, encode_: encode, schema_: schema }
}

///|
pub fn[T] TextCodec::decode(self : TextCodec[T], s : String) -> T raise DecodeFailure {
  (self.decode_)(s)
}

///|
pub fn[T] TextCodec::encode(self : TextCodec[T], v : T) -> String {
  (self.encode_)(v)
}

///|
pub fn[T] TextCodec::schema(self : TextCodec[T]) -> Schema {
  self.schema_
}

///|
pub let int : TextCodec[Int] = TextCodec::new(
  s => @string.parse_int(s) catch { _ => raise Malformed("not an integer: \{s}") },
  i => i.to_string(),
  Schema::of({ "type": "integer", "format": "int32" }),
)

///|
pub let string : TextCodec[String] = TextCodec::new(s => s, s => s, Schema::of({
  "type": "string",
}))

///|
/// A check plus the JSON Schema keywords that state it.
pub struct Validator[T] {
  priv check : (T) -> String?
  priv keywords : Map[String, Json]
}

///|
pub fn minimum(n : Int) -> Validator[Int] {
  { check: v => if v < n { Some("must be >= \{n}") } else { None }, keywords: {
      "minimum": n.to_json(),
    } }
}

///|
pub fn max_length(n : Int) -> Validator[String] {
  {
    // JSON Schema counts code points; length() would count UTF-16 units
    check: v => if v.iter().count() > n { Some("longer than \{n}") } else { None },
    keywords: { "maxLength": n.to_json() },
  }
}

///|
pub fn[T] TextCodec::validate(self : TextCodec[T], v : Validator[T]) -> TextCodec[T] {
  {
    decode_: s => {
      let x = (self.decode_)(s)
      match (v.check)(x) {
        Some(msg) => raise Invalid([{ path: "", code: "constraint", message: msg }])
        None => x
      }
    },
    encode_: self.encode_,
    schema_: self.schema_.patch(v.keywords),
  }
}

///|
/// Json <-> T, collecting every issue instead of stopping at the first.
pub struct JsonCodec[T] {
  priv from_ : (Json, String) -> T raise DecodeFailure
  priv to_ : (T) -> Json
  priv schema_ : Schema
}

///|
pub fn[T] JsonCodec::schema(self : JsonCodec[T]) -> Schema {
  self.schema_
}

///|
pub fn[T] JsonCodec::from_json(self : JsonCodec[T], j : Json) -> T raise DecodeFailure {
  (self.from_)(j, "")
}

///|
pub fn[T] JsonCodec::to_json(self : JsonCodec[T], v : T) -> Json {
  (self.to_)(v)
}

///|
/// For types that already `derive(FromJson, ToJson)`; the schema is supplied
/// (the OpenAPI generator knows it) and must describe what derive does.
pub fn[T : FromJson + ToJson] JsonCodec::derived(schema : Schema) -> JsonCodec[T] {
  {
    from_: (j, path) => @json.from_json(j) catch {
      e => raise Invalid([{ path, code: "json", message: e.to_string() }])
    },
    to_: v => ToJson::to_json(v),
    schema_: schema,
  }
}

///|
/// Implemented by generated code (or by hand); the `Self?` proxy lets a
/// generic function reach it: `JsonSchema::json_schema((None : T?))`.
pub(open) trait JsonSchema {
  json_schema(Self?) -> Schema
}

///|
pub fn[T : FromJson + ToJson + JsonSchema] json() -> JsonCodec[T] {
  JsonCodec::derived(JsonSchema::json_schema((None : T?)))
}

///|
pub let jint : JsonCodec[Int] = {
  from_: (j, path) => match j {
    Number(n, ..) if n == n.floor() && n >= -2147483648.0 && n <= 2147483647.0 =>
      n.to_int()
    _ => raise Invalid([{ path, code: "type", message: "expected integer" }])
  },
  to_: i => i.to_json(),
  schema_: Schema::of({ "type": "integer", "format": "int32" }),
}

///|
pub let jstring : JsonCodec[String] = {
  from_: (j, path) => match j {
    String(s) => s
    _ => raise Invalid([{ path, code: "type", message: "expected string" }])
  },
  to_: s => s.to_json(),
  schema_: Schema::of({ "type": "string" }),
}

///|
pub struct Field[T, A] {
  priv name : String
  priv codec : JsonCodec[A]
  priv get : (T) -> A
}

///|
pub fn[T, A] field(name : String, codec : JsonCodec[A], get : (T) -> A) -> Field[T, A] {
  { name, codec, get }
}

///|
fn[T, A] Field::decode(
  self : Field[T, A],
  obj : Map[String, Json],
  path : String,
  issues : Array[Issue],
) -> A? {
  let p = "\{path}/\{self.name}"
  match obj.get(self.name) {
    None => {
      issues.push({ path: p, code: "missing", message: "required" })
      None
    }
    Some(j) =>
      Some((self.codec.from_)(j, p)) catch {
        Invalid(found) => {
          issues.append(found)
          None
        }
        e => {
          issues.push({ path: p, code: "invalid", message: e.message() })
          None
        }
      }
  }
}

///|
/// No variadic generics: fixed arities (codegen emits object1..object16).
pub fn[T, A] object1(name : String, a : Field[T, A], make : (A) -> T) -> JsonCodec[T] {
  {
    from_: (j, path) => {
      guard j is Object(obj) else {
        raise Invalid([{ path, code: "type", message: "expected object" }])
      }
      let issues = []
      match a.decode(obj, path, issues) {
        Some(x) if issues.is_empty() => make(x)
        _ => raise Invalid(issues)
      }
    },
    to_: v => {
      let m = Map::new()
      m[a.name] = (a.codec.to_)((a.get)(v))
      Json::object(m)
    },
    schema_: {
      let defs : Map[String, Json] = Map::new()
      let props = Map::new()
      props[a.name] = a.codec.schema_.reference(defs)
      {
        name: Some(name),
        json: { "type": "object", "required": [a.name], "properties": Json::object(props) },
        defs,
      }
    },
  }
}

///|
pub fn[T, A, B] object2(
  name : String,
  a : Field[T, A],
  b : Field[T, B],
  make : (A, B) -> T,
) -> JsonCodec[T] {
  {
    from_: (j, path) => {
      guard j is Object(obj) else {
        raise Invalid([{ path, code: "type", message: "expected object" }])
      }
      let issues = []
      let va = a.decode(obj, path, issues)
      let vb = b.decode(obj, path, issues)
      match (va, vb) {
        (Some(x), Some(y)) if issues.is_empty() => make(x, y)
        _ => raise Invalid(issues)
      }
    },
    to_: v => {
      let m = Map::new()
      m[a.name] = (a.codec.to_)((a.get)(v))
      m[b.name] = (b.codec.to_)((b.get)(v))
      Json::object(m)
    },
    schema_: {
      let defs : Map[String, Json] = Map::new()
      let props = Map::new()
      props[a.name] = a.codec.schema_.reference(defs)
      props[b.name] = b.codec.schema_.reference(defs)
      {
        name: Some(name),
        json: { "type": "object", "required": [a.name, b.name], "properties": Json::object(props) },
        defs,
      }
    },
  }
}

///|
pub fn[T] array(c : JsonCodec[T]) -> JsonCodec[Array[T]] {
  let defs : Map[String, Json] = Map::new()
  let items = c.schema_.reference(defs)
  {
    from_: (j, path) => match j {
      Array(xs) => {
        let issues = []
        let out = []
        for i, x in xs {
          out.push((c.from_)(x, "\{path}/\{i}")) catch {
            Invalid(found) => issues.append(found)
            e => issues.push({ path: "\{path}/\{i}", code: "invalid", message: e.message() })
          }
        }
        if issues.is_empty() { out } else { raise Invalid(issues) }
      }
      _ => raise Invalid([{ path, code: "type", message: "expected array" }])
    },
    to_: xs => Json::array(xs.map(c.to_)),
    schema_: { name: None, json: { "type": "array", "items": items }, defs },
  }
}

///|
/// tapir SRef / lazy: ties the knot through a cell, so a recursive type is
/// a $ref to itself instead of an infinite definition (SC-01).
pub fn[T] recursive(name : String, body : (JsonCodec[T]) -> JsonCodec[T]) -> JsonCodec[T] {
  let cell : Ref[JsonCodec[T]?] = { val: None }
  let proxy : JsonCodec[T] = {
    from_: (j, p) => (cell.val.unwrap().from_)(j, p),
    to_: v => (cell.val.unwrap().to_)(v),
    schema_: { name: None, json: { "$ref": "#/components/schemas/\{name}".to_json() }, defs: {} },
  }
  let real = body(proxy)
  cell.val = Some(real)
  { ..real, schema_: { ..real.schema_, name: Some(name) } }
}

///|
/// Bytes <-> T with a media type: what a body input or output carries.
pub struct BodyCodec[T] {
  priv media_type_ : String
  priv decode_ : (Bytes) -> T raise DecodeFailure
  priv encode_ : (T) -> Bytes
  priv schema_ : Schema
}

///|
pub fn[T] BodyCodec::media_type(self : BodyCodec[T]) -> String {
  self.media_type_
}

///|
pub fn[T] BodyCodec::decode(self : BodyCodec[T], b : Bytes) -> T raise DecodeFailure {
  (self.decode_)(b)
}

///|
pub fn[T] BodyCodec::encode(self : BodyCodec[T], v : T) -> Bytes {
  (self.encode_)(v)
}

///|
pub fn[T] BodyCodec::schema(self : BodyCodec[T]) -> Schema {
  self.schema_
}

///|
pub fn[T] JsonCodec::body(self : JsonCodec[T]) -> BodyCodec[T] {
  {
    media_type_: "application/json",
    decode_: b => {
      let text = @utf8.decode(b) catch { _ => raise Malformed("not UTF-8") }
      let j = @json.parse(text) catch { e => raise Malformed(e.to_string()) }
      (self.from_)(j, "")
    },
    encode_: v => @utf8.encode((self.to_)(v).stringify()),
    schema_: self.schema_,
  }
}

///|
pub let raw_bytes : BodyCodec[Bytes] = {
  media_type_: "application/octet-stream",
  decode_: b => b,
  encode_: b => b,
  schema_: Schema::of({ "type": "string", "contentMediaType": "application/octet-stream" }),
}


///|
pub fn[T, U] TextCodec::map(
  self : TextCodec[T],
  to : (T) -> U raise DecodeFailure,
  from : (U) -> T,
) -> TextCodec[U] {
  {
    decode_: s => to((self.decode_)(s)),
    encode_: u => (self.encode_)(from(u)),
    schema_: self.schema_,
  }
}

///|
pub let text_body : BodyCodec[String] = {
  media_type_: "text/plain",
  decode_: b => @utf8.decode(b) catch { _ => raise Malformed("not UTF-8") },
  encode_: s => @utf8.encode(s),
  schema_: Schema::of({ "type": "string" }),
}

///|
/// Not in the architecture: a schema-carrying JsonCodec for an arbitrary
/// Json value (problem+json, passthrough).
pub let jvalue : JsonCodec[Json] = {
  from_: (j, _) => j,
  to_: j => j,
  schema_: Schema::of({}),
}
