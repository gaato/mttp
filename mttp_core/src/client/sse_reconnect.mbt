///|
/// How `Client::sse_reconnecting` ended.
#derive(Debug)
#non_exhaustive
pub(all) enum SseEnd {
  /// `stop` matched this event, which was not delivered.
  Stopped(@sse.SseEvent)
  /// The server answered 204 No Content, which tells an event-stream client
  /// to stop reconnecting.
  NoContent
  /// A response that reconnecting cannot fix: a status other than 2xx,
  /// 408, 429 and 5xx (an `UnexpectedStatus` with a bounded excerpt), a 2xx
  /// other than 200 and 204 (`UnexpectedStatus` with an empty body), or a
  /// 200 whose Content-Type is not `text/event-stream` (`Deserialization`).
  Rejected(ResponseFailure)
  /// The reconnect policy gave up, or the Client was closed while a
  /// reconnect was planned; this was the last connection's end.
  GaveUp(SseDisconnect)
}

///|
/// Formats the end of an event stream for diagnostics.
pub extend SseEnd with @debug.Debug::{to_repr}

///|
/// Why one connection of `Client::sse_reconnecting` ended and a reconnect
/// was considered.
#derive(Debug)
#non_exhaustive
pub(all) enum SseDisconnect {
  /// The stream reached its end.
  Ended
  /// The server answered 408, 429 or 5xx.
  Status(ResponseFailure)
  /// The connection or the stream failed.
  Failed(@mttp_core.TransportError)
}

///|
/// Formats a disconnect for diagnostics.
pub extend SseDisconnect with @debug.Debug::{to_repr}

///|
/// The stream state that outlives one connection.
priv struct SseSession {
  mut last_event_id : String?
  mut reconnection_ms : Int32?
  mut connected_at : Int64?
  mut in_callback : Bool
}

///|
/// Whether a Content-Type names `text/event-stream`, ignoring case and
/// parameters.
fn is_event_stream(content_type : String?) -> Bool {
  guard content_type is Some(value) else { return false }
  let media = match value.find(";") {
    Some(at) => value[:at]
    None => value[:]
  }
  media.trim().to_owned().to_lower() == "text/event-stream"
}

///|
/// Transport failures that would recur at once or were decided locally:
/// reconnecting cannot help, so `sse_reconnecting` raises them. `Protocol`
/// is not here, because a stream cut mid-chunk ends that way.
fn ends_the_stream(kind : @mttp_core.Kind) -> Bool {
  kind
  is (Invalid
  | Closed
  | TooLarge(..)
  | Unreplayable
  | TooManyRedirects(..)
  | RedirectRefused)
}

///|
/// Statuses after which an event stream is reconnected: a timeout, a rate
/// limit and server errors. Every other non-2xx status says the request
/// itself is wrong (or was redirected and not followed), so sending it again
/// cannot help.
fn reconnectable_status(status : Int32) -> Bool {
  status == 408 || status == 429 || (status >= 500 && status <= 599)
}

///|
/// The request for the next connection: `Accept: text/event-stream` unless
/// the request sets an Accept, and `Last-Event-ID` set to the stream's last
/// event ID, or removed when the stream reset it to empty. Before the
/// stream named one, the caller's own `Last-Event-ID` is kept.
fn sse_request(
  request : @mttp_core.Request,
  last_event_id : String?,
) -> @mttp_core.Request {
  let request = if request.headers.contains("accept") {
    request
  } else {
    request.set_header("accept", "text/event-stream")
  }
  match last_event_id {
    None => request
    Some("") => { ..request, headers: request.headers.remove("last-event-id"), }
    Some(id) => request.set_header("last-event-id", id)
  }
}

///|
/// Reads an event stream and reconnects it when it ends or fails, as an
/// `EventSource` does (WHATWG HTML, section 9.2).
///
/// Each connection sends `request` through `send`, with `Accept:
/// text/event-stream` unless it sets an Accept, and from the first
/// reconnect on, with `Last-Event-ID` set to the stream's last event ID.
/// A 200 response with that Content-Type is read with `@sse.SseReader`:
/// each event goes to `receive`, until `stop` matches one, which is
/// returned undelivered as `Stopped`.
///
/// When a connection ends (EOF, a transport failure, or a 408, 429 or 5xx
/// response), `policy` decides whether and when to reconnect: `attempts`
/// counts the reconnects in a row, the time from the 200 head to the end is
/// `lived_ms`, and the server's hint is the stream's latest `retry:` value
/// (kept across connections) or, for a status, its `Retry-After`. The wait
/// is on the Client's clock and its `random` spreads it. A 204 stops
/// (`NoContent`), as do the responses `SseEnd::Rejected` lists; a policy that
/// gives up returns `GaveUp` with the last connection's end.
///
/// Raised, without reconnecting: an error from `receive`; a transport
/// failure that would recur (`Invalid`, `Closed`, `TooLarge`, which an event
/// over `max_event_bytes` raises, `Unreplayable`, `TooManyRedirects`,
/// `RedirectRefused`); and cancellation, which also interrupts a wait.
/// Closing the Client before or during a wait returns `GaveUp` with the last
/// end, as a planned retry returns its last outcome.
///
/// The Client's own retry rules still apply to each connection before its
/// head arrives; its `total_ms`, when set, bounds each connection.
pub async fn Client::sse_reconnecting(
  self : Client,
  request : @mttp_core.Request,
  receive : async (@sse.SseEvent) -> Unit,
  policy~ : ReconnectPolicy = ReconnectPolicy::default(),
  stop~ : (@sse.SseEvent) -> Bool = _ => false,
  max_event_bytes~ : Int32 = 16 * 1024 * 1024,
) -> SseEnd {
  let session = SseSession::{
    last_event_id: None,
    reconnection_ms: None,
    connected_at: None,
    in_callback: false,
  }
  let plan = as_stream((head, stream) => {
    if head.status != 200 || !is_event_stream(head.headers.get("content-type")) {
      stream.close()
      return Some(
        match head.status {
          204 => SseEnd::NoContent
          200 =>
            SseEnd::Rejected(
              Deserialization(
                head,
                message="the Content-Type is not text/event-stream",
                body=b"",
              ),
            )
          _ => SseEnd::Rejected(UnexpectedStatus(head, body=b""))
        },
      )
    }
    session.connected_at = Some(self.clock.now_unix_ms())
    let reader = @sse.SseReader::new(stream, max_event_bytes~)
    defer {
      if reader.last_event_id() is Some(id) {
        session.last_event_id = Some(id)
      }
      if reader.reconnection_ms() is Some(ms) {
        session.reconnection_ms = Some(ms)
      }
    }
    while reader.next_event() is Some(event) {
      if stop(event) {
        reader.close()
        return Some(SseEnd::Stopped(event))
      }
      // An error raised while this is set came from the callback.
      session.in_callback = true
      receive(event)
      session.in_callback = false
    }
    None
  })
  for attempts = 0 {
    session.connected_at = None
    session.in_callback = false
    let sent = sse_request(request, session.last_event_id)
    // Ok(Ok(None)) is a stream that reached its end.
    let outcome : Result[Result[SseEnd?, ResponseFailure], Error] = try
      self.send(RequestPlan::new(sent, plan)).body
    catch {
      error => Err(error)
    } noraise {
      body => Ok(body)
    }
    let disconnect : SseDisconnect = match outcome {
      Ok(Ok(None)) => Ended
      Ok(Ok(Some(end))) => return end
      Ok(Err(failure)) =>
        if reconnectable_status(failure.head().status) {
          Status(failure)
        } else {
          return Rejected(failure)
        }
      Err(error) if session.in_callback => raise error
      Err(@mttp_core.TransportError(kind~, ..) as error) =>
        if ends_the_stream(kind) {
          raise error
        } else {
          Failed(error)
        }
      Err(error) => raise error
    }
    let lived_ms = match session.connected_at {
      Some(at) => (self.clock.now_unix_ms() - at).max(0L)
      None => 0L
    }
    let hint = match disconnect {
      Status(failure) =>
        failure.head().headers
        .get("retry-after")
        .bind(value => {
          @retry.parse_retry_after(value, now_unix_ms=self.clock.now_unix_ms())
        })
      _ => session.reconnection_ms
    }
    let decision = policy.decide(
      attempts~,
      lived_ms~,
      server_hint_ms?=hint,
      random=(self.random)(),
    )
    guard decision is Wait(ms) && !self.closed else {
      return GaveUp(disconnect)
    }
    self.clock.sleep(ms)
    if self.closed {
      return GaveUp(disconnect)
    }
    continue policy.next_attempts(attempts~, lived_ms~)
  }
}
