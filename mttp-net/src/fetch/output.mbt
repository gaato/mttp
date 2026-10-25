///|
priv struct Output {
  stream : &@model.BodyStream?
  input : Input
  mut pending : Bytes
  mut offset : Int32
  mut closed : Bool
}

///|
fn Output::close(self : Output) -> Unit {
  if !self.closed {
    self.closed = true
    self.pending = b""
    if self.stream is Some(stream) {
      stream.close()
    }
    self.input.close()
  }
}

///|
async fn Output::next(self : Output) -> Chunk {
  if self.closed {
    return { done: true, value: b"", }
  }
  errdefer self.close()
  if self.pending.is_empty() {
    let next = match self.stream {
      Some(stream) => stream.read_some()
      None => None
    }
    guard next is Some(bytes) else {
      self.close()
      return { done: true, value: b"", }
    }
    self.pending = bytes
  }
  let end = self.offset + (self.pending.length() - self.offset).min(65536)
  let bytes = self.pending[self.offset:end].to_owned()
  self.offset = end
  if end == self.pending.length() {
    self.pending = b""
    self.offset = 0
  }
  { done: false, value: bytes, }
}

///|
async fn adapt_response(
  reply : @model.Response,
  input : Input,
  request : JsRequest,
) -> WebResponse {
  let mut reply_owned = true
  errdefer (if reply_owned { reply.close() })
  reply.headers.validate()
  let no_body = request.verb() == "HEAD" ||
    reply.status == 204 ||
    reply.status == 205 ||
    reply.status == 304 ||
    reply.body is Empty
  let stream = if no_body {
    None
  } else {
    match reply.body {
      Stream(stream) => {
        reply_owned = false
        Some(stream.take())
      }
      _ => None
    }
  }
  if no_body {
    reply_owned = false
    reply.close()
  }
  let output = Output::{
    stream,
    input,
    pending: if no_body {
      b""
    } else {
      reply.body.as_bytes().unwrap_or(b"")
    },
    offset: 0,
    closed: false,
  }
  errdefer output.close()
  // First-read validation happens before constructing the host response.
  if stream is Some(stream) {
    output.pending = stream.read_some().unwrap_or(b"")
  }
  let headers = reply.headers.remove("transfer-encoding")
  let headers = if no_body {
    headers
  } else {
    match reply.body.length() {
      Some(length) => headers.set("content-length", length.to_string())
      None => headers.remove("content-length")
    }
  }
  let pairs = headers
    .iter()
    .map(pair => FixedArray::from_array([pair.0, pair.1]))
    .collect()
  response(
    reply.status,
    FixedArray::from_array(pairs),
    no_body,
    signal => {
      @js_async.Promise::from_async(abort_signal=signal, () => output.next())
    },
    () => output.close(),
    request.signal(),
  ).wait()
}
