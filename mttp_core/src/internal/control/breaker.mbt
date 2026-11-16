// Circuit-breaker accounting for one origin: a window of outcomes while the
// circuit is closed, a timed open state, and a half-open state that lets a
// fixed number of probes through. The client's CircuitBreaker wrapper keeps
// one state per origin and applies every transition here; nothing in this
// file reads a clock or sends a request.

///|
/// The thresholds of a breaker, normalised by `BreakerConfig::new`.
pub(all) struct BreakerConfig {
  /// The share of failed requests in a window that opens the circuit.
  failure_ratio : Double
  /// The requests a window needs before its ratio can open the circuit; at
  /// least 1.
  min_requests : Int32
  /// The length of a counting window; at least 1.
  window_ms : Int32
  /// How long the circuit stays open before probes are let through; at
  /// least 0.
  open_ms : Int32
  /// Requests let through at once while half-open; at least 1.
  half_open_probes : Int32
}

///|
/// Normalises the thresholds: `min_requests`, `window_ms` and
/// `half_open_probes` below 1 count as 1, and a negative `open_ms` as 0. A
/// `failure_ratio` that is NaN never opens the circuit; one of 0 or less
/// opens it on the first failure once `min_requests` were counted.
pub fn BreakerConfig::new(
  failure_ratio~ : Double,
  min_requests~ : Int32,
  window_ms~ : Int32,
  open_ms~ : Int32,
  half_open_probes~ : Int32,
) -> BreakerConfig {
  {
    failure_ratio,
    min_requests: min_requests.max(1),
    window_ms: window_ms.max(1),
    open_ms: open_ms.max(0),
    half_open_probes: half_open_probes.max(1),
  }
}

///|
/// Where the circuit is.
#derive(Eq, Debug)
pub(all) enum BreakerPhase {
  /// Requests pass and their outcomes are counted in the window that
  /// started at `window_start_ms`.
  Closed(window_start_ms~ : Int64, requests~ : Int32, failures~ : Int32)
  /// Requests are refused until `open_ms` after `opened_at_ms`.
  Open(opened_at_ms~ : Int64)
  /// `probes` requests are in flight; their outcome closes or reopens it.
  HalfOpen(probes~ : Int32)
}

///|
/// One origin's breaker. `generation` changes with every change of phase,
/// so an outcome reported for a request let through in an earlier phase is
/// ignored.
#derive(Eq, Debug)
pub(all) struct BreakerState {
  phase : BreakerPhase
  generation : Int64
}

///|
/// What `admit` decided for one request. A `Pass` or `Probe` must be given
/// back to `record` exactly once, with the request's outcome.
#derive(Eq, Debug)
pub(all) enum BreakerTicket {
  /// Sent while closed; its outcome is counted in the window.
  Pass(generation~ : Int64)
  /// Sent while half-open; its outcome closes or reopens the circuit.
  Probe(generation~ : Int64)
  /// Refused: the circuit is open, or every probe slot is taken.
  Reject
}

///|
/// The outcome of a request let through.
#derive(Eq, Debug)
pub(all) enum BreakerOutcome {
  /// The origin answered in a way that says it is healthy.
  Success
  /// The origin failed or did not answer.
  Failure
  /// Nothing was learned about the origin (the request was cancelled or
  /// refused locally); a probe gives its slot back.
  Neutral
}

///|
/// A closed circuit whose first window starts at `now`.
pub fn BreakerState::new(now~ : Int64) -> BreakerState {
  {
    phase: Closed(window_start_ms=now, requests=0, failures=0),
    generation: 0L,
  }
}

///|
/// Decides whether one request may be sent at `now`. An open circuit whose
/// `open_ms` has passed turns half-open with this request as its first
/// probe; a clock that went back before `opened_at_ms` restarts the open
/// time from `now`.
pub fn BreakerState::admit(
  self : BreakerState,
  config : BreakerConfig,
  now~ : Int64,
) -> (BreakerState, BreakerTicket) {
  match self.phase {
    Closed(..) => (self, Pass(generation=self.generation))
    Open(opened_at_ms~) if now < opened_at_ms =>
      ({ ..self, phase: Open(opened_at_ms=now), }, Reject)
    Open(opened_at_ms~) if now - opened_at_ms < config.open_ms.to_int64() =>
      (self, Reject)
    Open(_) => {
      let generation = self.generation + 1L
      ({ phase: HalfOpen(probes=1), generation, }, Probe(generation~))
    }
    HalfOpen(probes~) if probes < config.half_open_probes =>
      (
        { ..self, phase: HalfOpen(probes=probes + 1), },
        Probe(generation=self.generation),
      )
    HalfOpen(_) => (self, Reject)
  }
}

///|
/// Applies the outcome of a request `admit` let through. A ticket from an
/// earlier generation, or a `Reject`, changes nothing.
///
/// While closed, a window older than `window_ms` (or one that starts after
/// `now`) is replaced by a fresh one starting at `now` first; a `Neutral`
/// outcome is not counted. The circuit opens at `now` when the window holds
/// at least `min_requests` requests, at least one failure, and failures of
/// at least `failure_ratio` of them. While half-open, a successful probe
/// closes the circuit with a fresh window, a failed one opens it again, and
/// a neutral one frees its slot.
pub fn BreakerState::record(
  self : BreakerState,
  config : BreakerConfig,
  ticket : BreakerTicket,
  outcome : BreakerOutcome,
  now~ : Int64,
) -> BreakerState {
  match (ticket, self.phase) {
    (Pass(generation~), Closed(window_start_ms~, requests~, failures~)) if generation ==
      self.generation => {
      let (start, requests, failures) = if now < window_start_ms ||
        now - window_start_ms >= config.window_ms.to_int64() {
        (now, 0, 0)
      } else {
        (window_start_ms, requests, failures)
      }
      let (requests, failures) = match outcome {
        Success => (requests + 1, failures)
        Failure => (requests + 1, failures + 1)
        Neutral => (requests, failures)
      }
      if failures > 0 &&
        requests >= config.min_requests &&
        failures.to_double() >= config.failure_ratio * requests.to_double() {
        { phase: Open(opened_at_ms=now), generation: self.generation + 1L, }
      } else {
        { ..self, phase: Closed(window_start_ms=start, requests~, failures~), }
      }
    }
    (Probe(generation~), HalfOpen(probes~)) if generation == self.generation =>
      match outcome {
        Success =>
          {
            phase: Closed(window_start_ms=now, requests=0, failures=0),
            generation: self.generation + 1L,
          }
        Failure =>
          { phase: Open(opened_at_ms=now), generation: self.generation + 1L, }
        Neutral => { ..self, phase: HalfOpen(probes=(probes - 1).max(0)), }
      }
    _ => self
  }
}

///|
pub extend BreakerPhase with Eq::{equal, not_equal}

///|
pub extend BreakerPhase with @debug.Debug::{to_repr}

///|
pub extend BreakerState with Eq::{equal, not_equal}

///|
pub extend BreakerState with @debug.Debug::{to_repr}

///|
pub extend BreakerTicket with Eq::{equal, not_equal}

///|
pub extend BreakerTicket with @debug.Debug::{to_repr}

///|
pub extend BreakerOutcome with Eq::{equal, not_equal}

///|
pub extend BreakerOutcome with @debug.Debug::{to_repr}
