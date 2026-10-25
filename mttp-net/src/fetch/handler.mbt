///|
async fn empty_response(status : Int32, request : JsRequest) -> WebResponse {
  response(
    status,
    [],
    true,
    _ => @js_async.Promise::from_async(() => { done: true, value: b"", }),
    () => (),
    request.signal(),
  ).wait()
}

///|
/// Builds a host-neutral Web Request adapter. The background callback is
/// invoked once, synchronously at entry. Work registered through the request
/// attribute outlives response completion; register it before the handler returns.
/// Request bodies default to a 1 MiB ceiling and are delivered in 64 KiB pieces.
pub fn fetch_handler(
  handler : @model.Handler,
  max_body_bytes~ : Int32 = 1048576,
) -> (JsRequest, JsBackground) -> JsPromise {
  (request, register) => {
    let background = Background::new(register)
    if request.aborted() {
      background.finish()
      return request.reject_aborted()
    }
    let accepting = Ref(true)
    exported(
      @js_async.Promise::from_async(abort_signal=request.signal(), () => {
        defer background.finish()
        defer {
          accepting.val = false
        }
        if max_body_bytes < 0 {
          return empty_response(500, request)
        }
        let reader = request.reader().wait()
        let input = Input::{
          reader,
          limit: max_body_bytes,
          count: 0,
          pending: b"",
          offset: 0,
          closed: false,
          failure: None,
          declared: None,
        }
        let mut transferred = false
        defer (if !transferred { input.close() })
        let mut headers = @model.Headers::empty()
        for pair in request.headers() {
          headers = headers.add(pair[0], pair[1])
        }
        let framing = @h1.request_framing(headers) catch {
          _ => return empty_response(400, request)
        }
        if framing is Length(n) && n > max_body_bytes.to_int64() {
          return empty_response(413, request)
        }
        input.declared = match framing {
          Length(n) => Some(n)
          _ => None
        }
        let schedule = (work : async () -> Unit) => {
          if accepting.val {
            background.add(@js_async.Promise::from_async(work))
          }
        }
        let attributes = @model.Attributes::empty().put(
          @model.background, schedule,
        )
        let attributes = if environments.has(request) {
          attributes.put(env, environments.get(request))
        } else {
          attributes
        }
        let model = @model.Request::{
          ..@model.Request::new(
            @model.Method::parse(request.verb()),
            request.url(),
          ),
          headers,
          attributes,
          body: Stream(
            @model.StreamBody::new(
              input,
              length?=match framing {
                Length(n) => Some(n)
                _ => None
              },
            ),
          ),
        }
        model.validate() catch {
          _ => return empty_response(400, request)
        }
        let reply = handler(model)
        accepting.val = false
        if input.failure is Some(error) {
          reply.close()
          return empty_response(
            if error is @model.TransportError(kind=TooLarge(..), ..) {
              413
            } else {
              400
            },
            request,
          )
        }
        let result = adapt_response(reply, input, request) catch {
          _ =>
            return empty_response(
              if input.failure
                is Some(@model.TransportError(kind=TooLarge(..), ..)) {
                413
              } else {
                500
              },
              request,
            )
        }
        transferred = true
        result
      }),
    )
  }
}
