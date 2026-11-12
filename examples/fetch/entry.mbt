///|
let adapter : (@fetch.JsRequest, @fetch.JsBackground) -> @fetch.JsPromise = @fetch.fetch_handler(request => {
    @mttp_core.Response::new(200, body=request.body)
  },
)

///|
/// Exported bounded streaming echo for Web Request hosts.
pub fn fetch(
  request : @fetch.JsRequest,
  background : @fetch.JsBackground,
) -> @fetch.JsPromise {
  adapter(request, background)
}

///|
/// Workers entry associating host bindings with this request.
pub fn fetch_with_env(
  request : @fetch.JsRequest,
  background : @fetch.JsBackground,
  env : @fetch.JsEnv,
) -> @fetch.JsPromise {
  adapter(@fetch.with_env(request, env), background)
}
