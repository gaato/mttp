///|
/// An ordered handler wrapper. Calling next transfers the request body to it;
/// returning without calling next leaves cleanup to the router.
pub type Middleware = async (@http.Request, @http.Handler) -> @http.Response noraise

///|
/// The shared endpoint rejection context used by router policies.
pub using @endpoint {type FailureContext}

///|
/// Server limits, rejection policy and ordered middleware.
pub(all) struct ServerOptions {
  max_body_bytes : Int32
  max_issues : Int32
  decode_failure : (@endpoint.FailureContext) -> @http.Response?
  reject : (@http.Request, Array[@http.Method]) -> @http.Response
  on_unhandled : (@http.Request, Error) -> @http.Response?
  middleware : Array[Middleware]
}

///|
/// Creates an RFC 9457 problem document without exception details.
pub fn problem(
  status : Int32,
  title : String,
  errors~ : Json = [],
) -> @http.Response {
  let body : Json = {
    "type": "about:blank",
    "title": Json(title),
    "status": Json(status),
    "errors": errors,
  }
  @http.Response::new(
    status,
    headers=@http.Headers::of([("content-type", "application/problem+json")]),
    body=Bytes(@http.encode_utf8(body.stringify())),
  )
}

///|
fn location_name(location : @endpoint.Location) -> String {
  match location {
    Path => "path"
    Query => "query"
    Header => "header"
    Cookie => "cookie"
    Auth(..) => "auth"
    Body(..) | RawBody => "body"
    _ => "derived"
  }
}

///|
/// Maps bounded input issues to 400, authentication to 401, size to 413,
/// and unsupported representations to 415. Credentials are never echoed.
pub fn default_decode_failure(
  context : @endpoint.FailureContext,
) -> @http.Response {
  let items : Array[Json] = []
  for f in context.failures {
    let location = location_name(f.atom.location)
    if f.failure is @schema.DecodeFailure(kind=Invalid(issues), ..) {
      for issue in issues {
        items.push({
          "in": Json(location),
          "name": Json(f.atom.name),
          "path": Json(issue.path),
          "code": Json(issue.code),
          "message": Json(issue.message),
        })
      }
    } else {
      items.push({
        "in": Json(location),
        "name": Json(f.atom.name),
        "message": Json(f.failure.message()),
      })
    }
  }
  let errors = Json::array(items)
  if context.failures
    .iter()
    .any(f => f.failure is @schema.DecodeFailure(kind=TooLarge(..), ..)) {
    let response = problem(413, "Content Too Large", errors~)
    return { ..response, headers: response.headers.set("connection", "close"), }
  }
  if context.stage is Security {
    for f in context.failures {
      if f.atom.location is Auth(scheme~, ..) {
        let challenge = match scheme {
          Bearer(..) => "Bearer"
          Basic => "Basic charset=\"UTF-8\""
          _ => "ApiKey"
        }
        let response = problem(401, "Unauthorized")
        return {
          ..response,
          headers: response.headers.set("www-authenticate", challenge),
        }
      }
    }
  }
  if context.failures
    .iter()
    .any(f => {
      f.failure is @schema.DecodeFailure(kind=UnsupportedMediaType(_), ..)
    }) {
    return problem(415, "Unsupported Media Type", errors~)
  }
  problem(400, "Bad Request", errors~)
}

///|
/// Hides routes with failed authentication inputs behind a 404. Other input
/// failures use the default policy when this is installed as decode_failure.
pub fn hide_endpoints_with_auth(context : FailureContext) -> @http.Response? {
  if context.stage is Security &&
    context.failures.iter().any(f => f.atom.location is Auth(..)) {
    Some(problem(404, "Not Found"))
  } else {
    None
  }
}

///|
/// Uses a 1 MiB request limit, 100 reported issues and opaque 500 responses.
pub fn ServerOptions::default() -> ServerOptions {
  {
    max_body_bytes: 1048576,
    max_issues: 100,
    decode_failure: _ => None,
    reject: (_, allowed) => {
      if allowed.is_empty() {
        return problem(404, "Not Found")
      }
      let response = problem(405, "Method Not Allowed")
      {
        ..response,
        headers: response.headers.set(
          "allow",
          allowed.map(m => m.to_string()).join(", "),
        ),
      }
    },
    on_unhandled: (_, _) => None,
    middleware: [],
  }
}
