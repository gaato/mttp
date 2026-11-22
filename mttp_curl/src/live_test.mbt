// Live exchanges with public servers, for scripts/gates.sh curl-live only:
// they need the internet and, for HTTP/3, a libcurl built with it, so they
// run when MTTP_CURL_LIVE is set and return at once otherwise.

///|
fn live() -> Bool {
  @env.get_env_var("MTTP_CURL_LIVE") is Some(_)
}

///|
async test "live: HTTP/2 to www.cloudflare.com" {
  guard live() else { return }
  let backend = @mttp_curl.CurlBackend::new()
  defer backend.close()
  let response = backend.send(
    @mttp_core.Request::get("https://www.cloudflare.com/cdn-cgi/trace"),
    @mttp_core.SendOptions::default(),
  )
  assert_eq(response.status, 200)
  assert_eq(response.attributes.get(@mttp_core.protocol), Some("h2"))
  let body = @utf8.decode_lossy(response.body.read_all(max=1 << 20))
  assert_true(body.contains("http=http/2"))
}

///|
async test "live: HTTP/3 to cloudflare-quic.com, a whole uncompressed page" {
  guard live() else { return }
  guard @mttp_curl.CurlBackend::supports_http3() else {
    fail(
      "the linked libcurl has no HTTP/3: \{@mttp_curl.CurlBackend::libcurl_version()}",
    )
  }
  let backend = @mttp_curl.CurlBackend::new(http3=true)
  defer backend.close()
  let response = backend.send(
    @mttp_core.Request::get("https://cloudflare-quic.com/"),
    @mttp_core.SendOptions::default(),
  )
  assert_eq(response.status, 200)
  assert_eq(response.attributes.get(@mttp_core.protocol), Some("h3"))
  let body = @utf8.decode_lossy(response.body.read_all(max=4 << 20))
  assert_true(body.contains("</html>"))
}
