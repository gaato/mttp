///|
priv struct Target {
  host : String
  port : Int32
  secure : Bool
  authority : String
  origin : String
  path : String
}

///|
fn target(request : @model.Request) -> Target raise @model.TransportError {
  request.validate()
  let url = @model.Url::parse(request.url) catch {
    _ =>
      raise @model.TransportError(
        kind=Invalid,
        phase=Pool,
        detail="invalid URL",
      )
  }
  guard url.scheme is Some("http" | "https") &&
    url.host is Some(host) &&
    !host.is_empty() &&
    url.userinfo is None &&
    url.port_or_default() is Some(port) else {
    raise @model.TransportError(
      kind=Invalid,
      phase=Pool,
      detail="backend requires an absolute http(s) URL without userinfo",
    )
  }
  let host_field = if host.contains(":") { "[" + host + "]" } else { host }
  let authority = host_field + ":" + port.to_string()
  let path = if request.meth == Connect {
    authority
  } else {
    (if url.path.is_empty() { "/" } else { url.path }) +
    (match url.query {
      Some(q) => "?" + q
      None => ""
    })
  }
  {
    host,
    port,
    secure: url.scheme == Some("https"),
    authority,
    origin: url.scheme.unwrap() + "://" + authority,
    path,
  }
}

///|
async fn send_bytes(
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
async fn exchange(
  wire : Wire,
  request : @model.Request,
  head : Bytes,
  framing : @h1.Framing,
  timer : PhaseTimer,
  limits : @h1.Limits,
) -> (@h1.Version, @model.ResponseHead) raise @model.TransportError {
  let stream = match request.body {
    Stream(body) => Some(body.take())
    _ => None
  }
  defer (if stream is Some(stream) { stream.close() })
  timer.run(Write, () => wire.write(head))
  match request.body {
    Bytes(bytes) => send_bytes(wire, bytes, timer)
    Empty => ()
    Stream(_) => {
      let stream = stream.unwrap()
      while timer.run(Write, () => stream.read_some()) is Some(bytes) {
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
      }
      if framing == Chunked {
        timer.run(Write, () => wire.write(@h1.encode_chunk(b"")))
      }
    }
  }
  timer.run(Head, () => {
    for _ in 0..<17 {
      let result = wire.head(limits)
      if result.1.status >= 200 || result.1.status == 101 {
        return result
      }
    }
    raise @model.TransportError(
      kind=Protocol,
      phase=Head,
      detail="too many informational responses",
    )
  })
}

///|
/// Sends a validated request with bounded framing, phase deadlines and
/// incremental content decoding. Stream readers own the connection slot.
pub async fn H1Backend::send(
  self : H1Backend,
  request : @model.Request,
  options : @client.RequestOptions,
) -> @model.Response raise @model.TransportError {
  if self.pool.closed {
    raise @model.TransportError(
      kind=Closed,
      phase=Pool,
      detail="backend closed",
    )
  }
  let target = target(request)
  if options.max_body_bytes < 0 || (self.body_ceiling is Some(n) && n < 0) {
    raise @model.TransportError(
      kind=Invalid,
      phase=Pool,
      detail="negative body limit",
    )
  }
  let negotiated = options.decompress &&
    !request.headers.contains("accept-encoding")
  let mut headers = request.headers.remove("proxy-authorization")
  if !headers.contains("host") {
    headers = headers.add("host", target.authority)
  }
  if !headers.contains("accept-encoding") {
    headers = headers.add(
      "accept-encoding",
      if negotiated {
        @codings.accept_encoding()
      } else {
        "identity"
      },
    )
  }
  let framing = match request.body.length() {
    Some(n) => @h1.Framing::Length(n)
    None => Chunked
  }
  let head = @h1.write_request_head(
    request.meth,
    target.path,
    headers,
    framing,
    Http11,
  ) catch {
    @h1.ParseError(detail~, ..) =>
      raise @model.TransportError(kind=Invalid, phase=Pool, detail~)
  }
  let limits = {
    ..self.limits,
    total: options.timeout_ms.unwrap_or(self.limits.total),
    read: options.read_idle_ms.unwrap_or(self.limits.read),
  }
  let timer = PhaseTimer::exchange(self.clock, limits)
  self.slots.acquire(target.origin, timer)
  let mut transferred = false
  defer (if !transferred { self.slots.release(target.origin) })
  let agent = request.headers.get("user-agent")
  let mut fresh = false
  for ;; {
    if self.pool.closed {
      raise @model.TransportError(
        kind=Closed,
        phase=Pool,
        detail="backend closed",
      )
    }
    let (cached, expired) = self.pool.take(
      target.origin,
      agent,
      now=self.clock.now_unix_ms(),
    )
    for old in expired {
      old.close()
    }
    let cached = if fresh {
      if cached is Some(old) {
        old.close()
      }
      None
    } else {
      cached
    }
    let reused = cached is Some(_)
    let wire = match cached {
      Some(wire) => wire
      None =>
        timer.run(Dial, () => {
          Wire::dial(target.host, target.port, target.secure)
        })
    }
    let mut owned = true
    defer (if owned { wire.close() })
    let (v, response) = exchange(
      wire,
      request,
      head,
      framing,
      timer,
      self.head_limits,
    ) catch {
      @model.TransportError(kind=Network, ..) if reused && replayable(request) => {
        fresh = true
        continue
      }
      error => raise error
    }
    let framing = @h1.response_framing(
      response.headers,
      status=response.status,
      meth=request.meth,
    ) catch {
      error => raise failure(Head, error)
    }
    let keep_alive = framing != UntilClose &&
      response.status != 101 &&
      request.meth != Connect &&
      !connection_token(request.headers, "close") &&
      !connection_token(response.headers, "close") &&
      (v == Http11 || connection_token(response.headers, "keep-alive"))
    let (response, decoder) = if negotiated && framing != NoBody {
      @codings.decode_head(response)
    } else {
      (response, None)
    }
    if framing == NoBody || (framing == Length(0L) && decoder is None) {
      self.release(target.origin, agent, wire, keep_alive)
      owned = false
      transferred = true
      return @model.Response::new(response.status, headers=response.headers)
    }
    let body_timer = if options.body_deadline {
      timer
    } else {
      PhaseTimer::stream(self.clock, limits)
    }
    let limit = if options.body_deadline {
      Some(
        match self.body_ceiling {
          Some(n) => n.min(options.max_body_bytes)
          None => options.max_body_bytes
        },
      )
    } else {
      None
    }
    let reader = ResponseBody::new(
      self,
      target.origin,
      agent,
      wire,
      framing,
      decoder,
      body_timer,
      limit,
      keep_alive,
    )
    let length = if decoder is None {
      match framing {
        Length(n) => Some(n)
        _ => None
      }
    } else {
      None
    }
    owned = false
    transferred = true
    return @model.Response::new(
      response.status,
      headers=response.headers,
      body=Stream(@model.StreamBody::new(reader, length?)),
    )
  }
}
