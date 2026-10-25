///|
/// One reversible projection of a union value onto a payload codec.
pub struct Case[T] {
  priv tag : String
  priv decode : (Json, String) -> T raise DecodeFailure
  priv encode : (T) -> Json?
  priv schema : Schema
}

///|
/// Describes a union case. project and inject must be inverses for this case;
/// the union's projections must cover every value passed to its encoder.
pub fn[T, A] case_(
  tag : String,
  codec : JsonCodec[A],
  project : (T) -> A?,
  inject : (A) -> T,
) -> Case[T] {
  {
    tag,
    decode: (j, path) => inject((codec.from_)(j, path)),
    encode: v => project(v).map(codec.to_),
    schema: codec.schema_,
  }
}

///|
fn[T] check_cases(cases : Array[Case[T]]) -> Unit raise DecodeFailure {
  if cases.is_empty() || cases.length() > 64 {
    raise malformed("union requires 1 to 64 cases")
  }
  let names : Map[String, Bool] = Map([])
  for case_ in cases {
    if names.contains(case_.tag) {
      raise malformed("duplicate union tag: " + case_.tag)
    }
    names[case_.tag] = true
  }
}

///|
/// A discriminated object union. Definitions with duplicate tags or outside
/// 1..64 cases are rejected. Payload encoders must return objects; their
/// discriminator field is replaced by the tag. Projections must be exhaustive.
pub fn[T] tagged(
  name : String,
  discriminator : String,
  cases : Array[Case[T]],
) -> JsonCodec[T] raise DecodeFailure {
  check_cases(cases)
  let cases = cases.copy()
  let defs : Map[String, Json] = Map([])
  let alternatives = []
  let problems = []
  let mapping : Map[String, Json] = Map([])
  for i, case_ in cases {
    let child = case_.schema.reference(defs, problems~)
    let properties : Map[String, Json] = Map([
      (discriminator, { "const": Json(case_.tag) }),
    ])
    alternatives.push(
      Json({
        "allOf": [
          child,
          {
            "type": "object",
            "required": [discriminator],
            "properties": Json::object(properties),
          },
        ],
      }),
    )
    mapping[case_.tag] = Json(
      "#/components/schemas/\{pointer_segment(name)}/oneOf/\{i}",
    )
  }
  {
    from_: (j, path) => {
      guard j is Object(obj) else {
        raise invalid([
          { path, code: "type", message: "expected tagged object", },
        ])
      }
      let p = path + "/" + pointer_segment(discriminator)
      guard obj.get(discriminator) is Some(String(tag)) else {
        raise invalid([
          {
            path: p,
            code: "discriminator",
            message: "expected discriminator string",
          },
        ])
      }
      for case_ in cases {
        if case_.tag == tag {
          return (case_.decode)(j, path)
        }
      }
      raise invalid([
        { path: p, code: "discriminator", message: "unknown discriminator", },
      ])
    },
    to_: value => {
      for case_ in cases {
        if (case_.encode)(value) is Some(j) {
          guard j is Object(obj) else {
            abort("tagged payload encoder must return an object")
          }
          let obj = obj.copy()
          obj[discriminator] = Json(case_.tag)
          return Json::object(obj)
        }
      }
      abort("union projections do not cover encoded value")
    },
    missing_: None,
    omit_: never_omit,
    schema_: {
      name: Some(name),
      defs,
      problems,
      json: {
        "oneOf": Json::array(alternatives),
        "discriminator": {
          "propertyName": Json(discriminator),
          "mapping": Json::object(mapping),
        },
      },
    },
  }
}

///|
/// An untagged union that decodes the first successful case. If none match,
/// every case's issues are reported. Encoding selects the first projection;
/// projections must cover every encoded value. Requires 1..64 unique case tags.
pub fn[T] any_of(
  name : String,
  cases : Array[Case[T]],
) -> JsonCodec[T] raise DecodeFailure {
  check_cases(cases)
  let cases = cases.copy()
  let defs : Map[String, Json] = Map([])
  let problems = []
  let alternatives = cases.map(c => c.schema.reference(defs, problems~))
  {
    from_: (j, path) => {
      let issues = []
      for case_ in cases {
        try {
          return (case_.decode)(j, path)
        } catch {
          DecodeFailure(kind=Invalid(found), ..) => issues.append(found)
          error =>
            issues.push({ path, code: "union", message: error.message(), })
        }
      }
      raise invalid(issues)
    },
    to_: value => {
      for case_ in cases {
        if (case_.encode)(value) is Some(j) {
          return j
        }
      }
      abort("union projections do not cover encoded value")
    },
    missing_: None,
    omit_: never_omit,
    schema_: {
      name: Some(name),
      defs,
      problems,
      json: { "anyOf": Json::array(alternatives) },
    },
  }
}

///|
/// An open string enumeration. Known values are documented as examples;
/// unknown strings remain valid and round-trip without losing information.
pub fn open_string(known : Array[String]) -> JsonCodec[String] {
  {
    ..jstring,
    schema_: jstring.schema_.patch({ "examples": Json(known.copy()) }),
  }
}
