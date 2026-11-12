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
///   idempotent request on 408, 409, 429, 500, 502, 503 or 504 or a network
///   failure, and of any request that was never sent, honouring
///   `Retry-After` (a server that asks to wait more than 60 s is not
///   retried); set it to `RetryPolicy::none()` to turn retries off.
/// - `retry_budget` (default `RetryBudget::new()`): retries stay within 20 %
///   of the last 10 s of requests plus 10 per second.
/// - `timeout_ms` (default 30 s) for each attempt, and `total_ms` (default
///   120 s) for the whole call, retries and their waits included.
/// - `redirect` (default `RedirectConfig::default()`): up to 10 hops, no
///   HTTPS-to-HTTP downgrade, credentials dropped across origins;
///   `RedirectConfig::none()` turns redirects off, and a request opts out
///   with `RequestPlan::follow_redirects(false)`.
/// - Responses are decompressed (gzip, deflate, br, zstd) and buffered
///   bodies are limited to 64 MiB after decoding (`max_body_bytes`).
/// - `cookies` (no jar by default): a `CookieJar` that stores every
///   response's `Set-Cookie` and sends matching cookies, on each redirect
///   hop too. The jar belongs to the caller, so several Clients may share
///   it and it outlives them:
///
/// ```mbt nocheck
/// let jar = @mttp_async.CookieJar::new(@mttp_async.clock())
///
/// let site = @mttp_async.client(cookies=jar)
/// ```
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
  cookies? : @cookie.CookieJar,
) -> @client.Client {
  let clock = system_clock()
  @client.Client::new(
    network(trust, config),
    clock,
    base_url~,
    headers~,
    timeout_ms~,
    max_body_bytes?,
    timer=@runtime.ClockTimer::new(clock~),
    retry~,
    retry_budget~,
    redirect~,
    cookies?,
    limiter?,
    total_ms~,
  )
}

///|
/// The real network as a `Backend`: HTTP/1.1 over TCP and TLS with
/// connection reuse and decompressed responses. It is only the I/O: the
/// `Client` built over it follows redirects, and keeps cookies when given a
/// jar, as `Client::new` does over any backend. Pass it, with `clock` and `timer`,
/// to a library that builds its own `Client`, such as an API SDK:
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
/// The libraries keep their own defaults (base URL, authentication, retries)
/// and follow redirects through `Client::new`; this only supplies the I/O.
/// Closing the library's Client closes the connections.
pub fn backend(
  trust~ : @trust.Trust = System,
  config? : @h1client.ClientConfig,
) -> &@mttp.Backend {
  network(trust, config)
}

///|
fn network(
  trust : @trust.Trust,
  config : @h1client.ClientConfig?,
) -> &@mttp.Backend {
  @backend.AsyncBackend::new(config?, trust~, clock=system_clock())
}

///|
fn system_clock() -> &@rt.Clock {
  @runtime.AsyncClock::new()
}

///|
/// The system's wall and monotonic clock, for a `Client` built by hand.
pub fn clock() -> &@rt.Clock {
  system_clock()
}

///|
/// Timers on core/async's event loop, which let a `Client` enforce its
/// per-attempt and total deadlines.
pub fn timer() -> &@rt.Timer {
  @runtime.ClockTimer::new(clock=system_clock())
}

///|
/// Signals on core/async's event loop, for the parts of `gaato/mttp` that wait
/// without doing I/O themselves, such as `@endpoint.EventStream::channel`.
pub fn coordination() -> &@rt.Coordination {
  @runtime.RuntimeCoordination::new()
}
