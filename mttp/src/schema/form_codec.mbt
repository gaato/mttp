///|
/// The pairs a typed form body decodes, the same bound as `form_body`'s
/// default.
let form_codec_max_pairs : Int32 = 256

///|
/// Hops through `$ref` and `anyOf` a property schema may take before the
/// form plan gives up on it; recursive definitions would otherwise loop.
let form_shape_max_depth : Int32 = 32

///|
/// The text a form value is coerced from, by its property's JSON Schema type.
#derive(Eq)
priv enum FormScalar {
  Text
  Integer
  Number
  Boolean
}

///|
/// What a property schema projects to in a form.
#derive(Eq)
priv enum FormShape {
  Scalar(FormScalar)
  Repeated(FormScalar) // an array of scalars: one pair per item
  Untyped // no type stated: the text goes to the codec unchanged
  Null
  Unsupported(String)
}

///|
/// How one form name becomes a property of the codec's JSON object.
priv struct FormProperty {
  scalar : FormScalar
  repeated : Bool
  required : Bool
}

///|
/// An `application/x-www-form-urlencoded` body for an object codec, so a form
/// and a JSON API share one definition, one set of validation rules and the
/// same JSON-pointer issue paths.
///
/// Decoding reads at most 256 pairs, as `form_body` does, and builds a JSON
/// object guided by each property's schema type:
///
/// - `string` and untyped properties take the text as is; `integer` takes
///   decimal integer text (`+` and leading zeros allowed), `number` decimal
///   number text, `boolean` `true`, `false` or `on` (what a checkbox without a
///   value sends). An `array` of those takes one pair per item, in order.
/// - Text that does not coerce, or a non-array property given more than once,
///   is an issue at the property's pointer (`/count`), reported together with
///   the codec's own issues.
/// - HTML omits unchecked checkboxes and unselected options and has no way to
///   send `false` or an empty list, so an absent *required* boolean decodes as
///   `false` and an absent required array as `[]`. An absent optional property
///   stays absent, keeping `option` and `presence` meaningful.
/// - An empty integer, number or boolean of an optional property is absent,
///   as a blank `<input type=number>` means.
/// - Names the schema does not list stay strings (repeated: arrays of
///   strings), so the codec's own rules decide.
///
/// Encoding writes the codec's JSON object as pairs: scalars as text, arrays
/// as repeated names, nulls omitted.
///
/// A codec whose schema is not an object of scalars and arrays of scalars
/// records a definition problem in the body schema's `problems`, which the
/// endpoint definition checker refuses.
pub fn[T] form_codec(codec : JsonCodec[T]) -> BodyCodec[T] {
  let (plan, problems) = form_plan(codec.schema_)
  {
    media_type_: "application/x-www-form-urlencoded",
    decode_: bytes => {
      decode_form(codec, plan, form_pairs(bytes, form_codec_max_pairs))
    },
    encode_: v => @text.encode_utf8(@form.encode(form_fields(codec.to_json(v)))),
    schema_: with_problems(codec.schema_, problems),
  }
}

///|
/// Each listed property's coercion, and the definition problems found.
fn form_plan(schema : Schema) -> (Map[String, FormProperty], Array[String]) {
  let plan = Map([])
  let problems = []
  guard schema.json is Object(top) && top.get("type") is Some(String("object")) else {
    problems.push("form_codec needs an object schema")
    return (plan, problems)
  }
  let required = match top.get("required") {
    Some(Array(names)) => names
    _ => []
  }
  guard top.get("properties") is Some(Object(properties)) else {
    return (plan, problems)
  }
  for name, json in properties {
    let need = required.contains(Json::string(name))
    let property = (scalar : FormScalar, repeated : Bool) => {
      plan[name] = { scalar, repeated, required: need, }
    }
    match form_shape(json, schema.defs, 0) {
      Scalar(scalar) => property(scalar, false)
      Repeated(scalar) => property(scalar, true)
      Untyped | Null => property(Text, false)
      Unsupported(why) => problems.push("form_codec property \{name} \{why}")
    }
  }
  (plan, problems)
}

///|
/// The form shape of a property schema, following references and unions.
fn form_shape(
  json : Json,
  defs : Map[String, Json],
  depth : Int32,
) -> FormShape {
  if depth > form_shape_max_depth {
    return Unsupported("nests references too deeply")
  }
  guard json is Object(m) else { return Untyped }
  if m.get("$ref") is Some(String(target)) {
    let name = target
      .strip_prefix("#/components/schemas/")
      .map(s => s.to_owned().replace_all(old="~1", new="/"))
      .map(s => s.replace_all(old="~0", new="~"))
    return match name.bind(n => defs.get(n)) {
      Some(body) => form_shape(body, defs, depth + 1)
      None => Unsupported("refers to an unknown definition \{target}")
    }
  }
  match m.get("type") {
    Some(String(t)) => typed_shape(t, m, defs, depth)
    // Each alternative keeps the property's other keywords (`items` above
    // all), so `["array", "null"]` still knows its item type.
    Some(Array(types)) =>
      merge_shapes(
        types.map(t => {
          match t {
            String(t) => typed_shape(t, m, defs, depth)
            _ => Untyped
          }
        }),
      )
    _ =>
      match (m.get("anyOf"), m.get("oneOf")) {
        (Some(Array(members)), _) | (_, Some(Array(members))) =>
          merge_shapes(members.map(j => form_shape(j, defs, depth + 1)))
        _ => Untyped
      }
  }
}

///|
fn typed_shape(
  t : String,
  m : Map[String, Json],
  defs : Map[String, Json],
  depth : Int32,
) -> FormShape {
  match t {
    "string" => Scalar(Text)
    "integer" => Scalar(Integer)
    "number" => Scalar(Number)
    "boolean" => Scalar(Boolean)
    "null" => Null
    "array" =>
      match
        form_shape(m.get("items").unwrap_or(Json::object({})), defs, depth + 1) {
        Scalar(scalar) => Repeated(scalar)
        Untyped => Repeated(Text)
        _ => Unsupported("is not an array of scalars")
      }
    _ => Unsupported("is not a scalar or an array of scalars")
  }
}

///|
/// The one shape every non-null alternative shares.
fn merge_shapes(shapes : Array[FormShape]) -> FormShape {
  let mut found = Null
  for shape in shapes {
    match (shape, found) {
      (Null, _) => continue
      (Unsupported(_), _) => return shape
      (_, Null) => found = shape
      _ if shape == found => continue
      _ => return Unsupported("mixes value types")
    }
  }
  found
}

///|
fn[T] decode_form(
  codec : JsonCodec[T],
  plan : Map[String, FormProperty],
  pairs : Array[(String, String)],
) -> T raise DecodeFailure {
  let values : Map[String, Array[String]] = Map([])
  for pair in pairs {
    let (name, value) = pair
    match values.get(name) {
      Some(texts) => texts.push(value)
      None => values[name] = [value]
    }
  }
  let obj : Map[String, Json] = Map([])
  let issues : Array[Issue] = []
  let strings = (texts : Array[String]) => Json::array(texts.map(Json::string))
  for name, texts in values {
    let path = "/" + pointer_segment(name)
    match plan.get(name) {
      None =>
        obj[name] = if texts.length() == 1 {
          Json::string(texts[0])
        } else {
          strings(texts)
        }
      Some(p) if p.repeated =>
        obj[name] = Json::array(
          texts.mapi((i, text) => {
            coerce_at(p.scalar, text, "\{path}/\{i}", issues)
          }),
        )
      Some(_) if texts.length() > 1 => {
        issues.push({
          path,
          code: "multiple",
          message: "expected one value, got \{texts.length()}",
        })
        obj[name] = strings(texts)
      }
      Some(p) =>
        if !(texts[0].is_empty() && p.scalar != Text && !p.required) {
          obj[name] = coerce_at(p.scalar, texts[0], path, issues)
        }
    }
  }
  for name, p in plan {
    if p.required && !values.contains(name) {
      if p.repeated {
        obj[name] = Json::array([])
      } else if p.scalar == Boolean {
        obj[name] = Json::boolean(false)
      }
    }
  }
  let value = codec.from_json(Json::object(obj)) catch {
    DecodeFailure(kind=Invalid(found), ..) => {
      // A value the form could not coerce stays text, so the codec reports
      // it again; keep the form's issue, which names the expected text.
      let coerced = issues.map(issue => issue.path)
      for issue in found {
        let shadowed = coerced
          .iter()
          .any(p => issue.path == p || issue.path.has_prefix(p + "/"))
        if !shadowed {
          issues.push(issue)
        }
      }
      raise invalid(issues)
    }
    error => raise error
  }
  guard issues.is_empty() else { raise invalid(issues) }
  value
}

///|
/// The JSON value of `text`, or the text itself with an issue at `path`.
fn coerce_at(
  scalar : FormScalar,
  text : String,
  path : String,
  issues : Array[Issue],
) -> Json {
  match coerce(scalar, text) {
    Some(json) => json
    None => {
      let expected = match scalar {
        Integer => "expected integer"
        Number => "expected number"
        _ => "expected true, false or on"
      }
      issues.push({ path, code: "type", message: expected, })
      Json::string(text)
    }
  }
}

///|
fn coerce(scalar : FormScalar, text : String) -> Json? {
  match scalar {
    Text => Some(Json::string(text))
    Boolean =>
      match text {
        "true" | "on" => Some(Json::boolean(true))
        "false" => Some(Json::boolean(false))
        _ => None
      }
    Integer => {
      guard is_decimal_integer(text) else { return None }
      // The lexeme lets jint and jint64 check the exact value.
      let lexeme = json_integer_lexeme(text)
      let n = @string.parse_double(lexeme) catch { _ => return None }
      Some(Json::number(n, repr=lexeme))
    }
    Number => {
      guard is_decimal_number(text) else { return None }
      let n = @string.parse_double(text) catch { _ => return None }
      Some(Json::number(n))
    }
  }
}

///|
/// Decimal integer text as a JSON lexeme: no `+`, no leading zeros.
fn json_integer_lexeme(text : String) -> String {
  let chars = text.to_array()
  let start = if chars[0] is ('+' | '-') { 1 } else { 0 }
  let mut first = start
  while first < chars.length() - 1 && chars[first] == '0' {
    first += 1
  }
  let out = StringBuilder()
  if chars[0] == '-' {
    out.write_char('-')
  }
  for i in first..<chars.length() {
    out.write_char(chars[i])
  }
  out.to_string()
}

///|
/// A JSON object as form pairs: arrays as repeated names, nulls omitted.
fn form_fields(json : Json) -> Array[(String, String)] {
  let pairs = []
  guard json is Object(obj) else { return pairs }
  let push = (name : String, value : Json) => {
    match value {
      Null => ()
      String(s) => pairs.push((name, s))
      _ => pairs.push((name, value.stringify()))
    }
  }
  for name, value in obj {
    match value {
      Array(items) => items.each(item => push(name, item))
      _ => push(name, value)
    }
  }
  pairs
}
