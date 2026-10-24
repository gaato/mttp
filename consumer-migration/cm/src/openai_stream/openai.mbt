///|
priv suberror StreamDone {
  StreamDone
}

///|
priv struct Stainless {}

///|
impl @client.RetryDecider for Stainless with decide(_self, e, ctx) {
  if ctx.attempt >= 2 {
    return Stop
  }
  match e {
    @client.UnexpectedStatus({ status: 429 | 500 | 502 | 503, .. }, ..) => Wait(500)
    _ => Stop
  }
}

///|
pub struct OpenAI {
  priv backend : &@client.Backend
  priv clock : &@model.Clock
}

///|
pub fn OpenAI::new(backend : &@client.Backend, clock : &@model.Clock) -> OpenAI {
  { backend, clock }
}

///|
/// Port of OpenAI::stream_chat_completion: generic user error E, early stop
/// on "[DONE]" through a private sentinel raised from the SSE callback.
pub async fn[E : Error] OpenAI::stream_chat(
  self : OpenAI,
  f : async (String) -> Unit raise E,
) -> Unit {
  let url = @model.Url::parse("https://api.openai.com/v1/chat/completions")
  let req = @client.basic_request
    .post(url)
    .header("accept", "text/event-stream")
    .response(
      @client.as_sse(async fn(ev) {
        if ev.data == "[DONE]" {
          raise StreamDone
        }
        f(ev.data)
      }),
    )
  let policy = @client.Policy::new(self.clock, Stainless::{  })
  ignore(req.send(self.backend, policy~)) catch {
    StreamDone => ()
    e => raise e
  }
}
