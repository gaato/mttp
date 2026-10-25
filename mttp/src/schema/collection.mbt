///|
/// An array codec that collects every element error with its index path.
pub fn[T] array(c : JsonCodec[T]) -> JsonCodec[Array[T]] {
  let defs : Map[String, Json] = Map([])
  let items = c.schema_.reference(defs)
  {
    missing_: None,
    omit_: never_omit,
    from_: (j, path) => {
      match j {
        Array(xs) => {
          let issues = []
          let out = []
          for i, x in xs {
            out.push((c.from_)(x, "\{path}/\{i}")) catch {
              DecodeFailure(kind=Invalid(found), ..) => issues.append(found)
              e =>
                issues.push({
                  path: "\{path}/\{i}",
                  code: "invalid",
                  message: e.message(),
                })
            }
          }
          if issues.is_empty() {
            out
          } else {
            raise invalid(issues)
          }
        }
        _ => raise invalid([{ path, code: "type", message: "expected array", }])
      }
    },
    to_: xs => Json::array(xs.map(c.to_)),
    schema_: { name: None, json: { "type": "array", "items": items }, defs, },
  }
}

///|
/// tapir SRef / lazy: ties the knot through a cell, so a recursive type is
/// a $ref to itself instead of an infinite definition (SC-01).
pub fn[T] recursive(
  name : String,
  body : (JsonCodec[T]) -> JsonCodec[T],
  max_depth~ : Int32 = 128,
) -> JsonCodec[T] {
  let cell : Ref[JsonCodec[T]?] = { val: None, }
  let depth = Ref(0)
  let max_depth = max_depth.max(1)
  let proxy : JsonCodec[T] = {
    missing_: None,
    omit_: never_omit,
    from_: (j, p) => {
      guard cell.val is Some(codec) else {
        raise malformed("recursive codec used during construction")
      }
      if depth.val >= max_depth {
        raise invalid([
          { path: p, code: "depth", message: "recursive codec depth exceeded", },
        ])
      }
      depth.val += 1
      defer {
        depth.val -= 1
      }
      (codec.from_)(j, p)
    },
    to_: v => (cell.val.unwrap().to_)(v),
    schema_: {
      name: None,
      json: { "$ref": Json("#/components/schemas/\{pointer_segment(name)}") },
      defs: {},
    },
  }
  let real = body(proxy)
  cell.val = Some(real)
  {
    ..real,
    from_: proxy.from_,
    schema_: { ..real.schema_, name: Some(name), },
  }
}
