///|
/// Minimal stand-in for gaato/http/retry, ported (not moved verbatim):
/// HttpError -> TransportError, @http.Request -> @model.Request,
/// Outcome -> AttemptOutcome.
#non_exhaustive
pub(all) enum StopReason {
  Exhausted
  NotRetryable
  MethodNotAllowed
  NotReplayable
} derive(Eq, Debug)

///|
pub(all) enum Decision {
  Wait(Int)
  Stop(StopReason)
} derive(Eq, Debug)

///|
pub(all) enum AttemptOutcome {
  Response(status~ : Int, headers~ : @model.Headers)
  Failure(@model.TransportError)
} derive(Debug)

///|
pub(all) struct RetryRule {
  max_retries : Int
  statuses : Array[Int]
  unsent_failures : Bool
  base_delay_ms : Int
} derive(Eq, Debug)

///|
pub fn RetryRule::never() -> RetryRule {
  { max_retries: 0, statuses: [], unsent_failures: false, base_delay_ms: 0 }
}

///|
pub fn RetryRule::decide(
  self : RetryRule,
  outcome : AttemptOutcome,
  request : @model.Request,
  attempt~ : Int,
  random~ : Double,
  replayable? : Bool,
) -> Decision {
  if attempt >= self.max_retries {
    return Stop(Exhausted)
  }
  let replayable = replayable.unwrap_or(request.body.is_replayable())
  if !replayable {
    return Stop(NotReplayable)
  }
  let retryable = match outcome {
    Response(status~, ..) => self.statuses.contains(status)
    Failure(e) => self.unsent_failures && e.is_unsent()
  }
  if !retryable {
    return Stop(NotRetryable)
  }
  if !@model.is_idempotent(request) {
    return Stop(MethodNotAllowed)
  }
  let base = self.base_delay_ms * (1 << attempt)
  Wait(base + (random * base.to_double()).to_int() / 2)
}
