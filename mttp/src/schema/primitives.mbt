///|
/// Decimal signed 64-bit text, with checked overflow.
pub let int64 : TextCodec[Int64] = TextCodec::new(
  s => @string.parse_int64(s) catch { _ => raise malformed("expected int64") },
  v => v.to_string(),
  Schema::of({ "type": "integer", "format": "int64" }),
)

///|
/// Finite floating-point text. Encoding expects a finite value.
pub let double : TextCodec[Double] = TextCodec::new(
  s => {
    let n = @string.parse_double(s) catch {
      _ => raise malformed("expected number")
    }
    if n.is_nan() || n.is_inf() {
      raise malformed("expected finite number")
    }
    n
  },
  v => v.to_string(),
  Schema::of({ "type": "number", "format": "double" }),
)

///|
/// The exact lowercase tokens true and false.
pub let bool : TextCodec[Bool] = TextCodec::new(
  s => {
    match s {
      "true" => true
      "false" => false
      _ => raise malformed("expected true or false")
    }
  },
  v => v.to_string(),
  Schema::of({ "type": "boolean" }),
)

///|
/// A closed set of string values, copied at construction.
pub fn enum_of(values : Array[String]) -> TextCodec[String] {
  string.validate(one_of_values(values))
}

///|
/// An inclusive upper integer bound.
pub fn maximum(n : Int32) -> Validator[Int32] {
  custom(v => if v > n { Some("must be <= \{n}") } else { None }, keywords={
    "maximum": Json(n),
  })
}

///|
/// A lower string length bound measured in Unicode code points.
pub fn min_length(n : Int32) -> Validator[String] {
  custom(
    v => if v.iter().count() < n { Some("shorter than \{n}") } else { None },
    keywords={ "minLength": Json(n.max(0)) },
  )
}

///|
/// Membership validation and its JSON Schema enum. Values are copied.
pub fn[T : Eq + ToJson] one_of_values(values : Array[T]) -> Validator[T] {
  let values = values.copy()
  custom(
    v => if values.contains(v) { None } else { Some("not an allowed value") },
    keywords=if values.is_empty() {
      { "not": {} }
    } else {
      { "enum": Json(values) }
    },
  )
}

///|
/// Adds a custom predicate and the schema keywords describing it. The caller
/// owns agreement between the predicate and any supplied keywords.
pub fn[T] custom(
  check : (T) -> String?,
  keywords~ : Map[String, Json] = {},
) -> Validator[T] {
  { check, keywords: keywords.copy(), }
}

///|
/// A JSON boolean codec.
pub let jbool : JsonCodec[Bool] = {
  missing_: None,
  omit_: never_omit,
  from_: (j, path) => {
    match j {
      True => true
      False => false
      _ => raise invalid([{ path, code: "type", message: "expected boolean", }])
    }
  },
  to_: v => Json(v),
  schema_: bool.schema(),
}

///|
/// Finite JSON numbers. Encoding expects a finite value.
pub let jdouble : JsonCodec[Double] = {
  missing_: None,
  omit_: never_omit,
  from_: (j, path) => {
    match j {
      Number(n, ..) if !n.is_nan() && !n.is_inf() => n
      _ =>
        raise invalid([
          { path, code: "type", message: "expected finite number", },
        ])
    }
  },
  to_: v => Json(v),
  schema_: double.schema(),
}

///|
/// Adds validation to a JSON codec, preserving nested issue paths.
pub fn[T] JsonCodec::validate(
  self : JsonCodec[T],
  v : Validator[T],
) -> JsonCodec[T] {
  let check = (value : T, path : String) => {
    if (v.check)(value) is Some(message) {
      raise invalid([{ path, code: "constraint", message, }])
    }
    value
  }
  {
    ..self,
    from_: (j, path) => check((self.from_)(j, path), path),
    missing_: self.missing_.map(f => () => check(f(), "")),
    schema_: self.schema_.patch(v.keywords),
  }
}

///|
/// Maps the decoded value and its inverse while retaining the schema.
pub fn[T, U] JsonCodec::map(
  self : JsonCodec[T],
  to : (T) -> U raise DecodeFailure,
  from : (U) -> T,
) -> JsonCodec[U] {
  {
    from_: (j, path) => {
      let decoded = (self.from_)(j, path)
      to(decoded) catch {
        error => raise at_path(error, path)
      }
    },
    to_: v => (self.to_)(from(v)),
    schema_: self.schema_,
    missing_: self.missing_.map(f => () => to(f())),
    omit_: v => (self.omit_)(from(v)),
  }
}

///|
/// A named JSON string enum, rejecting values outside the copied set.
pub fn string_enum(name : String, values : Array[String]) -> JsonCodec[String] {
  let codec = jstring.validate(one_of_values(values))
  { ..codec, schema_: codec.schema_.named(name), }
}
