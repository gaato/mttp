///|
/// What the decode-failure handler is told (tapir's DecodeFailureContext).
pub(all) struct DecodeFailureContext {
  doc : EndpointDoc
  failures : Array[InputFailure]
  /// True when the failures are the security input's; the body is unread.
  security : Bool
}

///|
pub(all) struct ServerOptions {
  decode_failure : (DecodeFailureContext) -> @model.Response
  /// Errors `classify` did not recognise: logged here, answered with a 500
  /// whose body says nothing about them.
  on_unhandled : (EndpointDoc, Error) -> Unit
}

///|
pub fn problem(status : Int, title : String, errors? : Json = []) -> @model.Response {
  let body : Json = {
    "type": "about:blank",
    "title": title,
    "status": status.to_json(),
    "errors": errors,
  }
  {
    status: @model.Status(status),
    headers: @model.Headers::from_array([
      ("content-type", "application/problem+json"),
    ]),
    body: Bytes(@utf8.encode(body.stringify())),
  }
}

///|
fn location_name(l : Location) -> String {
  match l {
    Path => "path"
    Query => "query"
    Header => "header"
    Cookie => "cookie"
    Auth(..) => "auth"
    Body(..) => "body"
  }
}

///|
/// 401 for credentials, 415 for a body media type, 413 for size, 422 for
/// a body that parsed but failed validation, 400 for the rest.
pub fn default_decode_failure(ctx : DecodeFailureContext) -> @model.Response {
  let errors : Json = Json::array(
    ctx.failures.map(f => {
      "in": location_name(f.atom.location).to_json(),
      "name": f.atom.name.to_json(),
      "message": f.failure.message().to_json(),
    }),
  )
  for f in ctx.failures {
    if f.atom.location is Auth(scheme~, ..) {
      let r = problem(401, "unauthorized")
      let challenge = match scheme {
        Bearer(..) => "Bearer"
        Basic => "Basic"
        _ => "ApiKey"
      }
      return { ..r, headers: r.headers.add("www-authenticate", challenge) }
    }
  }
  for f in ctx.failures {
    match (f.atom.location, f.failure) {
      (_, TooLarge(..)) => {
        let r = problem(413, "content too large", errors~)
        return { ..r, headers: r.headers.add("connection", "close") }
      }
      (Body(..), Mismatch(..)) =>
        return problem(415, "unsupported media type", errors~)
      (Body(..), Invalid(_)) =>
        return problem(422, "validation failed", errors~)
      _ => ()
    }
  }
  problem(400, "bad request", errors~)
}

///|
pub let default_options : ServerOptions = {
  decode_failure: default_decode_failure,
  on_unhandled: (_, _) => (),
}

///|
/// An endpoint with its logic, types erased: what a Server routes to.
pub struct ServerEndpoint {
  priv doc : EndpointDoc
  priv run : async (@model.Request, Map[String, String], ServerOptions) -> Outcome
}

///|
/// What the sans-IO server decided: a response, or a WebSocket upgrade the
/// adapter performs and then hands the connection to.
pub enum Outcome {
  Respond(@model.Response)
  Upgrade(@model.ResponseHead, async (&@model.WebSocketIo) -> Unit)
}

///|
pub fn ServerEndpoint::doc(self : ServerEndpoint) -> EndpointDoc {
  self.doc
}

///|
fn discard(body : @model.Body) -> Unit {
  if body is Stream(s, ..) {
    s.close()
  }
}

///|
async fn read_body(body : @model.Body, limit : Int64) -> BodyValue raise @schema.DecodeFailure {
  match body {
    Empty => Buffered(b"")
    Bytes(b) =>
      if b.length().to_int64() > limit {
        raise TooLarge(limit~)
      } else {
        Buffered(b)
      }
    Stream(s, length~) => {
      if length is Some(n) && n > limit {
        s.close()
        raise TooLarge(limit~)
      }
      Buffered(@model.read_bounded(s, limit) catch { _ => raise TooLarge(limit~) })
    }
  }
}

///|
fn[E] error_response(
  errors : Errors[E],
  doc : EndpointDoc,
  e : Error,
  options : ServerOptions,
) -> @model.Response {
  match (errors.classify)(e) {
    Some(declared) =>
      match errors.out.encode(declared) {
        Some(r) => r
        None => {
          (options.on_unhandled)(doc, e)
          problem(500, "internal server error")
        }
      }
    None => {
      (options.on_unhandled)(doc, e)
      problem(500, "internal server error")
    }
  }
}

///|
/// tapir's serverSecurityLogic + serverLogic. Order of work for a request:
/// 1. head of security and regular inputs (no body read)
/// 2. a security failure answers now (401/400), body never read
/// 3. the body, buffered, only if the security input takes `raw_body`
/// 4. `authenticate`; a declared error answers now
/// 5. a regular-input head failure answers now (400/415)
/// 6. the body (bounded or streamed), then `handle`
/// Handlers raise anything: declared errors become their variants, the rest
/// a 500 whose details go to `on_unhandled` only.
pub fn[S, I, E, O, P] Endpoint::serve(
  self : Endpoint[S, I, E, O],
  authenticate : async (S) -> P,
  handle : async (P, I) -> O,
) -> ServerEndpoint {
  let doc = self.doc()
  let secondary = self.security.atoms.iter().any(a => a.location is Body(..))
  let streamed = self.input.atoms.iter().any(a => a.location is Body(streamed=true, ..))
  let has_body = self.input.atoms.iter().any(a => a.location is Body(..))
  let run = async fn(
    req : @model.Request,
    captures : Map[String, String],
    options : ServerOptions,
  ) -> @model.Response {
    let head = { request: req, captures }
    let sec_failures = []
    let sec = Some(self.security.decode_head(head)) catch {
      InputErrors(fs) => {
        sec_failures.append(fs)
        None
      }
    }
    let in_failures = []
    let inp = Some(self.input.decode_head(head)) catch {
      InputErrors(fs) => {
        in_failures.append(fs)
        None
      }
    }
    guard sec is Some(sec) else {
      discard(req.body)
      return (options.decode_failure)({ doc, failures: sec_failures, security: true })
    }
    let mut body_value = NoBody
    if secondary {
      body_value = read_body(req.body, self.max_body) catch {
        f =>
          return (options.decode_failure)({
            doc,
            failures: [{ atom: self.security.atoms[0], failure: f }],
            security: false,
          })
      }
    }
    let s = sec.finish(body_value) catch {
      InputErrors(fs) =>
        return (options.decode_failure)({ doc, failures: fs, security: true })
    }
    let principal = authenticate(s) catch {
      e => {
        discard(req.body)
        return error_response(self.errors, doc, e, options)
      }
    }
    guard inp is Some(inp) else {
      discard(req.body)
      return (options.decode_failure)({ doc, failures: in_failures, security: false })
    }
    if !secondary {
      body_value = if streamed {
        match req.body {
          Stream(s, ..) => Streamed(s)
          Bytes(b) => Buffered(b)
          Empty => Buffered(b"")
        }
      } else if has_body {
        read_body(req.body, self.max_body) catch {
          f => {
            let atom = self.input.atoms.filter(a => a.location is Body(..))[0]
            return (options.decode_failure)({
              doc,
              failures: [{ atom, failure: f }],
              security: false,
            })
          }
        }
      } else {
        discard(req.body)
        NoBody
      }
    }
    let i = inp.finish(body_value) catch {
      InputErrors(fs) =>
        return (options.decode_failure)({ doc, failures: fs, security: false })
    }
    let o = handle(principal, i) catch {
      e => return error_response(self.errors, doc, e, options)
    }
    match self.output.encode(o) {
      Some(r) => r
      None => problem(500, "no output variant matched")
    }
  }
  { doc, run: async fn(r, c, o) { Respond(run(r, c, o)) } }
}

///|
pub fn[I, E, O] Endpoint::serve_public(
  self : Endpoint[Unit, I, E, O],
  handle : async (I) -> O,
) -> ServerEndpoint {
  self.serve(async fn(_) { () }, async fn(_, i) { handle(i) })
}

///|
pub(all) suberror RouteError {
  Invalid(String, Array[String])
  Duplicate(String, String)
} derive(Debug)

///|
/// Sans-IO server: a request in, a response out. Adapters own sockets,
/// header limits, timeouts and draining.
pub struct Server {
  priv endpoints : Array[ServerEndpoint]
  priv options : ServerOptions
}

///|
fn shape(segments : Array[Seg]) -> String {
  segments.map(s => match s {
    Lit(l) => l
    Cap(_) => "{}"
  }).join("/")
}

///|
pub fn Server::new(
  endpoints : Array[ServerEndpoint],
  options? : ServerOptions = default_options,
) -> Server raise RouteError {
  let seen : Map[String, String] = {}
  for e in endpoints {
    let problems = e.doc.problems()
    if !problems.is_empty() {
      raise Invalid(e.doc.template, problems)
    }
    let key = "\{e.doc.meth.as_str()} \{shape(e.doc.segments)}"
    if seen.get(key) is Some(other) {
      raise Duplicate(other, e.doc.template)
    }
    seen[key] = e.doc.template
  }
  { endpoints, options }
}

///|
pub fn Server::docs(self : Server) -> Array[EndpointDoc] {
  self.endpoints.map(e => e.doc)
}

///|
/// Literal segments outrank captures, position by position.
fn match_path(segments : Array[Seg], path : Array[String]) -> (Int, Map[String, String])? {
  if segments.length() != path.length() {
    return None
  }
  let captures = {}
  let mut score = 0
  for i, s in segments {
    match s {
      Lit(l) => if l != path[i] { return None } else { score = score * 2 + 1 }
      Cap(n) => {
        captures[n] = path[i]
        score = score * 2
      }
    }
  }
  Some((score, captures))
}

///|
/// 404 when no template matches, 405 with Allow when the method does not,
/// HEAD served by GET, OPTIONS answered with Allow.
pub async fn Server::handle(
  self : Server,
  req : @model.Request,
) -> @model.Response noraise {
  match self.dispatch(req) {
    Respond(r) => r
    Upgrade(_, _) => problem(426, "upgrade required")
  }
}

///|
/// For adapters that can upgrade connections to WebSockets.
pub async fn Server::dispatch(
  self : Server,
  req : @model.Request,
) -> Outcome noraise {
  let mut best_score = -1
  let candidates : Array[(ServerEndpoint, Map[String, String])] = []
  for e in self.endpoints {
    if match_path(e.doc.segments, req.uri.segments) is Some((score, caps)) {
      if score > best_score {
        best_score = score
        candidates.clear()
      }
      if score == best_score {
        candidates.push((e, caps))
      }
    }
  }
  if candidates.is_empty() {
    discard(req.body)
    return Respond(problem(404, "not found"))
  }
  let wanted = if req.meth is Head { @model.Get } else { req.meth }
  for c in candidates {
    if c.0.doc.meth == wanted {
      let outcome = (c.0.run)(req, c.1, self.options) catch {
        e => {
          (self.options.on_unhandled)(c.0.doc, e)
          Respond(problem(500, "internal server error"))
        }
      }
      if req.meth is Head && outcome is Respond(resp) {
        discard(resp.body)
        return Respond({ ..resp, body: Empty })
      }
      return outcome
    }
  }
  discard(req.body)
  let allow = candidates.map(c => c.0.doc.meth.as_str()).join(", ")
  let status = if req.meth is Options { 204 } else { 405 }
  let r : @model.Response = if status == 204 {
    { status: @model.Status(204), headers: @model.Headers::new(), body: Empty }
  } else {
    problem(405, "method not allowed")
  }
  Respond({ ..r, headers: r.headers.add("allow", allow) })
}

///|
/// tapir's stub interpreter: the server as an in-process client backend.
pub impl @client.Backend for Server with send(self, req) {
  self.handle(req)
}
