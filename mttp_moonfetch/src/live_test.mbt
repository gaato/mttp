// Live exchanges with public servers, for the canary only: they need the
// internet and a server that offers HTTP/2 and HTTP/3, so they run when
// MTTP_MOONFETCH_LIVE is set and return at once otherwise.

///|
fn live() -> Bool {
  @env.get_env_var("MTTP_MOONFETCH_LIVE") is Some(_)
}

///|
async test "live: HTTP/2 to cloudflare.com through mttp's Client" {
  guard live() else { return }
  let backend = @mttp_moonfetch.backend()
  let response = backend.send(
    @mttp.Request::get("https://www.cloudflare.com/robots.txt"),
    { ..@mttp.SendOptions::default(), timeout_ms: Some(30000), },
  )
  assert_eq(
    response.attributes.get(@mttp_moonfetch.http_version),
    Some("HTTP/2"),
  )
  assert_true(read_text(response).length() > 0)
  let api = @mttp_async.client(base_url="https://www.cloudflare.com", backend~)
  defer api.close()
  let reply = api.send(@mttp_async.get("/robots.txt"))
  assert_eq(reply.status, 200)
}

///|
async test "live: HTTP/3 to cloudflare-quic.com, a compressed body" {
  guard live() else { return }
  let backend = @mttp_moonfetch.backend(http3=true)
  defer backend.close()
  let response = backend.send(
    @mttp.Request::get("https://cloudflare-quic.com/"),
    { ..@mttp.SendOptions::default(), timeout_ms: Some(30000), },
  )
  assert_eq(
    response.attributes.get(@mttp_moonfetch.http_version),
    Some("HTTP/3"),
  )
  assert_true(read_text(response).length() > 0)
}

///|
/// moonfetch 0.1.8 fails to read a larger HTTP/3 body (this page uncompressed
/// ends with moonhttp/http2's Incomplete), which is why `backend()` leaves
/// HTTP/3 off. This test passes while that holds and fails once the body
/// reads whole, as the signal to turn HTTP/3 on by default.
async test "live: HTTP/3 uncompressed body still fails (moonfetch's known bug)" {
  guard live() else { return }
  let backend = @mttp_moonfetch.backend(http3=true)
  defer backend.close()
  let response = backend.send(
    @mttp.Request::get("https://cloudflare-quic.com/").header(
      "accept-encoding", "identity",
    ),
    { ..@mttp.SendOptions::default(), timeout_ms: Some(30000), },
  )
  assert_eq(
    response.attributes.get(@mttp_moonfetch.http_version),
    Some("HTTP/3"),
  )
  let length = read_text(response) catch {
    @mttp.TransportError(..) => return
    other => raise other
  }
  fail(
    "an uncompressed HTTP/3 body of \{length} characters read whole: moonfetch's HTTP/3 body bug looks fixed, so consider http3=true by default",
  )
}
