///|
/// Loopback forward proxy for the external cache-tests suite. h1server
/// accepts absolute-form targets; HttpCache keys those absolute URLs.
async fn main {
  let cache = @httpcache.HttpCache::new(
    @backend.AsyncBackend::new(),
    clock=@runtime.AsyncClock::new(),
  )
  defer cache.close()
  @server.serve(
    request => {
      let url = @mttp_core.Url::parse(request.url) catch {
        _ => return @mttp_core.Response::new(400)
      }
      if !url.is_absolute() || url.scheme != Some("http") {
        return @mttp_core.Response::new(400)
      }
      // Remove hop fields before forwarding; the engine derives Host and
      // request framing from the absolute URL and Body.
      let mut headers = request.headers
      for connection in headers.get_all("connection") {
        for name in connection.split(",") {
          headers = headers.remove(name.trim().to_owned())
        }
      }
      for
        name in [
          "connection", "proxy-connection", "keep-alive", "te", "trailer", "transfer-encoding",
          "upgrade", "host", "content-length",
        ] {
        headers = headers.remove(name)
      }
      cache.send({ ..request, headers, }, {
        timeout_ms: Some(30000),
        body: Stream(idle_ms=Some(30000)),
      }) catch {
        _ => @mttp_core.Response::new(502)
      }
    },
    addr="127.0.0.1:39080",
    auto_date=false,
    on_listen=_ => println("cache-tests proxy ready: 127.0.0.1:39080"),
  )
}
