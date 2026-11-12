///|
/// Waits until the earliest sleep on `clock` is due at `at` ms, then moves
/// the clock there. Every deadline in these tests is known exactly, because
/// each retry waits for the server's `Retry-After` rather than a jittered
/// backoff.
async fn advance_at(clock : @runtime.VirtualClock, at : Int64) -> Unit {
  clock.settle(until=() => clock.next_deadline() == Some(at))
  assert_true(clock.advance_to_next())
}

///|
/// Sends `request` through `api` in the background; the result lands in the
/// returned cell.
fn send_later(
  group : @async.TaskGroup,
  api : @mttp_async.Client,
  request : @client.ClientRequest[Result[String, @client.ResponseFailure]],
) -> Ref[Result[@client.Reply[Result[String, @client.ResponseFailure]], Error]?] {
  let result = Ref(None)
  group.spawn_bg(() => {
    result.val = Some(Ok(api.send(request)) catch { error => Err(error) })
  })
  result
}

///|
async test "client(backend=, clock=) retries a 503 with the default policy on virtual time" {
  let clock = @runtime.VirtualClock(start_ms=0L)
  let stub = @testing.BackendStub::new()
    .expect(
      _ => true,
      @testing.Canned::bytes(
        503,
        headers=@mttp.Headers::of([("retry-after", "1")]),
      ),
    )
    .expect(_ => true, @testing.Canned::bytes(200, body=b"ok"))
  let api = @mttp_async.client(
    base_url="https://api.test",
    backend=stub,
    clock~,
  )
  defer api.close()
  @async.with_task_group(group => {
    let result = send_later(group, api, @mttp_async.get("/users/1"))
    // The server's Retry-After of 1 s is honoured on the virtual clock.
    advance_at(clock, 1000L)
    clock.settle(until=() => result.val is Some(_))
    guard result.val is Some(Ok(reply)) else { fail("the call failed") }
    assert_eq(reply.status, 200)
    assert_eq(reply.body, Ok("ok"))
  })
  stub.verify()
  let sent = stub.sent()
  assert_eq(sent.length(), 2)
  // Each attempt got the default 30 s deadline.
  assert_eq(sent[0].options.timeout_ms, Some(30_000))
  assert_eq(clock.now_unix_ms(), 1000L)
}

///|
async test "client(backend=, clock=) applies the default 30 s attempt deadline" {
  let clock = @runtime.VirtualClock(start_ms=0L)
  let stub = @testing.BackendStub::new().when(
    _ => true,
    Factory((_, _) => {
      clock.sleep(1_000_000)
      @mttp.Response::new(200)
    }),
  )
  let api = @mttp_async.client(
    base_url="https://api.test",
    backend=stub,
    clock~,
    retry=@mttp_async.RetryPolicy::none(),
  )
  defer api.close()
  @async.with_task_group(group => {
    let result = send_later(group, api, @mttp_async.get("/slow"))
    advance_at(clock, 30_000L)
    clock.settle(until=() => result.val is Some(_))
    guard result.val is Some(Err(@mttp.TransportError(kind~, ..))) else {
      fail("expected a transport failure")
    }
    assert_eq(kind, Timeout(ms=30_000))
  })
}

///|
async test "client(backend=, clock=) stops the whole call at the default 120 s" {
  let clock = @runtime.VirtualClock(start_ms=0L)
  let calls = Ref(0)
  let stub = @testing.BackendStub::new().when(
    _ => true,
    Factory((_, _) => {
      calls.val += 1
      match calls.val {
        1 => {
          clock.sleep(10_000)
          @mttp.Response::new(
            503,
            headers=@mttp.Headers::of([("retry-after", "50")]),
          )
        }
        2 => {
          clock.sleep(25_000)
          @mttp.Response::new(
            503,
            headers=@mttp.Headers::of([("retry-after", "20")]),
          )
        }
        _ => {
          clock.sleep(1_000_000)
          @mttp.Response::new(200)
        }
      }
    }),
  )
  let api = @mttp_async.client(
    base_url="https://api.test",
    backend=stub,
    clock~,
  )
  defer api.close()
  @async.with_task_group(group => {
    let result = send_later(group, api, @mttp_async.get("/busy"))
    advance_at(clock, 10_000L) // the first answer, 503: wait 50 s
    advance_at(clock, 60_000L) // the second attempt
    advance_at(clock, 85_000L) // its answer, 503: wait 20 s
    advance_at(clock, 105_000L) // the third attempt, which hangs
    // The call's deadline is due at 120 s already; let the third attempt
    // start (its deadline, the call's and its sleep) before reaching it.
    clock.settle(until=() => clock.pending().length() == 3)
    assert_eq(calls.val, 3)
    advance_at(clock, 120_000L)
    clock.settle(until=() => result.val is Some(_))
    guard result.val is Some(Err(@mttp.TransportError(kind~, ..))) else {
      fail("expected a transport failure")
    }
    assert_eq(kind, Timeout(ms=120_000))
  })
  assert_eq(calls.val, 3)
}

///|
async test "client(backend=, cookies=) follows a redirect and keeps its cookie over a stub" {
  let stub = @testing.BackendStub::new()
    .when(
      request => request.url.has_suffix("/login"),
      @testing.Canned::bytes(
        302,
        headers=@mttp.Headers::of([
          ("location", "/home"),
          ("set-cookie", "session=abc; Path=/"),
        ]),
      ),
    )
    .when(_ => true, @testing.Canned::bytes(200))
  let jar = @mttp_async.CookieJar::new(@runtime.VirtualClock())
  let site = @mttp_async.client(
    base_url="https://shop.test",
    backend=stub,
    clock=@runtime.VirtualClock(),
    cookies=jar,
  )
  defer site.close()
  let login = site.send(@mttp_async.get("/login"))
  assert_eq(login.status, 200)
  assert_eq(
    login.attributes.get(@client.final_url),
    Some("https://shop.test/home"),
  )
  assert_eq(site.send(@mttp_async.get("/me")).status, 200)
  assert_eq(
    stub.sent().map(r => (r.request.url, r.request.headers.get("cookie"))),
    [
      ("https://shop.test/login", None),
      ("https://shop.test/home", Some("session=abc")),
      ("https://shop.test/me", Some("session=abc")),
    ],
  )
  // A request still opts out of redirects.
  let raw = site.send(@mttp_async.get("/login").follow_redirects(false))
  assert_eq(raw.status, 302)
}
