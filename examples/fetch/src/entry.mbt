///|
let adapter : (@fetch.JsRequest, @fetch.JsBackground) -> @fetch.JsPromise = @fetch.fetch_handler(request => {
    @model.Response::new(200, body=request.body)
  },
)

///|
/// Exported host entry for a bounded streaming echo.
pub fn fetch(
  request : @fetch.JsRequest,
  background : @fetch.JsBackground,
) -> @fetch.JsPromise {
  adapter(request, background)
}

///|
/// Workers entry associating the host environment before dispatch.
pub fn fetch_with_env(
  request : @fetch.JsRequest,
  background : @fetch.JsBackground,
  env : @fetch.JsEnv,
) -> @fetch.JsPromise {
  adapter(@fetch.with_env(request, env), background)
}

///|
/// Browser client example; the backend and response are owned by this call.
pub fn get_text(url : String) -> @js_async.Promise[String] {
  @js_async.Promise::from_async(() => {
    let backend = @backend.AsyncBackend::new()
    defer backend.close()
    let response = backend.send(
      @model.Request::get(url),
      @client.RequestOptions::default(),
    )
    defer response.close()
    @utf8.decode(@client.read_body(response.body, 1048576))
  })
}
