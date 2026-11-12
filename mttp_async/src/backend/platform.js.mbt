///|
priv struct FetchDriver {
  ceiling : Int32?
  mut closed : Bool
  clock : &@rt.Clock
  timer : &@rt.Timer
}

///|
fn platform_backend(
  config : @h1client.ClientConfig?,
  _trust : @trust.Trust,
  clock : &@rt.Clock,
  timer : &@rt.Timer,
) -> AsyncBackend {
  let driver = FetchDriver::{
    ceiling: config.unwrap_or_else(@h1client.ClientConfig::default).max_body_bytes,
    closed: false,
    clock,
    timer,
  }
  { inner: driver, idle: () => 0, }
}

///|
impl @mttp_core.Backend for FetchDriver with fn close(self) {
  self.closed = true
}

///|
fn invalid(detail : String) -> @mttp_core.TransportError {
  @mttp_core.TransportError(kind=Invalid, phase=Pool, detail~)
}

///|
priv struct FetchTimer {
  clock : &@rt.Clock
  timer : &@rt.Timer
  total : Int32?
  deadline : Int64?
  idle : Int32?
}

///|
fn FetchTimer::new(
  clock : &@rt.Clock,
  timer : &@rt.Timer,
  total : Int32?,
  idle? : Int32,
) -> FetchTimer {
  {
    clock,
    timer,
    total,
    deadline: total.map(ms => clock.now_unix_ms() + ms.to_int64()),
    idle,
  }
}

///|
async fn[X] FetchTimer::run(
  self : FetchTimer,
  phase : @mttp_core.Phase,
  f : async () -> X,
) -> X raise @mttp_core.TransportError {
  let budget = match self.deadline {
    Some(at) =>
      Some(
        (
          (at - self.clock.now_unix_ms()).max(0L).min(2147483647L).to_int(),
          self.total.unwrap(),
        ),
      )
    None => self.idle.map(ms => (ms, ms))
  }
  try {
    guard budget is Some((ms, limit)) else { return f() }
    if ms > 0 {
      let mut result : Result[X, Error]? = None
      let complete = self.timer.within(ms, () => {
        result = Some(Ok(f()) catch { error => Err(error) })
      })
      match result {
        Some(Ok(value)) => return value
        Some(Err(error)) => raise error
        None if complete => raise invalid("timer did not run its callback")
        None => ()
      }
    }
    raise @mttp_core.TransportError(
      kind=Timeout(ms=limit),
      phase~,
      detail="fetch deadline expired",
    )
  } catch {
    @mttp_core.TransportError(_) as error => raise error
    error =>
      raise @mttp_core.TransportError(
        kind=Network,
        phase~,
        detail=error.to_string(),
      )
  }
}

///|
async fn upload(
  body : @mttp_core.Body,
  timer : FetchTimer,
) -> Bytes raise @mttp_core.TransportError {
  let limit = 16 * 1024 * 1024
  match body {
    Empty => b""
    Bytes(bytes) => {
      if bytes.length() > limit {
        raise @mttp_core.TransportError(
          kind=TooLarge(limit~),
          phase=Write,
          detail="fetch upload exceeds buffer limit",
        )
      }
      bytes
    }
    Stream(cell) => {
      let stream = cell.take()
      defer stream.close()
      if cell.length() is Some(n) && n > limit.to_int64() {
        raise @mttp_core.TransportError(
          kind=TooLarge(limit~),
          phase=Write,
          detail="fetch upload exceeds buffer limit",
        )
      }
      let buffer = Buffer()
      while timer.run(Write, () => stream.read_some()) is Some(bytes) {
        if bytes.length() > limit - buffer.length() {
          raise @mttp_core.TransportError(
            kind=TooLarge(limit~),
            phase=Write,
            detail="fetch upload exceeds buffer limit",
          )
        }
        buffer.write_bytes(bytes)
      }
      buffer.to_bytes()
    }
    @mttp_core.Body::.. => raise invalid("unsupported body kind")
  }
}

///|
impl @mttp_core.Backend for FetchDriver with fn send(self, request, options) {
  if self.closed {
    raise @mttp_core.TransportError(
      kind=Closed,
      phase=Pool,
      detail="backend closed",
    )
  }
  request.validate()
  options.validate()
  if self.ceiling is Some(n) && n < 0 {
    raise invalid("negative body ceiling")
  }
  let url = @mttp_core.Url::parse(request.url) catch {
    _ => raise invalid("invalid URL")
  }
  guard url.scheme is Some("http" | "https" as scheme) &&
    url.host is Some(host) &&
    !host.is_empty() &&
    url.userinfo is None &&
    url.port_or_default() is Some(port) else {
    raise invalid("fetch requires an absolute http(s) URL without userinfo")
  }
  // Refuse framing conflicts even though fetch chooses its own wire framing.
  let framing = @h1.request_framing(request.headers) catch {
    _ => raise invalid("invalid request framing")
  }
  if framing is Length(declared) {
    if request.body.length() is Some(n) && declared != n {
      raise invalid("Content-Length differs from body length")
    }
  }
  let verb = request.meth.to_string()
  if verb.to_upper() is ("CONNECT" | "TRACE" | "TRACK") {
    raise invalid("method forbidden by fetch")
  }
  let timer = FetchTimer::new(self.clock, self.timer, options.timeout_ms)
  let (body_timer, limit) = match options.body {
    Exchange(max_bytes~) =>
      (timer, Some(self.ceiling.unwrap_or(max_bytes).min(max_bytes)))
    Stream(idle_ms~) =>
      (
        FetchTimer::new(self.clock, self.timer, None, idle?=idle_ms),
        self.ceiling,
      )
    @mttp_core.BodyTiming::.. => raise invalid("unsupported body timing")
  }
  let bytes = upload(request.body, timer)
  if framing is Length(declared) && declared != bytes.length().to_int64() {
    raise invalid("Content-Length differs from buffered body length")
  }
  if verb.to_upper() is ("GET" | "HEAD") && !bytes.is_empty() {
    raise invalid("fetch forbids GET/HEAD bodies")
  }
  let headers = FetchHeaders::new()
  for (name, value) in request.headers.iter() {
    if name != "content-length" &&
      name != "transfer-encoding" &&
      name != "proxy-authorization" {
      headers.append(name, value)
    }
  }
  let name = if host.contains(":") { "[" + host + "]" } else { host }
  let target = scheme +
    "://" +
    name +
    ":" +
    port.to_string() +
    (if url.path.is_empty() { "/" } else { url.path }) +
    url.query.map(q => "?" + q).unwrap_or("")
  let abort = @js_async.AbortController::new()
  let mut transferred = false
  defer (if !transferred { abort.abort() })
  let response = timer.run(Unknown, () => {
    fetch_once(target, verb, headers, bytes, abort.signal()).wait(
      abort_controller=abort,
    )
  })
  let reader = response.reader()
  errdefer reader.close()
  let status = response.status()
  if status < 100 || status > 599 {
    raise @mttp_core.TransportError(
      kind=Protocol,
      phase=Unknown,
      detail="fetch returned an opaque response",
    )
  }
  let headers = @mttp_core.Headers::of(
    response.headers().iter().map(pair => (pair[0], pair[1])).collect(),
  )
  if request.meth == Head || status == 204 || status == 304 {
    reader.close()
    return @mttp_core.Response::new(status, headers~)
  }
  let body = FetchBody::{
    reader,
    abort,
    timer: body_timer,
    limit,
    count: 0L,
    pending: b"",
    offset: 0,
    closed: false,
  }
  transferred = true
  @mttp_core.Response::new(
    status,
    headers~,
    body=Stream(@mttp_core.StreamBody::new(body)),
  )
}
