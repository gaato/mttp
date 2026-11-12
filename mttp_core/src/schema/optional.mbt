///|
/// Nullable values. In an object field, missing and null both decode to None;
/// None is omitted on object encoding and encoded as null in arrays or alone.
pub fn[T] option(codec : JsonCodec[T]) -> JsonCodec[T?] {
  let defs : Map[String, Json] = Map([])
  let problems = []
  let child = codec.schema_.reference(defs, problems~)
  {
    from_: (j, path, d) => {
      if j is Null {
        None
      } else {
        Some(d.apply(codec, j, path))
      }
    },
    to_: v => {
      match v {
        None => Json::null()
        Some(v) => (codec.to_)(v)
      }
    },
    missing_: Some(() => None),
    omit_: v => v is None,
    schema_: {
      name: None,
      json: { "anyOf": [child, { "type": "null" }] },
      defs,
      problems,
    },
  }
}

///|
/// A value that an object may leave out but must not set to null. In an
/// object field, a missing field decodes to None and None is omitted on
/// encoding; null goes to the child codec, which refuses it with its usual
/// type issue at the field's path unless it accepts null itself. The schema
/// is the child's, not nullable, and the field is not required.
///
/// JSON has no missing value outside an object, so None encodes as null in
/// arrays or alone, as with `option`, and that null does not decode back;
/// use `option` where a value can be null.
pub fn[T] omittable(codec : JsonCodec[T]) -> JsonCodec[T?] {
  {
    from_: (j, path, d) => Some(d.apply(codec, j, path)),
    to_: v => {
      match v {
        None => Json::null()
        Some(v) => (codec.to_)(v)
      }
    },
    missing_: Some(() => None),
    omit_: v => v is None,
    schema_: codec.schema_,
  }
}

///|
/// Preserves the distinction between absent object fields and explicit null.
/// Outside objects, Absent encodes as null because JSON has no missing value.
pub fn[T] presence(codec : JsonCodec[T]) -> JsonCodec[@jsonkit.Presence[T]] {
  {
    from_: (j, path, d) => {
      if j is Null {
        @jsonkit.Null
      } else {
        @jsonkit.Value(d.apply(codec, j, path))
      }
    },
    to_: v => {
      match v {
        Absent | Null => Json::null()
        Value(v) => (codec.to_)(v)
      }
    },
    missing_: Some(() => @jsonkit.Absent),
    omit_: v => v is Absent,
    schema_: option(codec).schema_,
  }
}

///|
/// An object whose string keys map to values of one codec. All malformed
/// values are reported with escaped JSON-pointer keys; no keys are omitted.
pub fn[T] map_of(codec : JsonCodec[T]) -> JsonCodec[Map[String, T]] {
  let defs : Map[String, Json] = Map([])
  let problems = []
  let child = codec.schema_.reference(defs, problems~)
  {
    from_: (j, path, d) => {
      guard j is Object(obj) else {
        raise invalid([{ path, code: "type", message: "expected object", }])
      }
      let out : Map[String, T] = Map([])
      let issues = []
      for key, value in obj {
        let p = path + "/" + pointer_segment(key)
        out[key] = d.apply(codec, value, p) catch {
          error => {
            d.absorb(error, issues, p, "invalid")
            continue
          }
        }
      }
      if !issues.is_empty() {
        raise invalid(issues)
      }
      out
    },
    to_: values => {
      let obj : Map[String, Json] = Map([])
      for key, value in values {
        obj[key] = (codec.to_)(value)
      }
      Json::object(obj)
    },
    missing_: None,
    omit_: never_omit,
    schema_: {
      name: None,
      json: { "type": "object", "additionalProperties": child },
      defs,
      problems,
    },
  }
}
