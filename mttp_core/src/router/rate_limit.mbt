///|
/// Per-process exact sliding window, shared by users of this Middleware.
/// Values <= 0 are clamped to 1. Keys are LRU-bounded; evicted keys start afresh.
/// None keys bypass both accounting and response headers.
pub fn rate_limit(
  key~ : (@mttp_core.Request) -> String?,
  limit~ : Int32,
  window_ms~ : Int32,
  clock~ : &@rt.Clock,
  max_keys~ : Int32 = 10_000,
) -> Middleware {
  let limit = limit.max(1)
  let window_ms = window_ms.max(1)
  let max_keys = max_keys.max(1)
  let states : Map[String, @window.Sliding] = Map([])
  let policy = rate_field([("q", limit.to_int64()), ("w", seconds(window_ms))])
  (request, next) => {
    guard key(request) is Some(k) else { return next(request) }
    let decision = @window.sliding_step(
      clock.now_unix_ms(),
      limit~,
      window_ms~,
      states.get(k),
    )
    let (state, remaining, reset, response) = match decision {
      Admit(state, remaining~, reset_ms~) => (state, remaining, reset_ms, None)
      Wait(state, delay) =>
        (state, 0, delay, Some(problem(429, "Too Many Requests")))
    }
    states.remove(k)
    if states.length() >= max_keys {
      if states.iter().next() is Some((oldest, _)) {
        states.remove(oldest)
      }
    }
    states[k] = state
    let response = match response {
      Some(response) =>
        {
          ..response,
          headers: response.headers.set(
            "retry-after",
            seconds(reset).to_string(),
          ),
        }
      None => next(request)
    }
    {
      ..response,
      headers: response.headers
      .set("ratelimit-policy", policy)
      .set(
        "ratelimit",
        rate_field([("r", remaining.to_int64()), ("t", seconds(reset))]),
      ),
    }
  }
}

///|
fn seconds(ms : Int32) -> Int64 {
  (ms.to_int64() + 999L) / 1000L
}

///|
fn rate_field(params : Array[(String, Int64)]) -> String {
  @sf.serialize_list([
    @sf.Item({
      value: @sf.String("default"),
      params: params.map(p => (p.0, @sf.Integer(p.1))),
    }),
  ]).unwrap()
}
