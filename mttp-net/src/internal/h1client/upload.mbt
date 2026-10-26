///|
pub async fn send_bytes(
  wire : Wire,
  bytes : Bytes,
  timer : PhaseTimer,
) -> Unit raise @model.TransportError {
  for offset = 0; offset < bytes.length(); {
    let n = (bytes.length() - offset).min(65536)
    timer.run(Write, () => wire.write(bytes[offset:offset + n].to_owned()))
    continue offset + n
  }
}

///|
pub async fn exchange(
  wire : Wire,
  request : @model.Request,
  head : Bytes,
  framing : @h1.Framing,
  timer : PhaseTimer,
  limits : @h1.Limits,
  coordination : &@connection.Coordination,
) -> (@h1.Version, @model.ResponseHead, Bool) raise @model.TransportError {
  let stream = match request.body {
    Stream(body) => Some(body.take())
    _ => None
  }
  defer (if stream is Some(stream) { stream.close() })
  // A stream may validate nested multipart ownership on its first read.
  // Keep that validation, including a false length=0 claim, before the head.
  let first = match stream {
    Some(stream) => timer.run(Write, () => stream.read_some())
    None => None
  }
  timer.run(Write, () => wire.write(head))
  // The head write completes an empty upload. Reading its response directly
  // needs no upload task or completion signals, and starts the head budget
  // at exactly the same boundary as the duplex path.
  if request.body is Empty || (request.body is Bytes(bytes) && bytes.is_empty()) {
    let (version, response) = timer.run(Head, () => final_head(wire, limits))
    return (version, response, true)
  }
  duplex(
    wire,
    request.body,
    stream,
    first,
    framing,
    timer,
    limits,
    coordination,
  )
}

///|
pub async fn upload(
  wire : Wire,
  body : @model.Body,
  stream : &@model.BodyStream?,
  first : Bytes?,
  framing : @h1.Framing,
  timer : PhaseTimer,
) -> Unit raise @model.TransportError {
  match body {
    Bytes(bytes) => send_bytes(wire, bytes, timer)
    Empty => ()
    Stream(_) => {
      let stream = stream.unwrap()
      let mut next = first
      while next is Some(bytes) {
        for offset = 0; offset < bytes.length(); {
          let n = (bytes.length() - offset).min(65536)
          let slice = bytes[offset:offset + n].to_owned()
          let data = if framing == Chunked {
            @h1.encode_chunk(slice)
          } else {
            slice
          }
          timer.run(Write, () => wire.write(data))
          continue offset + n
        }
        next = timer.run(Write, () => stream.read_some())
      }
      if framing == Chunked {
        timer.run(Write, () => wire.write(@h1.encode_chunk(b"")))
      }
    }
    @model.Body::.. =>
      raise @model.TransportError(
        kind=Invalid,
        phase=Write,
        detail="unsupported body kind",
      )
  }
}

///|
pub async fn final_head(
  wire : Wire,
  limits : @h1.Limits,
) -> (@h1.Version, @model.ResponseHead) raise @model.TransportError {
  for _ in 0..<17 {
    let result = wire.head(limits) catch { error => raise failure(Head, error) }
    if result.1.status >= 200 || result.1.status == 101 {
      return result
    }
  }
  raise @model.TransportError(
    kind=Protocol,
    phase=Head,
    detail="too many informational responses",
  )
}

///|
pub async fn duplex(
  wire : Wire,
  body : @model.Body,
  stream : &@model.BodyStream?,
  first : Bytes?,
  framing : @h1.Framing,
  timer : PhaseTimer,
  limits : @h1.Limits,
  coordination : &@connection.Coordination,
) -> (@h1.Version, @model.ResponseHead, Bool) raise @model.TransportError {
  let changed = coordination.signal()
  let head_ready = coordination.signal()
  let received : Ref[
    Result[(@h1.Version, @model.ResponseHead), @model.TransportError]?,
  ] = Ref(None)
  let sent : Ref[Result[Unit, @model.TransportError]?] = Ref(None)
  let result : Ref[(@h1.Version, @model.ResponseHead, Bool)?] = Ref(None)
  coordination.supervise(
    monitor=() => {
      sent.val = Some(
        Ok(upload(wire, body, stream, first, framing, timer)) catch {
          error => Err(error)
        },
      )
      changed.notify()
    },
    primary=() => {
      coordination.supervise(
        monitor=() => {
          received.val = Some(
            Ok(final_head(wire, limits)) catch {
              error => Err(error)
            },
          )
          head_ready.notify()
          changed.notify()
        },
        primary=() => {
          while received.val is None && sent.val is None {
            changed.wait()
          }
          // A producer contract failure is not made valid by a server response.
          // A network write failure can instead be an early rejection closing TCP.
          if sent.val is Some(Err(error)) &&
            !(error is @model.TransportError(kind=Network, ..)) {
            raise error
          }
          if received.val is None {
            // The read-idle head budget starts after upload, preserving long uploads.
            // During upload, each write/producer read already enforces the total budget.
            timer.run(Head, () => {
              while received.val is None {
                head_ready.wait()
              }
            }) catch {
              error =>
                raise match sent.val {
                  Some(Err(write_error)) => write_error
                  _ => error
                }
            }
          }
          match received.val.unwrap() {
            Ok((version, head)) =>
              result.val = Some((version, head, sent.val is Some(Ok(_))))
            Err(error) => {
              if sent.val is Some(Err(write_error)) {
                raise write_error
              }
              raise error
            }
          }
        },
      )
    },
  ) catch {
    error => raise failure(Head, error)
  }
  guard result.val is Some(result) else {
    raise @model.TransportError(
      kind=Protocol,
      phase=Head,
      detail="exchange completed without a head",
    )
  }
  result
}
