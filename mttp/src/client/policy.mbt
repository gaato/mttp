///|
/// A retry rule of `gaato/mttp/client/retry`: which failures to retry, how long to
/// wait, and how often.
pub using @retry {type RetryRule}

///|
/// Response statuses a `RetryRule` retries, and for which methods (from
/// `gaato/mttp/client/retry`).
pub using @retry {type StatusRule}

///|
/// One status code or an inclusive range of them, in a `StatusRule` (from
/// `gaato/mttp/client/retry`).
pub using @retry {type StatusMatch}

///|
/// The request methods a retry is allowed for (from `gaato/mttp/client/retry`).
pub using @retry {type Methods}

///|
/// How a server-requested delay is read and bounded (from `gaato/mttp/client/retry`).
pub using @retry {type RetryAfter}

///|
/// A header a server-requested delay is read from (from `gaato/mttp/client/retry`).
pub using @retry {type RetryAfterSource}

///|
/// What to do with a server-requested delay over a limit (from
/// `gaato/mttp/client/retry`).
pub using @retry {type RetryAfterCap}

///|
/// Exponential backoff between attempts, in milliseconds (from
/// `gaato/mttp/client/retry`).
pub using @retry {type Backoff}

///|
/// How a backoff delay is spread so clients do not retry in lockstep (from
/// `gaato/mttp/client/retry`).
pub using @retry {type Jitter}

///|
/// The result of an attempt that did not succeed: a status or an `TransportError`
/// (from `gaato/mttp/client/retry`).
pub using @retry {type AttemptOutcome}

///|
/// What to do after a failed attempt: wait and retry, or stop (from
/// `gaato/mttp/client/retry`).
pub using @retry {type Decision}

///|
/// Why a `RetryRule` stopped retrying (from `gaato/mttp/client/retry`).
pub using @retry {type StopReason}

///|
/// A retry policy for `Client`: a `RetryRule` of `gaato/mttp/client/retry` applied
/// to HTTP outcome snapshots.
///
/// Start from a preset — `conservative()` (the default), `none()` — or from any rule with `from_rule`, and adjust it with
/// `with_max_retries`, `allow_non_idempotent` or a struct update of `rule`.
///
pub(all) struct RetryPolicy {
  /// What is retried, how long to wait, and when to stop.
  rule : RetryRule
} derive(Eq, Debug)

///|
/// Equality for retry policy values.
pub extend RetryPolicy with Eq::{equal, not_equal}

///|
/// Debug representation of retry policy values.
pub extend RetryPolicy with @debug.Debug::{to_repr}

///|
/// An opt-in conservative policy: two retries; 429 and 408, 409, 500, 502, 503 and 504 only for an idempotent request
/// (`@model.is_idempotent`, using the method or explicit replay_safe); a failure
/// that proves nothing was sent (`TransportError::is_unsent`) for any method,
/// and a proxy's refusal only when its status is one of those; a timeout or
/// network failure after sending only for an idempotent request.
///
/// The wait is `retry-after-ms`, else `Retry-After` (seconds or an HTTP
/// date), and a server that asks for more than 60 s is not retried;
/// `Retry-After: 0` retries at once. Without one, the backoff starts at
/// 500 ms, doubles up to 30 s and is spread by ±20 %.
///
pub fn RetryPolicy::conservative() -> RetryPolicy {
  {
    rule: {
      max_retries: 2,
      statuses: [
        { statuses: [Code(429)], methods: Idempotent, },
        {
          statuses: [
            Code(408),
            Code(409),
            Code(500),
            Code(502),
            Code(503),
            Code(504),
          ],
          methods: Idempotent,
        },
      ],
      sent_failures: Idempotent,
      unsent_failures: true,
      override_header: None,
      retry_after: {
        source: MsThenHeader,
        cap: StopAbove(60000),
        zero_means_backoff: false,
      },
      backoff: {
        base_ms: 500,
        max_ms: 30000,
        jitter: Proportional(lo=800, hi=1200),
      },
    },
  }
}

///|
/// `conservative()`.
pub fn RetryPolicy::default() -> RetryPolicy {
  RetryPolicy::conservative()
}

///|
/// `conservative()` without retries.
pub fn RetryPolicy::none() -> RetryPolicy {
  RetryPolicy::conservative().with_max_retries(0)
}

///|
/// A policy applying `rule` as it is.
pub fn RetryPolicy::from_rule(rule : RetryRule) -> RetryPolicy {
  { rule, }
}

///|
/// This policy with `max_retries` retries after the first attempt.
pub fn RetryPolicy::with_max_retries(
  self : RetryPolicy,
  max_retries : Int32,
) -> RetryPolicy {
  { rule: { ..self.rule, max_retries, }, }
}

///|
/// This policy with every `Idempotent` method set widened to `Any`, in its
/// status rules and for failures after sending: what `retry_non_idempotent:
/// true` did before 0.7.0. A retried POST may then run twice.
///
pub fn RetryPolicy::allow_non_idempotent(self : RetryPolicy) -> RetryPolicy {
  let widen = (methods : Methods) => {
    match methods {
      Idempotent => Methods::Any
      methods => methods
    }
  }
  {
    rule: {
      ..self.rule,
      statuses: self.rule.statuses.map(rule => {
        ..rule,
        methods: widen(rule.methods),
      }),
      sent_failures: widen(self.rule.sent_failures),
    },
  }
}

///|
