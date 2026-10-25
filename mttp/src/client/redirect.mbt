///|
priv suberror RedirectError {
  TooManyRedirects(max~ : Int32, location~ : String)
  Downgrade(location~ : String)
  BadLocation(location~ : String, reason~ : String)
  UnreplayableBody(location~ : String)
} derive(Debug)

///|
fn redirect_failure(error : RedirectError) -> @model.TransportError {
  match error {
    TooManyRedirects(max~, location~) =>
      @model.TransportError(
        kind=TooManyRedirects(max~),
        phase=Head,
        detail="redirect limit exceeded: " + location,
      )
    Downgrade(location~) =>
      @model.TransportError(
        kind=RedirectRefused,
        phase=Head,
        detail="refused redirect to http: " + location,
      )
    BadLocation(location~, reason~) =>
      @model.TransportError(
        kind=RedirectRefused,
        phase=Head,
        detail="bad redirect Location " + location.escape() + ": " + reason,
      )
    UnreplayableBody(location~) =>
      @model.TransportError(
        kind=Unreplayable,
        phase=Head,
        detail="request body was already sent: " + location,
      )
  }
}

///|
/// A followed redirect's metadata, without retaining either request or
/// response bodies. Its response stream is closed before this is reported.
pub struct RedirectHop {
  request : @model.RequestHead
  head : @model.ResponseHead
  next : @model.RequestHead
} derive(Eq, Debug)

///|
/// Compares redirect metadata.
pub extend RedirectHop with Eq::{equal, not_equal}

///|
/// Formats redirect metadata.
pub extend RedirectHop with @debug.Debug::{to_repr}

///|
/// Final URL sent by FollowRedirects, including when no hop was followed.
pub let final_url : @model.AttributeKey[String] = @model.AttributeKey::new(
  "final_url",
)

///|
/// Followed hops, bounded by RequestOptions.max_redirects.
pub let redirect_history : @model.AttributeKey[Array[RedirectHop]] = @model.AttributeKey::new(
  "redirect_history",
)

///|
/// Follows 301/302/303/307/308 responses using the mature redirect policy.
/// Intermediate bodies close unread. Credentials are removed on origin
/// changes except same-host upgrades on default ports. HTTPS downgrades
/// require opt-in. Place Cookies inside this wrapper to process every hop.
/// Per-hop backend deadlines use the supplied options; a Client Timer can
/// enforce the attempt deadline across the whole redirect chain.
pub struct FollowRedirects {
  priv inner : &Backend
  priv allow_downgrade : Bool
  priv credential_headers : Array[String]
  priv on_redirect : ((RedirectHop) -> Unit)?
  priv mut closed : Bool
}

///|
/// Wraps a backend; redirect count and enablement come from request options.
pub fn FollowRedirects::new(
  inner : &Backend,
  allow_downgrade~ : Bool = false,
  credential_headers~ : Array[String] = [],
  on_redirect? : (RedirectHop) -> Unit,
) -> FollowRedirects {
  {
    inner,
    allow_downgrade,
    credential_headers: credential_headers.copy(),
    on_redirect,
    closed: false,
  }
}

///|
/// Follows redirects and records the final URL and followed head metadata.
pub async fn FollowRedirects::send(
  self : FollowRedirects,
  request : @model.Request,
  options : RequestOptions,
) -> @model.Response raise @model.TransportError {
  if self.closed {
    raise @model.TransportError(
      kind=Closed,
      phase=Pool,
      detail="redirect backend is closed",
    )
  }
  request.validate()
  let mut request = request
  let history = []
  for followed = 0; ; followed = followed + 1 {
    let response = self.inner.send(request, {
      ..options,
      follow_redirects: false,
    })
    errdefer response.close()
    let planned = if options.follow_redirects {
      plan_redirect(
        request,
        response.head(),
        followed~,
        max_redirects=options.max_redirects,
        allow_downgrade=self.allow_downgrade,
        credential_headers=self.credential_headers,
      ) catch {
        error => raise redirect_failure(error)
      }
    } else {
      None
    }
    guard planned is Some(next) else {
      return {
        ..response,
        attributes: response.attributes
        .put(final_url, request.url)
        .put(redirect_history, history),
      }
    }
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
/// Closes the wrapped backend at most once.
pub fn FollowRedirects::close(self : FollowRedirects) -> Unit {
  if !self.closed {
    self.closed = true
    self.inner.close()
  }
}

///|
/// Sends through the shared backend interface.
pub impl Backend for FollowRedirects with fn send(self, request, options) {
  self.send(request, options)
}

///|
/// Closes through the shared backend interface.
pub impl Backend for FollowRedirects with fn close(self) {
  self.close()
}
