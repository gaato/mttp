///|
pub(all) struct Info {
  operation_id : String?
  summary : String?
  tags : Array[String]
  deprecated : Bool
} derive(Debug)

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
      out.push(Cap(p.unsafe_substring(start=1, end=p.length() - 1)))
    } else {
      out.push(Lit(p))
    }
  }
  out
}

///|
/// tapir's Endpoint[SECURITY_INPUT, INPUT, ERROR_OUTPUT, OUTPUT, R] without
/// R: streams are ordinary values (`&BodyStream`, `EventSource[T]`), and
/// WebSockets get their own type.
pub struct Endpoint[S, I, E, O] {
  priv meth : @model.Method
  priv template : String
  priv segments : Array[Seg]
  priv security : Input[S]
  priv input : Input[I]
  priv errors : Errors[E]
  priv output : Out[O]
  priv info : Info
  priv max_body : Int64
}

///|
/// The base every endpoint starts from; builders change one type argument
/// at a time.
pub fn endpoint(
  meth : @model.Method,
  template : String,
) -> Endpoint[Unit, Unit, NoError, Unit] {
  {
    meth,
    template,
    segments: parse_template(template),
    security: none(),
    input: none(),
    errors: no_errors(),
    output: { variants: [empty_variant(200)] },
    info: { operation_id: None, summary: None, tags: [], deprecated: false },
    max_body: 1048576L,
  }
}

///|
pub fn[S, I, E, O, S2] Endpoint::security(
  self : Endpoint[S, I, E, O],
  security : Input[S2],
) -> Endpoint[S2, I, E, O] {
  {
    meth: self.meth,
    template: self.template,
    segments: self.segments,
    security,
    input: self.input,
    errors: self.errors,
    output: self.output,
    info: self.info,
    max_body: self.max_body,
  }
}

///|
pub fn[S, I, E, O, I2] Endpoint::input(
  self : Endpoint[S, I, E, O],
  input : Input[I2],
) -> Endpoint[S, I2, E, O] {
  {
    meth: self.meth,
    template: self.template,
    segments: self.segments,
    security: self.security,
    input,
    errors: self.errors,
    output: self.output,
    info: self.info,
    max_body: self.max_body,
  }
}

///|
pub fn[S, I, E, O, E2] Endpoint::errors(
  self : Endpoint[S, I, E, O],
  errors : Errors[E2],
) -> Endpoint[S, I, E2, O] {
  {
    meth: self.meth,
    template: self.template,
    segments: self.segments,
    security: self.security,
    input: self.input,
    errors,
    output: self.output,
    info: self.info,
    max_body: self.max_body,
  }
}

///|
pub fn[S, I, E, O, O2] Endpoint::output(
  self : Endpoint[S, I, E, O],
  output : Out[O2],
) -> Endpoint[S, I, E, O2] {
  {
    meth: self.meth,
    template: self.template,
    segments: self.segments,
    security: self.security,
    input: self.input,
    errors: self.errors,
    output,
    info: self.info,
    max_body: self.max_body,
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
pub fn[S, I, E, O] Endpoint::tags(self : Endpoint[S, I, E, O], tags : Array[String]) -> Endpoint[S, I, E, O] {
  { ..self, info: { ..self.info, tags, } }
}

///|
pub fn[S, I, E, O] Endpoint::max_body(self : Endpoint[S, I, E, O], bytes : Int64) -> Endpoint[S, I, E, O] {
  { ..self, max_body: bytes }
}

///|
/// The untyped view every documentation and verification pass reads.
pub(all) struct EndpointDoc {
  meth : @model.Method
  template : String
  segments : Array[Seg]
  security : Array[Atom]
  inputs : Array[Atom]
  outputs : Array[VariantDoc]
  errors : Array[VariantDoc]
  /// Responses the framework itself can send for this endpoint (P4).
  implied : Array[(Int, String)]
  info : Info
  max_body : Int64
} derive(Debug)

///|
pub fn[S, I, E, O] Endpoint::doc(self : Endpoint[S, I, E, O]) -> EndpointDoc {
  let implied = []
  let all = [..self.security.atoms, ..self.input.atoms]
  if all.iter().any(a => !(a.location is (Auth(..) | Path))) {
    implied.push((400, "malformed request"))
  }
  if all.iter().any(a => a.location is Auth(..)) {
    implied.push((401, "missing or invalid credentials"))
  }
  if all.iter().any(a => a.location is Body(secondary=false, ..)) {
    implied.push((413, "body larger than \{self.max_body} bytes"))
    implied.push((415, "unsupported media type"))
    implied.push((422, "body failed validation"))
  }
  implied.push((500, "unexpected server error"))
  {
    meth: self.meth,
    template: self.template,
    segments: self.segments,
    security: self.security.atoms,
    inputs: self.input.atoms,
    outputs: self.output.docs(),
    errors: self.errors.out.docs(),
    implied,
    info: self.info,
    max_body: self.max_body,
  }
}

///|
/// Problems that make an endpoint unservable; refused at `Server::new`
/// and listed by `verify` in tests (tapir's EndpointVerifier).
pub fn EndpointDoc::problems(self : EndpointDoc) -> Array[String] {
  let out = []
  let captures = self.segments.filter_map(s => if s is Cap(n) { Some(n) } else { None })
  let path_atoms = [..self.security, ..self.inputs].filter(a => a.location is Path)
  for n in captures {
    if !path_atoms.iter().any(a => a.name == n) {
      out.push("{\{n}} in the template has no path input")
    }
  }
  for a in path_atoms {
    if !captures.contains(a.name) {
      out.push("path input \{a.name} is not in the template")
    }
  }
  let bodies = self.inputs.filter(a => a.location is Body(secondary=false, ..))
  if bodies.length() > 1 {
    out.push("more than one body input")
  }
  if self.security.iter().any(a => a.location is Body(secondary=false, ..)) {
    out.push("a security input may only take the raw body (raw_body)")
  }
  let secondary = self.security.iter().any(a => a.location is Body(secondary=true, ..))
  if secondary && bodies.iter().any(a => a.location is Body(streamed=true, ..)) {
    out.push("raw_body needs the body buffered; it cannot be streamed too")
  }
  if (self.meth is (Get | Head)) && !bodies.is_empty() {
    out.push("\{self.meth.as_str()} with a body")
  }
  for v in self.outputs {
    if (v.status == 204 || v.status == 304) && v.media_type is Some(_) {
      out.push("status \{v.status} with a body")
    }
  }
  out
}
