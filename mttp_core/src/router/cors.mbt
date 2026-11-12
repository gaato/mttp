///|
/// Adds CORS response headers for an explicit origin allowlist. Wildcard
/// origins use `*` unless credentials are enabled, in which case the origin is
/// reflected with Vary. Preflight methods come from the matched route's Allow.
///
/// A response to an allowed origin exposes `expose_headers` and the headers
/// the endpoint that answered declares (`@endpoint.declared_headers`), so a
/// browser lets the other origin read them and a typed client there decodes
/// its declared headers. CORS-safelisted response headers are readable
/// anyway and are left out. A preflight response exposes nothing: browsers
/// read `Access-Control-Expose-Headers` only from the actual response.
pub fn cors(
  allow_origins : Array[String],
  allow_credentials~ : Bool = false,
  expose_headers~ : Array[String] = [],
) -> Middleware {
  let origins = allow_origins.copy()
  let expose_headers = expose_headers.copy()
  (request, next) => {
    let response = next(request)
    let wildcard = origins.contains("*") && !allow_credentials
    // Cache variation applies to missing and denied origins too: either can
    // otherwise prime a shared cache with a response lacking CORS headers.
    let response = if !wildcard {
      { ..response, headers: response.headers.add("vary", "Origin"), }
    } else {
      {
        ..response,
        headers: response.headers.set("access-control-allow-origin", "*"),
      }
    }
    let response = if request.meth is Options {
      {
        ..response,
        headers: response.headers.add(
          "vary", "Access-Control-Request-Method, Access-Control-Request-Headers",
        ),
      }
    } else {
      response
    }
    guard request.headers.get_all("origin") is [origin] else { return response }
    if !origins.contains(origin) && !origins.contains("*") {
      return response
    }
    let mut headers = response.headers.set(
      "access-control-allow-origin",
      if wildcard {
        "*"
      } else {
        origin
      },
    )
    if allow_credentials {
      headers = headers.set("access-control-allow-credentials", "true")
    }
    if request.meth is Options &&
      request.headers.get("access-control-request-method") is Some(requested) {
      if response.headers.get("allow") is Some(allowed) &&
        allowed.split(",").any(m => m.trim() == requested) {
        headers = headers.set("access-control-allow-methods", allowed)
        if request.headers.get("access-control-request-headers") is Some(asked) {
          headers = headers.set("access-control-allow-headers", asked)
        }
      }
    } else {
      let declared = response.attributes
        .get(@endpoint.declared_headers)
        .unwrap_or([])
      let exposed = exposable([..expose_headers, ..declared])
      if !exposed.is_empty() {
        headers = headers.set(
          "access-control-expose-headers",
          exposed.join(", "),
        )
      }
    }
    { ..response, headers, }
  }
}

///|
/// Response headers a browser lets any origin read (Fetch's CORS-safelisted
/// response-header names), in lower case.
let safelisted_response_headers : Array[String] = [
  "cache-control", "content-language", "content-length", "content-type", "expires",
  "last-modified", "pragma",
]

///|
/// `names` without safelisted headers and without repeats (compared without
/// case), keeping the first spelling of each.
fn exposable(names : Array[String]) -> Array[String] {
  let seen : Set[String] = Set([])
  let out = []
  for name in names {
    let key = name.to_lower()
    if safelisted_response_headers.contains(key) || seen.contains(key) {
      continue
    }
    seen.add(key)
    out.push(name)
  }
  out
}
