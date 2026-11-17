///|
fn path_shape(path : String) -> String {
  let parts = path.split("{").collect()
  let result = [parts[0].to_owned()]
  for part in parts[1:] {
    match part.find("}") {
      Some(end) => result.push("{}" + part[end + 1:].to_owned())
      None => result.push("{" + part.to_owned())
    }
  }
  result.join("")
}

///|
fn parameter_key(p : Json, template : String) -> String {
  let name = str(field(p, "name"))
  let location = str(field(p, "in"))
  if location == "path" {
    for expression in template.split("{").drop(1); index = 0 {
      if expression.has_prefix(name + "}") {
        return "path:\{index}"
      }
      continue index + 1
    }
  }
  location + ":" + name
}

///|
fn State::parameters(
  s : State,
  w : Work,
  old_template : String,
  new_template : String,
) -> Unit {
  let a = arr(w.old)
  let b = arr(w.new)
  let matched : Map[Int32, Bool] = Map([])
  for x in a {
    let name = str(field(x, "name"))
    let location = str(field(x, "in"))
    let mut found = -1
    for i in 0..<b.length() {
      if !matched.contains(i) &&
        parameter_key(x, old_template) == parameter_key(b[i], new_template) {
        found = i
        break
      }
    }
    if found < 0 {
      for i in 0..<b.length() {
        if !matched.contains(i) && field(x, "name") == field(b[i], "name") {
          found = i
          break
        }
      }
    }
    if found < 0 {
      s.emit(
        Request,
        w.path,
        ParameterRemoved(name~, location~),
        Breaking,
        Warning,
      )
      continue
    }
    matched[found] = true
    let y = b[found]
    let p = pointer(w.path, found.to_string())
    if field(x, "content") == Json::null() &&
      field(y, "content") == Json::null() {
      for k in ["style", "explode", "allowReserved"] {
        let old = serialization(x, k)
        let new = serialization(y, k)
        if old != new {
          s.emit(
            Request,
            pointer(p, k),
            KeywordChanged(keyword=k, old=Some(old), new=Some(new)),
            Breaking,
            Breaking,
          )
        }
      }
    }
    if field(x, "in") != field(y, "in") {
      s.emit(
        Request,
        p,
        ParameterLocationChanged(name~, old=location, new=str(field(y, "in"))),
        Breaking,
        Breaking,
      )
    }
    if field(x, "required") != field(y, "required") {
      let required = field(y, "required") == Json::boolean(true)
      s.emit(
        Request,
        p,
        ParameterRequiredChanged(name~, location~, required~),
        if required {
          Breaking
        } else {
          Info
        },
        if required {
          Breaking
        } else {
          Info
        },
      )
    }
    s.push(x, y, p, Request, "message")
  }
  for i in 0..<b.length() {
    if !matched.contains(i) {
      let y = b[i]
      let required = field(y, "required") == Json::boolean(true)
      s.emit(
        Request,
        pointer(w.path, i.to_string()),
        ParameterAdded(
          name=str(field(y, "name")),
          location=str(field(y, "in")),
          required~,
        ),
        if required {
          Breaking
        } else {
          Info
        },
        if required {
          Breaking
        } else {
          Info
        },
      )
    }
  }
}

///|
fn requirements(j : Json) -> Array[Json] {
  if arr(j).is_empty() {
    [Json::object(Map([]))]
  } else {
    arr(j).map(v => {
      Json::object(obj(v).map((_, scopes) => strings_json(types(scopes))))
    })
  }
}

///|
fn serialization(parameter : Json, keyword : String) -> Json {
  let location = str(field(parameter, "in"))
  let style = obj(parameter)
    .get("style")
    .unwrap_or(
      Json::string(
        if location == "query" || location == "cookie" {
          "form"
        } else {
          "simple"
        },
      ),
    )
  match keyword {
    "style" => style
    "explode" =>
      obj(parameter)
      .get(keyword)
      .unwrap_or(
        Json::boolean(
          style == Json::string("form") || style == Json::string("cookie"),
        ),
      )
    _ => obj(parameter).get(keyword).unwrap_or(Json::boolean(false))
  }
}

///|
fn requirement(j : Json) -> Map[String, Array[String]] {
  obj(j).map((_, v) => arr(v).map(str))
}

///|
fn effective(op : Json, item : Json, root : Json, k : String) -> Json {
  obj(op).get(k).unwrap_or(obj(item).get(k).unwrap_or(field(root, k)))
}

///|
fn State::effective_parameters(
  s : State,
  root : Json,
  op : Json,
  item : Json,
  template : String,
  path : String,
) -> Json {
  let result : Array[Json] = []
  for p in arr(field(op, "parameters")) {
    if !s.visit(path) {
      break
    }
    result.push(s.expand(root, p, path))
  }
  for p in arr(field(item, "parameters")) {
    if !s.visit(path) {
      break
    }
    let p = s.expand(root, p, path)
    if !result.any(v => parameter_key(v, template) == parameter_key(p, template)) {
      result.push(p)
    }
  }
  Json::array(result)
}

///|
fn State::operation(
  s : State,
  a : Json,
  b : Json,
  ai : Json,
  bi : Json,
  ar : Json,
  br : Json,
  p : String,
  at : String,
  bt : String,
) -> Unit {
  if field(a, "operationId") != field(b, "operationId") {
    s.emit(
      Request,
      pointer(p, "operationId"),
      OperationIdChanged(
        old=text(field(a, "operationId")),
        new=text(field(b, "operationId")),
      ),
      Warning,
      Info,
    )
  }
  s.parameters(
    {
      old: s.effective_parameters(ar, a, ai, at, pointer(p, "parameters")),
      new: s.effective_parameters(br, b, bi, bt, pointer(p, "parameters")),
      path: pointer(p, "parameters"),
      side: Request,
      context: "parameters",
      uncertain: false,
      old_source: Source::new(pointer(p, "parameters")),
      new_source: Source::new(pointer(p, "parameters")),
    },
    at,
    bt,
  )
  let pp = pointer(p, "requestBody")
  let x = s.expand(ar, field(a, "requestBody"), pp)
  let y = s.expand(br, field(b, "requestBody"), pp)
  if x == Json::null() && y != Json::null() {
    let required = field(y, "required") == Json::boolean(true)
    s.emit(
      Request,
      pp,
      RequestBodyAdded(required~),
      if required {
        Breaking
      } else {
        Info
      },
      if required {
        Breaking
      } else {
        Info
      },
    )
  } else if x != Json::null() && y == Json::null() {
    s.emit(Request, pp, RequestBodyRemoved, Breaking, Warning)
  } else if x != Json::null() {
    if field(x, "required") != field(y, "required") {
      let required = field(y, "required") == Json::boolean(true)
      s.emit(
        Request,
        pp,
        RequestBodyRequiredChanged(required~),
        if required {
          Breaking
        } else {
          Info
        },
        if required {
          Breaking
        } else {
          Info
        },
      )
    }
    s.push(x, y, pp, Request, "message")
  }
  s.push(
    field(a, "responses"),
    field(b, "responses"),
    pointer(p, "responses"),
    Response,
    "responses",
  )
  let xs = requirements(effective(a, ai, ar, "security"))
  let ys = requirements(effective(b, bi, br, "security"))
  for v in xs {
    if !ys.contains(v) {
      s.emit(
        Request,
        pointer(p, "security"),
        SecurityRequirementRemoved(requirement=requirement(v)),
        Breaking,
        Breaking,
      )
    }
  }
  for v in ys {
    if !xs.contains(v) {
      s.emit(
        Request,
        pointer(p, "security"),
        SecurityRequirementAdded(requirement=requirement(v)),
        Info,
        Info,
      )
    }
  }
  let xx = arr(effective(a, ai, ar, "servers")).map(v => str(field(v, "url")))
  let yy = arr(effective(b, bi, br, "servers")).map(v => str(field(v, "url")))
  for url in xx {
    if !yy.contains(url) {
      s.emit(
        Request,
        pointer(p, "servers"),
        ServerRemoved(url~),
        Breaking,
        Warning,
      )
    }
  }
  for url in yy {
    if !xx.contains(url) {
      s.emit(Request, pointer(p, "servers"), ServerAdded(url~), Info, Info)
    }
  }
}
