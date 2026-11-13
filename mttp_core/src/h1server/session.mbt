// The exchange loop of one connection: read a head, refuse it or hand the
// request to the handler while a monitor watches the peer, write the
// response, drain what the handler left unread, and decide whether the next
// request may follow. Every exit closes the connection (in `serve_conn`).

///|
priv struct Session {
  wire : Wire
  clock : &@rt.Clock
  coordination : &@rt.Coordination
  handler : @mttp_core.Handler
  limits : ServerLimits
  scheme : String
  peer : String?
  authority : String
  on_error : (@mttp_core.TransportError) -> Unit
  stopping : () -> Bool
  background : ((async () -> Unit) -> Unit)?
  mut control : @control.SessionState
}

///|
fn Session::set_busy(self : Session, busy : Bool) -> Unit {
  self.control = self.control.step(if busy { Begin } else { Finish }).state
}

///|
fn Session::report(self : Session, error : @mttp_core.TransportError) -> Unit {
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
      self.report(@mttp_core.TransportError(kind=Protocol, phase=Head, detail~))
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
      @mttp_core.TransportError(
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
  let body : @mttp_core.Body = if source.done {
    Empty
  } else {
    Stream(
      @mttp_core.StreamBody::new(
        source,
        length?=match framing {
          Length(n) => Some(n)
          _ => None
        },
      ),
    )
  }
  defer (if body is Stream(stream) { stream.close() })
  let mut attributes = @mttp_core.Attributes::empty()
  if self.peer is Some(peer) {
    attributes = attributes.put(@mttp_core.remote_addr, peer)
  }
  if self.background is Some(schedule) {
    attributes = attributes.put(@mttp_core.background, schedule)
  }
  let request = @mttp_core.Request::{
    ..@mttp_core.Request::new(meth, url),
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
  request : @mttp_core.Request,
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
      @mttp_core.Response::new(
        body_status(error),
        headers=@mttp_core.Headers::of([("connection", "close")]),
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
        // The producer's timer can cancel a request pull before its own
        // timer records a failure. An unread body alone proves nothing:
        // an independent producer's timeout is a server failure.
        let status = match (source.failure, error) {
          (Some(failure), _) => body_status(failure)
          (None, @mttp_core.TransportError(kind=Timeout(..), phase=Body, ..)) if source.reading =>
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
/// Until the first body pull, reads raw bytes into the existing 64 KiB
/// pending buffer. A claim cancels and joins that read before waking the
/// body reader: the connection always has exactly one reader. Full buffers
/// stop monitoring; progress then relies on body pulls or a configured
/// handler deadline. Read-ahead does not parse a body, start its timer or
/// send 100 Continue.
/// Once the body is complete, one bounded read watches for peer failure.
/// Clean EOF always preserves the current response (a sending half-close).
async fn Session::watch_peer(
  self : Session,
  source : RequestBody,
) -> Unit raise @mttp_core.TransportError {
  if !source.done {
    self.coordination.supervise(primary=() => source.claim.wait(), monitor=() => {
      // Append tiny fragments without repeatedly copying the whole buffer.
      // Restore pending input on every exit, including handoff cancellation.
      let pending = Buffer()
      pending.write_bytes(self.wire.pending)
      self.wire.pending = b""
      defer {
        self.wire.pending = pending.to_bytes()
      }
      while !source.claimed && pending.length() < io_bytes {
        match self.read_peer(io_bytes - pending.length()) {
          None => return
          Some(bytes) => pending.write_bytes(bytes)
        }
      }
    })
    source.ready.notify()
  }
  while !source.done {
    source.changed.wait()
  }
  if !self.wire.pending.is_empty() {
    return
  }
  if self.read_peer(io_bytes) is Some(bytes) {
    self.wire.unread(bytes)
  }
}

///|
/// Reads directly from the connection. Only the peer monitor calls this,
/// while it owns the read direction.
async fn Session::read_peer(
  self : Session,
  max_len : Int32,
) -> Bytes? raise @mttp_core.TransportError {
  let next = read_conn(self.wire.conn, max_len) catch {
    error => {
      let change = self.control.step(PeerFailure)
      self.control = change.state
      if change.cancel_exchange {
        let @mttp_core.TransportError(kind~, detail~, ..) = error
        raise @mttp_core.TransportError(kind~, phase=Unknown, detail~)
      }
      return None
    }
  }
  match next {
    None => {
      self.control = self.control.step(PeerEof).state
      None
    }
    Some(_) => next
  }
}

///|
/// Answers with a bare `status` and `Connection: close`, ignoring failures:
/// the connection closes next either way.
async fn Session::reject(self : Session, status : Int32) -> Unit noraise {
  let head = "HTTP/1.1 \{status} \{@mttp_core.reason_phrase(status)}\r\nconnection: close\r\ncontent-length: 0\r\n\r\n"
  self.wire.write(@mttp_core.encode_utf8(head), self.limits.body_timeout_ms) catch {
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
  headers : @mttp_core.Headers,
) -> String raise @mttp_core.TransportError {
  let url = if target.has_prefix("/") || target == "*" {
    let host = headers.get("host").unwrap_or(self.authority)
    let path = if target == "*" { "/*" } else { target }
    "\{self.scheme}://\{host}\{path}"
  } else {
    target
  }
  let _ = @mttp_core.Url::parse(url) catch {
    _ => raise protocol("the request URL does not parse")
  }
  url
}

///|
fn protocol(detail : String) -> @mttp_core.TransportError {
  @mttp_core.TransportError(kind=Protocol, phase=Head, detail~)
}

///|
fn lower_trim(value : String) -> String {
  value.trim(chars=" \t").to_owned().to_lower()
}

///|
/// Whether a comma-separated field `name` lists `wanted`, ignoring case.
fn has_token(
  headers : @mttp_core.Headers,
  name : String,
  wanted : String,
) -> Bool {
  headers
  .get_all(name)
  .iter()
  .any(field => {
    field.split(",").any(token => lower_trim(token.to_owned()) == wanted)
  })
}
