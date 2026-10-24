// The architecture's shape, as in wf1/endpoint-first/mttp/src/schema (Schema = name + Json).
pub(all) struct Schema {
  name : String?
  json : Json
} derive(Eq, Debug)

pub struct JsonCodec[T] {
  from_ : (Json) -> T raise
  to_ : (T) -> Json
  schema_ : Schema
}

pub struct Field[T, A] {
  name : String
  codec : JsonCodec[A]
  get : (T) -> A
}

pub fn[T, A] field(name : String, codec : JsonCodec[A], get : (T) -> A) -> Field[T, A] {
  { name, codec, get }
}

pub let jstring : JsonCodec[String] = {
  from_: j => match j { String(s) => s; _ => fail("string") },
  to_: s => s.to_json(),
  schema_: { name: None, json: { "type": "string" } },
}

pub fn[T] array(c : JsonCodec[T]) -> JsonCodec[Array[T]] {
  {
    from_: j => match j { Array(xs) => xs.map(x => (c.from_)(x)); _ => fail("array") },
    to_: xs => Json::array(xs.map(c.to_)),
    schema_: { name: None, json: { "type": "array", "items": c.schema_.json } },
  }
}

// object2 exactly as the prototype: the child schema's *json* is embedded.
pub fn[T, A, B] object2(name : String, a : Field[T, A], b : Field[T, B], make : (A, B) -> T) -> JsonCodec[T] {
  {
    from_: j => match j {
      Object(o) => make((a.codec.from_)(o.get(a.name).unwrap()), (b.codec.from_)(o.get(b.name).unwrap()))
      _ => fail("object")
    },
    to_: v => { let m = Map::new(); m[a.name] = (a.codec.to_)((a.get)(v)); m[b.name] = (b.codec.to_)((b.get)(v)); Json::object(m) },
    schema_: {
      name: Some(name),
      json: {
        "type": "object",
        "properties": Json::object({ let m = Map::new(); m[a.name] = a.codec.schema_.json; m[b.name] = b.codec.schema_.json; m }),
      },
    },
  }
}

// prototype hoister (wf1/endpoint-first/mttp/src/openapi Components::refer)
pub fn hoist(top : Schema, components : Map[String, Json]) -> Json {
  match top.name {
    None => top.json
    Some(n) => { components[n] = top.json; { "$ref": "#/components/schemas/\{n}".to_json() } }
  }
}
