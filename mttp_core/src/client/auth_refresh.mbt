///|
/// Marks a request `AuthRefresh` already resent after refreshing its
/// credentials. A request carrying it (`true`) is never refreshed again, so
/// stacked wrappers or a caller resending it cannot loop on a 401.
pub let auth_refreshed : @mttp_core.AttributeKey[Bool] = @mttp_core.AttributeKey::new(
  "auth_refreshed",
)

///|
priv enum FlightResult {
  Pending
  Refreshed
  Failed
  Abandoned
}

///|
/// One call of the caller's refresh, which every concurrent 401 shares.
priv struct Flight {
  signal : &@rt.Signal
  mut result : FlightResult
}

///|
/// A backend that refreshes expired credentials once when a request gets
/// 401 Unauthorized, and sends that request once more with the new ones.
///
/// `apply` sets the current credentials only on requests to `origin` (scheme,
/// host and effective port), so requests after a refresh carry the new ones
/// from the start. Requests to other origins pass through untouched, without
/// applying credentials or refreshing a 401; this also covers redirect hops.
/// `refresh` obtains new credentials (and stores them where `apply` reads
/// them). On a 401:
///
/// - a request whose body cannot be sent again (a stream the backend took)
///   gets the 401;
/// - a request marked with `auth_refreshed` gets the 401;
/// - otherwise, if credentials were refreshed since the request was sent,
///   it is resent at once; if a refresh is running, it waits for that one;
///   if none is, it calls `refresh` itself. Concurrent 401s therefore share
///   one refresh, waiting through the coordination's `Signal`.
/// - Before starting or joining a refresh, the 401's transport is closed,
///   so refresh may use the same connection pool even with only one slot.
///   After a successful refresh, the request is sent
///   once more, marked with `auth_refreshed`, and that response is returned
///   whatever its status. A refresh that raises returns the original 401's
///   status, headers and attributes with an empty body; the next
///   401 tries again. A refresh cancelled with its caller hands the work to
///   the next waiter, which starts a refresh of its own.
///
/// Cancellation propagates unchanged; no 401 transport is held while waiting.
/// `SendOptions` pass through unchanged, so each of the two sends gets the
/// attempt deadline. Place it under `Client::new` (as its `backend`), so a
/// Client retry starts from the wrapper again.
pub struct AuthRefresh {
  priv inner : &@mttp_core.Backend
  priv origin : @mttp_core.Url
  priv coordination : &@rt.Coordination
  priv refresh : async () -> Unit
  priv apply : (@mttp_core.Request) -> @mttp_core.Request
  // Successful refreshes so far; a request sent under an older value was
  // sent with credentials that are gone.
  priv mut generation : Int64
  priv mut flight : Flight?
  priv mut closed : Bool
}

///|
/// Wraps `inner` for the absolute HTTP(S) `origin`; only its scheme, host and
/// effective port matter. `refresh` obtains new credentials, `apply` puts the
/// current ones on a request, and `coordination` supplies the signal that
/// concurrent 401s wait on.
pub fn AuthRefresh::new(
  inner : &@mttp_core.Backend,
  origin~ : @mttp_core.Url,
  refresh~ : async () -> Unit,
  apply~ : (@mttp_core.Request) -> @mttp_core.Request,
  coordination~ : &@rt.Coordination,
) -> AuthRefresh {
  {
    inner,
    origin,
    coordination,
    refresh,
    apply,
    generation: 0L,
    flight: None,
    closed: false,
  }
}

///|
/// Waits until the credentials differ from those of `generation`, refreshing
/// them unless a refresh is already running. Returns false when the refresh
/// this request relied on raised.
#warnings("-fragile_catch_all")
async fn AuthRefresh::renewed(
  self : AuthRefresh,
  generation : Int64,
) -> Bool noraise {
  for ;; {
    if self.generation != generation {
      return true
    }
    match self.flight {
      Some(flight) => {
        flight.signal.wait()
        match flight.result {
          Refreshed => return true
          Failed => return false
          // Its caller was cancelled: start or join the next refresh.
          Abandoned | Pending => continue
        }
      }
      None => {
        let flight = Flight::{
          signal: self.coordination.signal(),
          result: Pending,
        }
        self.flight = Some(flight)
        defer {
          if flight.result is Pending {
            flight.result = Abandoned
          }
          if self.flight is Some(current) && physical_equal(current, flight) {
            self.flight = None
          }
          flight.signal.notify()
        }
        let refreshed = try {
          (self.refresh)()
          true
        } catch {
          _ => false
        }
        if refreshed {
          self.generation += 1L
          flight.result = Refreshed
        } else {
          flight.result = Failed
        }
        return refreshed
      }
    }
  }
}

///|
/// Sends with the current credentials and handles a 401 as `AuthRefresh`
/// describes. Validates first, and closes the request stream it took.
pub async fn AuthRefresh::send(
  self : AuthRefresh,
  request : @mttp_core.Request,
  options : @mttp_core.SendOptions,
) -> @mttp_core.Response raise @mttp_core.TransportError {
  defer (if request.body is Stream(stream) { stream.close() })
  if self.closed {
    raise @mttp_core.TransportError(
      kind=Closed,
      phase=Pool,
      detail="auth refresh backend is closed",
    )
  }
  request.validate()
  options.validate()
  let url = @mttp_core.Url::parse(request.url) catch {
    _ => return self.inner.send(request, options)
  }
  if !self.origin.same_origin(url) {
    return self.inner.send(request, options)
  }
  let first = (self.apply)(request)
  first.validate()
  let generation = self.generation
  let response = self.inner.send(first, options)
  if response.status != 401 ||
    !request.body.is_replayable() ||
    request.attributes.get(auth_refreshed) is Some(true) {
    return response
  }
  @rt.close_unclaimed(response.attributes)
  response.close()
  let renewed = self.renewed(generation)
  if !renewed {
    return { ..response, body: Empty, }
  }
  let again = (self.apply)(request.attribute(auth_refreshed, true))
  again.validate()
  self.inner.send(again, options)
}

///|
/// Closes the wrapped backend at most once. Later sends fail with `Closed`
/// in phase Pool.
pub fn AuthRefresh::close(self : AuthRefresh) -> Unit {
  if !self.closed {
    self.closed = true
    self.inner.close()
  }
}

///|
/// Sends through the shared backend interface.
pub impl @mttp_core.Backend for AuthRefresh with fn send(self, request, options) {
  self.send(request, options)
}

///|
/// Closes through the shared backend interface.
pub impl @mttp_core.Backend for AuthRefresh with fn close(self) {
  self.close()
}
