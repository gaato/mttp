///|
/// tapir's SttpClientInterpreter: an endpoint plus values becomes a client
/// request whose reader yields `O`, raises the declared `E`, or raises
/// ResponseError for a status the endpoint does not declare.
pub fn[S, I, E : Error, O] Endpoint::request(
  self : Endpoint[S, I, E, O],
  base : @model.Uri,
  security : S,
  input : I,
) -> @client.ClientRequest[O] {
  let sink = RequestSink::new()
  self.security.encode(security, sink)
  self.input.encode(input, sink)
  let segments = self.segments.map(s => match s {
    Lit(l) => l
    Cap(n) => sink.captures.get(n).unwrap_or("")
  })
  let uri = { ..base.with_segments(segments), query: sink.query }
  let request : @model.Request = {
    meth: self.meth,
    uri,
    headers: sink.headers,
    body: sink.body,
  }
  let response_as = @client.ResponseAs::new(async fn(h, b) {
    if self.output.for_status(h.status) is Some(v) {
      return (v.decode)(h, b)
    }
    if self.errors.out.for_status(h.status) is Some(v) {
      raise (v.decode)(h, b)
    }
    raise @client.UnexpectedStatus(
      h,
      body=@client.body_bytes(b, @client.max_error_body),
    )
  })
  @client.ClientRequest::new(request, response_as)
}

///|
pub async fn[S, I, E : Error, O] Endpoint::call(
  self : Endpoint[S, I, E, O],
  backend : &@client.Backend,
  base : @model.Uri,
  security : S,
  input : I,
) -> O {
  self.request(base, security, input).send(backend).body
}

///|
/// Sync half of the client interpreter: the request to send...
pub fn[S, I, E, O] Endpoint::encode_request(
  self : Endpoint[S, I, E, O],
  base : @model.Uri,
  security : S,
  input : I,
) -> @model.Request {
  let sink = RequestSink::new()
  self.security.encode(security, sink)
  self.input.encode(input, sink)
  let segments = self.segments.map(s => match s {
    Lit(l) => l
    Cap(n) => sink.captures.get(n).unwrap_or("")
  })
  {
    meth: self.meth,
    uri: { ..base.with_segments(segments), query: sink.query },
    headers: sink.headers,
    body: sink.body,
  }
}

///|
/// ...and the buffered answer read back, no async runtime needed. Streaming
/// outputs (SSE, streams) are refused: they need `call`.
pub fn[S, I, E, O] Endpoint::decode_response(
  self : Endpoint[S, I, E, O],
  head : @model.ResponseHead,
  body : Bytes,
) -> Result[O, E] raise @client.ResponseError {
  if self.output.for_status(head.status) is Some(v) {
    guard v.decode_bytes is Some(f) else {
      raise @client.Deserialization(head, message="streaming output", body~)
    }
    return Ok(f(head, body)) catch {
      @client.ResponseError::_ as e => raise e
      e => raise @client.Deserialization(head, message=e.to_string(), body~)
    }
  }
  if self.errors.out.for_status(head.status) is Some(v) {
    guard v.decode_bytes is Some(f) else {
      raise @client.Deserialization(head, message="streaming error", body~)
    }
    return Err(f(head, body)) catch {
      @client.ResponseError::_ as e => raise e
      e => raise @client.Deserialization(head, message=e.to_string(), body~)
    }
  }
  raise @client.UnexpectedStatus(head, body~)
}
