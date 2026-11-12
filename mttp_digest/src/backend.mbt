///|
/// Digest credentials scoped to one HTTP(S) origin, wrapping a Backend.
/// Build the `Client` over it: the Client follows redirects outside this
/// wrapper, so each hop is checked against the origin. In a stack built by
/// hand, keep it inside `FollowRedirects` for the same reason.
pub struct DigestScheme {
  priv inner : &@mttp_core.Backend
  priv origin : String
  priv username : String
  priv password : String
  priv random : () -> Double
  priv state : DigestState
  priv mut closed : Bool
}

///|
/// Creates an origin-scoped wrapper. The origin must be an absolute HTTP(S)
/// URL without userinfo. Paths are ignored. Supply an unpredictable random
/// source returning values in [0,1) for cnonces, such as one built on
/// `@env.rand` of `moonbitlang/core/env`; tests can inject fixed values.
/// No network I/O occurs here. Explicit request Authorization takes precedence.
pub fn DigestScheme::new(
  inner : &@mttp_core.Backend,
  username : String,
  password : String,
  origin~ : String,
  random~ : () -> Double,
) -> DigestScheme raise @mttp_core.TransportError {
  @mttp_core.Request::get(origin).validate()
  guard digest_target(origin) is Some((url, origin, _)) &&
    (url.scheme == Some("http") || url.scheme == Some("https")) &&
    url.userinfo is None else {
    raise @mttp_core.TransportError(
      kind=Invalid,
      phase=Pool,
      detail="Digest requires an HTTP(S) credential origin without userinfo",
    )
  }
  {
    inner,
    origin,
    username,
    password,
    random,
    state: DigestState::new(),
    closed: false,
  }
}

///|
/// Sends one exchange, answering at most one challenge and one stale nonce.
/// Intermediate response bodies close before resending. Stream bodies are
/// never replayed. Requests outside the configured origin pass through.
/// SendOptions pass through unchanged to every send. A Client with a Timer
/// can bound the whole challenge exchange. After a 401 was answered, a
/// transport failure has phase Unknown; Connect and Proxy become Network,
/// and the detail retains the original failure, so it cannot appear unsent.
pub async fn DigestScheme::send(
  self : DigestScheme,
  request : @mttp_core.Request,
  options : @mttp_core.SendOptions,
) -> @mttp_core.Response raise @mttp_core.TransportError {
  defer (if request.body is Stream(stream) { stream.close() })
  if self.closed {
    raise @mttp_core.TransportError(
      kind=Closed,
      phase=Pool,
      detail="Digest backend is closed",
    )
  }
  request.validate()
  options.validate()
  guard !request.headers.contains("authorization") &&
    digest_target(request.url) is Some((url, origin, uri)) &&
    origin == self.origin else {
    return self.inner.send(request, options)
  }
  let body = request.body.as_bytes()
  let uri = if request.meth == @mttp_core.Method::Connect {
    // H1 uses authority-form for CONNECT, including an explicit port.
    let authority = origin.split("://").last().unwrap().to_owned()
    authority
  } else {
    uri
  }
  let authorize = (challenge : DigestChallenge, count : Int64) => {
    let value = digest_authorization(
      challenge,
      self.username,
      self.password,
      request.meth.to_string(),
      uri,
      count,
      make_cnonce(self.random),
      body,
    )
    request.header("authorization", value)
  }
  let first = match self.state.next(origin, body is Some(_)) {
    Some((challenge, count)) => authorize(challenge, count)
    None => request
  }
  let mut response = self.inner.send(first, options)
  for answers = 0 {
    guard response.status == 401 &&
      body is Some(_) &&
      same_origin_as(
        url,
        response.attributes.get(@client.final_url).unwrap_or(request.url),
      ) &&
      find_digest_challenge(response.headers, body is Some(_))
      is Some(challenge) &&
      should_answer(answers, challenge.stale) else {
      return response
    }
    guard self.state.adopt(origin, challenge) is Some(count) else {
      return response
    }
    response.close()
    response = self.inner.send(authorize(challenge, count), options) catch {
      error => raise after_challenge(error)
    }
    continue answers + 1
  }
}

///|
// A 401 proves the original request reached the peer. A later dial failure
// cannot license an unsent-only retry of that original request.
fn after_challenge(
  error : @mttp_core.TransportError,
) -> @mttp_core.TransportError {
  let @mttp_core.TransportError(kind~, ..) = error
  let kind : @mttp_core.Kind = match kind {
    Connect | Proxy(_) => Network
    kind => kind
  }
  @mttp_core.TransportError(
    kind~,
    phase=Unknown,
    detail="Digest send failed after a challenge was answered: \{error.message()}",
  )
}

///|
/// Closes the inner backend once and forgets retained nonces.
pub fn DigestScheme::close(self : DigestScheme) -> Unit {
  if !self.closed {
    self.closed = true
    self.state.nonces.clear()
    self.inner.close()
  }
}

///|
/// Implements the standard single-exchange Backend interface.
pub impl @mttp_core.Backend for DigestScheme with fn send(
  self,
  request,
  options,
) {
  self.send(request, options)
}

///|
/// Closes this wrapper through Backend.
pub impl @mttp_core.Backend for DigestScheme with fn close(self) {
  self.close()
}
