///|
/// One reversible projection of a union value onto a payload codec.
pub struct Case[T] {
  priv tag : String
  priv decode : (Json, String, Decoder) -> T raise DecodeFailure
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
    decode: (j, path, d) => inject(d.apply(codec, j, path)),
    encode: v => project(v).map(codec.to_),
    schema: codec.schema_,
  }
}

///|
/// The most cases a union may have.
let max_union_cases : Int32 = 64

///|
/// Definition problems of a union: its case count and duplicate tags. They
/// are recorded in the schema's `problems`, which the endpoint definition
/// checker refuses, rather than raised, so a union can be a `pub let`.
fn[T] case_problems(name : String, cases : Array[Case[T]]) -> Array[String] {
  let problems = []
  if cases.is_empty() || cases.length() > max_union_cases {
    problems.push(
      "union \{name} has \{cases.length()} cases; 1 to \{max_union_cases} are allowed",
    )
  }
  let names : Map[String, Unit] = Map([])
  for case_ in cases {
    if names.contains(case_.tag) {
      problems.push("union \{name} repeats the tag \{case_.tag}")
    }
    names[case_.tag] = ()
  }
  problems
}

///|
/// A discriminated object union. A definition with duplicate tags or outside
/// 1 to 64 cases records a problem in its schema (see `Schema::problems`);
/// decoding then uses the first case with the tag. Payload encoders must
/// return objects; their discriminator field is replaced by the tag.
/// Projections must be exhaustive.
pub fn[T] tagged(
  name : String,
  discriminator : String,
  cases : Array[Case[T]],
) -> JsonCodec[T] {
  let problems = case_problems(name, cases)
  let cases = cases.copy()
  let defs : Map[String, Json] = Map([])
  let alternatives = []
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
    from_: (j, path, d) => {
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
          return (case_.decode)(j, path, d)
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
/// projections must cover every encoded value. A definition with duplicate
/// tags or outside 1 to 64 cases records a problem in its schema. Retrying
/// cases is charged to the decode's step budget (`JsonCodec::from_json`).
pub fn[T] any_of(name : String, cases : Array[Case[T]]) -> JsonCodec[T] {
  let problems = case_problems(name, cases)
  let cases = cases.copy()
  let defs : Map[String, Json] = Map([])
  let alternatives = cases.map(c => c.schema.reference(defs, problems~))
  {
    from_: (j, path, d) => {
      let issues = []
      for case_ in cases {
        try {
          return (case_.decode)(j, path, d)
        } catch {
          error => d.absorb(error, issues, path, "union")
        }
      }
      if issues.is_empty() {
        issues.push({ path, code: "union", message: "union has no cases", })
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
