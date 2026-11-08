///|
/// Encodes a relative request target ("/api/v1/users/1?fields=a"); the
/// Client joins it onto its base URL by prefix. Internal in v0.3 (S-07).
fn[S, I, E, O, M] Endpoint::encode_request(
  self : Endpoint[S, I, E, O, M],
  security : S,
  input : I,
) -> @http.Request raise @client.InvalidRequest {
  let sink = RequestSink::new()
  (self.security.encode)(security, sink)
  (self.input.encode)(input, sink)
  let path_builder = StringBuilder()
  for segment in parse_template(self.template) {
    match segment {
      Lit(text) => {
        path_builder.write_char('/')
        path_builder.write_string(@http.percent_encode(text))
      }
      Cap(name) => {
        let value = sink.captures.get(name).unwrap_or("")
        reject_dot_segment(value)
        path_builder.write_char('/')
        path_builder.write_string(@http.percent_encode(value))
      }
      Rest(name) => {
        let value = sink.captures.get(name).unwrap_or("")
        for part in value.split("/") {
          let decoded = @http.percent_decode(part.to_owned()) catch {
            _ =>
              raise @client.InvalidRequest(message="invalid rest path encoding")
          }
          reject_dot_segment(decoded)
        }
        path_builder.write_string(value)
      }
    }
  }
  let encoded = path_builder.to_string()
  let path = if encoded.is_empty() { "/" } else { encoded }
  let url = if sink.query.is_empty() {
    path
  } else {
    path + "?" + @http.form_urlencode(sink.query)
  }
  let mut req : @http.Request = {
    ..@http.Request::new(self.meth.unwrap_or(Get), url),
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
fn reject_dot_segment(value : String) -> Unit raise @client.InvalidRequest {
  // Fetch normalizes even percent-encoded dots, so escaping cannot preserve
  // these identifiers consistently across the supported transports.
  if value == "." || value == ".." {
    raise @client.InvalidRequest(message="dot-only path capture")
  }
}

///|
fn excerpt(bytes : Bytes) -> Bytes {
  if bytes.length() <= 1048576 {
    bytes
  } else {
    bytes[:1048576].to_owned()
  }
}

///|
fn decode_failure(error : DecodeError) -> @client.ResponseFailure {
  let DecodeError(head, message~, body~) = error
  @client.Deserialization(head, message~, body=excerpt(body))
}

///|
/// Tries buffered outputs first, then declared errors, preserving declaration
/// order within each group. Both groups reuse the Client's bounded bytes.
/// If neither decodes, retain the output failure when there was one.
fn[S, I, E, O, M] Endpoint::decode_reply(
  self : Endpoint[S, I, E, O, M],
  head : @http.ResponseHead,
  bytes : Bytes,
) -> Result[Result[O, E], @client.ResponseFailure] raise {
  let mut failure : DecodeError? = None
  let output = self.output.decode_bytes(head, bytes) catch {
    DecodeError(_, ..) as error => {
      failure = Some(error)
      None
    }
    error => raise error
  }
  if output is Some(value) {
    return Ok(Ok(value))
  }
  let declared = self.errors.decode_bytes(head, bytes) catch {
    DecodeError(_, ..) as error => {
      if failure is None {
        failure = Some(error)
      }
      None
    }
    error => raise error
  }
  if declared is Some(value) {
    return Ok(Err(value))
  }
  match failure {
    Some(error) => Err(decode_failure(error))
    None => Err(@client.UnexpectedStatus(head, body=excerpt(bytes)))
  }
}

///|
/// Encodes a buffered endpoint. HTTP and decoding failures are values;
/// transport failures and unknown decoder errors remain raised effects.
pub fn[S, I, E, O] Endpoint::request(
  self : Endpoint[S, I, E, O, @client.Buffered],
  security : S,
  input : I,
) -> @client.ClientRequest[Result[Result[O, E], @client.ResponseFailure]] raise @client.InvalidRequest {
  let reader = @client.from_head(head => {
    if self.output.for_head(head).is_empty() &&
      self.errors.for_head(head).is_empty() {
      @client.ResponsePlan::reject()
    } else {
      @client.ResponsePlan::new((head, bytes) => self.decode_reply(head, bytes))
    }
  })
  @client.RequestPlan::new(self.encode_request(security, input), reader)
}

///|
/// Encodes a scoped response callback through the same Client executor.
/// Error responses are decoded before retry decisions; use_ starts only once.
pub fn[S, I, E, O, R, M] Endpoint::stream_request(
  self : Endpoint[S, I, E, O, M],
  security : S,
  input : I,
  use_ : async (O) -> R,
) -> @client.StreamRequest[Result[Result[R, E], @client.ResponseFailure]] raise @client.InvalidRequest {
  let reader = @client.from_head(head => {
    if self.output.for_head(head).is_empty() {
      if self.errors.for_head(head).is_empty() {
        return @client.ResponsePlan::reject().as_streaming()
      }
      @client.ResponsePlan::new((head, bytes) => {
        match self.decode_reply(head, bytes) {
          Ok(Err(error)) => Ok(Err(error))
          Err(error) => Err(error)
          Ok(Ok(_)) => abort("no output candidate")
        }
      }).as_streaming()
    } else if self.output
      .for_head(head)
      .iter()
      .all(v => v.decode_stream is None) {
      @client.ResponsePlan::prepared_stream(
        (head, bytes) => {
          match self.decode_reply(head, bytes) {
            Ok(Ok(value)) => Ok(value)
            Ok(Err(error)) => Err(Ok(Err(error)))
            Err(error) => Err(Err(error))
          }
        },
        value => Ok(Ok(use_(value))),
      )
    } else {
      @client.ResponsePlan::stream((head, stream, _) => {
        try {
          for variant in self.output.for_head(head) {
            if variant.decode_stream is Some(decode) {
              return Ok(Ok(use_(decode(head, stream))))
            }
          }
          abort("stream selection lost its decoder")
        } catch {
          DecodeError(_, ..) as error => Err(decode_failure(error))
          error => raise error
        }
      })
      .any_status()
      .map(result => {
        match result {
          Ok(result) => result
          Err(error) => Err(error)
        }
      })
    }
  })
  @client.RequestPlan::new(self.encode_request(security, input), reader)
}

///|
/// Sends a buffered endpoint through the normal policy pipeline.
pub async fn[S, I, E, O] Endpoint::call(
  self : Endpoint[S, I, E, O, @client.Buffered],
  client : @client.Client,
  security : S,
  input : I,
) -> Result[Result[O, E], @client.ResponseFailure] {
  self.request(security, input).send(client).body
}

///|
/// Sends an endpoint with its output scoped to the callback's lifetime.
pub async fn[S, I, E, O, R, M] Endpoint::call_with(
  self : Endpoint[S, I, E, O, M],
  client : @client.Client,
  security : S,
  input : I,
  use_ : async (O) -> R,
) -> Result[Result[R, E], @client.ResponseFailure] {
  self.stream_request(security, input, use_).send(client).body
}
