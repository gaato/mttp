///|
/// Preserves a single nonempty X-Request-ID, or generates a diagnostic ID,
/// and sets it on both the forwarded request and returned response. The
/// default is random, not a cryptographic token; inject a generator for tests.
pub fn request_id(generate~ : () -> String = diagnostic_id) -> Middleware {
  (request, next) => {
    let id = match request.headers.get_all("x-request-id") {
      [id] if !id.is_empty() => id
      _ => generate()
    }
    let response = next(request.set_header("x-request-id", id))
    { ..response, headers: response.headers.set("x-request-id", id), }
  }
}

///|
fn diagnostic_id() -> String {
  Array::makei(4, _ => {
    (@rt.default_random() * 1073741824.0).to_int().to_string()
  }).join("-")
}

///|
/// Reports the request head, response (including route_template), and elapsed
/// milliseconds when the response head is ready. The sink should inspect only
/// metadata: reading or taking the body transfers its ownership to the sink.
/// Stream consumption and cancellations before a response are not logged.
pub fn access_log(
  clock : &@rt.Clock,
  sink : (@http.RequestHead, @http.Response, Int64) -> Unit,
) -> Middleware {
  (request, next) => {
    let start = clock.now_unix_ms()
    let response = next(request)
    sink(request.head(), response, (clock.now_unix_ms() - start).max(0L))
    response
  }
}
