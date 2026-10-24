///|
let app : @model.Handler = async fn(req) noraise {
  Respond({
    status: 200,
    headers: @model.Headers::empty(),
    body: Bytes(@utf8.encode("hi \{req.url}")),
    close_connection: false,
  })
}

///|
let handler : (@fetch.JsRequest) -> @fetch.JsPromise = @fetch.fetch_handler(app)

///|
pub fn fetch(req : @fetch.JsRequest) -> @fetch.JsPromise {
  handler(req)
}
