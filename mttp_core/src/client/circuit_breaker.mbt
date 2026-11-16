///|
/// A backend that stops sending to an origin whose recent requests mostly
/// failed, so a client stops waiting on a server that is down and the server
/// gets room to recover.
///
/// Each origin (scheme, host and port) has its own circuit. While it is
/// closed, requests pass and their outcomes are counted in windows of
/// `window_ms`: a window with at least `min_requests` counted requests, of
/// which at least `failure_ratio` failed, opens the circuit. A failure is a
/// transport failure other than `Invalid`, `Closed` and `CircuitOpen` (which
/// say nothing about the origin), or a 502, 503 or 504 response; every other
/// response, 4xx included, is a success. While open, requests fail at once
/// with `TransportError(kind=CircuitOpen, phase=Pool, ..)`, which is unsent
/// and which the retry rules never retry. After `open_ms`, the circuit is
/// half-open: `half_open_probes` requests go through, the first success
/// closes the circuit with a fresh window and the first failure opens it
/// again. A probe that is cancelled, or refused as `Invalid`, frees its slot.
///
/// Only the head counts: a body that fails after `send` returned is the
/// caller's. A request whose URL has no origin passes uncounted. At most
/// `max_origins` circuits are kept; a new origin past that evicts the least
/// recently used one, which forgets its state.
///
/// The thresholds are normalised:
/// `min_requests`, `window_ms`, `half_open_probes` and `max_origins` below 1
/// count as 1 and a negative `open_ms` as 0. Place it under `Client::new`
/// (as its `backend`), so each redirect hop and each retry is counted, and
/// under the Client's retry rules, which leave `CircuitOpen` alone.
pub struct CircuitBreaker {
  priv inner : &@mttp_core.Backend
  priv clock : &@rt.Clock
  priv config : @control.BreakerConfig
  priv max_origins : Int32
  // Insertion order is recency: a used circuit is moved to the end, and
  // the first entry is the one to evict.
  priv circuits : Map[String, Ref[@control.BreakerState]]
  priv mut closed : Bool
}

///|
/// Wraps `inner`, reading time from `clock`. The defaults open a circuit
/// when 10 % of at least 100 requests in 30 s failed, keep it open for 5 s
/// and then let one probe through; at most 1024 origins are tracked.
pub fn CircuitBreaker::new(
  inner : &@mttp_core.Backend,
  clock~ : &@rt.Clock,
  failure_ratio~ : Double = 0.1,
  min_requests~ : Int32 = 100,
  window_ms~ : Int32 = 30_000,
  open_ms~ : Int32 = 5_000,
  half_open_probes~ : Int32 = 1,
  max_origins~ : Int32 = 1024,
) -> CircuitBreaker {
  {
    inner,
    clock,
    config: @control.BreakerConfig::new(
      failure_ratio~,
      min_requests~,
      window_ms~,
      open_ms~,
      half_open_probes~,
    ),
    max_origins: max_origins.max(1),
    circuits: Map([]),
    closed: false,
  }
}

///|
/// `scheme://host:port`, lowercased, with the scheme's default port when
/// the URL has none; `None` for a URL without an origin.
fn origin_key(url : String) -> String? {
  let parsed = @mttp_core.Url::parse(url) catch { _ => return None }
  match (parsed.scheme, parsed.host, parsed.port_or_default()) {
    (Some(scheme), Some(host), Some(port)) =>
      Some("\{scheme.to_lower()}://\{host.to_lower()}:\{port}")
    (Some(scheme), Some(host), None) =>
      Some("\{scheme.to_lower()}://\{host.to_lower()}")
    _ => None
  }
}

///|
/// The circuit of `key`, created when absent and marked most recently used.
fn CircuitBreaker::circuit(
  self : CircuitBreaker,
  key : String,
  now : Int64,
) -> Ref[@control.BreakerState] {
  match self.circuits.get(key) {
    Some(cell) => {
      self.circuits.remove(key)
      self.circuits.set(key, cell)
      cell
    }
    None => {
      if self.circuits.length() >= self.max_origins {
        let mut oldest = None
        for name, _ in self.circuits {
          oldest = Some(name)
          break
        }
        if oldest is Some(name) {
          self.circuits.remove(name)
        }
      }
      let cell = Ref(@control.BreakerState::new(now~))
      self.circuits.set(key, cell)
      cell
    }
  }
}

///|
/// Sends through the origin's circuit; see `CircuitBreaker`. Validates
/// before anything else, passes `SendOptions` through unchanged, closes a
/// request stream it refuses, and propagates cancellation unchanged.
pub async fn CircuitBreaker::send(
  self : CircuitBreaker,
  request : @mttp_core.Request,
  options : @mttp_core.SendOptions,
) -> @mttp_core.Response raise @mttp_core.TransportError {
  defer (if request.body is Stream(stream) { stream.close() })
  if self.closed {
    raise @mttp_core.TransportError(
      kind=Closed,
      phase=Pool,
      detail="circuit breaker backend is closed",
    )
  }
  request.validate()
  options.validate()
  guard origin_key(request.url) is Some(key) else {
    self.inner.send(request, options)
  }
  let cell = self.circuit(key, self.clock.now_unix_ms())
  let (state, ticket) = cell.val.admit(
    self.config,
    now=self.clock.now_unix_ms(),
  )
  cell.val = state
  if ticket is Reject {
    raise @mttp_core.TransportError(
      kind=CircuitOpen,
      phase=Pool,
      detail="circuit open for \{key}",
    )
  }
  // Cancellation and local refusals leave the outcome Neutral.
  let mut outcome : @control.BreakerOutcome = Neutral
  defer {
    cell.val = cell.val.record(
      self.config,
      ticket,
      outcome,
      now=self.clock.now_unix_ms(),
    )
  }
  let response = self.inner.send(request, options) catch {
    @mttp_core.TransportError(kind=Invalid | Closed | CircuitOpen, ..) as error =>
      raise error
    error => {
      outcome = Failure
      raise error
    }
  }
  outcome = if response.status is (502 | 503 | 504) { Failure } else { Success }
  response
}

///|
/// Closes the wrapped backend at most once. Later sends fail with `Closed`
/// in phase Pool.
pub fn CircuitBreaker::close(self : CircuitBreaker) -> Unit {
  if !self.closed {
    self.closed = true
    self.inner.close()
  }
}

///|
/// Sends through the shared backend interface.
pub impl @mttp_core.Backend for CircuitBreaker with fn send(
  self,
  request,
  options,
) {
  self.send(request, options)
}

///|
/// Closes through the shared backend interface.
pub impl @mttp_core.Backend for CircuitBreaker with fn close(self) {
  self.close()
}
