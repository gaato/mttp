///|
/// Refuses state-changing requests that a browser sends from another origin,
/// with Fetch Metadata and Origin verification (OWASP's CSRF guidance) and no
/// tokens or session state.
///
/// GET, HEAD, OPTIONS and TRACE pass untouched; keep them free of side
/// effects. Any other method is checked:
///
/// - With `Sec-Fetch-Site`, `same-origin` and `none` (typed in the address
///   bar, a bookmark) pass; any other value passes only when `Origin` is in
///   `allowed_origins`.
/// - Without it (older browsers, and plain-HTTP sites other than localhost,
///   where browsers do not send it), a missing `Origin` passes, because
///   non-browser clients send neither. An `Origin` passes when it equals the
///   request's own origin, the scheme, host and port of the absolute request
///   URL that the server engines build, or is in `allowed_origins`.
///
/// Where these rules consult a field, `Origin: null`, a repeated field and an
/// unknown `Sec-Fetch-Site` value count as cross-origin. A refusal is a 403
/// problem+json naming the field, and the handler does not run.
///
/// `allowed_origins` holds serialized origins as browsers send them
/// (`https://app.example`, with a port only when it is not the default) and
/// is compared exactly; `null` never matches. Behind a proxy that terminates
/// TLS the request URL says `http`, so list the public `https` origin too.
///
/// This stops cross-site browser requests that carry ambient credentials such
/// as cookies. It does not authenticate non-browser clients, which can send
/// any header, and it does not help against script injected into an allowed
/// origin (XSS). Use it with SameSite cookies.
pub fn same_origin(allowed_origins~ : Array[String] = []) -> Middleware {
  let allowed = allowed_origins.copy()
  (request, next) => {
    if request.meth is (Get | Head | Options | Trace) {
      return next(request)
    }
    match cross_origin_refusal(request, allowed) {
      None => next(request)
      Some(field) =>
        problem(403, "Forbidden", errors=[
          {
            "in": "header",
            "name": Json(field),
            "message": "cross-origin request refused",
          },
        ])
    }
  }
}

///|
/// The header field a cross-origin refusal rests on, or None to allow.
fn cross_origin_refusal(
  request : @mttp.Request,
  allowed : Array[String],
) -> String? {
  let origins = request.headers.get_all("origin")
  let listed = origins is [value] && value != "null" && allowed.contains(value)
  match request.headers.get_all("sec-fetch-site") {
    ["same-origin" | "none"] => None
    [] =>
      match origins {
        [] => None
        [value] if listed || own_origin(request.url, value) => None
        _ => Some("origin")
      }
    _ => if listed { None } else { Some("sec-fetch-site") }
  }
}

///|
/// Whether `origin` is a serialized origin equal to the absolute request
/// URL's scheme, host and port. A relative request URL has no origin.
fn own_origin(request_url : String, origin : String) -> Bool {
  let (own, other) = (@mttp.Url::parse(request_url), @mttp.Url::parse(origin)) catch {
    _ => return false
  }
  other.userinfo is None &&
  other.path == "" &&
  other.query is None &&
  other.fragment is None &&
  own.same_origin(other)
}
