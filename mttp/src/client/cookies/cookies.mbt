///|
/// A backend that attaches matching cookies and stores every response's
/// Set-Cookie fields before returning its head and caller-owned body.
/// Compose as FollowRedirects(Cookies(inner, jar)): each hop then uses its
/// own URL and stores cookies before the next hop. The jar does not enforce
/// browser SameSite policy. Explicit Cookie headers take precedence.
pub struct Cookies {
  priv inner : &@mttp.Backend
  priv jar : @cookie.CookieJar
  priv mut closed : Bool
}

///|
/// Wraps a backend with a caller-owned, clock-injected cookie jar.
pub fn Cookies::new(inner : &@mttp.Backend, jar : @cookie.CookieJar) -> Cookies {
  { inner, jar, closed: false, }
}

///|
/// Validates before I/O, passes SendOptions through unchanged, and stores
/// cookies from all statuses, including redirects and errors. A refusal
/// closes the request stream without reading it. Cancellation propagates
/// unchanged and closes the request body during unwind.
pub async fn Cookies::send(
  self : Cookies,
  request : @mttp.Request,
  options : @mttp.SendOptions,
) -> @mttp.Response raise @mttp.TransportError {
  defer (if request.body is Stream(stream) { stream.close() })
  if self.closed {
    raise @mttp.TransportError(
      kind=Closed,
      phase=Pool,
      detail="cookie backend is closed",
    )
  }
  request.validate()
  options.validate()
  let attached = self.jar.attach(request)
  attached.validate()
  let response = self.inner.send(attached, options)
  self.jar.store(response.headers, request.url)
  response
}

///|
/// Closes the wrapped backend once. The caller-owned jar remains available.
pub fn Cookies::close(self : Cookies) -> Unit {
  if !self.closed {
    self.closed = true
    self.inner.close()
  }
}

///|
/// Sends through the shared backend interface.
pub impl @mttp.Backend for Cookies with fn send(self, request, options) {
  self.send(request, options)
}

///|
/// Closes through the shared backend interface.
pub impl @mttp.Backend for Cookies with fn close(self) {
  self.close()
}
