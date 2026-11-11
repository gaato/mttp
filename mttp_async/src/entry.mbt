///|
/// Runs `main` on moonbitlang/core/async's event loop and returns when it
/// and every task it started have finished. An app calls it from a plain
/// `fn main`, so it needs neither an import of core/async nor its
/// experimental opt-in:
///
/// ```mbt nocheck
/// fn main {
///   @mttp_async.run(async fn() { ... })
/// }
/// ```
pub fn run(main : async () -> Unit) -> Unit {
  @async.run_async_main(main)
}

///|
/// A Client over the real network with the defaults an API client wants:
///
/// - `retry` (default `RetryPolicy::conservative()`): up to two retries of an
///   idempotent request on 408, 409, 429 and 5xx or a network failure, and of
///   any request that was never sent, honouring `Retry-After`; set it to
///   `RetryPolicy::none()` to turn retries off.
/// - `retry_budget` (default `RetryBudget::new()`): retries stay within 20 %
///   of the last 10 s of requests plus 10 per second.
/// - `timeout_ms` (default 30 s) for each attempt, and `total_ms` (default
///   120 s) for the whole call, retries and their waits included.
/// - `redirect` (default `RedirectConfig::default()`): up to 10 hops, no
///   HTTPS-to-HTTP downgrade, credentials dropped across origins; a request
///   opts out with `RequestPlan::follow_redirects(false)`.
/// - Responses are decompressed (gzip, deflate, br, zstd) and buffered
///   bodies are limited to 64 MiB after decoding (`max_body_bytes`).
///
/// `base_url` is joined to each relative request target, `headers` are sent
/// with every request, `limiter` admits requests (no limit by default),
/// `trust` chooses the TLS roots and `config` tunes the connection pool.
/// Close the Client when done; that closes its connections.
pub fn client(
  base_url~ : String = "",
  headers~ : @mttp.Headers = @mttp.Headers::empty(),
  timeout_ms~ : Int32 = 30_000,
  total_ms~ : Int32 = 120_000,
  max_body_bytes? : Int32,
  retry~ : @client.RetryPolicy = @client.RetryPolicy::conservative(),
  retry_budget~ : @client.RetryBudget = @client.RetryBudget::new(),
  redirect~ : @client.RedirectConfig = @client.RedirectConfig::default(),
  limiter? : &@client.RateLimiter,
  trust~ : @trust.Trust = System,
  config? : @h1client.ClientConfig,
) -> @client.Client {
  let clock = clock()
  @client.Client::new(
    backend(redirect~, trust~, config?),
    clock,
    base_url~,
    headers~,
    timeout_ms~,
    max_body_bytes?,
    timer=timer(),
    retry~,
    retry_budget~,
    limiter?,
    total_ms~,
  )
}

///|
/// The real network as a `Backend`, as `client` uses it: HTTP/1.1 over TCP
/// and TLS with connection reuse, decompressed responses, and redirects
/// followed by `redirect`. Pass it, with `clock` and `timer`, to a library
/// that builds its own `Client`, such as an API SDK:
///
/// ```mbt nocheck
/// let claude = @anthropic.Anthropic::new(
///   api_key~,
///   @mttp_async.backend(),
///   @mttp_async.clock(),
///   timer=@mttp_async.timer(),
/// )
/// ```
///
/// The libraries keep their own defaults (base URL, authentication, retries);
/// this only supplies the I/O. Closing the library's Client closes the
/// connections.
pub fn backend(
  redirect~ : @client.RedirectConfig = @client.RedirectConfig::default(),
  trust~ : @trust.Trust = System,
  config? : @h1client.ClientConfig,
) -> &@mttp.Backend {
  @client.FollowRedirects::new(
    @backend.AsyncBackend::new(config?, trust~, clock=clock()),
    config=redirect,
  )
}

///|
/// The system's wall and monotonic clock, for a `Client` built by hand.
pub fn clock() -> &@rt.Clock {
  @runtime.AsyncClock::new()
}

///|
/// Timers on core/async's event loop, which let a `Client` enforce its
/// per-attempt and total deadlines.
pub fn timer() -> &@rt.Timer {
  @runtime.ClockTimer::new(clock=clock())
}

///|
/// Signals on core/async's event loop, for the parts of `gaato/mttp` that wait
/// without doing I/O themselves, such as `@endpoint.EventStream::channel`.
pub fn coordination() -> &@rt.Coordination {
  @runtime.RuntimeCoordination::new()
}
