///|
/// Creates a ready client with the platform backend, clock and deadline timer.
/// Redirects are followed; retries are disabled unless a policy is supplied.
/// The caller owns this client's lifetime and closes it when finished.
pub fn new_client(
  base_url~ : String = "",
  headers~ : @model.Headers = @model.Headers::empty(),
  options~ : @client.RequestOptions = @client.RequestOptions::default(),
  retry~ : @client.RetryPolicy = @client.RetryPolicy::none(),
  limiter~ : &@client.RateLimiter = @client.NoLimiter::new(),
  total_ms? : Int32,
  observer~ : (@client.Attempt) -> Unit = _ => (),
) -> @client.Client {
  let clock = @runtime.AsyncClock::new()
  @client.Client::new(
    @client.FollowRedirects::new(@backend.AsyncBackend::new()),
    clock,
    base_url~,
    headers~,
    options~,
    retry~,
    limiter~,
    total_ms?,
    observer~,
    timer=@runtime.ClockTimer::new(clock~),
  )
}
