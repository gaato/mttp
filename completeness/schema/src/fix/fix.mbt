// Proposed shape: a schema remembers the named definitions it references.
pub(all) struct Schema {
  name : String?
  json : Json                 // for a named schema: its definition body
  defs : Map[String, Json]    // every named schema reachable from here
}

pub fn Schema::anon(json : Json) -> Schema { { name: None, json, defs: {} } }

// What a parent embeds for a child: a $ref for named children, the body otherwise.
pub fn Schema::use_(self : Schema, into : Map[String, Json]) -> Json {
  for k, v in self.defs { into[k] = v }
  match self.name {
    Some(n) => { into[n] = self.json; { "$ref": "#/components/schemas/\{n}".to_json() } }
    None => self.json
  }
}

pub struct JsonCodec[T] {
  from_ : (Json) -> T raise
  to_ : (T) -> Json
  schema_ : Schema
}

pub struct Field[T, A] { name : String; codec : JsonCodec[A]; get : (T) -> A }
pub fn[T, A] field(name : String, codec : JsonCodec[A], get : (T) -> A) -> Field[T, A] { { name, codec, get } }

pub let jstring : JsonCodec[String] = {
  from_: j => match j { String(s) => s; _ => fail("string") },
  to_: s => s.to_json(),
  schema_: Schema::anon({ "type": "string" }),
}

pub fn[T] array(c : JsonCodec[T]) -> JsonCodec[Array[T]] {
  let defs = {}
  let items = c.schema_.use_(defs)
  {
    from_: j => match j { Array(xs) => xs.map(x => (c.from_)(x)); _ => fail("array") },
    to_: xs => Json::array(xs.map(c.to_)),
    schema_: { name: None, json: { "type": "array", "items": items }, defs },
  }
}

pub fn[T, A, B] object2(name : String, a : Field[T, A], b : Field[T, B], make : (A, B) -> T) -> JsonCodec[T] {
  let defs = {}
  let props = Map::new()
  props[a.name] = a.codec.schema_.use_(defs)
  props[b.name] = b.codec.schema_.use_(defs)
  {
    from_: j => match j {
      Object(o) => make((a.codec.from_)(o.get(a.name).unwrap()), (b.codec.from_)(o.get(b.name).unwrap()))
      _ => fail("object")
    },
    to_: v => { let m = Map::new(); m[a.name] = (a.codec.to_)((a.get)(v)); m[b.name] = (b.codec.to_)((b.get)(v)); Json::object(m) },
    schema_: { name: Some(name), json: { "type": "object", "properties": Json::object(props) }, defs },
  }
}

// tapir's SRef / lazy implicit: tie the knot through a cell.
pub fn[T] recursive(name : String, body : (JsonCodec[T]) -> JsonCodec[T]) -> JsonCodec[T] {
  let cell : Ref[JsonCodec[T]?] = { val: None }
  let proxy : JsonCodec[T] = {
    from_: j => (cell.val.unwrap().from_)(j),
    to_: v => (cell.val.unwrap().to_)(v),
    // the proxy is a bare reference; its definition is attached once the knot is tied
    schema_: { name: None, json: { "$ref": "#/components/schemas/\{name}" }, defs: {} },
  }
  let real = body(proxy)
  cell.val = Some(real)
  { ..real, schema_: { ..real.schema_, name: Some(name) } }
}

pub fn components(top : Schema) -> (Json, Map[String, Json]) {
  let into = {}
  let r = top.use_(into)
  (r, into)
}
