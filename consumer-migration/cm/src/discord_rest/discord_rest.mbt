// Port of discord.mbt/discord/src/http/{retry,closed_gate,request,client}.mbt
// onto the proposed mttp client API (architecture §3.4, §6.6 "discord 0.14").

///|
pub(all) suberror DiscordHttpError {
  Api(status~ : Int, body~ : Json)
  RateLimited(retry_after_ms~ : Int64, global~ : Bool)
  Transport(phase~ : @model.Phase, message~ : String)
} derive(Debug)

///|
/// Replaces discord's REPLAY_SAFE_HEADER + ClosedGate header stripping: a typed
/// attribute never reaches the wire, so no stripping wrapper is needed.
pub let replay_safe : @model.AttributeKey[Bool] = @model.AttributeKey::new()

///|
pub(all) enum Telemetry {
  HttpRequest(bucket~ : String, status~ : Int, retries~ : Int)
  HttpRateLimited(bucket~ : String, retry_after_ms~ : Int64, global~ : Bool)
} derive(Debug, Eq)

///|
fn json_body(body : Bytes) -> Json {
  @json.parse(@utf8.decode_lossy(body)) catch {
    _ => Json::null()
  }
}

///|
fn rate_limit_details(headers : @model.Headers, body : Bytes) -> (Int64, Bool) {
  let global = headers.get("x-ratelimit-global") is Some(_) ||
    headers.get("x-ratelimit-scope") == Some("global")
  let ms : Int64 = match json_body(body) {
    { "retry_after": Number(s, ..), .. } => (s * 1000.0).to_int64()
    _ => 1000L
  }
  (ms, global)
}

///|
fn is_discord_rate_limit(headers : @model.Headers) -> Bool {
  headers.get("x-ratelimit-scope") is Some(_) ||
  headers.get("x-ratelimit-global") is Some(_) ||
  headers.get("content-type").map(v => v.contains("json")).unwrap_or(false)
}

///|
priv struct DiscordRetry {
  max_retries : Int
  closed : Ref[Bool]
}

///|
fn idempotent(req : @model.Request) -> Bool {
  (req.meth is (Get | Head | Put | Delete)) ||
  req.attributes.get(replay_safe) == Some(true)
}

///|
/// resend_decision, matching on mttp errors instead of SdkError.
impl @client.RetryDecider for DiscordRetry with decide(self, error, ctx) {
  if self.closed.val || ctx.attempt >= self.max_retries {
    return Stop
  }
  match error {
    @client.UnexpectedStatus({ status: 429, headers }, body~) => {
      if !is_discord_rate_limit(headers) {
        return Stop
      }
      let (ms, _) = rate_limit_details(headers, body)
      Wait(ms.to_int() + 1)
    }
    @client.UnexpectedStatus({ status: 502, .. }, ..) => Wait(500)
    @client.UnexpectedStatus({ status, .. }, ..) if status >= 500 &&
      idempotent(ctx.request) => Wait(500)
    @model.TransportError(..) as t if t.is_unsent() || idempotent(ctx.request) =>
      Wait(500)
    _ => Stop
  }
}

///|
pub struct Client {
  priv backend : &@client.Backend
  priv template : @client.PartialRequest[Bytes]
  priv policy : @client.Policy
  priv closed : Ref[Bool]
  telemetry : Array[Telemetry]
}

///|
pub fn Client::new(
  token : String,
  backend : &@client.Backend,
  clock : &@model.Clock,
  max_retries? : Int = 4,
) -> Client {
  let closed = Ref(false)
  let telemetry = []
  // ClosedGate: now an arrow-lambda wrapper (no header stripping needed).
  let gated = @client.from_fn((req, opts) => {
    if closed.val {
      raise TransportError(kind=Closed, phase=Pool, detail="client is closed")
    }
    backend.send(req, opts)
  })
  let base = @model.Url::parse("https://discord.com/api/v10") catch {
    _ => abort("static")
  }
  let policy = @client.Policy::new(
    clock,
    DiscordRetry::{ max_retries, closed },
    observer=a => {
      telemetry.push(HttpRequest(bucket=a.bucket, status=a.status, retries=a.attempt))
      // sdk-runtime's Attempt had `body`; mttp's does not. The 429 body is
      // recoverable only from the raised UnexpectedStatus in `error`.
      if a.error is Some(@client.UnexpectedStatus({ status: 429, headers }, body~)) {
        let (retry_after_ms, global) = rate_limit_details(headers, body)
        telemetry.push(HttpRateLimited(bucket=a.bucket, retry_after_ms~, global~))
      }
    },
  )
  {
    backend: gated,
    template: @client.basic_request
      .base_url(base)
      .header("authorization", "Bot " + token),
    policy,
    closed,
    telemetry,
  }
}

///|
pub fn Client::close(self : Client) -> Unit {
  self.closed.val = true
}

///|
/// request_online + settle_runtime_error: every status comes back as a value
/// for middleware, except a 429 that outlived its retries.
pub async fn Client::request(
  self : Client,
  path : String,
  bucket : String,
  post? : Json,
  replay_safe_call? : Bool = false,
) -> Json raise DiscordHttpError {
  let url = @model.Url::parse(path) catch {
    _ => raise Transport(phase=Unknown, message="other error")
  }
  let req = match post {
    None => self.template.get(url)
    Some(_) => self.template.post(url)
  }
  let req = req
    .attribute(@client.rate_limit_bucket, bucket)
    .attribute(replay_safe, replay_safe_call)
  let resp = req.send(self.backend, policy=self.policy) catch {
    @client.UnexpectedStatus({ status: 429, headers }, body~) => {
      let (retry_after_ms, global) = rate_limit_details(headers, body)
      raise RateLimited(retry_after_ms~, global~)
    }
    @client.UnexpectedStatus({ status, .. }, body~) =>
      raise Api(status~, body=json_body(body))
    @model.TransportError(phase~, detail~, ..) =>
      raise Transport(phase~, message=detail)
    _ => raise Transport(phase=Unknown, message="other error")
  }
  json_body(resp.body)
}
