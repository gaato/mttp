///|
pub(all) struct Info {
  operation_id : String?
  summary : String?
  description : String?
  tags : Array[String]
  deprecated : Bool
}

///|
pub(all) enum Seg {
  Lit(String)
  Cap(String)
} derive(Eq, Debug)

///|
fn parse_template(template : String) -> Array[Seg] {
  let out = []
  for part in template.split("/") {
    let p = part.to_string()
    if p.is_empty() {
      continue
    }
    if p.has_prefix("{") && p.has_suffix("}") {
      out.push(Cap(p.view(start_offset=1, end_offset=p.length() - 1).to_string()))
    } else {
      out.push(Lit(p))
    }
  }
  out
}

///|
pub struct Endpoint[S, I, E, O] {
  priv meth : @model.Method?
  priv template : String
  priv security : Input[S]
  priv input : Input[I]
  priv errors : Errors[E]
  priv output : Out[O]
  priv info : Info
  priv max_body_bytes : Int?
  priv method_set_twice : Bool
}

///|
pub let endpoint : Endpoint[Unit, Unit, NoError, Unit] = {
  meth: None,
  template: "",
  security: unit(),
  input: unit(),
  errors: no_errors(),
  output: { variants: [empty_variant(200)] },
  info: { operation_id: None, summary: None, description: None, tags: [], deprecated: false },
  max_body_bytes: None,
  method_set_twice: false,
}

///|
fn join_template(a : String, b : String) -> String {
  if a.has_suffix("/") && b.has_prefix("/") {
    a + b.view(start_offset=1).to_string()
  } else {
    a + b
  }
}

///|
pub fn[S, I, E, O] Endpoint::path(self : Endpoint[S, I, E, O], template : String) -> Endpoint[S, I, E, O] {
  { ..self, template: join_template(self.template, template) }
}

///|
pub fn[S, I, E, O] Endpoint::with_method(
  self : Endpoint[S, I, E, O],
  meth : @model.Method,
  template : String,
) -> Endpoint[S, I, E, O] {
  {
    ..self,
    meth: Some(meth),
    template: join_template(self.template, template),
    method_set_twice: self.method_set_twice || self.meth is Some(_),
  }
}

///|
pub fn[S, I, E, O] Endpoint::get(self : Endpoint[S, I, E, O], template : String) -> Endpoint[S, I, E, O] {
  self.with_method(Get, template)
}

///|
pub fn[S, I, E, O] Endpoint::post(self : Endpoint[S, I, E, O], template : String) -> Endpoint[S, I, E, O] {
  self.with_method(Post, template)
}

///|
pub fn[S, I, E, O] Endpoint::delete(self : Endpoint[S, I, E, O], template : String) -> Endpoint[S, I, E, O] {
  self.with_method(Delete, template)
}

///|
pub fn[I, E, O, S2] Endpoint::security(self : Endpoint[Unit, I, E, O], s : Input[S2]) -> Endpoint[S2, I, E, O] {
  {
    meth: self.meth,
    template: self.template,
    security: s,
    input: self.input,
    errors: self.errors,
    output: self.output,
    info: self.info,
    max_body_bytes: self.max_body_bytes,
    method_set_twice: self.method_set_twice,
  }
}

///|
pub fn[S, E, O, I2] Endpoint::input(self : Endpoint[S, Unit, E, O], i : Input[I2]) -> Endpoint[S, I2, E, O] {
  {
    meth: self.meth,
    template: self.template,
    security: self.security,
    input: i,
    errors: self.errors,
    output: self.output,
    info: self.info,
    max_body_bytes: self.max_body_bytes,
    method_set_twice: self.method_set_twice,
  }
}

///|
pub fn[S, I, O, E2] Endpoint::errors(self : Endpoint[S, I, NoError, O], e : Errors[E2]) -> Endpoint[S, I, E2, O] {
  {
    meth: self.meth,
    template: self.template,
    security: self.security,
    input: self.input,
    errors: e,
    output: self.output,
    info: self.info,
    max_body_bytes: self.max_body_bytes,
    method_set_twice: self.method_set_twice,
  }
}

///|
pub fn[S, I, E, O2] Endpoint::output(self : Endpoint[S, I, E, Unit], o : Out[O2]) -> Endpoint[S, I, E, O2] {
  {
    meth: self.meth,
    template: self.template,
    security: self.security,
    input: self.input,
    errors: self.errors,
    output: o,
    info: self.info,
    max_body_bytes: self.max_body_bytes,
    method_set_twice: self.method_set_twice,
  }
}

///|
pub fn[S, I, E, O] Endpoint::summary(self : Endpoint[S, I, E, O], s : String) -> Endpoint[S, I, E, O] {
  { ..self, info: { ..self.info, summary: Some(s) } }
}

///|
pub fn[S, I, E, O] Endpoint::operation_id(self : Endpoint[S, I, E, O], s : String) -> Endpoint[S, I, E, O] {
  { ..self, info: { ..self.info, operation_id: Some(s) } }
}

///|
pub fn[S, I, E, O] Endpoint::tag(self : Endpoint[S, I, E, O], t : String) -> Endpoint[S, I, E, O] {
  { ..self, info: { ..self.info, tags: [..self.info.tags, t] } }
}

///|
pub fn[S, I, E, O] Endpoint::max_body_bytes(self : Endpoint[S, I, E, O], n : Int) -> Endpoint[S, I, E, O] {
  { ..self, max_body_bytes: Some(n) }
}

///|
pub(all) struct EndpointDoc {
  meth : @model.Method?
  template : String
  segments : Array[Seg]
  security : Array[Atom]
  inputs : Array[Atom]
  outputs : Array[VariantDoc]
  errors : Array[VariantDoc]
  info : Info
  max_body_bytes : Int?
  method_set_twice : Bool
}

///|
pub fn[S, I, E, O] Endpoint::doc(self : Endpoint[S, I, E, O]) -> EndpointDoc {
  {
    meth: self.meth,
    template: self.template,
    segments: parse_template(self.template),
    security: self.security.atoms,
    inputs: self.input.atoms,
    outputs: self.output.docs(),
    errors: self.errors.out.docs(),
    info: self.info,
    max_body_bytes: self.max_body_bytes,
    method_set_twice: self.method_set_twice,
  }
}

///|
/// Per-endpoint problems; check_definitions adds cross-endpoint ones.
pub fn EndpointDoc::problems(self : EndpointDoc) -> Array[String] {
  let out = []
  if self.meth is None {
    out.push("no method")
  }
  if self.method_set_twice {
    out.push("method set twice")
  }
  // "/a/" and "/a//b" would be routed and encoded as "/a" and "/a/b".
  if self.template != "/" &&
    self.template.split("/").drop(1).any(p => p.length() == 0) {
    out.push("empty path segment (a trailing or doubled '/') in \{self.template}")
  }
  let captures = self.segments.filter_map(s => if s is Cap(n) { Some(n) } else { None })
  let path_atoms = [..self.security, ..self.inputs].filter(a => a.location is Path)
  for n in captures {
    if !path_atoms.iter().any(a => a.name == n) {
      out.push("{\{n}} in the template \{self.template} has no path input (a base endpoint's captures must be re-declared in each endpoint's input)")
    }
  }
  for a in path_atoms {
    if !captures.contains(a.name) {
      out.push("path input \{a.name} is not in the template")
    }
  }
  let bodies = self.inputs.filter(a => a.location is Body(..))
  if bodies.length() > 1 {
    out.push("more than one body input")
  }
  if (self.meth is Some(Get | Head)) && !bodies.is_empty() {
    out.push("GET or HEAD with a body")
  }
  out
}

///|
pub(all) struct DefinitionProblem {
  template : String
  message : String
  fatal : Bool       // fatal: Router::new and to_openapi refuse; otherwise advice for verify
} derive(Eq, Debug)

///|
/// The single definition checker, called by Router::new, to_openapi and
/// testkit.verify (S-04g): per-endpoint problems plus route conflicts.
pub fn check_definitions(docs : Array[EndpointDoc]) -> Array[DefinitionProblem] {
  let out = []
  let seen : Map[String, String] = Map::new()
  for d in docs {
    for p in d.problems() {
      out.push({ template: d.template, message: p, fatal: true })
    }
    let shape = d.segments.map(s => match s { Lit(l) => l; Cap(_) => "{}" }).join("/")
    let key = "\{d.meth.unwrap_or(Get)} \{shape}"
    match seen.get(key) {
      Some(other) => out.push({ template: d.template, message: "conflicts with \{other}", fatal: true })
      None => seen[key] = d.template
    }
    let statuses = d.errors.map(v => (v.status, v.media_type))
    for i, a in statuses {
      for j in 0..<i {
        if statuses[j] == a {
          out.push({ template: d.template, message: "two error variants share status \{a.0} and a media type: the client tries them in order", fatal: false })
        }
      }
    }
  }
  out
}

///|
pub(all) suberror DefinitionError {
  DefinitionError(Array[DefinitionProblem])
} derive(Debug)
