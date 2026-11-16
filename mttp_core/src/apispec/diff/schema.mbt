///|
fn types(j : Json) -> Array[String] {
  let values = match j {
    String(s) => [s]
    Array(a) => a.map(str)
    _ => []
  }
  let unique : Array[String] = []
  for v in values {
    if !unique.contains(v) {
      unique.push(v)
    }
  }
  unique.sort_by((a, b) => a.compare(b))
  unique
}

///|
fn State::schema(s : State, w : Work) -> Unit {
  let a = w.old
  let b = w.new
  for k in keys(a, b) {
    if s.stopped {
      break
    }
    let x = field(a, k)
    let y = field(b, k)
    let p = pointer(w.path, k)
    if obj(a).get(k) == obj(b).get(k) &&
      ![
        "properties", "items", "additionalProperties", "oneOf", "anyOf", "allOf",
        "not", "contains", "propertyNames", "if", "then", "else",
      ].contains(k) {
      continue
    }
    match k {
      "$ref" => ()
      "type" => {
        let xs = types(x)
        let ys = types(y)
        if xs.contains("null") != ys.contains("null") {
          s.variance(
            w,
            p,
            if ys.contains("null") {
              NullableAdded
            } else {
              NullableRemoved
            },
            !ys.contains("null"),
          )
        }
        let xx = xs.filter(t => t != "null")
        let yy = ys.filter(t => t != "null")
        if xx != yy {
          s.emit(w.side, p, TypeChanged(old=xx, new=yy), Breaking, Warning)
        }
      }
      "format" =>
        s.emit(
          w.side,
          p,
          FormatChanged(old=text(x), new=text(y)),
          Warning,
          Warning,
        )
      "enum" =>
        if x == Json::null() {
          s.variance(w, p, EnumAdded, true)
        } else if y == Json::null() {
          s.variance(w, p, EnumRemoved, false)
        } else {
          for v in arr(x) {
            if !arr(y).contains(v) {
              s.variance(w, p, EnumValueRemoved(value=v), true)
            }
          }
          for v in arr(y) {
            if !arr(x).contains(v) {
              s.variance(w, p, EnumValueAdded(value=v), false)
            }
          }
        }
      "required" => {
        for v in arr(x) {
          if !arr(y).contains(v) {
            s.variance(w, p, RequiredPropertyRemoved(name=str(v)), false)
          }
        }
        for v in arr(y) {
          if !arr(x).contains(v) {
            s.variance(w, p, RequiredPropertyAdded(name=str(v)), true)
          }
        }
      }
      "properties" =>
        for name in keys(x, y) {
          let pp = pointer(p, name)
          if !obj(x).contains(name) {
            s.emit(w.side, pp, PropertyAdded(name~), Info, Info)
          } else if !obj(y).contains(name) {
            s.emit(w.side, pp, PropertyRemoved(name~), Breaking, Warning)
          } else {
            s.push(field(x, name), field(y, name), pp, w.side, "schema")
          }
        }
      "additionalProperties" => {
        let effective_x = obj(a).get(k).unwrap_or(Json::boolean(true))
        let effective_y = obj(b).get(k).unwrap_or(Json::boolean(true))
        if x is Object(_) && y is Object(_) {
          s.push(x, y, p, w.side, "schema")
        } else if effective_x != effective_y {
          s.variance(
            w,
            p,
            AdditionalPropertiesChanged(old=obj(a).get(k), new=obj(b).get(k)),
            y == Json::boolean(false) ||
            (y is Object(_) && effective_x == Json::boolean(true)),
          )
        }
      }
      "items" | "not" | "contains" | "propertyNames" | "if" | "then" | "else" =>
        s.push(x, y, p, w.side, "schema")
      "oneOf" | "anyOf" | "allOf" => {
        let xx = arr(x)
        let yy = arr(y)
        for i in 0..<xx.length().max(yy.length()) {
          let pp = pointer(p, i.to_string())
          if i >= xx.length() {
            s.emit(
              w.side,
              pp,
              SubschemaAdded(keyword=k, index=i),
              Warning,
              Warning,
            )
          } else if i >= yy.length() {
            s.emit(
              w.side,
              pp,
              SubschemaRemoved(keyword=k, index=i),
              Warning,
              Warning,
            )
          } else {
            s.push(xx[i], yy[i], pp, w.side, "schema")
          }
        }
      }
      "minimum"
      | "maximum"
      | "exclusiveMinimum"
      | "exclusiveMaximum"
      | "minLength"
      | "maxLength"
      | "minItems"
      | "maxItems"
      | "minProperties"
      | "maxProperties" =>
        if (x is True || x is False) || y is True || y is False {
          s.emit(
            w.side,
            p,
            KeywordChanged(keyword=k, old=obj(a).get(k), new=obj(b).get(k)),
            Warning,
            Warning,
          )
        } else {
          let narrowing = match (x, y) {
            (_, Null) => false
            (Null, _) => true
            (Number(xx, ..), Number(yy, ..)) =>
              if k.has_prefix("min") || k == "exclusiveMinimum" {
                yy > xx
              } else {
                yy < xx
              }
            _ => true
          }
          s.variance(
            w,
            p,
            BoundChanged(keyword=k, old=obj(a).get(k), new=obj(b).get(k)),
            narrowing,
          )
        }
      _ =>
        s.emit(
          w.side,
          p,
          KeywordChanged(keyword=k, old=obj(a).get(k), new=obj(b).get(k)),
          Warning,
          Warning,
        )
    }
  }
  if !(a is Object(_)) || !(b is Object(_)) {
    if a != b {
      s.emit(
        w.side,
        w.path,
        KeywordChanged(keyword="schema", old=Some(a), new=Some(b)),
        Warning,
        Warning,
      )
    }
  }
}
