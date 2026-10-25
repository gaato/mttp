///|
/// Adds CORS response headers for an explicit origin allowlist. Wildcard
/// origins use `*` unless credentials are enabled, in which case the origin is
/// reflected with Vary. Preflight methods come from the matched route's Allow.
pub fn cors(
  allow_origins : Array[String],
  allow_credentials~ : Bool = false,
) -> Middleware {
  let origins = allow_origins.copy()
  (request, next) => {
    let response = next(request)
    guard request.headers.get_all("origin") is [origin] else { return response }
    if !origins.contains(origin) && !origins.contains("*") {
      return response
    }
    let wildcard = origins.contains("*") && !allow_credentials
    let mut headers = response.headers.set(
      "access-control-allow-origin",
      if wildcard {
        "*"
      } else {
        origin
      },
    )
    if !wildcard {
      headers = headers.add("vary", "Origin")
    }
    if allow_credentials {
      headers = headers.set("access-control-allow-credentials", "true")
    }
    if request.meth is Options &&
      request.headers.get("access-control-request-method") is Some(requested) {
      headers = headers.add(
        "vary", "Access-Control-Request-Method, Access-Control-Request-Headers",
      )
      if response.headers.get("allow") is Some(allowed) &&
        allowed.split(",").any(m => m.trim() == requested) {
        headers = headers.set("access-control-allow-methods", allowed)
        if request.headers.get("access-control-request-headers") is Some(asked) {
          headers = headers.set("access-control-allow-headers", asked)
        }
      }
    }
    { ..response, headers, }
  }
}
