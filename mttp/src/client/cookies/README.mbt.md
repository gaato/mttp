# gaato/mttp/client/cookies

`Cookies::new(inner, jar)` is an `http.Backend` wrapper. It attaches cookies
matching each request URL, preserves an explicit Cookie header, and stores
every Set-Cookie field as soon as a response head arrives, including error
and redirect responses. The response body stays owned by the caller.

Compose wrappers as `FollowRedirects(Cookies(inner, jar))`: Cookies then
sees each hop's URL, records its cookies before the next hop, and attaches
only those that match that hop. Keep retries above redirects. An outer
Cookies wrapper would see only the original request and final response.

The wrapper validates requests and SendOptions before I/O, passes options
unchanged, and closes request streams on refusal, completion, failure and
cancellation. Close is idempotent and closes the inner backend once; it leaves
the caller-owned jar available. The jar's clock and capacity limits are
configured in `gaato/mttp/cookie`; it does not enforce browser SameSite policy.

```mbt check
///|
test "wrap each redirect hop with cookies" {
  @driver.run_sync(() => {
    let jar = @cookie.CookieJar::new(@sim.FakeClock::new())
    let transport = @client.from_fn((_, _) => {
      @http.Response::new(
        200,
        headers=@http.Headers::of([("Set-Cookie", "sid=one; Path=/")]),
      )
    })
    let backend = @client.FollowRedirects::new(
      @cookies.Cookies::new(transport, jar),
    )
    defer backend.close()
    backend
    .send(
      @http.Request::get("https://example.test/"),
      @http.SendOptions::default(),
    )
    .close()
    assert_eq(jar.header_for("https://example.test/"), Some("sid=one"))
  })
}
```
