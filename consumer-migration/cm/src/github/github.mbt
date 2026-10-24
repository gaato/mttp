///|
pub(all) suberror GraphqlFailure {
  GraphqlFailure(@model.ResponseHead, body~ : Bytes, rate_limited~ : Bool)
} derive(Debug)

///|
pub(all) struct GitHubRetry {
  max_retries : Int
}

///|
impl @client.RetryDecider for GitHubRetry with decide(self, error, ctx) {
  if ctx.attempt >= self.max_retries {
    return Stop
  }
  match error {
    @client.UnexpectedStatus({ status: 403 | 429, headers }, ..) =>
      match headers.get("retry-after") {
        Some(s) => Wait((@string.parse_int(s) catch { _ => 60 }) * 1000)
        None => Wait(60000)
      }
    GraphqlFailure(_, rate_limited=true, ..) => Wait(1000)
    @client.UnexpectedStatus({ status, .. }, ..) if status >= 500 &&
      ctx.request.meth is Get => Wait(500)
    _ => Stop
  }
}

///|
pub struct GitHub {
  priv backend : &@client.Backend
  priv template : @client.PartialRequest[Bytes]
  priv policy : @client.Policy
}

///|
pub fn GitHub::new(
  backend : &@client.Backend,
  clock : &@model.Clock,
  base_url? : String = "https://api.github.com",
) -> GitHub raise @model.UrlError {
  {
    backend,
    template: @client.basic_request
      .base_url(@model.Url::parse(base_url))
      .header("accept", "application/vnd.github+json"),
    policy: @client.Policy::new(clock, GitHubRetry::{ max_retries: 3 }),
  }
}

///|
/// No architecture entry point turns a generated @model.Request into a
/// ClientRequest that keeps the template's base URL and default headers, so the
/// facade re-implements sdk-runtime's merge: base resolution, then request
/// headers ahead of template defaults.
fn GitHub::lift(self : GitHub, req : @model.Request) -> @client.ClientRequest[Bytes] {
  let shaped = self.template.get(req.url) // resolves against base_url
  let t = shaped.raw()
  let @model.Headers(defaults) = t.headers
  let mut headers = req.headers
  for p in defaults {
    if headers.get(p.0) is None {
      headers = headers.add(p.0, p.1)
    }
  }
  shaped.with_raw({ ..req, url: t.url, headers, attributes: t.attributes })
}

///|
pub async fn[T] GitHub::call(
  self : GitHub,
  req : @model.Request,
  decode : (@model.ResponseHead, Bytes) -> T raise @client.ResponseError,
  always? : Bool = false,
) -> T {
  let reader = if always {
    // what §6.6 literally says: as_bytes_always().map_with_head(..)
    @client.as_bytes_always().map_with_head((b, h) => decode(h, b))
  } else {
    @client.as_bytes().map_with_head((b, h) => decode(h, b))
  }
  self.lift(req).response(reader).send(self.backend, policy=self.policy).body
}

///|
/// sdk-runtime Paginator[T, SdkError] becomes Paginator[T, Error]: the send
/// path raises TransportError, ResponseError, UrlError or user errors.
pub fn[T] GitHub::paginator(
  self : GitHub,
  first : @model.Request,
  decode : (@model.ResponseHead, Bytes) -> Array[T] raise @client.ResponseError,
) -> @client.Paginator[T, Error] {
  @client.Paginator::with_cursor(cursor => {
    let req = match cursor {
      None => first
      Some(next) => { ..first, url: @model.Url::parse(next) } // String -> Url now raises
    }
    let resp = self
      .lift(req)
      .response(@client.as_bytes())
      .send(self.backend, policy=self.policy)
    let head : @model.ResponseHead = { status: resp.status, headers: resp.headers }
    { items: decode(head, resp.body), next: @model.parse_link_next(resp.headers) }
  })
}

///|
/// GraphQL: the reader raises from a 200 body inside the attempt.
pub async fn GitHub::graphql(self : GitHub, query : String) -> Json {
  let url = @model.Url::parse("/graphql")
  let reader = @client.as_bytes().map_with_head((b, h) => {
    let j = @json.parse(@utf8.decode(b))
    if j is { "errors": Array([{ "type": String("RATE_LIMITED"), .. }, ..]), .. } {
      raise GraphqlFailure(h, body=b, rate_limited=true)
    }
    j
  })
  self.template
  .post(url)
  .header("x-q", query)
  .response(reader)
  .send(self.backend, policy=self.policy)
  .body
}
