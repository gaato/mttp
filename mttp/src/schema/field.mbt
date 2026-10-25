///|
/// A named field, its value codec, and the projection used when encoding.
pub struct Field[T, A] {
  priv name : String
  priv codec : JsonCodec[A]
  priv get : (T) -> A
}

///|
/// Describes a typed object field. Optional and Presence codecs allow absence.
pub fn[T, A] field(
  name : String,
  codec : JsonCodec[A],
  get : (T) -> A,
) -> Field[T, A] {
  { name, codec, get, }
}

///|
fn[T, A] Field::decode(
  self : Field[T, A],
  obj : Map[String, Json],
  path : String,
  issues : Array[Issue],
) -> A? {
  let p = path + "/" + pointer_segment(self.name)
  try {
    match obj.get(self.name) {
      Some(j) => Some((self.codec.from_)(j, p))
      None =>
        match self.codec.missing_ {
          Some(make) => Some(make() catch { error => raise at_path(error, p) })
          None => {
            issues.push({ path: p, code: "missing", message: "required", })
            None
          }
        }
    }
  } catch {
    DecodeFailure(kind=Invalid(found), ..) => {
      issues.append(found)
      None
    }
    error => {
      issues.push({ path: p, code: "invalid", message: error.message(), })
      None
    }
  }
}

///|
fn[T, A] Field::encode_field(
  self : Field[T, A],
  obj : Map[String, Json],
  value : T,
) -> Unit {
  let field = (self.get)(value)
  if !(self.codec.omit_)(field) {
    obj[self.name] = (self.codec.to_)(field)
  }
}

///|
fn object_schema(
  name : String,
  fields : Array[(String, Schema, Bool)],
) -> Schema {
  let defs : Map[String, Json] = Map([])
  let props : Map[String, Json] = Map([])
  let required = []
  let problems = []
  for (key, schema, need) in fields {
    if props.contains(key) {
      problems.push("duplicate object field \{key}")
    }
    props[key] = schema.reference(defs, problems~)
    if need {
      required.push(key)
    }
  }
  {
    name: Some(name),
    json: {
      "type": "object",
      "properties": Json::object(props),
      "required": Json(required),
    },
    defs,
    problems,
  }
}
