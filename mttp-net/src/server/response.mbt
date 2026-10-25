///|
fn has_token(headers : @model.Headers, name : String, wanted : String) -> Bool {
  headers
  .get_all(name)
  .iter()
  .any(field => {
    field
    .split(",")
    .any(token => token.trim(chars=" \t").to_owned().to_lower() == wanted)
  })
}

///|
fn compress_response(
  request : @model.Request,
  response : @model.Response,
) -> @model.Response raise @model.TransportError {
  if request.meth is Head ||
    response.status < 200 ||
    response.status == 204 ||
    response.status == 304 ||
    response.status == 206 ||
    response.body is Empty ||
    response.headers.get("content-encoding") is Some(_) ||
    response.headers.get("content-range") is Some(_) ||
    has_token(response.headers, "cache-control", "no-transform") {
    return response
  }
  let headers = if has_token(response.headers, "vary", "accept-encoding") ||
    has_token(response.headers, "vary", "*") {
    response.headers
  } else {
    response.headers.add("vary", "Accept-Encoding")
  }
  match @codings.negotiate_encoding(request.headers) {
    Identity => { ..response, headers, }
    Unacceptable => {
      response.close()
      @model.Response::new(
        406,
        headers=@model.Headers::of([("vary", "Accept-Encoding")]),
      )
    }
    Encoded(coding) => {
      let body = @codings.encode_body(response.body, coding)
      let headers = headers
        .remove("content-length")
        .remove("content-md5")
        .remove("content-digest")
        .set("content-encoding", coding.name())
      let headers = match headers.get("etag") {
        Some(value) if !value.has_prefix("W/") =>
          headers.set("etag", "W/" + value)
        _ => headers
      }
      { ..response, headers, body, }
    }
    @codings.EncodingChoice::.. => { ..response, headers, }
  }
}

///|
async fn write_response(
  wire : Wire,
  response : @model.Response,
  meth : @model.Method,
  version : @h1.Version,
  close : Bool,
  limits : ServerLimits,
  sent : Ref[Bool],
) -> Unit {
  defer response.close()
  if response.status < 200 || response.status > 599 {
    raise @model.TransportError(
      kind=Invalid,
      phase=Head,
      detail="invalid final response status",
    )
  }
  let headers = if close {
    response.headers.set("connection", "close")
  } else {
    response.headers
  }
  if meth is Head || response.status == 204 || response.status == 304 {
    let head = @h1.write_response_head(
      response.status,
      headers,
      NoBody,
      version,
    )
    sent.val = true
    wire.write(head, limits.body_timeout_ms)
    return
  }
  match response.body {
    Stream(stream) => {
      let reader = stream.take()
      let first = @async.with_timeout(
        limits.body_timeout_ms,
        () => reader.read_some(),
        error=@model.TransportError(
          kind=Timeout(ms=limits.body_timeout_ms),
          phase=Body,
          detail="response producer timed out",
        ),
      )
      let framing = match stream.length() {
        Some(length) => @h1.Length(length)
        None => if version == @h1.Http10 { @h1.UntilClose } else { @h1.Chunked }
      }
      let head = @h1.write_response_head(
        response.status,
        headers,
        framing,
        version,
      )
      sent.val = true
      wire.write(head, limits.body_timeout_ms)
      let mut next = first
      while next is Some(bytes) {
        // A producer may return large caller-owned chunks; each write still
        // uses bounded slices and never allocates framing for the whole chunk.
        for offset = 0; offset < bytes.length(); {
          let end = offset + (bytes.length() - offset).min(65536)
          let chunk = bytes[offset:end].to_owned()
          wire.write(
            if framing == @h1.Chunked {
              @h1.encode_chunk(chunk)
            } else {
              chunk
            },
            limits.body_timeout_ms,
          )
          continue end
        }
        next = @async.with_timeout(
          limits.body_timeout_ms,
          () => reader.read_some(),
          error=@model.TransportError(
            kind=Timeout(ms=limits.body_timeout_ms),
            phase=Body,
            detail="response producer timed out",
          ),
        )
      }
      if framing == @h1.Chunked {
        wire.write(@h1.encode_chunk(b""), limits.body_timeout_ms)
      }
    }
    _ => {
      let bytes = response.body.as_bytes().unwrap_or(b"")
      let head = @h1.write_response_head(
        response.status,
        headers,
        Length(bytes.length().to_int64()),
        version,
      )
      sent.val = true
      wire.write(head, limits.body_timeout_ms)
      wire.write(bytes, limits.body_timeout_ms)
    }
  }
}

///|
async fn reject(wire : Wire, status : Int32, limits : ServerLimits) -> Unit {
  let response = @model.Response::new(status)
  write_response(wire, response, Get, Http11, true, limits, Ref(false)) catch {
    _ => ()
  }
}

///|
fn report(error : Error, observer : (ServeError) -> Unit) -> Unit {
  let failure = match error {
    @model.TransportError(kind~, phase~, detail~) =>
      ServeError::{ kind, phase, detail, }
    @h1.ParseError(detail~, ..) => { kind: Protocol, phase: Head, detail, }
    _ => { kind: Network, phase: Unknown, detail: "connection failed", }
  }
  observer(failure)
}
