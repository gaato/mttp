///|
/// What a `Client` built with `events` reports while it sends, in the order
/// it happens. For each attempt: `AttemptStart`, then the backend's `Phase`
/// events and a `Redirect` for each hop followed inside the attempt, then
/// `AttemptEnd` with the same `Attempt` the `observer` gets; a `Retry`
/// comes between one attempt's `AttemptEnd` and the next one's
/// `AttemptStart`. Nothing about an attempt is reported after its
/// `AttemptEnd`, including after a cancellation. The client README maps the
/// fields onto OpenTelemetry's HTTP semantic conventions.
#non_exhaustive
pub(all) enum ClientEvent {
  /// The attempt was admitted and is about to be sent. `request` is the
  /// prepared request (defaults and `base_url` applied) before its body
  /// factory runs; `attempt` counts from zero (OpenTelemetry
  /// `http.request.resend_count`); `bucket` is its rate-limit bucket.
  AttemptStart(
    request~ : @mttp_core.RequestHead,
    attempt~ : Int32,
    bucket~ : String
  )
  /// The backend reached `phase` in attempt `attempt`.
  Phase(attempt~ : Int32, phase~ : @mttp_core.PhaseEvent)
  /// The attempt settled, as reported to the observer.
  AttemptEnd(Attempt)
  /// Attempt `attempt` is being sent after a wait of `wait_ms`, because the
  /// previous one ended with `reason`: its status code (`"503"`), or the
  /// kind of its transport failure (`"timeout"`, `"network"`, ...), as
  /// OpenTelemetry's `error.type` names them. Reported when the retry is
  /// sent, so a retry that closing or the retry budget cancels during its
  /// wait reports none.
  Retry(attempt~ : Int32, wait_ms~ : Int32, reason~ : String)
  /// A redirect was followed from `from` to `to` on a `status` response.
  Redirect(from~ : String, to~ : String, status~ : Int32)
}

///|
/// The `reason` of a `Retry` after `result`.
fn[T] retry_reason(result : AttemptResult[T]) -> String {
  match result {
    Buffered(reply) => reply.status.to_string()
    StreamReady(head) => head.status.to_string()
    TransportFailure(@mttp_core.TransportError(kind~, ..)) => kind_name(kind)
  }
}

///|
/// A transport failure's kind as a low-cardinality name.
fn kind_name(kind : @mttp_core.Kind) -> String {
  match kind {
    Invalid => "invalid"
    Connect => "connect"
    Timeout(..) => "timeout"
    Network => "network"
    Protocol => "protocol"
    Proxy(..) => "proxy"
    TooLarge(..) => "too_large"
    TooManyRedirects(..) => "too_many_redirects"
    RedirectRefused => "redirect_refused"
    Unreplayable => "unreplayable"
    Closed => "closed"
    IncompleteClose => "incomplete_close"
    Refused => "refused"
    @mttp_core.Kind::.. => "transport"
  }
}

///|
/// One attempt's event sink: open until its `AttemptEnd`, after which
/// phase and redirect reports for it are dropped.
priv struct AttemptEvents {
  sink : ((ClientEvent) -> Unit)?
  attempt : Int32
  mut open : Bool
}

///|
fn AttemptEvents::new(
  sink : ((ClientEvent) -> Unit)?,
  attempt : Int32,
) -> AttemptEvents {
  { sink, attempt, open: true, }
}

///|
/// `request` with this attempt's `on_phase` callback and the redirect
/// callback `FollowRedirects` reports to, or unchanged when nobody listens.
fn AttemptEvents::attach(
  self : AttemptEvents,
  request : @mttp_core.Request,
) -> @mttp_core.Request {
  guard self.sink is Some(sink) else { return request }
  let attempt = self.attempt
  let attributes = request.attributes
    .put(@mttp_core.on_phase, phase => {
      if self.open {
        sink(Phase(attempt~, phase~))
      }
    })
    .put(redirect_events, hop => {
      if self.open {
        sink(
          Redirect(
            from=hop.request.url,
            to=hop.next.url,
            status=hop.head.status,
          ),
        )
      }
    })
  { ..request, attributes, }
}

///|
/// Closes the attempt and reports its end.
fn AttemptEvents::end(self : AttemptEvents, info : Attempt) -> Unit {
  if self.open {
    self.open = false
    if self.sink is Some(sink) {
      sink(AttemptEnd(info))
    }
  }
}
