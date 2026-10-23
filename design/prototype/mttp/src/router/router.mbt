///|
/// Re-exported for convenience; defined in endpoint (I-01).
pub using @endpoint {type FailureContext}

///|
pub type Middleware = async (@model.Request, async (@model.Request) -> @model.Response noraise) -> @model.Response noraise

///|
pub(all) struct ServerOptions {
  max_body_bytes : Int
  max_issues : Int
  decode_failure : (@endpoint.FailureContext) -> @model.Response?
  reject : (@model.Request, Array[@model.Method]) -> @model.Response
  on_unhandled : (@model.Request, Error) -> @model.Response?   // None = plain 500 problem; never shows details by default
  middleware : Array[Middleware]
}

///|
pub fn problem(status : Int, title : String, errors? : Json = []) -> @model.Response {
  let body : Json = {
    "type": "about:blank",
    "title": title.to_json(),
    "status": status.to_json(),
    "errors": errors,
  }
  @model.Response::new(
    status,
    headers=@model.Headers::of([("content-type", "application/problem+json")]),
    body=Bytes(@utf8.encode(body.stringify())),
  )
}

///|
fn location_name(l : @endpoint.Location) -> String {
  match l {
    Path => "path"
    Query => "query"
    Header => "header"
    Cookie => "cookie"
    Auth(..) => "auth"
    Body(..) | RawBody => "body"
    Derived => "derived"
  }
}

///|
pub fn default_decode_failure(ctx : @endpoint.FailureContext) -> @model.Response {
  let errors : Json = Json::array(
    ctx.failures.map(f => {
      "in": location_name(f.atom.location).to_json(),
      "name": f.atom.name.to_json(),
      "message": f.failure.message().to_json(),
    }),
  )
  for f in ctx.failures {
    if f.failure is TooLarge(..) {
      let r = problem(413, "content too large", errors~)
      return { ..r, headers: r.headers.add("connection", "close") }
    }
  }
  if ctx.stage is Security {
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
  }
  for f in ctx.failures {
    if f.failure is UnsupportedMediaType(_) {
      return problem(415, "unsupported media type", errors~)
    }
  }
  problem(400, "bad request", errors~)
}

///|
pub fn ServerOptions::default() -> ServerOptions {
  {
    max_body_bytes: 1024 * 1024,
    max_issues: 100,
    decode_failure: _ => None,
    reject: (_req, allowed) => if allowed.is_empty() {
      problem(404, "not found")
    } else {
      let r = problem(405, "method not allowed")
      { ..r, headers: r.headers.add("allow", allowed.map(m => m.to_string()).join(", ")) }
    },
    on_unhandled: (_, _) => None,
    middleware: [],
  }
}

///|
///|
pub struct Router {
  priv endpoints : Array[@endpoint.ServerEndpoint]
  priv options : ServerOptions
  priv ctx : @endpoint.DispatchContext
}

///|
///|
pub fn Router::new(
  endpoints : Array[@endpoint.ServerEndpoint],
  options? : ServerOptions = ServerOptions::default(),
) -> Router raise @endpoint.DefinitionError {
  let problems = @endpoint.check_definitions(endpoints.map(e => e.doc())).filter(p => p.fatal)
  if !problems.is_empty() {
    raise DefinitionError(problems)
  }
  let ctx : @endpoint.DispatchContext = {
    max_body_bytes: options.max_body_bytes,
    max_issues: options.max_issues,
    decode_failure: fc => match (options.decode_failure)(fc) {
      Some(r) => r
      None => default_decode_failure(fc)
    },
    unhandled: (req, e) => match (options.on_unhandled)(req, e) {
      Some(r) => r
      None => problem(500, "internal server error")
    },
  }
  { endpoints, options, ctx }
}

///|
fn match_path(segments : Array[@endpoint.Seg], path : Array[String]) -> (Int, Map[String, String])? {
  if segments.length() != path.length() {
    return None
  }
  let captures = Map::new()
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
fn discard(body : @model.Body) -> Unit {
  if body is Stream(s, ..) {
    s.close()
  }
}

///|
async fn Router::route(self : Router, req : @model.Request) -> @model.Response noraise {
  let path = @model.Url::parse(req.url).path_segments() catch {
    _ => {
      discard(req.body)
      return problem(400, "bad path")
    }
  }
  let mut best = -1
  let candidates : Array[(@endpoint.ServerEndpoint, Map[String, String])] = []
  for e in self.endpoints {
    if match_path(e.doc().segments, path) is Some((score, caps)) {
      if score > best {
        best = score
        candidates.clear()
      }
      if score == best {
        candidates.push((e, caps))
      }
    }
  }
  if candidates.is_empty() {
    discard(req.body)
    return (self.options.reject)(req, [])
  }
  // An explicit HEAD endpoint wins; otherwise HEAD is served by GET.
  let wanted : @model.Method = if req.meth is Head &&
    !candidates.iter().any(c => c.0.doc().meth is Some(Head)) {
    Get
  } else {
    req.meth
  }
  for c in candidates {
    if c.0.doc().meth == Some(wanted) {
      return c.0.dispatch(req, c.1, self.ctx)
    }
  }
  discard(req.body)
  let allowed : Array[@model.Method] = []
  for c in candidates {
    if c.0.doc().meth is Some(m) {
      if !allowed.contains(m) {
        allowed.push(m)
      }
      if m is Get && !allowed.contains(Head) {
        allowed.push(Head)
      }
    }
  }
  allowed.push(Options)
  if req.meth is Options {
    let allow = allowed.map(m => m.to_string()).join(", ")
    return @model.Response::new(204, headers=@model.Headers::of([("allow", allow)]))
  }
  (self.options.reject)(req, allowed)
}

///|
pub async fn Router::dispatch(self : Router, req : @model.Request) -> @model.Response noraise {
  let mut next : async (@model.Request) -> @model.Response noraise = r => self.route(r)
  for i = self.options.middleware.length() - 1; i >= 0; i = i - 1 {
    let mw = self.options.middleware[i]
    let inner = next
    next = r => mw(r, inner)
  }
  let resp = next(req)
  // HEAD responses are bodyless, whatever produced them: an endpoint, a
  // rejection, or middleware.
  if req.meth is Head {
    resp.close()
    return { ..resp, body: Empty }
  }
  resp
}

///|
pub fn Router::handler(self : Router) -> @model.Handler {
  req => self.dispatch(req)
}

///|
pub fn Router::docs(self : Router) -> Array[@endpoint.EndpointDoc] {
  self.endpoints.map(e => e.doc())
}

///|
/// Stub interpreter: in-process round trips on every target. The server
/// never sees client attributes (only remote_addr = "in-process"), and the
/// client never sees server-side response attributes, as over a socket.
/// Bodies pass through unbuffered (pull only), so SSE streams work.
pub impl @client.Backend for Router with send(self, req, _opts) {
  let server_req = {
    ..req,
    attributes: @model.Attributes::empty().put(@model.remote_addr, "in-process"),
  }
  let resp = self.dispatch(server_req)
  { ..resp, attributes: @model.Attributes::empty() }
}

///|
pub fn cors(allow_origins : Array[String]) -> Middleware {
  async fn(req, next) noraise {
    let origin = req.headers.get("origin")
    let r = next(req)
    match origin {
      Some(o) if allow_origins.contains(o) || allow_origins.contains("*") =>
        { ..r, headers: r.headers.add("access-control-allow-origin", o) }
      _ => r
    }
  }
}
