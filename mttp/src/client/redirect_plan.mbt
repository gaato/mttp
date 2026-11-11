///|
/// A body-free plan, computed without acquiring or inspecting a live stream.
priv struct RedirectPlan {
  head : @mttp.RequestHead
  drop_body : Bool
}

///|
/// The request head to send after a response, or None when it is
/// not a redirect to follow.
fn plan_redirect(
  request : @mttp.RequestHead,
  response : @mttp.ResponseHead,
  replayable~ : Bool,
  followed~ : Int32,
  max_redirects~ : Int32,
  allow_downgrade~ : Bool,
  credential_headers~ : Array[String],
) -> RedirectPlan? raise RedirectError {
  guard redirect_status(response.status) &&
    response.headers.get("location") is Some(location) else {
    return None
  }
  let (from, to) = redirect_target(request.url, location)
  if from.scheme == Some("https") &&
    to.scheme == Some("http") &&
    !allow_downgrade {
    raise Downgrade(location=to.to_string())
  }
  if followed >= max_redirects {
    raise TooManyRedirects(max=max_redirects, location=to.to_string())
  }
  let http_method = redirect_method(response.status, request.meth.to_string())
  let drop_body = http_method != request.meth.to_string()
  if !drop_body && !replayable {
    raise UnreplayableBody(location=to.to_string())
  }
  let headers = redirect_headers(
    request.headers,
    from~,
    to~,
    drop_body~,
    credential_headers~,
  )
  Some({
    head: {
      meth: @mttp.Method::parse(http_method),
      url: to.without_fragment().to_string(),
      headers,
    },
    drop_body,
  })
}

///|
/// Whether `status` is a redirect this step follows. 300 leaves the choice to
/// the user, 304 is a cache answer and 305 and 306 are retired (RFC 9110
/// §15.4).
fn redirect_status(status : Int32) -> Bool {
  status is (301 | 302 | 303 | 307 | 308)
}

///|
/// The method of the redirected request: 303 makes everything but HEAD a
/// GET, 301 and 302 make POST a GET, the rest keep theirs (Fetch, httpx).
fn redirect_method(status : Int32, http_method : String) -> String {
  let upper = http_method.to_upper()
  match status {
    303 if upper != "GET" && upper != "HEAD" => "GET"
    301 | 302 if upper == "POST" => "GET"
    _ => http_method
  }
}

///|
/// The request URL and the `Location` resolved against it, refused unless the
/// result is an absolute `http` or `https` URL with a host.
fn redirect_target(
  request_url : String,
  location : String,
) -> (@mttp.Url, @mttp.Url) raise RedirectError {
  let from = @mttp.Url::parse(request_url) catch {
    @mttp.UrlError::Invalid(reason) =>
      raise BadLocation(location~, reason="request URL: " + reason)
  }
  guard from.scheme is Some("http" | "https") else {
    raise BadLocation(location~, reason="request URL is not absolute http(s)")
  }
  let to = from.resolve(
    @mttp.Url::parse(location) catch {
      @mttp.UrlError::Invalid(reason) => raise BadLocation(location~, reason~)
    },
  )
  guard to.scheme is Some("http" | "https") else {
    raise BadLocation(location~, reason="not an http or https URL")
  }
  guard to.host is Some(host) && host != "" else {
    raise BadLocation(location~, reason="no host")
  }
  (from, to)
}

///|
/// The headers of the redirected request: without the body's headers when
/// the body is dropped, and without `credential_headers` (lower-case) when the
/// origin changes, except on a same-host upgrade from `http` to `https` on
/// default ports.
fn redirect_headers(
  headers : @mttp.Headers,
  from~ : @mttp.Url,
  to~ : @mttp.Url,
  drop_body~ : Bool,
  credential_headers~ : Array[String],
) -> @mttp.Headers {
  let removed = []
  if drop_body {
    removed.push_iter(body_headers.iter())
  }
  if !from.same_origin(to) {
    removed.push("host")
    if !secure_upgrade(from, to) {
      removed.push_iter(credential_headers.iter())
    }
  }
  @mttp.Headers::of(
    headers.iter().filter(pair => !removed.contains(pair.0)).collect(),
  )
}

///|
let body_headers : Array[String] = [
  "content-length", "content-type", "transfer-encoding", "content-encoding", "content-language",
  "content-location",
]

///|
/// Whether `to` is `from` moved from `http` on port 80 to `https` on port 443
/// of the same host (httpx's `_is_https_redirect`).
fn secure_upgrade(from : @mttp.Url, to : @mttp.Url) -> Bool {
  from.host == to.host &&
  from.scheme == Some("http") &&
  from.port_or_default() == Some(80) &&
  to.scheme == Some("https") &&
  to.port_or_default() == Some(443)
}
