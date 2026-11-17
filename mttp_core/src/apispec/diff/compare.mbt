///|
fn obj(j : Json) -> Map[String, Json] {
  match j {
    Object(m) => m
    _ => Map([])
  }
}

///|
fn arr(j : Json) -> Array[Json] {
  match j {
    Array(a) => a
    _ => []
  }
}

///|
fn field(j : Json, k : String) -> Json {
  obj(j).get(k).unwrap_or(Json::null())
}

///|
fn str(j : Json) -> String {
  match j {
    String(s) => s
    _ => ""
  }
}

///|
fn text(j : Json) -> String? {
  match j {
    String(s) => Some(s)
    _ => None
  }
}

///|
fn pointer(p : String, k : String) -> String {
  p + "/" + k.replace(old="~", new="~0").replace(old="/", new="~1")
}

///|
fn keys(a : Json, b : Json) -> Iter[String] {
  obj(a).keys().concat(obj(b).keys().filter(k => !obj(a).contains(k)))
}

///|
priv struct Source {
  root : String
  overrides : Map[String, String]
}

///|
fn Source::new(root : String) -> Source {
  { root, overrides: Map([]), }
}

///|
fn Source::at(self : Source, relative : String) -> String {
  for key, origin in self.overrides {
    let prefix = pointer("", key)
    if relative == prefix || relative.has_prefix(prefix + "/") {
      return origin + relative[prefix.length():].to_owned()
    }
  }
  self.root + relative
}

///|
fn reference_source(
  source : Source,
  reference : String?,
  wrapper : Json,
  merged : Bool,
) -> Source {
  guard reference is Some(reference) else { return source }
  let overrides : Map[String, String] = Map([])
  if merged {
    for key in obj(wrapper).keys() {
      if key != "$ref" {
        overrides[key] = source.at(pointer("", key))
      }
    }
  }
  { root: reference[1:].to_owned(), overrides, }
}

///|
priv struct Work {
  old : Json
  new : Json
  path : String
  side : Side
  context : String
  uncertain : Bool
  old_source : Source
  new_source : Source
}

///|
priv struct State {
  report : Report
  queue : Array[Work]
  refs : Map[String, Bool]
  max : Int32
  mut used : Int32
  mut stopped : Bool
  mut uncertain : Bool
  mut active : Work?
}

///|
fn relative_path(root : String, path : String) -> String? {
  if path == root || path.has_prefix(root + "/") {
    Some(path[root.length():].to_owned())
  } else {
    None
  }
}

///|
fn State::source_at(s : State, path : String, old : Bool) -> Source {
  guard s.active is Some(w) && relative_path(w.path, path) is Some(relative) else {
    return Source::new(path)
  }
  let source = if old { w.old_source } else { w.new_source }
  if relative == "" {
    source
  } else {
    Source::new(source.at(relative))
  }
}

///|
fn State::change_path(s : State, path : String) -> String {
  guard s.active is Some(w) && relative_path(w.path, path) is Some(relative) else {
    return path
  }
  // Select the side that actually owns the changed member before mapping its
  // provenance. Removed sibling members must retain their old wrapper location.
  if resolve(w.new, "#" + relative) == None &&
    resolve(w.old, "#" + relative) != None {
    w.old_source.at(relative)
  } else {
    w.new_source.at(relative)
  }
}

///|
fn State::emit(
  s : State,
  side : Side,
  path : String,
  kind : ChangeKind,
  client : Severity,
  server : Severity,
) -> Unit {
  if s.stopped {
    return
  }
  let path = s.change_path(path)
  if s.used >= s.max {
    s.stopped = true
    let limit = {
      side,
      path,
      kind: LimitReached(max_nodes=s.max),
      client: Warning,
      server: Warning,
    }
    match side {
      Request => s.report.request.push(limit)
      Response => s.report.response.push(limit)
    }
    return
  }
  s.used += 1
  let change = {
    side,
    path,
    kind,
    client: if s.uncertain {
      Warning
    } else {
      client
    },
    server: if s.uncertain {
      Warning
    } else {
      server
    },
  }
  match side {
    Request => s.report.request.push(change)
    Response => s.report.response.push(change)
  }
}

///|
fn State::push(
  s : State,
  old : Json,
  new : Json,
  path : String,
  side : Side,
  context : String,
  uncertain? : Bool,
  old_source? : Source,
  new_source? : Source,
) -> Unit {
  if s.stopped {
    return
  }
  if s.used >= s.max {
    s.emit(side, path, LimitReached(max_nodes=s.max), Warning, Warning)
  } else {
    s.used += 1
    s.queue.push({
      old,
      new,
      path,
      side,
      context,
      uncertain: uncertain.unwrap_or(s.uncertain),
      old_source: old_source.unwrap_or(s.source_at(path, true)),
      new_source: new_source.unwrap_or(s.source_at(path, false)),
    })
  }
}

///|
fn State::visit(s : State, path : String) -> Bool {
  if s.stopped {
    return false
  }
  if s.used >= s.max {
    s.emit(Request, path, LimitReached(max_nodes=s.max), Warning, Warning)
    return false
  }
  s.used += 1
  true
}

///|
fn State::variance(
  s : State,
  w : Work,
  path : String,
  kind : ChangeKind,
  narrowing : Bool,
) -> Unit {
  let client = if (w.side == Request && narrowing) ||
    (w.side == Response && !narrowing) {
    Breaking
  } else {
    Info
  }
  let server = if w.side == Request { client } else { Info }
  s.emit(w.side, path, kind, client, server)
}

///|
fn resolve(root : Json, reference : String) -> Json? {
  if reference == "#" {
    return Some(root)
  }
  if !reference.has_prefix("#/") {
    return None
  }
  let mut j = root
  for token in reference[2:].split("/") {
    let k = token
      .to_owned()
      .replace(old="~1", new="/")
      .replace(old="~0", new="~")
    match j {
      Object(m) =>
        match m.get(k) {
          Some(v) => j = v
          None => return None
        }
      Array(a) => {
        if k.is_empty() || (k.length() > 1 && k.has_prefix("0")) {
          return None
        }
        let mut index = 0
        for digit in k.iter() {
          if digit < '0' || digit > '9' {
            return None
          }
          let n = digit.to_int() - '0'.to_int()
          if index > (a.length() - n) / 10 {
            return None
          }
          index = index * 10 + n
        }
        guard a.get(index) is Some(value) else { return None }
        j = value
      }
      _ => return None
    }
  }
  Some(j)
}

///|
// Metadata such as requiredness can live behind a non-schema reference.
fn State::expand(s : State, root : Json, value : Json, path : String) -> Json {
  let seen : Map[String, Bool] = Map([])
  let mut value = value
  while !s.stopped {
    guard text(field(value, "$ref")) is Some(reference) else { break }
    if seen.contains(reference) {
      break
    }
    if s.used >= s.max {
      s.emit(Request, path, LimitReached(max_nodes=s.max), Warning, Warning)
      break
    }
    s.used += 1
    seen[reference] = true
    guard resolve(root, reference) is Some(target) else {
      s.emit(
        Request,
        path,
        KeywordChanged(
          keyword="unresolved-ref",
          old=Some(value),
          new=Some(value),
        ),
        Warning,
        Warning,
      )
      break
    }
    value = target
  }
  value
}

///|
/// Compare decoded documents. Local JSON Pointer references are followed without
/// I/O, once per (side, old reference, new reference, conservative context).
/// External or missing targets
/// produce a warning. `max_nodes` bounds visited work and emitted changes;
/// exhaustion yields one LimitReached and an explicitly incomplete report.
pub fn compare(
  old : @apispec.OpenApi,
  new : @apispec.OpenApi,
  max_nodes~ : Int32 = 100000,
) -> Report {
  let s : State = {
    report: { request: [], response: [], },
    queue: [],
    refs: Map([]),
    max: max_nodes.max(0),
    used: 0,
    stopped: false,
    uncertain: false,
    active: None,
  }
  let ar = old.to_json()
  let br = new.to_json()
  let old_schemes = field(field(ar, "components"), "securitySchemes")
  let new_schemes = field(field(br, "components"), "securitySchemes")
  // Equal wrappers may reference targets outside the securitySchemes map.
  if old_schemes != new_schemes ||
    obj(old_schemes).values().any(scheme => text(field(scheme, "$ref")) != None) {
    s.push(
      old_schemes,
      new_schemes,
      "/components/securitySchemes",
      Request,
      "security-schemes",
    )
  }
  let ap = field(ar, "paths")
  let bp = field(br, "paths")
  let matched : Map[String, Bool] = Map([])
  for at in obj(ap).keys() {
    if !s.visit(pointer("/paths", at)) {
      break
    }
    let mut bt : String? = if obj(bp).contains(at) { Some(at) } else { None }
    if bt == None {
      let mut candidates = 0
      for t in obj(bp).keys() {
        if !matched.contains(t) &&
          !obj(ap).contains(t) &&
          path_shape(at) == path_shape(t) {
          bt = Some(t)
          candidates += 1
        }
      }
      if candidates != 1 {
        bt = None
      }
    }
    guard bt is Some(bt) else {
      s.emit(Request, pointer("/paths", at), PathRemoved, Breaking, Breaking)
      continue
    }
    matched[bt] = true
    let p = pointer("/paths", bt)
    let ai = s.expand(ar, field(ap, at), pointer("/paths", at))
    let bi = s.expand(br, field(bp, bt), p)
    for
      meth in [
        "get", "put", "post", "delete", "options", "head", "patch", "trace", "query",
      ] {
      let a = field(ai, meth)
      let b = field(bi, meth)
      let pp = pointer(p, meth)
      if a == Json::null() && b != Json::null() {
        s.emit(Request, pp, OperationAdded(meth~), Info, Info)
      } else if a != Json::null() && b == Json::null() {
        s.emit(Request, pp, OperationRemoved(meth~), Breaking, Breaking)
      } else if a != Json::null() {
        s.operation(a, b, ai, bi, ar, br, pp, at, bt)
      }
    }
    let ax = field(ai, "additionalOperations")
    let bx = field(bi, "additionalOperations")
    for meth in keys(ax, bx) {
      let a = field(ax, meth)
      let b = field(bx, meth)
      let pp = pointer(pointer(p, "additionalOperations"), meth)
      if a == Json::null() {
        s.emit(Request, pp, OperationAdded(meth~), Info, Info)
      } else if b == Json::null() {
        s.emit(Request, pp, OperationRemoved(meth~), Breaking, Breaking)
      } else {
        s.operation(a, b, ai, bi, ar, br, pp, at, bt)
      }
    }
  }
  for bt in obj(bp).keys() {
    if !matched.contains(bt) {
      s.emit(Request, pointer("/paths", bt), PathAdded, Info, Info)
    }
  }
  let mut i = 0
  while i < s.queue.length() && !s.stopped {
    let w = s.queue[i]
    s.active = Some(w)
    s.uncertain = w.uncertain
    i += 1
    // OAuth scopes maps contain scope names and descriptions, not references.
    let xref = if w.context == "oauth-scopes" {
      None
    } else {
      text(field(w.old, "$ref"))
    }
    let yref = if w.context == "oauth-scopes" {
      None
    } else {
      text(field(w.new, "$ref"))
    }
    if xref != yref {
      s.emit(
        w.side,
        pointer(w.path, "$ref"),
        RefTargetChanged(old=xref, new=yref),
        Warning,
        Warning,
      )
    }
    if xref != None || yref != None {
      let key = w.side.to_json().stringify() +
        w.uncertain.to_string() +
        Json::array([optional_string(xref), optional_string(yref)]).stringify() +
        (if xref == None || yref == None {
          strings_json([w.old_source.root, w.new_source.root]).stringify()
        } else {
          ""
        })
      if !s.refs.contains(key) {
        s.refs[key] = true
        let a = match xref {
          Some(r) => resolve(ar, r)
          None => Some(w.old)
        }
        let b = match yref {
          Some(r) => resolve(br, r)
          None => Some(w.new)
        }
        match (a, b) {
          (Some(a), Some(b)) => {
            let one_ref = xref == None || yref == None
            let (a, ac) = if one_ref && xref != None && w.context == "schema" {
              reference_schema(a, w.old)
            } else {
              (a, false)
            }
            let (b, bc) = if one_ref && yref != None && w.context == "schema" {
              reference_schema(b, w.new)
            } else {
              (b, false)
            }
            if ac || bc {
              // Do not traverse synthetic allOf members: they have no source
              // pointers and their interaction has not been proved equivalent.
              s.emit(
                w.side,
                w.path,
                KeywordChanged(
                  keyword="reference-conjunction",
                  old=Some(a),
                  new=Some(b),
                ),
                Warning,
                Warning,
              )
              continue
            }
            s.push(
              a,
              b,
              match yref {
                Some(r) => r[1:].to_owned()
                None => w.path
              },
              w.side,
              w.context,
              uncertain=w.uncertain || ac || bc,
              old_source=reference_source(
                w.old_source,
                xref,
                w.old,
                one_ref && w.context == "schema",
              ),
              new_source=reference_source(
                w.new_source,
                yref,
                w.new,
                one_ref && w.context == "schema",
              ),
            )
          }
          _ =>
            s.emit(
              w.side,
              w.path,
              KeywordChanged(
                keyword="unresolved-ref",
                old=Some(w.old),
                new=Some(w.new),
              ),
              Warning,
              Warning,
            )
        }
      }
      // The resolved pair owns inline-vs-reference comparisons. Comparing the
      // wrapper again would manufacture missing type/enum/bound constraints.
      if xref == None || yref == None {
        continue
      }
    }
    if w.context == "schema" {
      s.schema(w)
      continue
    }
    if [
        "security-schemes", "security-scheme", "oauth-flows", "oauth-flow", "oauth-scopes",
      ].contains(w.context) {
      s.security_fields(w)
      continue
    }
    if w.context == "responses" ||
      w.context == "content" ||
      w.context == "headers" {
      for k in keys(w.old, w.new) {
        let p = pointer(w.path, k)
        let a = field(w.old, k)
        let b = field(w.new, k)
        if a == Json::null() || b == Json::null() {
          let added = a == Json::null()
          let kind = if w.context == "responses" {
            if added {
              ResponseAdded(status=k)
            } else {
              ResponseRemoved(status=k)
            }
          } else if w.context == "content" {
            if added {
              MediaTypeAdded(media_type=k)
            } else {
              MediaTypeRemoved(media_type=k)
            }
          } else {
            KeywordChanged(
              keyword=k,
              old=obj(w.old).get(k),
              new=obj(w.new).get(k),
            )
          }
          s.emit(
            w.side,
            p,
            kind,
            if (w.side == Response && added) || (w.side == Request && !added) {
              Breaking
            } else {
              Warning
            },
            Warning,
          )
        } else {
          s.push(a, b, p, w.side, "message")
        }
      }
    } else {
      for k in ["schema", "itemSchema", "content", "headers"] {
        let a = field(w.old, k)
        let b = field(w.new, k)
        if a != Json::null() || b != Json::null() {
          s.push(
            a,
            b,
            pointer(w.path, k),
            w.side,
            if k == "schema" || k == "itemSchema" {
              "schema"
            } else {
              k
            },
          )
        }
      }
    }
  }
  s.report
}
