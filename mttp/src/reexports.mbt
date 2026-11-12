///|
pub using @mttp_core {
  type Request,
  type Response,
  type Body,
  type Headers,
  type Method,
  type TransportError,
}

///|
pub using @client {
  type Client,
  type RequestPlan,
  type ResponsePlan,
  type Reply,
  type ResponseFailure,
  type RetryPolicy,
  type RetryBudget,
  type RedirectConfig,
  get,
  post,
  request,
  as_string,
  as_json,
  as_json_value,
  as_bytes,
  as_lines,
  as_sse,
}

///|
pub using @trust {type Trust}

///|
pub using @cookie {type CookieJar}
