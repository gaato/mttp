///|
/// A checked collection of endpoints, also usable as an in-process backend.
pub struct Router {
  priv endpoints : Array[@endpoint.ServerEndpoint]
  priv options : ServerOptions
  priv context : @endpoint.DispatchContext
  priv clock : &@rt.Clock?
  priv timer : &@rt.Timer?
  priv mut closed : Bool
}

///|
/// `Router::new` for definitions that are known to be right, such as a
/// top-level `let` in an application or a JavaScript entry, where an error
/// cannot be raised: a definition problem is a programming error, so this
/// aborts with the problems (as `DefinitionError` prints them) instead.
pub fn Router::must(
  endpoints : Array[@endpoint.ServerEndpoint],
  options~ : ServerOptions = ServerOptions::default(),
  adapter_max_body_bytes? : Int32,
  clock? : &@rt.Clock,
  timer? : &@rt.Timer,
) -> Router {
  Router::new(endpoints, options~, adapter_max_body_bytes?, clock?, timer?) catch {
    error => abort("\{error}")
  }
}

///|
/// Checks definitions before accepting traffic. Routes and middleware arrays
/// are copied so subsequent caller mutations cannot change dispatch.
pub fn Router::new(
  endpoints : Array[@endpoint.ServerEndpoint],
  options~ : ServerOptions = ServerOptions::default(),
  adapter_max_body_bytes? : Int32,
  clock? : &@rt.Clock,
  timer? : &@rt.Timer,
) -> Router raise @endpoint.DefinitionError {
  let problems = @endpoint.check_definitions(
    endpoints.map(e => e.doc()),
    adapter_max_body_bytes?,
  ).filter(p => p.fatal)
  if options.max_body_bytes < 0 || options.max_issues < 1 {
    problems.push(@endpoint.DefinitionProblem::new("", "invalid server limits"))
  }
  if !problems.is_empty() {
    raise @endpoint.DefinitionError(problems)
  }
  let options = { ..options, middleware: options.middleware.copy(), }
  let context = @endpoint.DispatchContext::new(
    max_body_bytes=options.max_body_bytes,
    max_issues=options.max_issues,
    decode_failure=f => {
      (options.decode_failure)(f).unwrap_or_else(() => default_decode_failure(f))
    },
    unhandled=(req, error) => {
      (options.on_unhandled)(req, error).unwrap_or_else(() => {
        problem(500, "Internal Server Error")
      })
    },
  )
  {
    endpoints: endpoints.copy(),
    options,
    context,
    clock,
    timer,
    closed: false,
  }
}

///|
fn captures(
  segments : Array[@endpoint.Seg],
  path : Array[String],
) -> Map[String, String]? {
  let rest = segments.last() is Some(Rest(_))
  if rest {
    if path.length() < segments.length() - 1 {
      return None
    }
  } else if segments.length() != path.length() {
    return None
  }
  let values : Map[String, String] = Map([])
  for i, segment in segments {
    match segment {
      Lit(text) => if text != path[i] { return None }
      Cap(name) => values[name] = path[i]
      Rest(name) => {
        let builder = StringBuilder()
        for part in path[i:] {
          builder.write_char('/')
          builder.write_string(@mttp_core.percent_encode(part))
        }
        values[name] = builder.to_string()
      }
      @endpoint.Seg::.. => return None
    }
  }
  Some(values)
}

///|
// Lexicographic specificity avoids integer-score overflow on deep paths.
fn more_specific(a : Array[@endpoint.Seg], b : Array[@endpoint.Seg]) -> Bool {
  for i, segment in a {
    if i >= b.length() {
      return false
    }
    let left = match segment {
      Lit(_) => 2
      Cap(_) => 1
      _ => 0
    }
    let right = match b[i] {
      Lit(_) => 2
      Cap(_) => 1
      _ => 0
    }
    if left != right {
      return left > right
    }
  }
  a.length() < b.length()
}

///|
fn discard(body : @mttp_core.Body) -> Unit {
  if body is Stream(stream) {
    stream.close()
  }
}

///|
async fn Router::route(
  self : Router,
  request : @mttp_core.Request,
) -> @mttp_core.Response noraise {
  let path = try {
    request.validate()
    let url = @mttp_core.Url::parse(request.url)
    if url.path != "" &&
      url.path != "/" &&
      url.path
      .clamped_view(start=if url.path.has_prefix("/") { 1 } else { 0 })
      .split("/")
      .take(65)
      .count() >
      64 {
      return (self.options.reject)(request, [])
    }
    url.path_segments()
  } catch {
    _ => return problem(400, "Bad Request")
  }
  let candidates : Array[(@endpoint.ServerEndpoint, Map[String, String])] = []
  let mut best : Array[@endpoint.Seg]? = None
  for endpoint in self.endpoints {
    let segments = endpoint.doc().segments
    if captures(segments, path) is Some(params) {
      match best {
        Some(previous) => {
          if more_specific(previous, segments) {
            continue
          }
          if more_specific(segments, previous) {
            candidates.clear()
            best = Some(segments)
          }
        }
        None => best = Some(segments)
      }
      candidates.push((endpoint, params))
    }
  }
  if candidates.is_empty() {
    return (self.options.reject)(request, [])
  }
  let wanted = if request.meth is Head &&
    !candidates.iter().any(c => c.0.doc().meth is Some(Head)) {
    @mttp_core.Get
  } else {
    request.meth
  }
  for (endpoint, params) in candidates {
    if endpoint.doc().meth == Some(wanted) {
      return endpoint.dispatch(request, params, self.context)
    }
  }
  let allowed : Array[@mttp_core.Method] = []
  for (endpoint, _) in candidates {
    if endpoint.doc().meth is Some(meth) {
      if !allowed.contains(meth) {
        allowed.push(meth)
      }
      if meth is Get && !allowed.contains(Head) {
        allowed.push(Head)
      }
    }
  }
  if !allowed.contains(Options) {
    allowed.push(Options)
  }
  if request.meth is Options {
    return @mttp_core.Response::new(
      204,
      headers=@mttp_core.Headers::of([
        ("allow", allowed.map(m => m.to_string()).join(", ")),
      ]),
    )
  }
  (self.options.reject)(request, allowed)
}

///|
/// Dispatches through middleware and the most specific path. HEAD strips and
/// closes any body, including bodies returned by rejection middleware.
pub async fn Router::dispatch(
  self : Router,
  request : @mttp_core.Request,
) -> @mttp_core.Response noraise {
  if self.closed {
    discard(request.body)
    return head_response(request, problem(503, "Service Unavailable"))
  }
  request.validate() catch {
    _ => {
      discard(request.body)
      return head_response(request, problem(400, "Bad Request"))
    }
  }
  let mut next : @mttp_core.Handler = req => {
    with_owned_request(req, req => self.route(req))
  }
  for i = self.options.middleware.length() - 1; i >= 0; i = i - 1 {
    let middleware = self.options.middleware[i]
    let inner = next
    next = req => {
      with_owned_request(req, req => {
        let produced : Ref[@mttp_core.Response?] = Ref(None)
        errdefer (if produced.val is Some(response) { response.close() })
        let response = middleware(req, forwarded => {
          // A taken stream belongs to the middleware's reader or lazy wrapper.
          // Only an unclaimed response can be discarded by the router here.
          if produced.val is Some(previous) {
            previous.close_if_unclaimed()
          }
          let response = inner(forwarded)
          produced.val = Some(response)
          response
        })
        if produced.val is Some(previous) && previous.body != response.body {
          previous.close_if_unclaimed()
        }
        response
      })
    }
  }
  let response = next(request)
  head_response(request, response)
}

///|
/// Creates a handler for transport adapters.
pub fn Router::handler(self : Router) -> @mttp_core.Handler {
  request => self.dispatch(request)
}

///|
/// Returns endpoint metadata for API descriptions and verification.
pub fn Router::docs(self : Router) -> Array[@endpoint.EndpointDoc] {
  self.endpoints.map(e => e.doc())
}

///|
/// Stops new dispatches; already returned response streams remain usable.
pub fn Router::close(self : Router) -> Unit {
  self.closed = true
}

///|
/// Closes the router through the Backend interface.
pub impl @mttp_core.Backend for Router with fn close(self) {
  self.close()
}

///|
/// Sends an in-process request with the Backend contract.
pub extend Router with @mttp_core.Backend::{send}

///|
fn head_response(
  request : @mttp_core.Request,
  response : @mttp_core.Response,
) -> @mttp_core.Response {
  if request.meth is Head {
    response.close()
    { ..response, body: Empty, }
  } else {
    response
  }
}
