///|
/// A backend that attaches cookies and stores response Set-Cookie fields.
/// Place inside the redirect wrapper so each hop uses its own URL and stores
/// its cookies before the next hop. The jar does not enforce browser SameSite.
pub struct Cookies {
  priv inner : &@client.Backend
  priv jar : @cookie.CookieJar
  priv mut closed : Bool
}

///|
/// Wraps a backend with the given clock-injected cookie jar.
pub fn Cookies::new(
  inner : &@client.Backend,
  jar : @cookie.CookieJar,
) -> Cookies {
  { inner, jar, closed: false, }
}

///|
/// Sends with matching cookies and stores response cookies before returning.
pub async fn Cookies::send(
  self : Cookies,
  request : @model.Request,
  options : @client.RequestOptions,
) -> @model.Response raise @model.TransportError {
  if self.closed {
    raise @model.TransportError(
      kind=Closed,
      phase=Pool,
      detail="cookie backend is closed",
    )
  }
  request.validate()
  let response = self.inner.send(self.jar.attach(request), options)
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
/// Sends through the cookie wrapper via the shared backend interface.
pub impl @client.Backend for Cookies with fn send(self, request, options) {
  self.send(request, options)
}

///|
/// Closes through the shared backend interface.
pub impl @client.Backend for Cookies with fn close(self) {
  self.close()
}
