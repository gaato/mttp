///|
/// Operation identifiers, descriptions, tags and deprecation metadata.
pub(all) struct Info {
  operation_id : String?
  summary : String?
  description : String?
  tags : Array[String]
  deprecated : Bool
}

///|
/// A literal, single capture, or final rest capture in a path template.
#non_exhaustive
pub(all) enum Seg {
  Lit(String)
  Cap(String)
  Rest(String)
} derive(Eq, Debug)

///|
fn parse_template(template : String) -> Array[Seg] {
  let out = []
  for part in template.split("/") {
    let p = part.to_owned()
    if p.is_empty() {
      continue
    }
    if p.has_prefix("{") && p.has_suffix("}") {
      let name = p[1:p.length() - 1].to_owned()
      if name.has_suffix("...") {
        out.push(Rest(name[:name.length() - 3].to_owned()))
      } else {
        out.push(Cap(name))
      }
    } else {
      out.push(Lit(p))
    }
  }
  out
}

///|
/// A typed endpoint definition interpreted by clients, servers and API docs.
pub struct Endpoint[S, I, E, O, M] {
  priv meth : @model.Method?
  priv template : String
  priv security : Input[S]
  priv input : Input[I]
  priv errors : Out[E, @client.Buffered]
  priv output : Out[O, M]
  priv info : Info
  priv max_body_bytes : Int32?
  priv bucket : ((@model.Request) -> String)?
  priv method_set_twice : Bool
}

///|
/// An empty endpoint builder with Unit inputs and an empty 200 response.
pub let endpoint : Endpoint[Unit, Unit, NoError, Unit, @client.Buffered] = {
  meth: None,
  template: "",
  security: unit(),
  input: unit(),
  errors: no_errors(),
  output: { variants: [empty_variant(200)], mode: @client.Buffered::{ }, },
  info: {
    operation_id: None,
    summary: None,
    description: None,
    tags: [],
    deprecated: false,
  },
  max_body_bytes: None,
  bucket: None,
  method_set_twice: false,
}

///|
fn join_template(a : String, b : String) -> String {
  if a.has_suffix("/") && b.has_prefix("/") {
    a + b.view(start_offset=1).to_owned()
  } else {
    a + b
  }
}

///|
/// Appends a path template to this endpoint's prefix.
pub fn[S, I, E, O, M] Endpoint::path(
  self : Endpoint[S, I, E, O, M],
  template : String,
) -> Endpoint[S, I, E, O, M] {
  { ..self, template: join_template(self.template, template), }
}

///|
/// Sets the method and appends a template; repeated method assignment is checked later.
pub fn[S, I, E, O, M] Endpoint::with_method(
  self : Endpoint[S, I, E, O, M],
  meth : @model.Method,
  template : String,
) -> Endpoint[S, I, E, O, M] {
  {
    ..self,
    meth: Some(meth),
    template: join_template(self.template, template),
    method_set_twice: self.method_set_twice || self.meth is Some(_),
  }
}

///|
/// Sets GET and appends a path template.
pub fn[S, I, E, O, M] Endpoint::get(
  self : Endpoint[S, I, E, O, M],
  template : String,
) -> Endpoint[S, I, E, O, M] {
  self.with_method(Get, template)
}

///|
/// Sets POST and appends a path template.
pub fn[S, I, E, O, M] Endpoint::post(
  self : Endpoint[S, I, E, O, M],
  template : String,
) -> Endpoint[S, I, E, O, M] {
  self.with_method(Post, template)
}

///|
/// Sets DELETE and appends a path template.
pub fn[S, I, E, O, M] Endpoint::delete(
  self : Endpoint[S, I, E, O, M],
  template : String,
) -> Endpoint[S, I, E, O, M] {
  self.with_method(Delete, template)
}

///|
/// Adds typed security inputs, decoded before regular handler inputs.
pub fn[I, E, O, S2, M] Endpoint::security(
  self : Endpoint[Unit, I, E, O, M],
  s : Input[S2],
) -> Endpoint[S2, I, E, O, M] {
  {
    meth: self.meth,
    template: self.template,
    security: s,
    input: self.input,
    errors: self.errors,
    output: self.output,
    info: self.info,
    max_body_bytes: self.max_body_bytes,
    bucket: self.bucket,
    method_set_twice: self.method_set_twice,
  }
}

///|
/// Adds the typed regular request input.
pub fn[S, E, O, I2, M] Endpoint::input(
  self : Endpoint[S, Unit, E, O, M],
  i : Input[I2],
) -> Endpoint[S, I2, E, O, M] {
  {
    meth: self.meth,
    template: self.template,
    security: self.security,
    input: i,
    errors: self.errors,
    output: self.output,
    info: self.info,
    max_body_bytes: self.max_body_bytes,
    bucket: self.bucket,
    method_set_twice: self.method_set_twice,
  }
}

///|
/// Declares application error classification and response variants.
pub fn[S, I, O, E2, M] Endpoint::errors(
  self : Endpoint[S, I, NoError, O, M],
  e : Out[E2, @client.Buffered],
) -> Endpoint[S, I, E2, O, M] {
  {
    meth: self.meth,
    template: self.template,
    security: self.security,
    input: self.input,
    errors: e,
    output: self.output,
    info: self.info,
    max_body_bytes: self.max_body_bytes,
    bucket: self.bucket,
    method_set_twice: self.method_set_twice,
  }
}

///|
/// Declares the typed successful response variants.
pub fn[S, I, E, O2, M, N] Endpoint::output(
  self : Endpoint[S, I, E, Unit, M],
  o : Out[O2, N],
) -> Endpoint[S, I, E, O2, N] {
  {
    meth: self.meth,
    template: self.template,
    security: self.security,
    input: self.input,
    errors: self.errors,
    output: o,
    info: self.info,
    max_body_bytes: self.max_body_bytes,
    bucket: self.bucket,
    method_set_twice: self.method_set_twice,
  }
}

///|
/// Sets the short operation summary.
pub fn[S, I, E, O, M] Endpoint::summary(
  self : Endpoint[S, I, E, O, M],
  s : String,
) -> Endpoint[S, I, E, O, M] {
  { ..self, info: { ..self.info, summary: Some(s), }, }
}

///|
/// Sets a unique operation identifier for documentation and client observations.
pub fn[S, I, E, O, M] Endpoint::operation_id(
  self : Endpoint[S, I, E, O, M],
  s : String,
) -> Endpoint[S, I, E, O, M] {
  { ..self, info: { ..self.info, operation_id: Some(s), }, }
}

///|
/// Appends a documentation tag.
pub fn[S, I, E, O, M] Endpoint::tag(
  self : Endpoint[S, I, E, O, M],
  t : String,
) -> Endpoint[S, I, E, O, M] {
  { ..self, info: { ..self.info, tags: [..self.info.tags, t], }, }
}

///|
/// Overrides the server's request-body limit for this endpoint.
pub fn[S, I, E, O, M] Endpoint::max_body_bytes(
  self : Endpoint[S, I, E, O, M],
  n : Int32,
) -> Endpoint[S, I, E, O, M] {
  { ..self, max_body_bytes: Some(n), }
}

///|
/// Interpreter-independent endpoint metadata for routing, checking and API docs.
pub struct EndpointDoc {
  meth : @model.Method?
  template : String
  segments : Array[Seg]
  security : Array[Atom]
  inputs : Array[Atom]
  outputs : Array[VariantDoc]
  errors : Array[VariantDoc]
  info : Info
  max_body_bytes : Int32?
  method_set_twice : Bool
}

///|
/// Projects this endpoint into documentation metadata.
pub fn[S, I, E, O, M] Endpoint::doc(
  self : Endpoint[S, I, E, O, M],
) -> EndpointDoc {
  {
    meth: self.meth,
    template: self.template,
    segments: parse_template(self.template),
    security: self.security.atoms.copy(),
    inputs: self.input.atoms.copy(),
    outputs: self.output.docs(),
    errors: self.errors.docs(),
    info: { ..self.info, tags: self.info.tags.copy(), },
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
  if !self.template.has_prefix("/") ||
    self.template.contains("?") ||
    self.template.contains("#") {
    out.push("template must be an absolute path without query or fragment")
  }
  for part in self.template.split("/") {
    if part.contains("{") || part.contains("}") {
      if !(part.has_prefix("{") && part.has_suffix("}")) ||
        part.length() < 3 ||
        part[1:part.length() - 1].iter().any(c => c == '{' || c == '}') {
        out.push("malformed path capture")
      }
    }
  }
  if self.max_body_bytes is Some(limit) && limit < 0 {
    out.push("negative body limit")
  }
  // "/a/" and "/a//b" would be routed and encoded as "/a" and "/a/b".
  if self.template != "/" &&
    self.template.split("/").drop(1).any(p => p.length() == 0) {
    out.push(
      "empty path segment (a trailing or doubled '/') in \{self.template}",
    )
  }
  let captures = self.segments.filter_map(s => {
    match s {
      Cap(n) | Rest(n) => Some(n)
      Lit(_) => None
    }
  })
  for i, segment in self.segments {
    if segment is Rest(name) {
      if i != self.segments.length() - 1 || name.is_empty() {
        out.push("rest capture must be named and final")
      }
    }
  }
  let path_atoms = [..self.security, ..self.inputs].filter(a => {
    a.location is Path
  })
  let seen_captures : Map[String, Bool] = Map([])
  for n in captures {
    if seen_captures.contains(n) {
      out.push("duplicate path capture \{n}")
    }
    seen_captures[n] = true
    if !path_atoms.iter().any(a => a.name == n) {
      out.push(
        "{\{n}} in the template \{self.template} has no path input (a base endpoint's captures must be re-declared in each endpoint's input)",
      )
    }
  }
  let seen_inputs : Map[String, Bool] = Map([])
  for a in path_atoms {
    if seen_inputs.contains(a.name) {
      out.push("duplicate path input \{a.name}")
    }
    seen_inputs[a.name] = true
    if !a.required {
      out.push("optional path input \{a.name}")
    }
    let rest_capture = self.segments
      .iter()
      .any(s => s is Rest(name) && name == a.name)
    if a.rest != rest_capture {
      out.push("path input \{a.name} does not match capture kind")
    }
    if !captures.contains(a.name) {
      out.push("path input \{a.name} is not in the template")
    }
  }
  let bodies = self.inputs.filter(a => a.location is (Body(..) | RawBody))
  let security_bodies = self.security.filter(a => {
    a.location is (Body(..) | RawBody)
  })
  if bodies.length() > 1 {
    out.push("more than one body input")
  }
  if security_bodies.length() > 1 {
    out.push("more than one security body")
  }
  if security_bodies.iter().any(a => a.location is Body(..)) {
    out.push("security body must use raw_body")
  }
  if !security_bodies.is_empty() &&
    bodies.iter().any(a => a.location is Body(streamed=true, ..)) {
    out.push("raw security body cannot be combined with streamed input")
  }
  if self.meth is Some(Get | Head) &&
    (!bodies.is_empty() || !security_bodies.is_empty()) {
    out.push("GET or HEAD with a body")
  }
  if self.outputs.is_empty() {
    out.push("no output variants")
  }
  for variant in [..self.outputs, ..self.errors] {
    let headers : Map[String, Bool] = Map([])
    for name in variant.headers {
      let lower = name.to_lower()
      if headers.contains(lower) && lower != "set-cookie" {
        out.push("duplicate response header " + name)
      }
      headers[lower] = true
      @model.Request::get("/").header(name, "").validate() catch {
        _ => out.push("invalid response header " + name)
      }
      if lower == "content-length" ||
        lower == "transfer-encoding" ||
        (lower == "content-type" && variant.media_type is Some(_)) {
        out.push(
          "response header conflicts with representation framing: " + name,
        )
      }
    }
    if variant.status < 200 || variant.status > 599 {
      out.push("response status must be between 200 and 599")
    }
    if (variant.status == 204 || variant.status == 304) &&
      variant.media_type is Some(_) {
      out.push("body representation on a bodyless response status")
    }
  }
  out
}

///|
/// A fatal definition error or nonfatal verification advisory.
pub(all) struct DefinitionProblem {
  template : String
  message : String
  fatal : Bool // fatal: Router::new and to_openapi refuse; otherwise advice for verify
} derive(Eq, Debug)

///|
/// The single definition checker, called by Router::new, to_openapi and
/// testkit.verify (S-04g): per-endpoint problems plus route conflicts.
pub fn check_definitions(docs : Array[EndpointDoc]) -> Array[DefinitionProblem] {
  let out = []
  let seen : Map[String, String] = Map([])
  let operation_ids : Map[String, Bool] = Map([])
  let schemas : Map[String, Json] = Map([])
  for d in docs {
    let schema_problems = []
    for atom in [..d.security, ..d.inputs] {
      ignore(atom.schema.reference(schemas, problems=schema_problems))
    }
    for variant in [..d.outputs, ..d.errors] {
      for _, schema in variant.header_schemas {
        ignore(schema.reference(schemas, problems=schema_problems))
      }
      if variant.schema is Some(schema) {
        ignore(schema.reference(schemas, problems=schema_problems))
      }
    }
    for message in schema_problems {
      out.push({ template: d.template, message, fatal: true, })
    }
    if d.info.operation_id is Some(id) {
      if id.is_empty() || operation_ids.contains(id) {
        out.push({
          template: d.template,
          message: "empty or duplicate operation_id \{id}",
          fatal: true,
        })
      }
      operation_ids[id] = true
    }
    for p in d.problems() {
      out.push({ template: d.template, message: p, fatal: true, })
    }
    let shape = d.segments
      .map(s => {
        match s {
          Lit(l) => l
          Cap(_) => "{}"
          Rest(_) => "{...}"
        }
      })
      .join("/")
    let key = "\{d.meth.unwrap_or(Get)} \{shape}"
    match seen.get(key) {
      Some(other) =>
        out.push({
          template: d.template,
          message: "conflicts with \{other}",
          fatal: true,
        })
      None => seen[key] = d.template
    }
    let statuses = d.errors.map(v => (v.status, v.media_type))
    for i, a in statuses {
      for j in 0..<i {
        if statuses[j] == a {
          out.push({
            template: d.template,
            message: "two error variants share status \{a.0} and a media type: the client tries them in order",
            fatal: false,
          })
        }
      }
    }
  }
  out
}

///|
/// Definition problems which prevent an interpreter from being constructed.
pub(all) suberror DefinitionError {
  DefinitionError(Array[DefinitionProblem])
} derive(Debug)
