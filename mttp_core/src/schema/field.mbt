///|
/// A named field, its value codec, and the projection used when encoding.
pub struct Field[T, A] {
  priv name : String
  priv codec : JsonCodec[A]
  priv get : (T) -> A
  priv description : String?
}

///|
/// Describes a typed object field. Optional and Presence codecs allow absence.
pub fn[T, A] field(
  name : String,
  codec : JsonCodec[A],
  get : (T) -> A,
  description? : String,
) -> Field[T, A] {
  { name, codec, get, description, }
}

///|
/// Decodes this field of `obj`, recording its problems in `issues`.
fn[T, A] Field::decode(
  self : Field[T, A],
  obj : Map[String, Json],
  path : String,
  issues : Array[Issue],
  d : Decoder,
) -> A? raise DecodeFailure {
  let p = path + "/" + pointer_segment(self.name)
  try {
    match obj.get(self.name) {
      Some(j) => Some(d.apply(self.codec, j, p))
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
    error => {
      d.absorb(error, issues, p, "invalid")
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
  fields : Array[(String, Schema, Bool, String?)],
) -> Schema {
  let defs : Map[String, Json] = Map([])
  let props : Map[String, Json] = Map([])
  let required = []
  let problems = []
  for (key, schema, need, description) in fields {
    if props.contains(key) {
      problems.push("duplicate object field \{key}")
    }
    let reference = schema.reference(defs, problems~)
    props[key] = match description {
      None => reference
      Some(text) =>
        match reference {
          Object(properties) => {
            let properties = properties.copy()
            properties["description"] = Json(text)
            Json::object(properties)
          }
          _ => { "allOf": [reference], "description": Json(text) }
        }
    }
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

///|
/// What `object_schema` needs of a field: its name, its schema, and whether
/// it is required (its codec has no value for a missing field), and its description.
fn[T, A] Field::describe(self : Field[T, A]) -> (String, Schema, Bool, String?) {
  (self.name, self.codec.schema_, self.codec.missing_ is None, self.description)
}

///|
/// The members of a JSON object, or a `type` issue at `path`.
fn expect_object(
  j : Json,
  path : String,
) -> Map[String, Json] raise DecodeFailure {
  guard j is Object(obj) else {
    raise invalid([{ path, code: "type", message: "expected object", }])
  }
  obj
}
