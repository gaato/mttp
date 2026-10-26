///|

///|
/// The time limits of an exchange, in milliseconds. `total` bounds the
/// exchange as a whole; the others bound one phase each, `read` the head and
/// every body read separately.
pub(all) struct Timeouts {
  total : Int32
  pool : Int32
  connect : Int32
  write : Int32
  read : Int32
}

///|
/// The limit of one phase.
pub fn Timeouts::of(self : Timeouts, phase : @model.Phase) -> Int32 {
  match phase {
    Pool => self.pool
    Dial => self.connect
    Write => self.write
    Head | Body | Unknown | @model.Phase::.. => self.read
  }
}

///|
/// How long a phase may run, and the limit to report when it runs out: the
/// phase's own `limit`, or the `remaining` time of an exchange limited to
/// `total` when that ends first. A nonpositive budget has already run out.
pub fn phase_budget(
  limit : Int32,
  total~ : Int32,
  remaining~ : Int64?,
) -> (Int32, Int32) {
  match remaining {
    Some(left) if left < limit.to_int64() => (left.max(0L).to_int(), total)
    _ => (limit, limit)
  }
}

///|
/// Runs the phases of one exchange against its limits on `clock`. `deadline`
/// is when the whole exchange must be done, or `None` for a stream's body
/// reads, which only the read limit bounds.
pub(all) struct PhaseTimer {
  timer : &@clock.Timer
  clock : &@clock.Clock
  limits : Timeouts
  deadline : Int64?
}

///|
/// A timer for an exchange starting now, due within `limits.total`.
pub fn PhaseTimer::exchange(
  clock : &@clock.Clock,
  limits : Timeouts,
  timer~ : &@clock.Timer,
) -> PhaseTimer {
  let now = clock.now_unix_ms()
  let duration = limits.total.max(0).to_int64()
  {
    clock,
    timer,
    limits,
    deadline: Some(
      if now > 9223372036854775807L - duration {
        9223372036854775807L
      } else {
        now + duration
      },
    ),
  }
}

///|
/// A timer for the body reads of a stream, each bounded by `limits.read`.
pub fn PhaseTimer::stream(
  clock : &@clock.Clock,
  limits : Timeouts,
  timer~ : &@clock.Timer,
) -> PhaseTimer {
  { clock, timer, limits, deadline: None, }
}

///|
/// Runs `f` as `phase`. A limit that runs out cancels `f` and raises
/// `Timeout` with the phase the platform can see and the limit that expired;
/// one already spent raises without starting `f`. Failures of `f` become an
/// `HttpError` through `failure`. Cancellation from outside is not an
/// `Error`, so it propagates untouched.
pub async fn[X] PhaseTimer::run(
  self : PhaseTimer,
  phase : @model.Phase,
  f : async () -> X,
) -> X raise @model.TransportError {
  let (budget, limit) = phase_budget(
    self.limits.of(phase),
    total=self.limits.total,
    remaining=self.deadline.map(at => {
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
    }),
  )
  let expired = @model.TransportError(
    kind=Timeout(ms=limit),
    phase~,
    detail="phase timeout",
  )
  if budget <= 0 {
    raise expired
  }
  let outcome : Ref[Result[X, @model.TransportError]?] = Ref(None)
  let completed = self.timer.within(budget, () => {
    outcome.val = Some(Ok(f()) catch { error => Err(failure(phase, error)) })
  })
  if !completed {
    raise expired
  }
  match outcome.val {
    Some(Ok(value)) => value
    Some(Err(error)) => raise error
    None => raise expired
  }
}
