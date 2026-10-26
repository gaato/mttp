///|
/// Sends a validated request with bounded framing, phase deadlines and
/// incremental content decoding. Stream readers own the connection slot.
pub async fn Client::send(
  self : Client,
  request : @model.Request,
  options : @client.RequestOptions,
) -> @model.Response raise @model.TransportError {
  if self.pool.control.closed {
    raise @model.TransportError(
      kind=Closed,
      phase=Pool,
      detail="backend closed",
    )
  }
  let target = target(request)
  let route = self.proxies.route(target)
  let key = route.key(target.origin)
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
  if route is Forward(proxy) && proxy.authorization is Some(auth) {
    headers = headers.add("proxy-authorization", auth)
  }
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
    route.target(target.origin, target.path, request.meth),
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
  let timer = PhaseTimer::exchange(self.clock, limits, timer=self.timer)
  self.slots.acquire(key, timer)
  let mut transferred = false
  defer (if !transferred { self.slots.release(key) })
  let agent = request.headers.get("user-agent")
  let mut fresh = false
  for ;; {
    if self.pool.control.closed {
      raise @model.TransportError(
        kind=Closed,
        phase=Pool,
        detail="backend closed",
      )
    }
    let (cached, expired) = self.pool.take(
      key,
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
          dial_route(self.dialer, target, route, agent, self.head_limits)
        })
    }
    let mut owned = true
    defer (if owned { wire.close() })
    let (v, response, uploaded) = exchange(
      wire,
      request,
      head,
      framing,
      timer,
      self.head_limits,
      self.coordination,
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
    let keep_alive = uploaded &&
      framing != UntilClose &&
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
      self.release(key, agent, wire, keep_alive)
      owned = false
      transferred = true
      return @model.Response::new(response.status, headers=response.headers)
    }
    let body_timer = if options.body_deadline {
      timer
    } else {
      PhaseTimer::stream(self.clock, limits, timer=self.timer)
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
      self, key, agent, wire, framing, decoder, body_timer, limit, keep_alive,
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
