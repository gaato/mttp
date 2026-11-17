///|
pub fn routing_after() -> @mttp.Handler {
  request => {
    let url = @mttp.Url::parse(request.url) catch {
      _ => return @mttp.Response::new(400)
    }
    match (request.meth, url.path) {
      (Get, "/hello") => handler_after(request)
      (Get, "/json") =>
        @mttp.Response::new(200, body=Bytes(b"{\"name\":\"Ada\"}"))
      (Post, "/echo") => body_after(request)
      (Get, "/stream") => response_stream_after(request)
      _ => @mttp.Response::new(404)
    }
  }
}
