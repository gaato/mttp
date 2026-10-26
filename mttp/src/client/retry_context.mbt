///|
/// Inputs to a retry decision. Attempt zero is the initial exchange.
pub(all) struct RetryContext {
  request : @model.RequestHead
  idempotent : Bool
  bucket : String
  attempt : Int32
  random : Double
  now_unix_ms : Int64
  remaining_ms : Int64?
  replayable : Bool
}

///|
/// Creates a context, with midpoint jitter and no deadline by default.
pub fn RetryContext::new(
  request : @model.RequestHead,
  idempotent~ : Bool,
  replayable~ : Bool,
  attempt~ : Int32 = 0,
  bucket~ : String = "default",
  random~ : Double = 0.5,
  now_unix_ms~ : Int64 = 0L,
  remaining_ms? : Int64,
) -> RetryContext {
  {
    request,
    idempotent,
    bucket,
    attempt,
    random,
    now_unix_ms,
    remaining_ms,
    replayable,
  }
}

///|
/// Captures live request facts at the boundary before invoking a policy.
/// Later acquisition or closure of the body cannot change this snapshot.
pub fn RetryContext::capture(
  request : @model.Request,
  attempt~ : Int32 = 0,
  bucket~ : String = "default",
  random~ : Double = 0.5,
  now_unix_ms~ : Int64 = 0L,
  remaining_ms? : Int64,
  replayable? : Bool,
) -> RetryContext {
  RetryContext::new(
    request.head(),
    idempotent=@model.is_idempotent(request),
    replayable=replayable.unwrap_or_else(() => request.body.is_replayable()),
    attempt~,
    bucket~,
    random~,
    now_unix_ms~,
    remaining_ms?,
  )
}

///|
/// Decides whether any attempt error should cause a retry. Reader errors are
/// included; applications can interpret errors embedded in successful JSON.
pub(open) trait RetryDecider {
  fn decide(Self, Error, RetryContext) -> @retry.Decision
}

///|
/// Extracts a transport failure or rejected HTTP status for a retry rule.
/// Decoding and application errors need an application-specific decider.
pub fn outcome_of(error : Error) -> @retry.AttemptOutcome? {
  match error {
    @model.TransportError(..) as failure => Some(Failure(failure))
    UnexpectedStatus(head, ..) =>
      Some(Response(status=head.status, headers=head.headers))
    _ => None
  }
}

///|
/// Applies this policy to an attempt error.
pub extend RetryPolicy with RetryDecider::{decide}

///|
/// Uses the mature status, method, replayability, jitter and budget rules.
pub impl RetryDecider for RetryPolicy with fn decide(self, error, context) {
  guard outcome_of(error) is Some(outcome) else { return Stop(NotRetryable) }
  self.rule.decide(
    outcome,
    context.request,
    attempt=context.attempt,
    random=context.random,
    now_unix_ms=context.now_unix_ms,
    remaining_ms?=context.remaining_ms,
    replayable=context.replayable,
    idempotent=context.idempotent,
  )
}
