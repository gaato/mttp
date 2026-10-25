///|
/// Adds this jar's Cookie header for the request URL, unless the caller
/// already supplied one. Returns a copy and leaves the original unchanged.
pub fn CookieJar::attach(
  self : CookieJar,
  request : @model.Request,
) -> @model.Request {
  if request.headers.contains("cookie") {
    return request
  }
  match self.header_for(request.url) {
    Some(value) => request.header("Cookie", value)
    None => request
  }
}
