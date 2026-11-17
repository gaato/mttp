///|
/// The shared definition supplies both request routing and the typed client.
pub let hello : @endpoint.Endpoint[
  Unit,
  String,
  @endpoint.NoError,
  String,
  @client.Buffered,
] = @endpoint.endpoint
  .get("/hello/{name}")
  .input(@endpoint.path("name", @schema.string))
  .output(@endpoint.json_out(@schema.jstring.body()))
  .operation_id("hello")

///|
/// Builds the Router independently of the Web Request host for testing.
pub fn application() -> @router.Router {
  @router.Router::must(
    [hello.serve_public(name => Ok("Hello, \{name}"))],
    clock=@mttp.clock(),
    timer=@mttp.timer(),
  )
}

///|
let app : @router.Router = application()

///|
let adapter : (@fetch.JsRequest, @fetch.JsBackground) -> @fetch.JsPromise = @fetch.fetch_handler(
  app.handler(),
)

///|
/// Associates the Workers bindings and background scheduler with the request.
pub fn fetch_with_env(
  request : @fetch.JsRequest,
  background : @fetch.JsBackground,
  env : @fetch.JsEnv,
) -> @fetch.JsPromise {
  adapter(@fetch.with_env(request, env), background)
}
