///|
/// Encodes a relative request target ("/api/v1/users/1?fields=a"); the
/// Client joins it onto its base URL by prefix. Internal in v0.3 (S-07).
fn[S, I, E, O] Endpoint::encode_request(self : Endpoint[S, I, E, O], security : S, input : I) -> @model.Request {
  let sink = RequestSink::new()
  (self.security.encode)(security, sink)
  (self.input.encode)(input, sink)
  let segments = parse_template(self.template).map(s => match s {
    Lit(l) => l
    Cap(n) => sink.captures.get(n).unwrap_or("")
  })
  let mut url = @model.encode_path(segments)
  for q in sink.query {
    url = @model.append_query(url, q.0, q.1)
  }
  let mut req : @model.Request = { ..@model.Request::new(self.meth.unwrap_or(Get), url), headers: sink.headers, body: sink.body }
  if self.info.operation_id is Some(id) {
    req = req.attribute(@client.operation_id, id)
    req = req.attribute(@client.rate_limit_bucket, id)
  }
  req
}

///|
/// accept: a declared output variant matches (status, media type).
/// reject: a declared error decodes to E (raised as itself); anything else
/// is UnexpectedStatus. Both run inside the attempt, so retries see them.
fn[S, I, E : Error, O, R] Endpoint::reader(
  self : Endpoint[S, I, E, O],
  read : async (@model.ResponseHead, @model.Body, @client.RequestOptions) -> R,
  streaming~ : Bool,
) -> @client.ResponseAs[R] {
  @client.ResponseAs::new(
    read,
    accept_head=h => !self.output.for_head(h).is_empty(),
    reject=(h, body) => if self.errors.out.decode_bytes(h, body) is Some(e) { raise e },
    streaming~,
  )
}

///|
pub fn[S, I, E : Error, O] Endpoint::request(self : Endpoint[S, I, E, O], security : S, input : I) -> @client.ClientRequest[O] {
  let ra = self.reader(
    async fn(h, body, opts) {
      let bytes = @client.read_body(body, opts.max_body_bytes)
      match self.output.decode_bytes(h, bytes) {
        Some(o) => o
        None => raise @client.UnexpectedStatus(h, body=bytes)
      }
    },
    streaming=false,
  )
  @client.ClientRequest::new(self.encode_request(security, input), ra)
}

///|
pub async fn[S, I, E : Error, O] Endpoint::call(self : Endpoint[S, I, E, O], client : @client.Client, security : S, input : I) -> O {
  client.send(self.request(security, input)).body
}

///|
/// Streaming outputs live only inside `use_`, which runs once after the
/// retry loop; error statuses are decoded inside the attempt (I-03).
pub async fn[S, I, E : Error, O, R] Endpoint::call_with(
  self : Endpoint[S, I, E, O],
  client : @client.Client,
  security : S,
  input : I,
  use_ : async (O) -> R,
) -> R {
  let ra = self.reader(
    async fn(h, body, opts) {
      let s : &@model.BodyStream = match body {
        Stream(s, ..) => s
        Bytes(b) => @model.BytesStream::new([b])
        _ => @model.BytesStream::new([])
      }
      defer s.close()
      // A streaming variant gets the stream; otherwise read the body once
      // and try every buffered candidate in order, as `call` does.
      for v in self.output.for_head(h) {
        if v.decode_stream is Some(f) {
          return use_(f(h, s))
        }
      }
      let body = @model.read_bounded(s, opts.max_body_bytes)
      match self.output.decode_bytes(h, body) {
        Some(o) => use_(o)
        None => raise @client.UnexpectedStatus(h, body~)
      }
    },
    streaming=true,
  )
  client.send(@client.ClientRequest::new(self.encode_request(security, input), ra)).body
}
