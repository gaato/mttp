///|
pub async fn exchange(
  connection : Connection,
  peer : String,
  authority : String,
  handler : @model.Handler,
  limits : ServerLimits,
  stopping : () -> Bool,
  observer : (ServeError) -> Unit,
  compression : Bool,
  background : ((async () -> Unit) -> Unit)?,
) -> Unit {
  let wire = connection.wire
  while !stopping() {
    connection.set_busy(false)
    let head = wire.head(limits) catch {
      error => {
        report(error, observer)
        let status = match error {
          @h1.ParseError(kind=HeadTooLarge, ..) => 431
          @model.TransportError(kind=Timeout(..), ..) => 408
          _ => 400
        }
        reject(wire, status, limits)
        return
      }
    }
    guard head is Some((meth, target, version, headers)) else { return }
    connection.set_busy(true)
    if meth is Connect {
      reject(wire, 501, limits)
      return
    }
    let framing = @h1.request_framing(headers) catch {
      _ => {
        reject(wire, 400, limits)
        return
      }
    }
    if framing is Length(length) && length > limits.max_body_bytes.to_int64() {
      reject(wire, 413, limits)
      return
    }
    let expectations = headers.get_all("expect")
    let expect = !expectations.is_empty()
    if expect &&
      (
        expectations.length() != 1 ||
        expectations[0].trim(chars=" \t").to_owned().to_lower() !=
        "100-continue"
      ) {
      reject(wire, 417, limits)
      return
    }
    let source = RequestBody::new(wire, framing, limits, expect)
    let body = if source.done {
      @model.Empty
    } else {
      @model.Stream(@model.StreamBody::new(source))
    }
    let url = if target.has_prefix("/") || target == "*" {
      "http://" +
      headers.get("host").unwrap_or(authority) +
      (if target == "*" { "/*" } else { target })
    } else {
      target
    }
    let attributes = @model.Attributes::empty().put(@model.remote_addr, peer)
    let attributes = match background {
      Some(schedule) => attributes.put(@model.background, schedule)
      None => attributes
    }
    let request = @model.Request::{
      ..@model.Request::new(meth, url),
      headers,
      body,
      attributes,
    }
    defer (if body is Stream(stream) { stream.close() })
    let keep = Ref(false)
    wire.coordination.supervise(
      primary=() => {
        keep.val = respond(
          wire, request, source, version, handler, limits, stopping, observer, compression,
        )
      },
      monitor=() => watch_peer(connection, source),
    ) catch {
      error => if connection.control.failed { return } else { raise error }
    }
    if !keep.val {
      return
    }
  }
}

///|
pub async fn watch_peer(
  connection : Connection,
  source : RequestBody,
) -> Unit raise @model.TransportError {
  let wire = connection.wire
  while !source.done {
    source.changed.wait()
  }
  // One bounded read-ahead detects read-side disconnects without racing
  // the request reader or accumulating pipelined requests indefinitely.
  if !wire.pending.is_empty() {
    return
  }
  let next = wire.read() catch {
    error => {
      let change = connection.control.step(PeerFailure)
      connection.control = change.state
      if change.cancel_exchange {
        raise error
      }
      return
    }
  }
  match next {
    // FIN closes only the peer's sending half. The current response must
    // still be delivered; the next head read will observe EOF and stop.
    None => connection.control = connection.control.step(PeerEof).state
    Some(bytes) => wire.unread(bytes)
  }
}

///|
pub async fn respond(
  wire : Wire,
  request : @model.Request,
  source : RequestBody,
  version : @h1.Version,
  handler : @model.Handler,
  limits : ServerLimits,
  stopping : () -> Bool,
  observer : (ServeError) -> Unit,
  compression : Bool,
) -> Bool noraise {
  let response = match limits.handler_timeout_ms {
    None => handler(request)
    Some(timeout) =>
      wire.with_timeout(
        timeout,
        () => handler(request),
        error=@model.TransportError(
          kind=Timeout(ms=timeout),
          phase=Unknown,
          detail="handler timed out",
        ),
      ) catch {
        error => {
          report(error, observer)
          reject(wire, 504, limits)
          return false
        }
      }
  }
  let response = if source.failure is Some(error) {
    response.close()
    report(error, observer)
    let status = match error {
      @model.TransportError(kind=TooLarge(..), ..) => 413
      @model.TransportError(kind=Timeout(..), ..) => 408
      _ => 400
    }
    @model.Response::new(
      status,
      headers=@model.Headers::of([("connection", "close")]),
    )
  } else {
    response
  }
  let response = if compression {
    compress_response(request, response) catch {
      error => {
        response.close()
        report(error, observer)
        reject(
          wire,
          if error is @model.TransportError(kind=Invalid, phase=Head, ..) {
            400
          } else {
            500
          },
          limits,
        )
        return false
      }
    }
  } else {
    response
  }
  let close = stopping() ||
    version == @h1.Http10 ||
    has_token(request.headers, "connection", "close") ||
    response.closes_connection() ||
    source.expect
  let sent = Ref(false)
  write_response(wire, response, request.meth, version, close, limits, sent) catch {
    error => {
      report(error, observer)
      if !sent.val {
        let status = match source.failure {
          Some(@model.TransportError(kind=TooLarge(..), ..)) => 413
          Some(@model.TransportError(kind=Timeout(..), ..)) => 408
          Some(_) => 400
          None =>
            if !source.done &&
              error is @model.TransportError(kind=Timeout(..), phase=Body, ..) {
              408
            } else {
              500
            }
        }
        reject(wire, status, limits)
      }
      return false
    }
  }
  !close && source.drain()
}
