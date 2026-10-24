///|
extern "js" fn new_request(url : String, meth : String, body : String) -> JsRequest =
  #| (url, method, body) => new Request(url, { method, body, headers: [["cookie", "a=1"], ["x-y", "z"]] })

///|
extern "js" fn as_any_promise(p : JsPromise) -> @js_async.Promise[JsAny] = "(p) => p"

///|
extern "js" fn resp_status(r : JsAny) -> Int = "(r) => r.status"

///|
extern "js" fn resp_text(r : JsAny) -> @js_async.Promise[String] = "(r) => r.text()"

///|
extern "js" fn resp_set_cookie(r : JsAny) -> String = "(r) => r.headers.getSetCookie().join('|')"

///|
async test "fetch_handler round trip under node" {
  let h = fetch_handler(async fn(req) noraise {
    let body = match req.body {
      Bytes(b) => @utf8.decode_lossy(b)
      _ => ""
    }
    Respond({
      status: 201,
      headers: @model.Headers::of([("set-cookie", "a=1"), ("set-cookie", "b=2")]),
      body: Bytes(@utf8.encode("\{req.meth} \{req.url} \{req.headers.get("x-y").unwrap_or("-")} \{body}")),
      close_connection: false,
    })
  })
  let resp = as_any_promise(h(new_request("http://w.test/p?q=1", "POST", "hi"))).wait()
  inspect(resp_status(resp), content="201")
  inspect(resp_text(resp).wait(), content="POST http://w.test/p?q=1 z hi")
  inspect(resp_set_cookie(resp), content="a=1|b=2")
}
