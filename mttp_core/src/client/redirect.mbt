///|
#derive(Debug)
priv suberror RedirectError {
  TooManyRedirects(max~ : Int32, location~ : String)
  Downgrade(location~ : String)
  BadLocation(location~ : String, reason~ : String)
  UnreplayableBody(location~ : String)
}

///|
fn redirect_failure(error : RedirectError) -> @mttp_core.TransportError {
  match error {
    TooManyRedirects(max~, location~) =>
      @mttp_core.TransportError(
        kind=TooManyRedirects(max~),
        phase=Head,
        detail="redirect limit exceeded: " + location,
      )
    Downgrade(location~) =>
      @mttp_core.TransportError(
        kind=RedirectRefused,
        phase=Head,
        detail="refused redirect to http: " + location,
      )
    BadLocation(location~, reason~) =>
      @mttp_core.TransportError(
        kind=RedirectRefused,
        phase=Head,
        detail="bad redirect Location " + location.escape() + ": " + reason,
      )
    UnreplayableBody(location~) =>
      @mttp_core.TransportError(
        kind=Unreplayable,
        phase=Head,
        detail="request body was already sent: " + location,
      )
  }
}

///|
/// A followed redirect's metadata, without retaining either request or
/// response bodies. Its response stream is closed before this is reported.
#derive(Eq, Debug)
pub struct RedirectHop {
  request : @mttp_core.RequestHead
  head : @mttp_core.ResponseHead
  next : @mttp_core.RequestHead
}

///|
/// Compares redirect metadata.
pub extend RedirectHop with Eq::{equal, not_equal}

///|
/// Formats redirect metadata.
pub extend RedirectHop with @debug.Debug::{to_repr}

///|
/// Final URL sent by FollowRedirects, including when no hop was followed.
pub let final_url : @mttp_core.AttributeKey[String] = @mttp_core.AttributeKey::new(
  "final_url",
)

///|
/// Followed hops, at most the effective redirect limit.
pub let redirect_history : @mttp_core.AttributeKey[Array[RedirectHop]] = @mttp_core.AttributeKey::new(
  "redirect_history",
)

///|
/// How a `Client` (its `redirect` argument) or a `FollowRedirects` wrapper
/// follows redirects. Build it from `RedirectConfig::default()` with a record
/// update, or take `RedirectConfig::none()`; the field set is frozen.
#derive(Eq, Debug)
pub(all) struct RedirectConfig {
  /// Hops followed before `TooManyRedirects(max)`; 0 or less follows none.
  /// The `redirect_limit` attribute overrides it per request, except on a
  /// `Client`, where 0 or less means the Client has no redirect layer at all.
  max_redirects : Int32
  /// Whether an `https` request may be redirected to `http`.
  allow_downgrade : Bool
  /// Headers removed, ignoring ASCII case, when a redirect changes the
  /// origin (except a same-host upgrade from `http` on port 80 to `https`
  /// on port 443). The list is the whole set: replacing it with one that
  /// omits a name forwards that header across origins.
  credential_headers : Array[String]
}

///|
/// Compares redirect configurations.
pub extend RedirectConfig with Eq::{equal, not_equal}

///|
/// Formats a redirect configuration for diagnostics.
pub extend RedirectConfig with @debug.Debug::{to_repr}

///|
/// Ten hops, no downgrade, and `authorization`, `proxy-authorization` and
/// `cookie` as the credentials removed on an origin change.
///
/// ```mbt check
/// test {
///   let config = {
///     ..@client.RedirectConfig::default(),
///     credential_headers: [
///       "authorization", "proxy-authorization", "cookie", "x-api-key",
///     ],
///   }
///   assert_eq(config.max_redirects, 10)
///   assert_false(config.allow_downgrade)
/// }
/// ```
pub fn RedirectConfig::default() -> RedirectConfig {
  {
    max_redirects: 10,
    allow_downgrade: false,
    credential_headers: ["authorization", "proxy-authorization", "cookie"],
  }
}

///|
/// No redirects: the default configuration with `max_redirects` 0. Given to
/// `Client::new`, the Client follows no redirect and returns each 3xx as the
/// backend gave it; pass it when the backend already follows redirects.
///
/// ```mbt check
/// test {
///   assert_eq(@client.RedirectConfig::none().max_redirects, 0)
/// }
/// ```
pub fn RedirectConfig::none() -> RedirectConfig {
  { ..RedirectConfig::default(), max_redirects: 0, }
}

///|
/// Follows 301, 302, 303, 307 and 308 responses. Intermediate bodies close
/// unread; credentials are removed when the origin changes; an HTTPS
/// downgrade is refused unless configured. A 303, or a 301 or 302 to a POST,
/// becomes a GET without the body; any other hop resends the body, so a body
/// that cannot be sent again is refused (`Unreplayable`).
///
/// `Client::new` already wraps its backend in this, following its `redirect`
/// argument; use the wrapper directly for a custom stack, and give that
/// stack's Client `RedirectConfig::none()` so redirects are not followed
/// twice.
///
/// The wrapper passes `SendOptions` to every hop unchanged, so each hop gets
/// the attempt deadline; a `Client` with a Timer bounds the whole chain.
/// Place `Cookies` inside this wrapper so every hop is processed, and keep
/// retries above it: a 503 on the second hop re-sends the first.
///
/// A transport failure on a later hop is never reported as unsent: the first
/// request got an answer, so it reached the server. Such a failure has phase
/// `Unknown`, and a `Connect` or `Proxy` kind becomes `Network`; the detail
/// keeps the original.
pub struct FollowRedirects {
  priv inner : &@mttp_core.Backend
  priv config : RedirectConfig
  priv credentials : Array[String]
  priv on_redirect : ((RedirectHop) -> Unit)?
  priv mut closed : Bool
}

///|
/// Wraps a backend. `on_redirect` sees each followed hop after its response
/// was closed.
pub fn FollowRedirects::new(
  inner : &@mttp_core.Backend,
  config~ : RedirectConfig = RedirectConfig::default(),
  on_redirect? : (RedirectHop) -> Unit,
) -> FollowRedirects {
  {
    inner,
    config: { ..config, credential_headers: config.credential_headers.copy(), },
    credentials: config.credential_headers.map(String::to_lower),
    on_redirect,
    closed: false,
  }
}

///|
/// Follows redirects and records the final URL (`final_url`) and the
/// followed hops (`redirect_history`) on the returned response.
pub async fn FollowRedirects::send(
  self : FollowRedirects,
  request : @mttp_core.Request,
  options : @mttp_core.SendOptions,
) -> @mttp_core.Response raise @mttp_core.TransportError {
  if self.closed {
    raise @mttp_core.TransportError(
      kind=Closed,
      phase=Pool,
      detail="redirect backend is closed",
    )
  }
  request.validate()
  options.validate()
  let max = request.attributes
    .get(redirect_limit)
    .unwrap_or(self.config.max_redirects)
  let mut request = request
  let history = []
  for followed = 0; ; followed = followed + 1 {
    let response = if followed == 0 {
      self.inner.send(request, options)
    } else {
      self.inner.send(request, options) catch {
        error => raise after_redirect(error, followed)
      }
    }
    errdefer response.close()
    let planned = if max > 0 {
      plan_redirect(
        request.head(),
        response.head(),
        replayable=request.body.is_replayable(),
        followed~,
        max_redirects=max,
        allow_downgrade=self.config.allow_downgrade,
        credential_headers=self.credentials,
      ) catch {
        error => raise redirect_failure(error)
      }
    } else {
      None
    }
    guard planned is Some(plan) else {
      return {
        ..response,
        attributes: response.attributes
        .put(final_url, request.url)
        .put(redirect_history, history),
      }
    }
    let next = apply_redirect(request, plan)
    response.close()
    let hop = RedirectHop::{
      request: request.head(),
      head: response.head(),
      next: next.head(),
    }
    history.push(hop)
    if self.on_redirect is Some(callback) {
      callback(hop)
    }
    request = next
  }
}

///|
fn apply_redirect(
  request : @mttp_core.Request,
  plan : RedirectPlan,
) -> @mttp_core.Request {
  {
    ..request,
    meth: plan.head.meth,
    url: plan.head.url,
    headers: plan.head.headers,
    body: if plan.drop_body {
      Empty
    } else {
      request.body
    },
  }
}

///|
/// Closes the wrapped backend at most once.
pub fn FollowRedirects::close(self : FollowRedirects) -> Unit {
  if !self.closed {
    self.closed = true
    self.inner.close()
  }
}

///|
/// Sends through the shared backend interface.
pub impl @mttp_core.Backend for FollowRedirects with fn send(
  self,
  request,
  options,
) {
  self.send(request, options)
}

///|
/// Closes through the shared backend interface.
pub impl @mttp_core.Backend for FollowRedirects with fn close(self) {
  self.close()
}

///|
/// A failure of a hop after the first, which must not read as unsent: an
/// earlier hop got a response, so the original request reached the server
/// and may have been processed, whatever this hop's phase says. The phase
/// becomes `Unknown`, a `Connect` or `Proxy` kind (which imply that nothing
/// was sent) becomes `Network`, and the detail keeps the original kind,
/// phase and detail.
fn after_redirect(
  error : @mttp_core.TransportError,
  followed : Int32,
) -> @mttp_core.TransportError {
  let @mttp_core.TransportError(kind~, ..) = error
  let kind : @mttp_core.Kind = match kind {
    Connect | Proxy(_) => Network
    kind => kind
  }
  @mttp_core.TransportError(
    kind~,
    phase=Unknown,
    detail="redirect hop \{followed} failed after an earlier hop was answered: \{error.message()}",
  )
}
