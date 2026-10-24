// A case of a field-discriminated union, erased to T (same trick as Variant::contramap).
pub struct Case[T] {
  tag : String
  schema : Schema
  decode : (Json) -> T raise
  encode : (T) -> Json?          // None: not this case
}

pub fn[T, A] case_(tag : String, codec : JsonCodec[A], project : (T) -> A?, inject : (A) -> T) -> Case[T] {
  {
    tag,
    schema: codec.schema_,
    decode: j => inject((codec.from_)(j)),
    encode: v => match project(v) { Some(a) => Some((codec.to_)(a)); None => None },
  }
}

pub suberror UnionError { UnknownTag(String); NoCase } derive(Debug)

// tapir Schema.oneOfUsingField + Codec: {"type": "<tag>", ...fields}
pub fn[T] tagged(name : String, discriminator : String, cases : Array[Case[T]]) -> JsonCodec[T] {
  let defs = {}
  let refs = []
  let mapping = Map::new()
  for c in cases {
    let r = c.schema.use_(defs)
    refs.push(r)
    if r is Object(o) && o.get("$ref") is Some(String(target)) { mapping[c.tag] = target.to_json() }
  }
  {
    from_: j => {
      guard j is Object(o) && o.get(discriminator) is Some(String(tag)) else { raise UnknownTag("<missing>") }
      for c in cases { if c.tag == tag { return (c.decode)(j) } }
      raise UnknownTag(tag)
    },
    to_: v => {
      for c in cases {
        if (c.encode)(v) is Some(Object(fields)) {
          let m = Map::new()
          m[discriminator] = c.tag.to_json()
          for k, x in fields { m[k] = x }
          return Json::object(m)
        }
      }
      abort("no case")
    },
    schema_: {
      name: Some(name),
      json: { "oneOf": Json::array(refs), "discriminator": { "propertyName": discriminator.to_json(), "mapping": Json::object(mapping) } },
      defs,
    },
  }
}

pub let jdouble : JsonCodec[Double] = {
  from_: j => match j { Number(n, ..) => n; _ => fail("number") },
  to_: d => d.to_json(),
  schema_: Schema::anon({ "type": "number" }),
}

pub fn[T, A] object1(name : String, a : Field[T, A], make : (A) -> T) -> JsonCodec[T] {
  let defs = {}
  let props = Map::new()
  props[a.name] = a.codec.schema_.use_(defs)
  {
    from_: j => match j { Object(o) => make((a.codec.from_)(o.get(a.name).unwrap())); _ => fail("object") },
    to_: v => { let m = Map::new(); m[a.name] = (a.codec.to_)((a.get)(v)); Json::object(m) },
    schema_: { name: Some(name), json: { "type": "object", "properties": Json::object(props) }, defs },
  }
}
