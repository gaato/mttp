///|
/// Encodes a relative request target ("/api/v1/users/1?fields=a"); the
/// Client joins it onto its base URL by prefix. Internal in v0.3 (S-07).
fn[S, I, E, O] Endpoint::encode_request(
  self : Endpoint[S, I, E, O],
  security : S,
  input : I,
) -> @model.Request {
  let sink = RequestSink::new()
  (self.security.encode)(security, sink)
  (self.input.encode)(input, sink)
  let path_builder = StringBuilder()
  for segment in parse_template(self.template) {
    match segment {
      Lit(text) => {
        path_builder.write_char('/')
        path_builder.write_string(@model.percent_encode(text))
      }
      Cap(name) => {
        path_builder.write_char('/')
        path_builder.write_string(
          @model.percent_encode(sink.captures.get(name).unwrap_or("")),
        )
      }
      Rest(name) =>
        path_builder.write_string(sink.captures.get(name).unwrap_or(""))
    }
  }
  let encoded = path_builder.to_string()
  let path = if encoded.is_empty() { "/" } else { encoded }
  let url = if sink.query.is_empty() {
    path
  } else {
    path + "?" + @model.form_urlencode(sink.query)
  }
  let mut req : @model.Request = {
    ..@model.Request::new(self.meth.unwrap_or(Get), url),
    headers: sink.headers,
    body: sink.body,
  }
  if self.info.operation_id is Some(id) {
    req = req.attribute(@client.operation_id, id)
  }
  if self.bucket is Some(bucket) {
    req = req.attribute(@client.rate_limit_bucket, bucket(req))
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
    reject=(h, body) => {
      if self.errors.out.decode_bytes(h, body) is Some(e) {
        raise e
      }
    },
    streaming~,
  )
}

///|
/// Encodes a typed client request; its endpoint definition must pass checking.
pub fn[S, I, E : Error, O] Endpoint::request(
  self : Endpoint[S, I, E, O],
  security : S,
  input : I,
) -> @client.ClientRequest[O] {
  let ra = self.reader(
    (h, body, opts) => {
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
/// Sends a typed buffered request through the normal client policy pipeline.
pub async fn[S, I, E : Error, O] Endpoint::call(
  self : Endpoint[S, I, E, O],
  client : @client.Client,
  security : S,
  input : I,
) -> O {
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
    (h, body, opts) => {
      let s : &@model.BodyStream = match body {
        Stream(s) => s.take()
        Bytes(b) => BufferedStream::new(b)
        _ => BufferedStream::new(b"")
      }
      defer s.close()
      // A streaming variant gets the stream; otherwise read the body once
      // and try every buffered candidate in order, as `call` does.
      for v in self.output.for_head(h) {
        if v.decode_stream is Some(f) {
          let value = f(h, s) catch {
            error =>
              raise @client.Deserialization(
                h,
                message=error.to_string(),
                body=b"",
              )
          }
          return use_(value)
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
  client.send(
    @client.ClientRequest::new(self.encode_request(security, input), ra),
  ).body
}
