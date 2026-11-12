// What an app that does not use typed endpoints reaches through gaato/mttp
// alone: each name below is spelled `@mttp.`, and each is gaato/mttp_core's
// own, so values pass between the two modules unchanged.

///|
/// A body of fixed chunks, written with `@mttp.BodyStream` only.
struct Chunks {
  chunks : Array[Bytes]
  mut next : Int32
}

///|
impl @mttp.BodyStream for Chunks with fn read_some(self) {
  guard self.next < self.chunks.length() else { return None }
  self.next += 1
  Some(self.chunks[self.next - 1])
}

///|
impl @mttp.BodyStream for Chunks with fn close(_) {
  ()
}

///|
/// A backend written with `@mttp.Backend` and `@mttp.SendOptions` only.
struct Teapot {}

///|
impl @mttp.Backend for Teapot with fn send(_, _, _options : @mttp.SendOptions) {
  @mttp.Response::new(418)
}

///|
test "request attributes and their keys are reachable through gaato/mttp" {
  let user : @mttp.AttributeKey[String] = @mttp.AttributeKey::new("user")
  let attributes = @mttp.Attributes::empty()
    .put(@mttp.remote_addr, "192.0.2.1:50000")
    .put(@mttp.close_on_shutdown, true)
    .put(user, "ada")
  assert_eq(attributes.get(@mttp.remote_addr), Some("192.0.2.1:50000"))
  assert_eq(attributes.get(@mttp.close_on_shutdown), Some(true))
  assert_eq(attributes.get(user), Some("ada"))
  assert_true(attributes.get(@mttp.background) is None)
  // The keys are the core's: an attribute set through one module is read
  // through the other.
  assert_eq(attributes.get(@mttp_core.remote_addr), Some("192.0.2.1:50000"))
  let request = @mttp.Request::post("https://api.test/orders").attribute(
    @mttp.replay_safe, true,
  )
  assert_eq(request.attributes.get(@mttp_core.replay_safe), Some(true))
}

///|
test "handlers, URLs, stream bodies and backends are the core's types" {
  let handler : @mttp.Handler = _ => @mttp.Response::new(204)
  let core_handler : @mttp_core.Handler = handler
  ignore(core_handler)
  let url = @mttp.Url::parse("https://api.test/users?page=2")
  assert_eq(url.query_params(), [("page", "2")])
  let parsed : Result[@mttp.Url, @mttp.UrlError] = Ok(
    @mttp.Url::parse("http://[::1"),
  ) catch {
    error => Err(error)
  }
  assert_true(parsed is Err(Invalid(_)))
  let body = @mttp.StreamBody::new(Chunks::{ chunks: [b"ab", b"c"], next: 0, })
  let response = @mttp.Response::new(200, body=Stream(body))
  assert_eq(response.body.length(), None)
  let backend : &@mttp.Backend = Teapot::{ }
  let core_backend : &@mttp_core.Backend = backend
  ignore(core_backend)
}

///|
async test "read_bounded and a backend's send work through gaato/mttp" {
  let stream = Chunks::{ chunks: [b"ab", b"c"], next: 0, }
  assert_eq(@mttp.read_bounded(stream, 3), b"abc")
  let backend : &@mttp.Backend = Teapot::{ }
  let response = backend.send(
    @mttp.Request::get("http://local.test/"),
    @mttp.SendOptions::default(),
  )
  assert_eq(response.status, 418)
}
