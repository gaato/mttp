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
  default_decision : @retry.Decision
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
  default_decision~ : @retry.Decision = Stop(NotRetryable),
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
    default_decision,
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
/// A typed value or transport failure offered before any stream handoff.
pub(all) enum AttemptResult[T] {
  /// A complete buffered value with actual response metadata.
  Buffered(Reply[T])
  /// A selected stream consumer that has not started.
  StreamReady(@model.ResponseHead)
  /// A raised transport failure, distinct from response error values.
  TransportFailure(@model.TransportError)
}

///|
/// Projects HTTP facts for a generic retry rule without inspecting T.
pub fn[T] AttemptResult::http_outcome(
  self : AttemptResult[T],
) -> @retry.AttemptOutcome {
  match self {
    Buffered(reply) =>
      @retry.Response(status=reply.status, headers=reply.headers)
    StreamReady(head) =>
      @retry.Response(status=head.status, headers=head.headers)
    TransportFailure(error) => @retry.Failure(error)
  }
}

///|
/// Applies pure HTTP retry data to a snapshot.
pub fn RetryPolicy::decide(
  self : RetryPolicy,
  outcome : @retry.AttemptOutcome,
  context : RetryContext,
) -> @retry.Decision {
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
