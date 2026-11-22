// What `SendOptions` promise for one attempt, for every Backend to keep the
// same way: the attempt deadline and per-phase limits (each phase checked
// when it starts, not only while it waits), and the byte bound of a
// response body. gaato/mttp_core's HTTP/1 client runs on these; a Backend
// that hands the transport to something else (libcurl, a host's fetch)
// uses them to keep the contract its own transport does not know.

///|
/// Per-phase limits in milliseconds; `None` sets none. Head and Body share
/// the read limit.
#derive(Eq, @debug.Debug)
pub(all) struct PhaseLimits {
  pool : Int32?
  connect : Int32?
  write : Int32?
  read : Int32?
}

///|
/// No per-phase limit: only an attempt deadline, if any, bounds the phases.
pub fn PhaseLimits::none() -> PhaseLimits {
  { pool: None, connect: None, write: None, read: None, }
}

///|
/// The limit of `phase`: Head, Body and Unknown share the read limit.
pub fn PhaseLimits::of(self : PhaseLimits, phase : @mttp_core.Phase) -> Int32? {
  match phase {
    Pool => self.pool
    Dial => self.connect
    Write => self.write
    _ => self.read
  }
}

///|
/// How long a phase may run and the limit to report when it runs out: the
/// phase's own `limit`, or the `remaining` time of an attempt limited to
/// `total` when that ends first (a tie reports the phase's own). `None`
/// when neither applies. A nonpositive budget has already run out.
fn phase_budget(
  limit : Int32?,
  total~ : Int32,
  remaining~ : Int64?,
) -> (Int32, Int32)? {
  match (limit, remaining) {
    (Some(limit), Some(left)) if left < limit.to_int64() =>
      Some((left.max(0L).to_int(), total))
    (Some(limit), _) => Some((limit, limit))
    (None, Some(left)) => Some((left.max(0L).min(2147483647L).to_int(), total))
    (None, None) => None
  }
}

///|
/// `error` as a TransportError of `phase`: a TransportError keeps its kind
/// and its phase unless that is `Unknown`, and anything else is `Connect`
/// while dialling and `Network` otherwise. Cancellation is not an `Error`
/// and never reaches this. A Backend with errors of its own (a codec's)
/// passes `classify` to `AttemptTimer::new` and falls back to this.
pub fn failure(
  phase : @mttp_core.Phase,
  error : Error,
) -> @mttp_core.TransportError {
  match error {
    @mttp_core.TransportError(kind~, phase=Unknown, detail~) =>
      @mttp_core.TransportError(kind~, phase~, detail~)
    @mttp_core.TransportError(..) as error => error
    _ =>
      @mttp_core.TransportError(
        kind=if phase == Dial { Connect } else { Network },
        phase~,
        detail=error.to_string(),
      )
  }
}

///|
/// The phases of one attempt against the attempt deadline and per-phase
/// limits, on a Clock and Timer port.
pub struct AttemptTimer {
  priv timer : &@rt.Timer
  priv clock : &@rt.Clock
  priv limits : PhaseLimits
  /// The attempt deadline's length, reported when it runs out.
  priv total : Int32
  /// When the attempt must be done, or `None` when no deadline covers the
  /// phases this timer runs.
  priv deadline : Int64?
  priv classify : (@mttp_core.Phase, Error) -> @mttp_core.TransportError
}

///|
/// A timer for the phases of an attempt starting now and due within
/// `total` milliseconds (`SendOptions.timeout_ms`), or without a deadline
/// when `total` is `None`. `classify` turns a phase's failure into a
/// TransportError (default: `failure`).
pub fn AttemptTimer::new(
  clock : &@rt.Clock,
  timer : &@rt.Timer,
  total : Int32?,
  limits~ : PhaseLimits = PhaseLimits::none(),
  classify~ : (@mttp_core.Phase, Error) -> @mttp_core.TransportError = failure,
) -> AttemptTimer {
  let deadline = total.map(ms => {
    let now = clock.now_unix_ms()
    let duration = ms.max(0).to_int64()
    if now > 9223372036854775807L - duration {
      9223372036854775807L
    } else {
      now + duration
    }
  })
  { timer, clock, limits, total: total.unwrap_or(0), deadline, classify, }
}

///|
/// The Timer port this timer runs on, for waits of a Backend's own that
/// should never outlast `remaining`.
pub fn AttemptTimer::timer(self : AttemptTimer) -> &@rt.Timer {
  self.timer
}

///|
/// Milliseconds left before the attempt deadline, or `None` without one.
pub fn AttemptTimer::remaining(self : AttemptTimer) -> Int64? {
  self.deadline.map(at => {
    let now = self.clock.now_unix_ms()
    if at <= now {
      0L
    } else {
      let left = at - now
      if left < 0L {
        9223372036854775807L
      } else {
        left
      }
    }
  })
}

///|
/// Runs `f` as `phase`. A limit already spent raises `Timeout` in `phase`
/// before `f` starts, so a phase that would not wait (bytes already
/// buffered, an end already known) is bounded as one that would. A limit
/// that runs out while `f` runs cancels it and raises the same. Failures of
/// `f` become a TransportError of `phase` through `classify`. Cancellation
/// from outside is not an `Error`, so it propagates untouched.
pub async fn[X] AttemptTimer::run(
  self : AttemptTimer,
  phase : @mttp_core.Phase,
  f : async () -> X,
) -> X raise @mttp_core.TransportError {
  let remaining = self.remaining()
  guard phase_budget(self.limits.of(phase), total=self.total, remaining~)
    is Some((budget, limit)) else {
    return f() catch { error => raise (self.classify)(phase, error) }
  }
  let expired = @mttp_core.TransportError(
    kind=Timeout(ms=limit),
    phase~,
    detail="the limit of \{limit} ms ran out",
  )
  if budget <= 0 {
    raise expired
  }
  let mut outcome : Result[X, @mttp_core.TransportError]? = None
  let completed = self.timer.within(budget, () => {
    outcome = Some(
      Ok(f()) catch {
        error => Err((self.classify)(phase, error))
      },
    )
  })
  match outcome {
    Some(Ok(value)) if completed => value
    Some(Err(error)) if completed => raise error
    _ => raise expired
  }
}

///|
/// The timer for a response body under `timing`, as the Backend contract
/// gives it: with `Exchange` the attempt deadline covers the whole body, so
/// it is this timer; with `Stream` the deadline ended with the head and each
/// read waits at most `idle_ms` (and the read limit), so it is a timer
/// without a deadline. An unknown timing keeps this timer.
pub fn AttemptTimer::for_body(
  self : AttemptTimer,
  timing : @mttp_core.BodyTiming,
) -> AttemptTimer {
  match timing {
    Stream(idle_ms~) =>
      {
        ..self,
        limits: { ..self.limits, read: min_limit(idle_ms, self.limits.read), },
        total: 0,
        deadline: None,
      }
    Exchange(..) => self
    @mttp_core.BodyTiming::.. => self
  }
}

///|
/// The byte bound of a response body under `timing` and a Backend's own
/// `ceiling`: `Exchange(max_bytes)` takes the smaller of the two, `Stream`
/// the ceiling alone (the reader bounds decoded bytes).
pub fn body_limit(timing : @mttp_core.BodyTiming, ceiling? : Int32) -> Int32? {
  match timing {
    Exchange(max_bytes~) => min_limit(ceiling, Some(max_bytes))
    Stream(..) => ceiling
    @mttp_core.BodyTiming::.. => ceiling
  }
}

///|
fn min_limit(a : Int32?, b : Int32?) -> Int32? {
  match (a, b) {
    (Some(a), Some(b)) => Some(a.min(b))
    (Some(_), None) => a
    (None, _) => b
  }
}

///|
/// Counts the bytes of a response body against its bound: the piece that
/// would cross it is refused before it is delivered. Counting is in
/// `Int64`, and a piece is compared with what is left, so no bound up to
/// `Int` max can wrap.
pub struct BodyBudget {
  priv limit : Int32?
  priv mut count : Int64
}

///|
/// A budget of `limit` bytes, or none.
pub fn BodyBudget::new(limit : Int32?) -> BodyBudget {
  { limit, count: 0L, }
}

///|
/// Bytes admitted so far.
pub fn BodyBudget::count(self : BodyBudget) -> Int64 {
  self.count
}

///|
/// Refuses a body whose declared length (a Content-Length) is past the
/// bound before any of it is read.
pub fn BodyBudget::check_declared(
  self : BodyBudget,
  declared : Int64?,
) -> Unit raise @mttp_core.TransportError {
  if self.limit is Some(limit) &&
    declared is Some(length) &&
    length > limit.to_int64() {
    raise too_large(limit)
  }
}

///|
/// Admits a piece of `n` bytes, or raises `TooLarge(limit)` in phase Body
/// when it would cross the bound.
pub fn BodyBudget::admit(
  self : BodyBudget,
  n : Int32,
) -> Unit raise @mttp_core.TransportError {
  if self.limit is Some(limit) && n.to_int64() > limit.to_int64() - self.count {
    raise too_large(limit)
  }
  self.count += n.to_int64()
}

///|
fn too_large(limit : Int32) -> @mttp_core.TransportError {
  @mttp_core.TransportError(
    kind=TooLarge(limit~),
    phase=Body,
    detail="the response body exceeds \{limit} bytes",
  )
}
