// Identical source for both runtimes: only js_async's Promise is used, and it
// never appears in a public signature.

///|
#external
pub type JsRequest

///|
#external
pub type JsPromise

///|
#external
priv type JsAny

///|
extern "js" fn req_method(r : JsRequest) -> String = "(r) => r.method"

///|
extern "js" fn req_url(r : JsRequest) -> String = "(r) => r.url"

///|
extern "js" fn req_header_pairs(r : JsRequest) -> Array[String] =
  #| (r) => { const out = []; for (const [k, v] of r.headers) { out.push(k, v) } return out }

///|
extern "js" fn req_body(r : JsRequest) -> @js_async.Promise[JsAny] = "(r) => r.arrayBuffer()"

///|
extern "js" fn to_bytes(b : JsAny) -> Bytes =
  #| (b) => new Uint8Array(b)

///|
extern "js" fn make_response(status : Int, headers : Array[String], body : Bytes) -> JsAny =
  #| (status, h, body) => { const hs = new Headers(); for (let i = 0; i < h.length; i += 2) hs.append(h[i], h[i+1]); return new Response(status === 204 ? null : body, { status, headers: hs }) }

///|
fn[X] as_js_promise(p : @js_async.Promise[X]) -> JsPromise = "%identity"

///|
pub fn fetch_handler(
  handler : @model.Handler,
  max_body_bytes? : Int = 1048576,
) -> (JsRequest) -> JsPromise {
  fn(js_req) {
    as_js_promise(
      @js_async.Promise::from_async(async fn() {
        let body = to_bytes(req_body(js_req).wait())
        if body.length() > max_body_bytes {
          return make_response(413, [], b"")
        }
        let flat = req_header_pairs(js_req)
        let pairs = []
        for i = 0; i + 1 < flat.length(); i = i + 2 {
          pairs.push((flat[i], flat[i + 1]))
        }
        let outcome = handler({
          meth: req_method(js_req),
          url: req_url(js_req),
          headers: @model.Headers::of(pairs),
          body: Bytes(body),
        })
        match outcome {
          Respond(resp) => {
            let hs = []
            for p in resp.headers.iter() {
              hs.push(p.0)
              hs.push(p.1)
            }
            let out = match resp.body {
              Bytes(b) => b
              _ => b""
            }
            make_response(resp.status, hs, out)
          }
        }
      }),
    )
  }
}
