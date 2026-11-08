// The exchange loop of one connection: read a head, refuse it or hand the
// request to the handler while a monitor watches the peer, write the
// response, drain what the handler left unread, and decide whether the next
// request may follow. Every exit closes the connection (in `serve_conn`).

///|
priv struct Session {
  wire : Wire
  clock : &@rt.Clock
  coordination : &@rt.Coordination
  handler : @http.Handler
  limits : ServerLimits
  scheme : String
  peer : String?
  authority : String
  on_error : (@http.TransportError) -> Unit
  stopping : () -> Bool
  background : ((async () -> Unit) -> Unit)?
  mut control : @control.SessionState
}

///|
fn Session::set_busy(self : Session, busy : Bool) -> Unit {
  self.control = self.control.step(if busy { Begin } else { Finish }).state
}

///|
fn Session::report(self : Session, error : @http.TransportError) -> Unit {
  (self.on_error)(error)
}

///|
/// Serves requests until the connection ends or must close.
async fn Session::run(self : Session) -> Unit noraise {
  while !(self.stopping)() {
    self.set_busy(false)
    match self.wire.head(self.limits) {
      Idle => return
      Lost(error) => {
        self.report(error)
        return
      }
      Refuse(status~, error~) => {
        self.report(error)
        self.reject(status)
        return
      }
      Request(request) => {
        self.set_busy(true)
        if !self.exchange(request) {
          return
        }
      }
    }
  }
}

///|
/// Serves one request; `true` when the connection may carry the next one.
async fn Session::exchange(
  self : Session,
  parsed : @h1.ParsedRequest,
) -> Bool noraise {
  let { meth, target, version, headers, } = parsed
  let framing = @h1.request_framing(headers) catch {
    @h1.ParseError(kind~, detail~) => {
      self.report(@http.TransportError(kind=Protocol, phase=Head, detail~))
      self.reject(framing_status(kind))
      return false
    }
  }
  if meth == Connect {
    self.report(protocol("CONNECT is not served"))
    self.reject(501)
    return false
  }
  if framing is Length(n) && n > self.limits.max_body_bytes.to_int64() {
    self.report(
      @http.TransportError(
        kind=TooLarge(limit=self.limits.max_body_bytes),
        phase=Head,
        detail="Content-Length exceeds \{self.limits.max_body_bytes} bytes",
      ),
    )
    self.reject(413)
    return false
  }
  // An HTTP/1.0 client cannot wait for 100 Continue, so its expectation is
  // ignored (RFC 9110, section 10.1.1); any other expectation is refused.
  let expect = match headers.get_all("expect") {
    [] => false
    [value] if lower_trim(value) == "100-continue" => version == Http11
    _ => {
      self.report(protocol("unsupported expectation"))
      self.reject(417)
      return false
    }
  }
  let url = self.request_url(target, headers) catch {
    error => {
      self.report(error)
      self.reject(400)
      return false
    }
  }
  let source = RequestBody::new(
    self.wire,
    self.clock,
    self.coordination,
    framing,
    self.limits,
    expect~,
  )
  let body : @http.Body = if source.done {
    Empty
  } else {
    Stream(
      @http.StreamBody::new(
        source,
        length?=match framing {
          Length(n) => Some(n)
          _ => None
        },
      ),
    )
  }
  defer (if body is Stream(stream) { stream.close() })
  let mut attributes = @http.Attributes::empty()
  if self.peer is Some(peer) {
    attributes = attributes.put(@http.remote_addr, peer)
  }
  if self.background is Some(schedule) {
    attributes = attributes.put(@http.background, schedule)
  }
  let request = @http.Request::{
    ..@http.Request::new(meth, url),
    headers,
    body,
    attributes,
  }
  let mut keep = false
  self.coordination.supervise(
    primary=() => keep = self.respond(request, source, version),
    monitor=() => self.watch_peer(source),
  ) catch {
    error => {
      self.report(error)
      return false
    }
  }
  keep
}

///|
/// Runs the handler, writes its response and drains the rest of the body;
/// `true` when the connection may carry the next request.
async fn Session::respond(
  self : Session,
  request : @http.Request,
  source : RequestBody,
  version : @h1.Version,
) -> Bool noraise {
  let response = match self.limits.handler_timeout_ms {
    None => (self.handler)(request)
    Some(ms) => {
      let mut response = None
      // A handler that returned has finished, whatever the deadline did
      // after it.
      let _ = self.wire.timer.within(ms, () => {
        response = Some((self.handler)(request))
      })
      guard response is Some(response) else {
        self.report(timeout(ms, Unknown, "the handler"))
        self.reject(504)
        return false
      }
      response
    }
  }
  // A body the handler could not read is answered with its own status, even
  // when the handler caught the failure and returned a response.
  let input_failed = source.failure is Some(_)
  let response = match source.failure {
    Some(error) => {
      response.close()
      self.report(error)
      @http.Response::new(
        body_status(error),
        headers=@http.Headers::of([("connection", "close")]),
      )
    }
    None => response
  }
  let keep_alive = match version {
    Http11 => !has_token(request.headers, "connection", "close")
    _ =>
      has_token(request.headers, "connection", "keep-alive") &&
      !has_token(request.headers, "connection", "close")
  }
  let close = (self.stopping)() ||
    !keep_alive ||
    response.closes_connection() ||
    source.expect
  let sent = Ref(false)
  let reused = self.write_response(
    response,
    source,
    request.meth,
    version,
    close,
    sent,
  ) catch {
    error => {
      self.report(error)
      if !sent.val {
        // A response that streams the request body may time out on it
        // through its own deadline before the body's records a failure.
        let status = match (source.failure, error) {
          (Some(failure), _) => body_status(failure)
          (None, @http.TransportError(kind=Timeout(..), phase=Body, ..)) if !source.done =>
            408
          _ => 500
        }
        self.reject(status)
      }
      return false
    }
  }
  // A later response pull may have caught an input error after the head was
  // sent. Report it even when Connection: close already prevents draining.
  if !input_failed && source.failure is Some(error) {
    self.report(error)
    return false
  }
  reused &&
  (source.drain() catch {
    error => {
      self.report(error)
      false
    }
  })
}

///|
/// Watches the peer while the exchange runs. Once the body was read, one
/// bounded read ahead tells a reset from a pipelined request: a failure
/// cancels the exchange, EOF lets it finish its response (the peer may have
/// closed only its sending half), and bytes stay pending for the next head.
async fn Session::watch_peer(
  self : Session,
  source : RequestBody,
) -> Unit raise @http.TransportError {
  while !source.done {
    source.changed.wait()
  }
  if !self.wire.pending.is_empty() {
    return
  }
  let next = self.wire.read(io_bytes, Unknown) catch {
    error => {
      let change = self.control.step(PeerFailure)
      self.control = change.state
      if change.cancel_exchange {
        raise error
      }
      return
    }
  }
  match next {
    None => self.control = self.control.step(PeerEof).state
    Some(bytes) => self.wire.unread(bytes)
  }
}

///|
/// Answers with a bare `status` and `Connection: close`, ignoring failures:
/// the connection closes next either way.
async fn Session::reject(self : Session, status : Int32) -> Unit noraise {
  let head = "HTTP/1.1 \{status} \{@http.reason_phrase(status)}\r\nconnection: close\r\ncontent-length: 0\r\n\r\n"
  self.wire.write(@http.encode_utf8(head), self.limits.body_timeout_ms) catch {
    _ => ()
  }
}

///|
/// The absolute URL the handler sees: an absolute-form target as it came
/// (its host wins over `Host`, RFC 9112, section 3.2.2), otherwise the
/// configured scheme, the `Host` field (or the configured authority when an
/// HTTP/1.0 request has none) and the target. The asterisk-form of `OPTIONS
/// *` becomes the path `/*`.
fn Session::request_url(
  self : Session,
  target : String,
  headers : @http.Headers,
) -> String raise @http.TransportError {
  let url = if target.has_prefix("/") || target == "*" {
    let host = headers.get("host").unwrap_or(self.authority)
    let path = if target == "*" { "/*" } else { target }
    "\{self.scheme}://\{host}\{path}"
  } else {
    target
  }
  let _ = @http.Url::parse(url) catch {
    _ => raise protocol("the request URL does not parse")
  }
  url
}

///|
fn protocol(detail : String) -> @http.TransportError {
  @http.TransportError(kind=Protocol, phase=Head, detail~)
}

///|
fn lower_trim(value : String) -> String {
  value.trim(chars=" \t").to_owned().to_lower()
}

///|
/// Whether a comma-separated field `name` lists `wanted`, ignoring case.
fn has_token(headers : @http.Headers, name : String, wanted : String) -> Bool {
  headers
  .get_all(name)
  .iter()
  .any(field => {
    field.split(",").any(token => lower_trim(token.to_owned()) == wanted)
  })
}
