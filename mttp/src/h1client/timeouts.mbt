// Deadlines of one exchange. Each phase has its own limit from the
// ClientConfig; the attempt deadline (`SendOptions.timeout_ms`) caps every
// phase it covers with the time left. Whichever ends first is the one a
// `Timeout(ms)` reports.

///|
/// The per-phase limits in milliseconds; `None` sets none.
priv struct Timeouts {
  pool : Int32?
  connect : Int32?
  write : Int32?
  read : Int32?
}

///|
/// The limit of `phase`: Head and Body share the read limit.
fn Timeouts::of(self : Timeouts, phase : @mttp.Phase) -> Int32? {
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
/// Runs the phases of one exchange against its limits on `clock`.
priv struct PhaseTimer {
  timer : &@rt.Timer
  clock : &@rt.Clock
  limits : Timeouts
  /// The attempt deadline's length, reported when it runs out.
  total : Int32
  /// When the attempt must be done, or `None` when no deadline covers the
  /// phases this timer runs.
  deadline : Int64?
}

///|
/// A timer for phases of an attempt starting now and due within `total`
/// milliseconds, or without a deadline when `total` is `None`.
fn PhaseTimer::new(
  clock : &@rt.Clock,
  timer : &@rt.Timer,
  limits : Timeouts,
  total : Int32?,
) -> PhaseTimer {
  let deadline = total.map(ms => {
    let now = clock.now_unix_ms()
    let duration = ms.max(0).to_int64()
    if now > 9223372036854775807L - duration {
      9223372036854775807L
    } else {
      now + duration
    }
  })
  { timer, clock, limits, total: total.unwrap_or(0), deadline, }
}

///|
/// Milliseconds left before the attempt deadline, or `None` without one.
fn PhaseTimer::remaining(self : PhaseTimer) -> Int64? {
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
/// Runs `f` as `phase`. A limit that runs out cancels `f` and raises
/// `Timeout` in `phase` with the limit that expired; one already spent
/// raises without starting `f`. Failures of `f` become a TransportError of
/// `phase` through `failure`. Cancellation from outside is not an `Error`,
/// so it propagates untouched.
async fn[X] PhaseTimer::run(
  self : PhaseTimer,
  phase : @mttp.Phase,
  f : async () -> X,
) -> X raise @mttp.TransportError {
  let remaining = self.remaining()
  guard phase_budget(self.limits.of(phase), total=self.total, remaining~)
    is Some((budget, limit)) else {
    return f() catch { error => raise failure(phase, error) }
  }
  let expired = @mttp.TransportError(
    kind=Timeout(ms=limit),
    phase~,
    detail="the limit of \{limit} ms ran out",
  )
  if budget <= 0 {
    raise expired
  }
  let mut outcome : Result[X, @mttp.TransportError]? = None
  let completed = self.timer.within(budget, () => {
    outcome = Some(Ok(f()) catch { error => Err(failure(phase, error)) })
  })
  match outcome {
    Some(Ok(value)) if completed => value
    Some(Err(error)) if completed => raise error
    _ => raise expired
  }
}
