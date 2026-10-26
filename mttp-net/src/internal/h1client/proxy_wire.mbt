///|
pub async fn Wire::start_tls(
  self : Wire,
  dialer : &@connection.Dialer,
  host : String,
) -> Unit {
  if !self.pending.is_empty() {
    raise @model.TransportError(
      kind=Protocol,
      phase=Dial,
      detail="unexpected bytes after proxy CONNECT",
    )
  }
  self.conn = dialer.start_tls(self.conn, host~)
}

///|
pub async fn open_tunnel(
  wire : Wire,
  origin : Target,
  proxy : ProxyServer,
  agent : String?,
  limits : @h1.Limits,
) -> Unit {
  let mut headers = @model.Headers::of([("host", origin.authority)])
  if proxy.authorization is Some(auth) {
    headers = headers.add("proxy-authorization", auth)
  }
  if agent is Some(agent) {
    headers = headers.add("user-agent", agent)
  }
  wire.write(
    @h1.write_request_head(Connect, origin.authority, headers, NoBody, Http11),
  )
  for _ in 0..<17 {
    let (_, head) = wire.head(limits, phase=Dial)
    if head.status >= 200 {
      if head.status >= 300 {
        raise @model.TransportError(
          kind=Proxy(status=head.status),
          phase=Dial,
          detail="proxy refused CONNECT",
        )
      }
      return
    }
    if head.status == 101 {
      break
    }
  }
  raise @model.TransportError(
    kind=Protocol,
    phase=Dial,
    detail="invalid proxy informational response",
  )
}

///|
pub async fn dial_route(
  dialer : &@connection.Dialer,
  origin : Target,
  route : Route,
  agent : String?,
  limits : @h1.Limits,
) -> Wire {
  match route {
    Direct => Wire::dial(dialer, origin.host, origin.port, origin.secure)
    Forward(proxy) | Tunnel(proxy) => {
      let target = target(@model.Request::get(proxy.origin))
      let wire = Wire::dial(dialer, target.host, target.port, target.secure)
      errdefer wire.close()
      if route is Tunnel(_) {
        open_tunnel(wire, origin, proxy, agent, limits)
        wire.start_tls(dialer, origin.host)
      }
      wire
    }
  }
}
