///|
#non_exhaustive
#derive(Eq, Debug)
pub(all) enum FrameOptions {
  Deny
  SameOrigin
}

///|
pub extend FrameOptions with Eq::{equal, not_equal}

///|
pub extend FrameOptions with Debug::{to_repr}

///|
/// Adds missing security headers. HSTS requires trusted connection metadata,
/// not the URL or a forwarded header. Existing handler fields always win.
pub fn secure_headers(
  hsts? : Int32,
  content_type_options~ : Bool = true,
  frame_options~ : FrameOptions = Deny,
  referrer_policy~ : String = "no-referrer",
  csp? : String,
) -> Middleware {
  (request, next) => {
    let response = next(request)
    let mut headers = response.headers
    let add = (name, value) => {
      if !headers.contains(name) {
        headers = headers.set(name, value)
      }
    }
    if hsts is Some(age) &&
      request.attributes.get(@mttp_core.connection_scheme) == Some("https") {
      add("strict-transport-security", "max-age=\{age.max(0)}")
    }
    if content_type_options {
      add("x-content-type-options", "nosniff")
    }
    add(
      "x-frame-options",
      match frame_options {
        Deny => "DENY"
        SameOrigin => "SAMEORIGIN"
      },
    )
    add("referrer-policy", referrer_policy)
    if csp is Some(value) {
      add("content-security-policy", value)
    }
    { ..response, headers, }
  }
}
