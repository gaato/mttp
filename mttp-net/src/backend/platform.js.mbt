///|
using @engine {type Slots, type PhaseTimer, target}

///|
priv struct FetchDriver {
  settings : Settings
  slots : Slots
  mut closed : Bool
}

///|
fn platform_backend(settings : Settings) -> AsyncBackend {
  let driver = FetchDriver::{
    settings,
    slots: Slots::new(
      coordination=@runtime.RuntimeCoordination::new(),
      max_total?=settings.max_connections,
      max_per_origin?=settings.max_connections_per_origin,
    ),
    closed: false,
  }
  { inner: driver, idle: () => 0, }
}

///|
impl @client.Backend for FetchDriver with fn close(self) {
  self.closed = true
  self.slots.refuse_waiting()
}

///|
async fn upload(
  body : @model.Body,
  timer : PhaseTimer,
) -> Bytes raise @model.TransportError {
  match body {
    Empty => b""
    Bytes(bytes) => bytes
    Stream(cell) => {
      let limit = 16 * 1024 * 1024
      if cell.length() is Some(n) && n > limit.to_int64() {
        raise @model.TransportError(
          kind=TooLarge(limit~),
          phase=Write,
          detail="fetch stream upload exceeds buffer limit",
        )
      }
      let stream = cell.take()
      defer stream.close()
      let buffer = Buffer()
      while timer.run(Write, () => stream.read_some()) is Some(bytes) {
        if bytes.length() > limit - buffer.length() {
          raise @model.TransportError(
            kind=TooLarge(limit~),
            phase=Write,
            detail="fetch stream upload exceeds buffer limit",
          )
        }
        buffer.write_bytes(bytes)
      }
      buffer.to_bytes()
    }
    @model.Body::.. =>
      raise @model.TransportError(
        kind=Invalid,
        phase=Write,
        detail="unsupported body kind",
      )
  }
}

///|
impl @client.Backend for FetchDriver with fn send(self, request, options) {
  if self.closed {
    raise @model.TransportError(
      kind=Closed,
      phase=Pool,
      detail="backend closed",
    )
  }
  let destination = target(request)
  if self.settings.proxy is Some(_) {
    raise @model.TransportError(
      kind=Protocol,
      phase=Pool,
      detail="an explicit proxy is not supported by fetch",
    )
  }
  if options.max_body_bytes < 0 ||
    (self.settings.max_body_bytes is Some(n) && n < 0) {
    raise @model.TransportError(
      kind=Invalid,
      phase=Pool,
      detail="negative body limit",
    )
  }
  let verb = request.meth.to_string()
  if verb.to_upper() is ("CONNECT" | "TRACE" | "TRACK") {
    raise @model.TransportError(
      kind=Invalid,
      phase=Pool,
      detail="method forbidden by fetch",
    )
  }
  let limits = {
    ..self.settings.timeouts,
    total: options.timeout_ms.unwrap_or(self.settings.timeouts.total),
    read: options.read_idle_ms.unwrap_or(self.settings.timeouts.read),
  }
  let timer = PhaseTimer::exchange(
    self.settings.clock,
    limits,
    timer=@runtime.ClockTimer::new(clock=self.settings.clock),
  )
  self.slots.acquire(destination.origin, timer)
  let mut transferred = false
  defer (if !transferred { self.slots.release(destination.origin) })
  if self.closed {
    raise @model.TransportError(
      kind=Closed,
      phase=Pool,
      detail="backend closed",
    )
  }
  let bytes = upload(request.body, timer)
  if verb.to_upper() is ("GET" | "HEAD") && !bytes.is_empty() {
    raise @model.TransportError(
      kind=Invalid,
      phase=Write,
      detail="fetch forbids GET/HEAD bodies",
    )
  }
  let headers = FetchHeaders::new()
  for (name, value) in request.headers.iter() {
    if name != "content-length" &&
      name != "transfer-encoding" &&
      name != "proxy-authorization" {
      if value.iter().any(c => c.to_int() > 255) {
        raise @model.TransportError(
          kind=Invalid,
          phase=Pool,
          detail="fetch header value is not Latin-1",
        )
      }
      headers.append(name, value)
    }
  }
  let abort = @js_async.AbortController::new()
  let mut owned = true
  defer (if owned { abort.abort() })
  let response = timer.run(Unknown, () => {
    fetch_once(
      destination.origin + destination.path,
      verb,
      headers,
      bytes,
      abort.signal(),
    ).wait(abort_controller=abort)
  })
  let reader = response.reader()
  errdefer reader.close()
  let status = response.status()
  if status < 100 || status > 599 {
    raise @model.TransportError(
      kind=Protocol,
      phase=Unknown,
      detail="fetch returned an opaque response; redirects may be hidden by the browser",
    )
  }
  let headers = @model.Headers::of(
    response.headers().iter().map(pair => (pair[0], pair[1])).collect(),
  )
  if request.meth == Head || status == 204 || status == 304 {
    reader.close()
    return @model.Response::new(status, headers~)
  }
  let body = FetchBody::{
    driver: self,
    key: destination.origin,
    reader,
    abort,
    timer: if options.body_deadline {
      timer
    } else {
      PhaseTimer::stream(
        self.settings.clock,
        limits,
        timer=@runtime.ClockTimer::new(clock=self.settings.clock),
      )
    },
    limit: if options.body_deadline {
      Some(
        self.settings.max_body_bytes
        .unwrap_or(options.max_body_bytes)
        .min(options.max_body_bytes),
      )
    } else {
      None
    },
    count: 0L,
    pending: b"",
    offset: 0,
    closed: false,
    busy: false,
  }
  owned = false
  transferred = true
  @model.Response::new(
    status,
    headers~,
    body=Stream(@model.StreamBody::new(body)),
  )
}
